#include "runtime.hpp"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "compositor.hpp"
#include "control.hpp"

namespace {

constexpr size_t kEventCapacity = 8;
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

SRWLOCK gLifecycleLock = SRWLOCK_INIT;
CONDITION_VARIABLE gFrameCondition = CONDITION_VARIABLE_INIT;
XrInstance gLifecycleInstance = XR_NULL_HANDLE;
XrSession gLifecycleSession = XR_NULL_HANDLE;
XrSessionState gSessionState = XR_SESSION_STATE_UNKNOWN;
bool gSessionRunning = false;
bool gWaitToken = false;
bool gFrameBegun = false;
XrTime gNextWaitDeadline = 0;
XrTime gLastPrediction = 0;
XrTime gLastEventTime = 0;
XrEventDataBuffer gEvents[kEventCapacity]{};
size_t gEventHead = 0;
size_t gEventCount = 0;

struct TimerApi {
    HANDLE timer = nullptr;
    BOOL(WINAPI* setTimer)(
        HANDLE, const LARGE_INTEGER*, LONG, PTIMERAPCROUTINE, LPVOID, BOOL) = nullptr;
};

INIT_ONCE gTimerInit = INIT_ONCE_STATIC_INIT;
TimerApi gTimerApi{};

BOOL CALLBACK initializeTimer(PINIT_ONCE, PVOID, PVOID*) {
    using CreateTimerExProc = HANDLE(WINAPI*)(
        LPSECURITY_ATTRIBUTES, LPCWSTR, DWORD, DWORD);
    using CreateTimerProc = HANDLE(WINAPI*)(
        LPSECURITY_ATTRIBUTES, BOOL, LPCWSTR);
    using SetTimerProc = BOOL(WINAPI*)(
        HANDLE, const LARGE_INTEGER*, LONG, PTIMERAPCROUTINE, LPVOID, BOOL);

    const HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
    if (kernel32 == nullptr) {
        return TRUE;
    }

    CreateTimerExProc createTimerEx = nullptr;
    CreateTimerProc createTimer = nullptr;
    SetTimerProc setTimer = nullptr;
    FARPROC address = GetProcAddress(kernel32, "CreateWaitableTimerExW");
    static_assert(sizeof(createTimerEx) == sizeof(address));
    std::memcpy(&createTimerEx, &address, sizeof(address));
    address = GetProcAddress(kernel32, "CreateWaitableTimerW");
    static_assert(sizeof(createTimer) == sizeof(address));
    std::memcpy(&createTimer, &address, sizeof(address));
    address = GetProcAddress(kernel32, "SetWaitableTimer");
    static_assert(sizeof(setTimer) == sizeof(address));
    std::memcpy(&setTimer, &address, sizeof(address));

    HANDLE timer = createTimerEx != nullptr
        ? createTimerEx(
              nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
              TIMER_ALL_ACCESS)
        : nullptr;
    if (timer == nullptr && createTimer != nullptr) {
        timer = createTimer(nullptr, FALSE, nullptr);
    }
    gTimerApi = TimerApi{timer, setTimer};
    return TRUE;
}

XrTime monotonicTime() {
    LARGE_INTEGER counter{};
    LARGE_INTEGER frequency{};
    if (!QueryPerformanceCounter(&counter) || !QueryPerformanceFrequency(&frequency) ||
        frequency.QuadPart <= 0) {
        return static_cast<XrTime>(GetTickCount64()) * 1'000'000;
    }

    const int64_t seconds = counter.QuadPart / frequency.QuadPart;
    const int64_t remainder = counter.QuadPart % frequency.QuadPart;
    return static_cast<XrTime>(seconds) * 1'000'000'000 +
           static_cast<XrTime>((remainder * 1'000'000'000) / frequency.QuadPart);
}

void resetFrameStateLocked() {
    gWaitToken = false;
    gFrameBegun = false;
    gNextWaitDeadline = 0;
    gLastPrediction = 0;
    WakeAllConditionVariable(&gFrameCondition);
}

// Wine's Sleep(14) runs at roughly 60-63 Hz on macOS, and restarting a
// relative timer after each late wake permanently accumulates that error.
// A waitable timer gives sub-millisecond requests; the absolute deadline in
// waitFrame compensates ordinary wake-up latency on the following interval.
void waitUntil(XrTime deadline) {
    InitOnceExecuteOnce(&gTimerInit, initializeTimer, nullptr, nullptr);

    while (true) {
        const XrTime now = monotonicTime();
        if (now >= deadline) {
            return;
        }
        const XrDuration remaining = deadline - now;
        if (gTimerApi.timer != nullptr && gTimerApi.setTimer != nullptr) {
            LARGE_INTEGER due{};
            due.QuadPart = -std::max<LONGLONG>(
                1, static_cast<LONGLONG>(remaining / 100));
            if (gTimerApi.setTimer(
                    gTimerApi.timer, &due, 0, nullptr, nullptr, FALSE) &&
                WaitForSingleObject(gTimerApi.timer, 1000) == WAIT_OBJECT_0) {
                continue;
            }
        }

        // Last-resort fallback. Stay below the deadline so the final yield
        // does not add an entire coarse Wine timer quantum.
        if (remaining > 2'000'000) {
            const DWORD milliseconds = static_cast<DWORD>(
                std::max<XrDuration>(1, remaining / 1'000'000 - 1));
            Sleep(milliseconds);
        } else {
            Sleep(0);
        }
    }
}

void clearEventsLocked() {
    gEventHead = 0;
    gEventCount = 0;
    std::memset(gEvents, 0, sizeof(gEvents));
}

void queueEventLocked(const void* event, size_t eventSize) {
    if (event == nullptr || eventSize > sizeof(XrEventDataBuffer)) {
        return;
    }
    if (gEventCount == kEventCapacity) {
        gEventHead = (gEventHead + 1) % kEventCapacity;
        --gEventCount;
    }
    const size_t tail = (gEventHead + gEventCount) % kEventCapacity;
    gEvents[tail] = {};
    std::memcpy(&gEvents[tail], event, eventSize);
    ++gEventCount;
}

void queueStateLocked(XrSessionState state) {
    gSessionState = state;
    XrTime eventTime = monotonicTime();
    if (eventTime <= gLastEventTime) {
        eventTime = gLastEventTime + 1;
    }
    gLastEventTime = eventTime;

    XrEventDataSessionStateChanged event{};
    event.type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;
    event.next = nullptr;
    event.session = gLifecycleSession;
    event.state = state;
    event.time = eventTime;
    queueEventLocked(&event, sizeof(event));
}

bool lifecycleMatchesLocked(XrSession session) {
    return session != XR_NULL_HANDLE && session == gLifecycleSession;
}

// Every queued session-scoped event names its session. OpenComposite aborts
// on a state event for any session but its current one, so an event that
// outlived its session (one is cleared and the next initialized under the
// same lock, but stay defensive) is dropped rather than delivered.
bool eventBelongsToLifecycleLocked(const XrEventDataBuffer& event) {
    switch (event.type) {
    case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED:
        return lifecycleMatchesLocked(
            reinterpret_cast<const XrEventDataSessionStateChanged*>(&event)->session);
    case XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED:
        return lifecycleMatchesLocked(
            reinterpret_cast<const XrEventDataInteractionProfileChanged*>(&event)->session);
    case XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING:
        return lifecycleMatchesLocked(
            reinterpret_cast<const XrEventDataReferenceSpaceChangePending*>(&event)->session);
    default:
        return true;
    }
}

}  // namespace

namespace basalt {

bool isSessionFocused(XrSession session) {
    AcquireSRWLockShared(&gLifecycleLock);
    const bool focused = lifecycleMatchesLocked(session) &&
                         gSessionState == XR_SESSION_STATE_FOCUSED;
    ReleaseSRWLockShared(&gLifecycleLock);
    return focused;
}

void queueInteractionProfileChanged(XrSession session) {
    AcquireSRWLockExclusive(&gLifecycleLock);
    if (lifecycleMatchesLocked(session) && gSessionRunning) {
        XrEventDataInteractionProfileChanged event{};
        event.type = XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED;
        event.next = nullptr;
        event.session = session;
        queueEventLocked(&event, sizeof(event));
    }
    ReleaseSRWLockExclusive(&gLifecycleLock);
}

void queueReferenceSpaceChange(
    XrSession session,
    XrTime changeTime,
    const XrPosef& poseInPreviousSpace) {
    AcquireSRWLockExclusive(&gLifecycleLock);
    if (lifecycleMatchesLocked(session) && gSessionRunning && changeTime > 0) {
        // STAGE shares LOCAL's origin, so a recenter moves both by the same
        // transform (OpenComposite tracks in STAGE).
        for (const XrReferenceSpaceType referenceSpaceType :
             {XR_REFERENCE_SPACE_TYPE_LOCAL, XR_REFERENCE_SPACE_TYPE_STAGE}) {
            XrEventDataReferenceSpaceChangePending event{};
            event.type = XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING;
            event.next = nullptr;
            event.session = session;
            event.referenceSpaceType = referenceSpaceType;
            event.changeTime = changeTime;
            event.poseValid = XR_TRUE;
            event.poseInPreviousSpace = poseInPreviousSpace;
            queueEventLocked(&event, sizeof(event));
        }
    }
    ReleaseSRWLockExclusive(&gLifecycleLock);
}

}  // namespace basalt

namespace {

constexpr XrCompositionLayerFlags kSupportedLayerFlags =
    XR_COMPOSITION_LAYER_CORRECT_CHROMATIC_ABERRATION_BIT |
    XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT |
    XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;

// A negative extent flips that axis (OpenComposite submits flipped bounds
// this way): the rect then spans [offset + extent, offset).
bool rectAxisInBounds(int32_t offset, int32_t extent, uint32_t size) {
    const int64_t first = extent < 0
        ? static_cast<int64_t>(offset) + extent : static_cast<int64_t>(offset);
    const int64_t last = extent < 0
        ? static_cast<int64_t>(offset) : static_cast<int64_t>(offset) + extent;
    return extent != 0 && first >= 0 && last <= static_cast<int64_t>(size);
}

// Validates one layer's subimage against the session's swapchains and
// captures the image the compositor would consume. *direct reports whether
// the native streamer can read it as-is: an exported swapchain whose whole
// image is submitted unflipped (the streamer ignores rects).
XrResult validateSubImage(
    XrSession session,
    const XrSwapchainSubImage& subImage,
    basalt::CompositionSubImage* captured,
    bool* direct) {
    basalt::SwapchainLayerState state{};
    if (!basalt::getSwapchainLayerState(subImage.swapchain, &state) ||
        state.session != session) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (state.depth) {
        // A depth swapchain is never a color source.
        return XR_ERROR_LAYER_INVALID;
    }
    if (subImage.imageArrayIndex >= state.arraySize) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    const XrRect2Di& rect = subImage.imageRect;
    if (!rectAxisInBounds(rect.offset.x, rect.extent.width, state.width) ||
        !rectAxisInBounds(rect.offset.y, rect.extent.height, state.height)) {
        return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    }
    if (!state.hasReleasedImage) {
        // The compositor can only consume an image the app has released.
        return XR_ERROR_LAYER_INVALID;
    }

    captured->swapchain = subImage.swapchain;
    captured->imageIndex = state.lastReleasedIndex;
    captured->imageArrayIndex = subImage.imageArrayIndex;
    captured->rect = rect;
    *direct = state.exported && rect.offset.x == 0 && rect.offset.y == 0 &&
              static_cast<int64_t>(rect.extent.width) == state.width &&
              static_cast<int64_t>(rect.extent.height) == state.height;
    return XR_SUCCESS;
}

// Validates one submitted projection layer against the session's spaces and
// swapchains, capturing per-view data for FrameReady or the compositor.
XrResult validateProjectionLayer(
    XrSession session,
    const XrCompositionLayerProjection* layer,
    basalt::CompositionLayer* captured,
    bool* direct) {
    constexpr float kMaxFovHalfAngleRadians = 1.57079633f;
    constexpr uint32_t kStereoViewCount = 2;

    if ((layer->layerFlags & ~kSupportedLayerFlags) != 0) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!basalt::isSpaceForSession(layer->space, session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (layer->viewCount != kStereoViewCount || layer->views == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    captured->kind = basalt::CompositionLayerKind::kProjection;
    captured->layerFlags = layer->layerFlags;
    captured->space = layer->space;
    *direct = true;
    for (uint32_t index = 0; index < layer->viewCount; ++index) {
        const XrCompositionLayerProjectionView& view = layer->views[index];
        if (view.type != XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW) {
            return XR_ERROR_VALIDATION_FAILURE;
        }
        if (!basalt::isPoseWellFormed(view.pose)) {
            return XR_ERROR_POSE_INVALID;
        }
        const XrFovf& fov = view.fov;
        if (!std::isfinite(fov.angleLeft) || !std::isfinite(fov.angleRight) ||
            !std::isfinite(fov.angleUp) || !std::isfinite(fov.angleDown) ||
            fov.angleLeft >= fov.angleRight || fov.angleDown >= fov.angleUp ||
            fov.angleLeft < -kMaxFovHalfAngleRadians ||
            fov.angleRight > kMaxFovHalfAngleRadians ||
            fov.angleDown < -kMaxFovHalfAngleRadians ||
            fov.angleUp > kMaxFovHalfAngleRadians) {
            return XR_ERROR_VALIDATION_FAILURE;
        }

        bool viewDirect = false;
        const XrResult result = validateSubImage(
            session, view.subImage, &captured->subImages[index], &viewDirect);
        if (XR_FAILED(result)) {
            return result;
        }
        *direct = *direct && viewDirect;
        captured->poses[index] = view.pose;
        captured->fovs[index] = view.fov;
    }
    return XR_SUCCESS;
}

XrResult validateQuadLayer(
    XrSession session,
    const XrCompositionLayerQuad* layer,
    basalt::CompositionLayer* captured) {
    if ((layer->layerFlags & ~kSupportedLayerFlags) != 0) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!basalt::isSpaceForSession(layer->space, session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (layer->eyeVisibility != XR_EYE_VISIBILITY_BOTH &&
        layer->eyeVisibility != XR_EYE_VISIBILITY_LEFT &&
        layer->eyeVisibility != XR_EYE_VISIBILITY_RIGHT) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!basalt::isPoseWellFormed(layer->pose)) {
        return XR_ERROR_POSE_INVALID;
    }
    if (!std::isfinite(layer->size.width) || !std::isfinite(layer->size.height) ||
        layer->size.width <= 0.0f || layer->size.height <= 0.0f) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    bool direct = false;
    const XrResult result = validateSubImage(
        session, layer->subImage, &captured->subImages[0], &direct);
    if (XR_FAILED(result)) {
        return result;
    }
    captured->kind = basalt::CompositionLayerKind::kQuad;
    captured->layerFlags = layer->layerFlags;
    captured->space = layer->space;
    captured->eyeVisibility = layer->eyeVisibility;
    captured->pose = layer->pose;
    captured->size = layer->size;
    return XR_SUCCESS;
}

}  // namespace

namespace basalt {

void initializeSessionLifecycle(XrInstance instance, XrSession session) {
    AcquireSRWLockExclusive(&gLifecycleLock);
    gLifecycleInstance = instance;
    gLifecycleSession = session;
    gSessionRunning = false;
    gSessionState = XR_SESSION_STATE_UNKNOWN;
    gLastEventTime = 0;
    clearEventsLocked();
    resetFrameStateLocked();
    queueStateLocked(XR_SESSION_STATE_IDLE);
    queueStateLocked(XR_SESSION_STATE_READY);
    ReleaseSRWLockExclusive(&gLifecycleLock);
}

void invalidateSessionLifecycle(XrSession session) {
    AcquireSRWLockExclusive(&gLifecycleLock);
    if (lifecycleMatchesLocked(session)) {
        gLifecycleInstance = XR_NULL_HANDLE;
        gLifecycleSession = XR_NULL_HANDLE;
        gSessionState = XR_SESSION_STATE_UNKNOWN;
        gSessionRunning = false;
        clearEventsLocked();
        resetFrameStateLocked();
    }
    ReleaseSRWLockExclusive(&gLifecycleLock);
}

XrResult XRAPI_CALL pollEvent(
    XrInstance instance,
    XrEventDataBuffer* eventData) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (eventData == nullptr || eventData->type != XR_TYPE_EVENT_DATA_BUFFER) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    XrEventDataBuffer event{};
    bool found = false;
    while (instance == gLifecycleInstance && gEventCount > 0 && !found) {
        event = gEvents[gEventHead];
        gEventHead = (gEventHead + 1) % kEventCapacity;
        --gEventCount;
        found = eventBelongsToLifecycleLocked(event);
    }
    ReleaseSRWLockExclusive(&gLifecycleLock);
    if (!found) {
        return XR_EVENT_UNAVAILABLE;
    }

    std::memset(eventData, 0, sizeof(*eventData));
    std::memcpy(eventData, &event, sizeof(event));
    return XR_SUCCESS;
}

XrResult XRAPI_CALL beginSession(
    XrSession session,
    const XrSessionBeginInfo* beginInfo) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (beginInfo == nullptr || beginInfo->type != XR_TYPE_SESSION_BEGIN_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (beginInfo->primaryViewConfigurationType !=
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_RUNNING;
    }
    if (gSessionState != XR_SESSION_STATE_READY) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_READY;
    }

    gSessionRunning = true;
    resetFrameStateLocked();
    ReleaseSRWLockExclusive(&gLifecycleLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL requestExitSession(XrSession session) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }
    if (gSessionState != XR_SESSION_STATE_STOPPING) {
        if (gSessionState == XR_SESSION_STATE_READY) {
            queueStateLocked(XR_SESSION_STATE_SYNCHRONIZED);
        }
        if (gSessionState == XR_SESSION_STATE_FOCUSED) {
            queueStateLocked(XR_SESSION_STATE_VISIBLE);
        }
        if (gSessionState == XR_SESSION_STATE_VISIBLE) {
            queueStateLocked(XR_SESSION_STATE_SYNCHRONIZED);
        }
        queueStateLocked(XR_SESSION_STATE_STOPPING);
    }
    WakeAllConditionVariable(&gFrameCondition);
    ReleaseSRWLockExclusive(&gLifecycleLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL endSession(XrSession session) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }
    if (gSessionState != XR_SESSION_STATE_STOPPING) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_STOPPING;
    }

    gSessionRunning = false;
    resetFrameStateLocked();
    queueStateLocked(XR_SESSION_STATE_IDLE);
    queueStateLocked(XR_SESSION_STATE_EXITING);
    ReleaseSRWLockExclusive(&gLifecycleLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL waitFrame(
    XrSession session,
    const XrFrameWaitInfo* frameWaitInfo,
    XrFrameState* frameState) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if ((frameWaitInfo != nullptr && frameWaitInfo->type != XR_TYPE_FRAME_WAIT_INFO) ||
        frameState == nullptr || frameState->type != XR_TYPE_FRAME_STATE) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }

    while (gWaitToken && gSessionRunning && lifecycleMatchesLocked(session)) {
        SleepConditionVariableSRW(
            &gFrameCondition, &gLifecycleLock, INFINITE, 0);
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }

    // Do not let the application's next frame enter the GPU/control/composer
    // pipeline until the streamer has consumed the previous one. The control
    // wait owns a separate lock and may disconnect, so never hold the frame
    // lifecycle lock across it.
    ReleaseSRWLockExclusive(&gLifecycleLock);
    controlWaitForFrameBudget(session);
    // The negotiated headset refresh period (HELLO_ACK); 72 Hz when headless.
    const XrDuration displayPeriod = controlDisplayPeriod(session);
    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }

    const XrTime waitDeadline = gNextWaitDeadline;
    XrTime now = monotonicTime();
    if (waitDeadline > now) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        waitUntil(waitDeadline);
        AcquireSRWLockExclusive(&gLifecycleLock);
        if (!lifecycleMatchesLocked(session)) {
            ReleaseSRWLockExclusive(&gLifecycleLock);
            return XR_ERROR_HANDLE_INVALID;
        }
        if (!gSessionRunning) {
            ReleaseSRWLockExclusive(&gLifecycleLock);
            return XR_ERROR_SESSION_NOT_RUNNING;
        }
        now = monotonicTime();
    }

    // Advance the scheduled deadline, not the actual (possibly late) wake
    // time. This preserves the requested average cadence without issuing
    // catch-up frames when the process misses a whole display period.
    XrTime nextDeadline = waitDeadline == 0
                              ? now + displayPeriod
                              : waitDeadline + displayPeriod;
    if (nextDeadline <= now) {
        const XrDuration missed = now - nextDeadline;
        nextDeadline += (missed / displayPeriod + 1) * displayPeriod;
    }
    gNextWaitDeadline = nextDeadline;

    const XrTime predictedDisplayTime = std::max(
        now + displayPeriod,
        gLastPrediction == 0 ? static_cast<XrTime>(1)
                             : gLastPrediction + displayPeriod);
    gLastPrediction = predictedDisplayTime;
    gWaitToken = true;
    frameState->predictedDisplayTime = predictedDisplayTime;
    frameState->predictedDisplayPeriod = displayPeriod;
    // With the streamer daemon consuming frames, submitted images are
    // displayed; headless sessions keep telling the app not to render.
    frameState->shouldRender = controlActive(session) ? XR_TRUE : XR_FALSE;
    ReleaseSRWLockExclusive(&gLifecycleLock);
    controlNotePredictedDisplayTime(session, predictedDisplayTime);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL beginFrame(
    XrSession session,
    const XrFrameBeginInfo* frameBeginInfo) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (frameBeginInfo != nullptr && frameBeginInfo->type != XR_TYPE_FRAME_BEGIN_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }
    if (!gWaitToken) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_CALL_ORDER_INVALID;
    }

    gWaitToken = false;
    const bool discarded = gFrameBegun;
    gFrameBegun = true;
    WakeAllConditionVariable(&gFrameCondition);
    ReleaseSRWLockExclusive(&gLifecycleLock);
    return discarded ? XR_FRAME_DISCARDED : XR_SUCCESS;
}

XrResult XRAPI_CALL endFrame(
    XrSession session,
    const XrFrameEndInfo* frameEndInfo) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (frameEndInfo == nullptr || frameEndInfo->type != XR_TYPE_FRAME_END_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gLifecycleLock);
    if (!lifecycleMatchesLocked(session)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!gSessionRunning) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_SESSION_NOT_RUNNING;
    }
    if (!gFrameBegun) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_CALL_ORDER_INVALID;
    }
    if (frameEndInfo->displayTime <= 0) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_TIME_INVALID;
    }
    if (frameEndInfo->environmentBlendMode != XR_ENVIRONMENT_BLEND_MODE_OPAQUE) {
        const XrResult result =
            frameEndInfo->environmentBlendMode == XR_ENVIRONMENT_BLEND_MODE_ADDITIVE ||
                    frameEndInfo->environmentBlendMode == XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND
                ? XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED
                : XR_ERROR_VALIDATION_FAILURE;
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return result;
    }
    if (frameEndInfo->layerCount >
        static_cast<uint32_t>(XR_MIN_COMPOSITION_LAYERS_SUPPORTED)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_LAYER_LIMIT_EXCEEDED;
    }
    if (frameEndInfo->layerCount > 0 && frameEndInfo->layers == nullptr) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_ERROR_VALIDATION_FAILURE;
    }
    // Layers are captured in submission order. Only the first projection
    // layer is displayed; later ones are validated like before.
    basalt::CompositionFrame composition{};
    bool haveProjection = false;
    bool projectionDirect = false;
    uint32_t projectionLayer = 0;
    bool haveQuads = false;
    for (uint32_t index = 0; index < frameEndInfo->layerCount; ++index) {
        const XrCompositionLayerBaseHeader* layer = frameEndInfo->layers[index];
        XrResult layerResult = XR_SUCCESS;
        basalt::CompositionLayer captured{};
        if (layer == nullptr) {
            layerResult = XR_ERROR_LAYER_INVALID;
        } else if (layer->type == XR_TYPE_COMPOSITION_LAYER_PROJECTION) {
            bool direct = false;
            layerResult = validateProjectionLayer(
                session,
                reinterpret_cast<const XrCompositionLayerProjection*>(layer),
                &captured, &direct);
            if (XR_SUCCEEDED(layerResult) && !haveProjection) {
                projectionLayer = composition.layerCount;
                composition.layers[composition.layerCount++] = captured;
                haveProjection = true;
                projectionDirect = direct;
            }
        } else if (layer->type == XR_TYPE_COMPOSITION_LAYER_QUAD) {
            layerResult = validateQuadLayer(
                session,
                reinterpret_cast<const XrCompositionLayerQuad*>(layer),
                &captured);
            if (XR_SUCCEEDED(layerResult)) {
                composition.layers[composition.layerCount++] = captured;
                haveQuads = true;
            }
        } else {
            // Extension layers (cylinder, cube, equirect) are not enabled.
            layerResult = XR_ERROR_LAYER_INVALID;
        }
        if (XR_FAILED(layerResult)) {
            ReleaseSRWLockExclusive(&gLifecycleLock);
            return layerResult;
        }
    }

    gFrameBegun = false;
    if (gSessionState == XR_SESSION_STATE_READY) {
        queueStateLocked(XR_SESSION_STATE_SYNCHRONIZED);
    }
    // Once the daemon displays submitted frames the session is visible, and
    // nothing else contends for input, so it is also focused.
    if (gSessionState == XR_SESSION_STATE_SYNCHRONIZED && controlActive(session)) {
        queueStateLocked(XR_SESSION_STATE_VISIBLE);
        queueStateLocked(XR_SESSION_STATE_FOCUSED);
    }
    const uint64_t questTrackingTimestamp = haveProjection
        ? locatedViewsQuestTimestamp(session, frameEndInfo->displayTime) : 0;
    ReleaseSRWLockExclusive(&gLifecycleLock);

    // The streamer reads whole BGRA eye images. A frame that already has
    // that shape is exported zero-copy exactly as before; anything else is
    // drawn by the runtime compositor into its own exported images.
    basalt::ControlFrameView frameViews[2]{};
    if (haveProjection) {
        const basalt::CompositionLayer& projection =
            composition.layers[projectionLayer];
        for (uint32_t eye = 0; eye < 2; ++eye) {
            const basalt::CompositionSubImage& subImage = projection.subImages[eye];
            frameViews[eye].swapchainId =
                reinterpret_cast<uintptr_t>(subImage.swapchain);
            frameViews[eye].imageIndex = subImage.imageIndex;
            frameViews[eye].imageArrayIndex = subImage.imageArrayIndex;
            frameViews[eye].rect = subImage.rect;
            frameViews[eye].pose = projection.poses[eye];
            frameViews[eye].fov = projection.fovs[eye];
        }
    }
    if (haveQuads || (haveProjection && !projectionDirect)) {
        const bool composited = basalt::compositorSubmitFrame(
            session, frameEndInfo->displayTime, questTrackingTimestamp,
            composition);
        if (!composited && haveProjection && projectionDirect) {
            // Without a usable compositor, still show the projection rather
            // than dropping the frame (its quads are lost).
            controlFrameReady(
                frameEndInfo->displayTime,
                questTrackingTimestamp,
                frameViews, 2, true);
        }
    } else if (haveProjection) {
        controlFrameReady(
            frameEndInfo->displayTime,
            questTrackingTimestamp,
            frameViews, 2, true);
    }
    return XR_SUCCESS;
}

}  // namespace basalt
