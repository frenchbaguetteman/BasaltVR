#include "runtime.hpp"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "control.hpp"

namespace {

constexpr XrDuration kDisplayPeriod = 13'888'889;
// A session emits at most ten state changes (IDLE through EXITING), and state
// changes are never dropped, so the queue always has room to shed the oldest
// other event when an application stops polling.
constexpr size_t kEventCapacity = 16;
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
uint32_t gLostEventCount = 0;

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
    gLostEventCount = 0;
    std::memset(gEvents, 0, sizeof(gEvents));
}

void queueEventLocked(const void* event, size_t eventSize) {
    if (event == nullptr || eventSize > sizeof(XrEventDataBuffer)) {
        return;
    }
    if (gEventCount == kEventCapacity) {
        // Drop the oldest event that is not a session state change; the
        // application learns of the loss through XrEventDataEventsLost.
        size_t dropped = 0;
        while (dropped + 1 < gEventCount &&
               gEvents[(gEventHead + dropped) % kEventCapacity].type ==
                   XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
            ++dropped;
        }
        for (size_t offset = dropped; offset + 1 < gEventCount; ++offset) {
            gEvents[(gEventHead + offset) % kEventCapacity] =
                gEvents[(gEventHead + offset + 1) % kEventCapacity];
        }
        --gEventCount;
        ++gLostEventCount;
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
    // LOCAL_FLOOR and STAGE share LOCAL's origin, so a recenter moves them
    // by the same pose. Report LOCAL always and the floor spaces once the
    // application has created one.
    const bool includeLocalFloor =
        sessionHasReferenceSpace(session, XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR);
    const bool includeStage =
        sessionHasReferenceSpace(session, XR_REFERENCE_SPACE_TYPE_STAGE);
    AcquireSRWLockExclusive(&gLifecycleLock);
    if (lifecycleMatchesLocked(session) && gSessionRunning && changeTime > 0) {
        XrEventDataReferenceSpaceChangePending event{};
        event.type = XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING;
        event.next = nullptr;
        event.session = session;
        event.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        event.changeTime = changeTime;
        event.poseValid = XR_TRUE;
        event.poseInPreviousSpace = poseInPreviousSpace;
        queueEventLocked(&event, sizeof(event));
        if (includeLocalFloor) {
            event.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR;
            queueEventLocked(&event, sizeof(event));
        }
        if (includeStage) {
            event.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
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

// Validates a layer's swapchain sub-image: the swapchain must belong to the
// session, the array slice and rectangle must lie inside it, and the app must
// have released an image the compositor can read.
XrResult validateSubImage(
    XrSession session,
    const XrSwapchainSubImage& subImage,
    uint32_t* lastReleasedIndex) {
    XrSession swapchainSession = XR_NULL_HANDLE;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t arraySize = 0;
    bool hasReleasedImage = false;
    if (!basalt::getSwapchainSubmitState(
            subImage.swapchain,
            &swapchainSession,
            &width,
            &height,
            &arraySize,
            &hasReleasedImage,
            lastReleasedIndex) ||
        swapchainSession != session) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (subImage.imageArrayIndex >= arraySize) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    const XrRect2Di& rect = subImage.imageRect;
    if (rect.offset.x < 0 || rect.offset.y < 0 ||
        rect.extent.width <= 0 || rect.extent.height <= 0 ||
        static_cast<int64_t>(rect.offset.x) + rect.extent.width >
            static_cast<int64_t>(width) ||
        static_cast<int64_t>(rect.offset.y) + rect.extent.height >
            static_cast<int64_t>(height)) {
        return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    }
    if (!hasReleasedImage) {
        // The compositor can only consume an image the app has released.
        return XR_ERROR_LAYER_INVALID;
    }
    return XR_SUCCESS;
}

// Validates one submitted projection layer against the session's spaces and
// swapchains. When outViews is non-null, the validated per-view submission
// data is captured for the control-socket FrameReady handoff.
XrResult validateProjectionLayer(
    XrSession session,
    const XrCompositionLayerProjection* layer,
    basalt::ControlFrameView* outViews) {
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

        uint32_t lastReleasedIndex = 0;
        const XrResult subImageResult =
            validateSubImage(session, view.subImage, &lastReleasedIndex);
        if (XR_FAILED(subImageResult)) {
            return subImageResult;
        }

        if (outViews != nullptr) {
            outViews[index].swapchainId =
                reinterpret_cast<uintptr_t>(view.subImage.swapchain);
            outViews[index].imageIndex = lastReleasedIndex;
            outViews[index].imageArrayIndex = view.subImage.imageArrayIndex;
            outViews[index].rect = view.subImage.imageRect;
            outViews[index].pose = view.pose;
            outViews[index].fov = view.fov;
        }
    }
    return XR_SUCCESS;
}

// Quad layers are validated like any submitted layer but not yet composed:
// only the first projection layer reaches the streamer.
XrResult validateQuadLayer(
    XrSession session,
    const XrCompositionLayerQuad* layer) {
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
    uint32_t lastReleasedIndex = 0;
    return validateSubImage(session, layer->subImage, &lastReleasedIndex);
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
    if (instance != gLifecycleInstance ||
        (gEventCount == 0 && gLostEventCount == 0)) {
        ReleaseSRWLockExclusive(&gLifecycleLock);
        return XR_EVENT_UNAVAILABLE;
    }

    XrEventDataBuffer event{};
    if (gLostEventCount > 0) {
        auto* lost = reinterpret_cast<XrEventDataEventsLost*>(&event);
        lost->type = XR_TYPE_EVENT_DATA_EVENTS_LOST;
        lost->next = nullptr;
        lost->lostEventCount = gLostEventCount;
        gLostEventCount = 0;
    } else {
        event = gEvents[gEventHead];
        gEventHead = (gEventHead + 1) % kEventCapacity;
        --gEventCount;
    }
    ReleaseSRWLockExclusive(&gLifecycleLock);

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
                              ? now + kDisplayPeriod
                              : waitDeadline + kDisplayPeriod;
    if (nextDeadline <= now) {
        const XrDuration missed = now - nextDeadline;
        nextDeadline += (missed / kDisplayPeriod + 1) * kDisplayPeriod;
    }
    gNextWaitDeadline = nextDeadline;

    const XrTime predictedDisplayTime = std::max(
        now + kDisplayPeriod,
        gLastPrediction == 0 ? static_cast<XrTime>(1)
                             : gLastPrediction + kDisplayPeriod);
    gLastPrediction = predictedDisplayTime;
    gWaitToken = true;
    frameState->predictedDisplayTime = predictedDisplayTime;
    frameState->predictedDisplayPeriod = kDisplayPeriod;
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
    basalt::ControlFrameView frameViews[2]{};
    bool haveFrameViews = false;
    for (uint32_t index = 0; index < frameEndInfo->layerCount; ++index) {
        const XrCompositionLayerBaseHeader* layer = frameEndInfo->layers[index];
        XrResult layerResult = XR_SUCCESS;
        if (layer == nullptr) {
            layerResult = XR_ERROR_LAYER_INVALID;
        } else if (layer->type == XR_TYPE_COMPOSITION_LAYER_PROJECTION) {
            // The first projection layer feeds the FrameReady handoff; the
            // native compositor composes additional layers later.
            layerResult = validateProjectionLayer(
                session,
                reinterpret_cast<const XrCompositionLayerProjection*>(layer),
                haveFrameViews ? nullptr : frameViews);
            haveFrameViews = true;
        } else if (layer->type == XR_TYPE_COMPOSITION_LAYER_QUAD) {
            // Validated, then left out until the native compositor composes
            // quads. A frame with only quads therefore submits no frame,
            // exactly like a frame with no layers.
            layerResult = validateQuadLayer(
                session, reinterpret_cast<const XrCompositionLayerQuad*>(layer));
        } else {
            // Extension layers wait for the native compositor.
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
    const uint64_t questTrackingTimestamp = haveFrameViews
        ? locatedViewsQuestTimestamp(session, frameEndInfo->displayTime) : 0;
    ReleaseSRWLockExclusive(&gLifecycleLock);
    if (haveFrameViews) {
        controlFrameReady(
            frameEndInfo->displayTime,
            questTrackingTimestamp,
            frameViews, 2);
    }
    return XR_SUCCESS;
}

}  // namespace basalt
