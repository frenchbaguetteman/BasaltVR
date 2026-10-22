#include <winsock2.h>
#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <cerrno>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <set>
#include <vector>

#include "basalt_test_colors.h"

namespace {

// Must match BASALT_GUID_IOSURFACE_ID in the Basalt DXMT fork
// (runtime/dxmt-fork). {DD807311-529E-4856-A5C0-48BED2048129}
constexpr GUID kBasaltIOSurfaceIdGuid = {
    0xdd807311, 0x529e, 0x4856, {0xa5, 0xc0, 0x48, 0xbe, 0xd2, 0x04, 0x81, 0x29}};

// BASALT_EXPECT_IOSURFACE=1 asserts that every swapchain texture republishes
// a nonzero, distinct IOSurfaceID (forked DXMT with DXMT_BASALT_IOSURFACE=1);
// otherwise the GUID must be absent (stock DXMT, or the fork gate off).
// BASALT_EXPECT_HEAD_POSE=1 additionally checks the native test daemon's
// deterministic pose; BASALT_REQUIRE_HEAD_POSE=1 accepts any fresh live pose.
bool expectBasaltIOSurface() {
    const char* value = std::getenv("BASALT_EXPECT_IOSURFACE");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

// When the harness provides a control daemon (BASALT_CONTROL set), the
// runtime reports shouldRender, reaches VISIBLE/FOCUSED, and lets
// xrSyncActions/haptics succeed; headless it must behave exactly as before.
bool expectConnected() {
    const char* value = std::getenv("BASALT_CONTROL");
    return value != nullptr && value[0] != '\0';
}

// A connected session's control socket must not be inheritable: The Lab
// launches Robot Repair with CreateProcess(bInheritHandles=TRUE) and exits,
// and an inherited socket kept its connection open in the child, so the
// streamer never saw the old session end and the new one ran headless.
// Scans this process's handle table for sockets; at least one (the control
// connection) must exist and none may carry HANDLE_FLAG_INHERIT.
bool controlSocketIsNotInheritable() {
    WSADATA wsaData{};
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        std::fputs("FAIL: WSAStartup for the socket inheritance check\n", stderr);
        return false;
    }
    int sockets = 0;
    int inheritable = 0;
    for (uintptr_t value = 4; value < 0x10000; value += 4) {
        const SOCKET candidate = static_cast<SOCKET>(value);
        int type = 0;
        int length = sizeof(type);
        if (getsockopt(candidate, SOL_SOCKET, SO_TYPE,
                       reinterpret_cast<char*>(&type), &length) != 0) {
            continue;
        }
        DWORD flags = 0;
        if (!GetHandleInformation(reinterpret_cast<HANDLE>(value), &flags)) {
            continue;
        }
        ++sockets;
        if ((flags & HANDLE_FLAG_INHERIT) != 0) {
            ++inheritable;
        }
    }
    WSACleanup();
    if (sockets == 0 || inheritable != 0) {
        std::fprintf(stderr,
                     "FAIL: control socket inheritance: %d socket(s), %d inheritable "
                     "(a child process would keep the session connection open)\n",
                     sockets, inheritable);
        return false;
    }
    return true;
}

bool expectInjectedHeadPose() {
    const char* value = std::getenv("BASALT_EXPECT_HEAD_POSE");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

bool requireHeadPose() {
    const char* value = std::getenv("BASALT_REQUIRE_HEAD_POSE");
    return expectInjectedHeadPose() ||
           (value != nullptr && std::strcmp(value, "1") == 0);
}

bool requireControllerInput() {
    const char* value = std::getenv("BASALT_REQUIRE_CONTROLLER_INPUT");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

uint32_t expectedViewDimension(const char* name, uint32_t fallback) {
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') {
        return fallback;
    }
    char* end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    return end != value && *end == '\0' && parsed <= UINT32_MAX
        ? static_cast<uint32_t>(parsed) : fallback;
}

bool nearlyEqual(float a, float b, float tolerance = 0.0001f) {
    return std::fabs(a - b) <= tolerance;
}

struct SmokeOptions {
    uint64_t renderFrames = 20;
    bool visual = false;
};

struct VisualControllerMarker {
    bool active = false;
    float x = 0.5f;
    float y = 0.5f;
    float squeeze = 0.0f;
    float radius = 0.02f;
};

XrVector3f rotateVector(const XrQuaternionf& rotation, const XrVector3f& vector) {
    const XrVector3f twiceCross{
        2.0f * (rotation.y * vector.z - rotation.z * vector.y),
        2.0f * (rotation.z * vector.x - rotation.x * vector.z),
        2.0f * (rotation.x * vector.y - rotation.y * vector.x),
    };
    return {
        vector.x + rotation.w * twiceCross.x +
            (rotation.y * twiceCross.z - rotation.z * twiceCross.y),
        vector.y + rotation.w * twiceCross.y +
            (rotation.z * twiceCross.x - rotation.x * twiceCross.z),
        vector.z + rotation.w * twiceCross.z +
            (rotation.x * twiceCross.y - rotation.y * twiceCross.x),
    };
}

VisualControllerMarker projectWorldMarker(
    const XrVector3f& pointInLocal,
    const XrView& eye,
    float worldRadius,
    float squeeze = 0.0f) {
    const XrVector3f localDelta{
        pointInLocal.x - eye.pose.position.x,
        pointInLocal.y - eye.pose.position.y,
        pointInLocal.z - eye.pose.position.z,
    };
    const XrQuaternionf inverseEye{
        -eye.pose.orientation.x,
        -eye.pose.orientation.y,
        -eye.pose.orientation.z,
        eye.pose.orientation.w,
    };
    const XrVector3f inEye = rotateVector(inverseEye, localDelta);
    if (!std::isfinite(inEye.x) || !std::isfinite(inEye.y) ||
        !std::isfinite(inEye.z) || inEye.z >= -0.05f) {
        return {};
    }
    const float left = std::tan(eye.fov.angleLeft);
    const float right = std::tan(eye.fov.angleRight);
    const float down = std::tan(eye.fov.angleDown);
    const float up = std::tan(eye.fov.angleUp);
    const float horizontal = inEye.x / -inEye.z;
    const float vertical = inEye.y / -inEye.z;
    if (!(right > left) || !(up > down)) {
        return {};
    }
    VisualControllerMarker marker{};
    marker.active = true;
    marker.x = (horizontal - left) / (right - left);
    marker.y = 1.0f - (vertical - down) / (up - down);
    marker.squeeze = std::clamp(squeeze, 0.0f, 1.0f);
    marker.radius = std::clamp(
        worldRadius / -inEye.z / (right - left), 0.004f, 0.15f);
    return marker;
}

XrVector3f transformPoint(const XrPosef& pose, const XrVector3f& point) {
    const XrVector3f rotated = rotateVector(pose.orientation, point);
    return {pose.position.x + rotated.x,
            pose.position.y + rotated.y,
            pose.position.z + rotated.z};
}

XrPosef levelPoseToLocalUp(const XrPosef& pose) {
    // LOCAL is Y-up. Preserve the user's initial facing direction, but remove
    // headset pitch/roll so a slightly tilted head does not bake a tilted
    // horizon into the world-fixed acceptance grid.
    const XrVector3f forward =
        rotateVector(pose.orientation, {0.0f, 0.0f, -1.0f});
    const float horizontalLength = std::hypot(forward.x, forward.z);
    if (!std::isfinite(horizontalLength) || horizontalLength < 0.001f) {
        return {{0.0f, 0.0f, 0.0f, 1.0f}, pose.position};
    }
    const float yaw = std::atan2(-forward.x, -forward.z);
    const float halfYaw = yaw * 0.5f;
    return {{0.0f, std::sin(halfYaw), 0.0f, std::cos(halfYaw)}, pose.position};
}

bool parseOptions(int argc, char** argv, SmokeOptions& options) {
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--visual") == 0) {
            options.visual = true;
            continue;
        }
        if (std::strcmp(argv[index], "--render-frames") == 0 && index + 1 < argc) {
            errno = 0;
            char* end = nullptr;
            const unsigned long long value = std::strtoull(argv[++index], &end, 10);
            if (errno != 0 || end == argv[index] || *end != '\0' || value == 0 ||
                value > 1'000'000) {
                std::fprintf(
                    stderr,
                    "FAIL: --render-frames expects an integer from 1 to 1000000\n");
                return false;
            }
            options.renderFrames = static_cast<uint64_t>(value);
            continue;
        }
        std::fprintf(
            stderr,
            "usage: d3d11_runtime_smoke.exe [--render-frames N] [--visual]\n");
        return false;
    }
    return true;
}

// Renders the deterministic per-frame color into a swapchain texture so the
// control daemon can verify the delivered IOSurface contents cross-process.
bool clearSwapchainTexture(
    ID3D11Device* device,
    ID3D11DeviceContext* context,
    ID3D11Texture2D* texture,
    uint64_t frameNumber,
    bool visual,
    const VisualControllerMarker* marker = nullptr,
    const std::vector<VisualControllerMarker>* landmarks = nullptr,
    uint32_t arraySlice = 0) {
    D3D11_TEXTURE2D_DESC textureDescription{};
    texture->GetDesc(&textureDescription);
    if (arraySlice >= textureDescription.ArraySize) {
        return false;
    }
    D3D11_RENDER_TARGET_VIEW_DESC viewDescription{};
    D3D11_RENDER_TARGET_VIEW_DESC* requestedView = nullptr;
    if (textureDescription.ArraySize > 1) {
        viewDescription.Format = textureDescription.Format;
        viewDescription.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DARRAY;
        viewDescription.Texture2DArray.MipSlice = 0;
        viewDescription.Texture2DArray.FirstArraySlice = arraySlice;
        viewDescription.Texture2DArray.ArraySize = 1;
        requestedView = &viewDescription;
    }
    ID3D11RenderTargetView* renderTarget = nullptr;
    if (FAILED(device->CreateRenderTargetView(
            texture, requestedView, &renderTarget))) {
        return false;
    }
    float color[4]{};
    if (visual) {
        // A slow eight-second blue pulse is conspicuous in-headset without
        // turning the long integration test into a rapid flashing stimulus.
        constexpr double kTau = 6.28318530717958647692;
        constexpr double kNominalFps = 72.0;
        const double phase = kTau * static_cast<double>(frameNumber) /
                             (kNominalFps * 8.0);
        const float brightness = static_cast<float>(0.82 + 0.18 * std::sin(phase));
        color[0] = 0.10f * brightness;
        color[1] = 0.38f * brightness;
        color[2] = 0.72f * brightness;
        color[3] = 1.0f;
    } else {
        const uint32_t packed = basaltTestClearColor(frameNumber);
        color[0] = static_cast<float>(packed & 0xff) / 255.0f;
        color[1] = static_cast<float>((packed >> 8) & 0xff) / 255.0f;
        color[2] = static_cast<float>((packed >> 16) & 0xff) / 255.0f;
        color[3] = 1.0f;
    }
    context->ClearRenderTargetView(renderTarget, color);
    const bool hasLandmarks = landmarks != nullptr && !landmarks->empty();
    const bool hasController = marker != nullptr && marker->active &&
        marker->x >= -0.05f && marker->x <= 1.05f &&
        marker->y >= -0.05f && marker->y <= 1.05f;
    if (visual && (hasLandmarks || hasController)) {
        ID3D11DeviceContext1* context1 = nullptr;
        const HRESULT query = context->QueryInterface(
            IID_ID3D11DeviceContext1, reinterpret_cast<void**>(&context1));
        if (FAILED(query) || context1 == nullptr) {
            renderTarget->Release();
            return false;
        }
        const LONG width = static_cast<LONG>(textureDescription.Width);
        const LONG height = static_cast<LONG>(textureDescription.Height);
        if (hasLandmarks) {
            std::vector<D3D11_RECT> landmarkRectangles;
            landmarkRectangles.reserve(landmarks->size());
            for (const VisualControllerMarker& landmark : *landmarks) {
                if (!landmark.active || landmark.x < -0.05f || landmark.x > 1.05f ||
                    landmark.y < -0.05f || landmark.y > 1.05f) {
                    continue;
                }
                const LONG x = static_cast<LONG>(
                    std::clamp(landmark.x, 0.0f, 1.0f) * static_cast<float>(width));
                const LONG y = static_cast<LONG>(
                    std::clamp(landmark.y, 0.0f, 1.0f) * static_cast<float>(height));
                const LONG radius = (std::max)(2L, static_cast<LONG>(
                    landmark.radius * static_cast<float>(width)));
                landmarkRectangles.push_back({
                    (std::max)(0L, x - radius), (std::max)(0L, y - radius),
                    (std::min)(width, x + radius + 1),
                    (std::min)(height, y + radius + 1),
                });
            }
            if (!landmarkRectangles.empty()) {
                const float landmarkColor[4] = {0.70f, 0.82f, 1.0f, 1.0f};
                context1->ClearView(
                    renderTarget, landmarkColor, landmarkRectangles.data(),
                    static_cast<UINT>(landmarkRectangles.size()));
            }
        }
        if (hasController) {
            const LONG centerX = static_cast<LONG>(
                std::clamp(marker->x, 0.0f, 1.0f) * static_cast<float>(width));
            const LONG centerY = static_cast<LONG>(
                std::clamp(marker->y, 0.0f, 1.0f) * static_cast<float>(height));
            const LONG arm = (std::max)(4L, static_cast<LONG>(
                marker->radius * static_cast<float>(width)));
            const LONG thickness = (std::max)(1L, width / 80);
            const LONG core = thickness * 2 +
                static_cast<LONG>(std::clamp(marker->squeeze, 0.0f, 1.0f) * arm);
            const D3D11_RECT rectangles[] = {
                {(std::max)(0L, centerX - thickness),
                 (std::max)(0L, centerY - arm),
                 (std::min)(width, centerX + thickness + 1),
                 (std::min)(height, centerY + arm + 1)},
                {(std::max)(0L, centerX - arm),
                 (std::max)(0L, centerY - thickness),
                 (std::min)(width, centerX + arm + 1),
                 (std::min)(height, centerY + thickness + 1)},
                {(std::max)(0L, centerX - core),
                 (std::max)(0L, centerY - core),
                 (std::min)(width, centerX + core + 1),
                 (std::min)(height, centerY + core + 1)},
            };
            const float markerColor[4] = {
                0.25f + 0.75f * std::clamp(marker->squeeze, 0.0f, 1.0f),
                1.0f,
                0.20f,
                1.0f,
            };
            context1->ClearView(
                renderTarget, markerColor, rectangles,
                static_cast<UINT>(sizeof(rectangles) / sizeof(rectangles[0])));
        }
        context1->Release();
    }
    renderTarget->Release();
    return true;
}

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

bool luidEqual(const LUID& left, const LUID& right) {
    return left.LowPart == right.LowPart && left.HighPart == right.HighPart;
}

int fail(const char* operation, XrResult result) {
    std::fprintf(stderr, "FAIL: %s returned XrResult %d\n", operation, result);
    return 1;
}

int failHresult(const char* operation, HRESULT result) {
    std::fprintf(stderr, "FAIL: %s returned HRESULT 0x%08lx\n",
                 operation, static_cast<unsigned long>(result));
    return 1;
}

bool expectSessionState(
    XrInstance instance,
    XrSession session,
    XrSessionState expectedState) {
    XrEventDataBuffer eventData{};
    eventData.type = XR_TYPE_EVENT_DATA_BUFFER;
    const XrResult result = xrPollEvent(instance, &eventData);
    if (result != XR_SUCCESS ||
        eventData.type != XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
        std::fprintf(
            stderr,
            "FAIL: xrPollEvent expected session state %d, got XrResult %d/type %d\n",
            static_cast<int>(expectedState),
            result,
            static_cast<int>(eventData.type));
        return false;
    }

    const auto* changed =
        reinterpret_cast<const XrEventDataSessionStateChanged*>(&eventData);
    if (changed->session != session || changed->state != expectedState ||
        changed->time <= 0 || changed->next != nullptr) {
        std::fprintf(
            stderr,
            "FAIL: malformed session event (wanted state %d, got %d)\n",
            static_cast<int>(expectedState),
            static_cast<int>(changed->state));
        return false;
    }
    return true;
}

bool expectNoEvent(XrInstance instance) {
    XrEventDataBuffer eventData{};
    eventData.type = XR_TYPE_EVENT_DATA_BUFFER;
    const XrResult result = xrPollEvent(instance, &eventData);
    if (result != XR_EVENT_UNAVAILABLE) {
        std::fprintf(
            stderr,
            "FAIL: xrPollEvent expected XR_EVENT_UNAVAILABLE, got %d\n",
            result);
        return false;
    }
    return true;
}

bool expectInteractionProfileChanged(XrInstance instance, XrSession session) {
    XrEventDataBuffer eventData{};
    eventData.type = XR_TYPE_EVENT_DATA_BUFFER;
    const XrResult result = xrPollEvent(instance, &eventData);
    if (result != XR_SUCCESS ||
        eventData.type != XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED) {
        std::fprintf(
            stderr,
            "FAIL: expected interaction-profile event, got XrResult %d/type %d\n",
            result, static_cast<int>(eventData.type));
        return false;
    }
    const auto* changed =
        reinterpret_cast<const XrEventDataInteractionProfileChanged*>(&eventData);
    if (changed->session != session || changed->next != nullptr) {
        std::fprintf(stderr, "FAIL: malformed interaction-profile event\n");
        return false;
    }
    return true;
}

// Consecutive locates may see a newer live sample on a real headset, so the
// tolerance allows a few millimetres of motion between the two calls.
bool posesNearlyEqual(const XrPosef& a, const XrPosef& b) {
    constexpr float kTolerance = 0.01f;
    return nearlyEqual(a.position.x, b.position.x, kTolerance) &&
           nearlyEqual(a.position.y, b.position.y, kTolerance) &&
           nearlyEqual(a.position.z, b.position.z, kTolerance) &&
           nearlyEqual(a.orientation.x, b.orientation.x, kTolerance) &&
           nearlyEqual(a.orientation.y, b.orientation.y, kTolerance) &&
           nearlyEqual(a.orientation.z, b.orientation.z, kTolerance) &&
           nearlyEqual(a.orientation.w, b.orientation.w, kTolerance);
}

// OpenComposite uses STAGE as its standing tracking universe. Basalt's LOCAL
// origin already sits on the Quest floor, so STAGE shares that origin: every
// STAGE location must equal the LOCAL one, with or without live tracking.
bool checkStageSpace(
    XrSession session,
    XrSpace localSpace,
    XrSpace handSpace,
    XrTime locateTime) {
    XrReferenceSpaceCreateInfo spaceInfo{};
    spaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    XrSpace stageSpace = XR_NULL_HANDLE;
    XrResult result = xrCreateReferenceSpace(session, &spaceInfo, &stageSpace);
    spaceInfo.poseInReferenceSpace.position = {0.25f, 0.5f, -1.0f};
    XrSpace offsetStageSpace = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateReferenceSpace(session, &spaceInfo, &offsetStageSpace);
    }
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    spaceInfo.poseInReferenceSpace.position = {0.0f, 0.0f, 0.0f};
    XrSpace viewSpace = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateReferenceSpace(session, &spaceInfo, &viewSpace);
    }
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: xrCreateReferenceSpace(STAGE) returned %d\n", result);
        return false;
    }

    // The STAGE↔LOCAL offset is static and known before any head sample.
    constexpr XrSpaceLocationFlags kValidFlags =
        XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    XrSpaceLocation location{};
    location.type = XR_TYPE_SPACE_LOCATION;
    result = xrLocateSpace(offsetStageSpace, localSpace, locateTime, &location);
    if (XR_FAILED(result) || location.locationFlags != kValidFlags ||
        !nearlyEqual(location.pose.position.x, 0.25f) ||
        !nearlyEqual(location.pose.position.y, 0.5f) ||
        !nearlyEqual(location.pose.position.z, -1.0f) ||
        !nearlyEqual(location.pose.orientation.w, 1.0f)) {
        std::fprintf(stderr, "FAIL: xrLocateSpace(STAGE offset in LOCAL) returned %d\n", result);
        return false;
    }
    result = xrLocateSpace(localSpace, offsetStageSpace, locateTime, &location);
    if (XR_FAILED(result) || location.locationFlags != kValidFlags ||
        !nearlyEqual(location.pose.position.x, -0.25f) ||
        !nearlyEqual(location.pose.position.y, -0.5f) ||
        !nearlyEqual(location.pose.position.z, 1.0f)) {
        std::fprintf(stderr, "FAIL: xrLocateSpace(LOCAL in STAGE offset) returned %d\n", result);
        return false;
    }

    // VIEW and controller locations must be identical relative to STAGE and
    // LOCAL (same flags, same pose), in both directions.
    const XrSpace targets[] = {viewSpace, handSpace};
    for (XrSpace target : targets) {
        XrSpaceLocation inLocal{};
        inLocal.type = XR_TYPE_SPACE_LOCATION;
        XrSpaceLocation inStage{};
        inStage.type = XR_TYPE_SPACE_LOCATION;
        result = xrLocateSpace(target, localSpace, locateTime, &inLocal);
        if (XR_SUCCEEDED(result)) {
            result = xrLocateSpace(target, stageSpace, locateTime, &inStage);
        }
        if (XR_FAILED(result) || inLocal.locationFlags != inStage.locationFlags ||
            !posesNearlyEqual(inLocal.pose, inStage.pose)) {
            std::fprintf(stderr, "FAIL: STAGE and LOCAL locations differ (%d)\n", result);
            return false;
        }
        result = xrLocateSpace(stageSpace, target, locateTime, &inStage);
        if (XR_SUCCEEDED(result)) {
            result = xrLocateSpace(localSpace, target, locateTime, &inLocal);
        }
        if (XR_FAILED(result) || inLocal.locationFlags != inStage.locationFlags ||
            !posesNearlyEqual(inLocal.pose, inStage.pose)) {
            std::fprintf(stderr, "FAIL: STAGE and LOCAL inverse locations differ (%d)\n", result);
            return false;
        }
    }

    XrViewLocateInfo viewLocateInfo{};
    viewLocateInfo.type = XR_TYPE_VIEW_LOCATE_INFO;
    viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    viewLocateInfo.displayTime = locateTime;
    XrViewState localState{};
    localState.type = XR_TYPE_VIEW_STATE;
    XrViewState stageState{};
    stageState.type = XR_TYPE_VIEW_STATE;
    XrView localViews[2]{};
    XrView stageViews[2]{};
    for (uint32_t index = 0; index < 2; ++index) {
        localViews[index].type = XR_TYPE_VIEW;
        stageViews[index].type = XR_TYPE_VIEW;
    }
    uint32_t viewCount = 0;
    viewLocateInfo.space = localSpace;
    result = xrLocateViews(session, &viewLocateInfo, &localState, 2, &viewCount, localViews);
    viewLocateInfo.space = stageSpace;
    if (XR_SUCCEEDED(result)) {
        result = xrLocateViews(session, &viewLocateInfo, &stageState, 2, &viewCount, stageViews);
    }
    if (XR_FAILED(result) || viewCount != 2 ||
        localState.viewStateFlags != stageState.viewStateFlags ||
        !posesNearlyEqual(localViews[0].pose, stageViews[0].pose) ||
        !posesNearlyEqual(localViews[1].pose, stageViews[1].pose)) {
        std::fprintf(stderr, "FAIL: xrLocateViews(STAGE) differs from LOCAL (%d)\n", result);
        return false;
    }
    // The connected smoke reaches this point right after deliberately letting
    // the injected head pose go stale; the height only applies when tracked.
    if (expectInjectedHeadPose() &&
        (stageState.viewStateFlags & XR_VIEW_STATE_POSITION_TRACKED_BIT) != 0 &&
        !nearlyEqual(stageViews[0].pose.position.y, 1.5f)) {
        std::fprintf(stderr, "FAIL: STAGE eye height %.3f is not floor-relative\n",
                     stageViews[0].pose.position.y);
        return false;
    }

    XrExtent2Df bounds{1.0f, 1.0f};
    result = xrGetReferenceSpaceBoundsRect(session, XR_REFERENCE_SPACE_TYPE_STAGE, &bounds);
    if (result != XR_SPACE_BOUNDS_UNAVAILABLE || bounds.width != 0.0f ||
        bounds.height != 0.0f) {
        std::fprintf(stderr, "FAIL: xrGetReferenceSpaceBoundsRect(STAGE) returned %d\n", result);
        return false;
    }
    bounds = {1.0f, 1.0f};
    result = xrGetReferenceSpaceBoundsRect(session, XR_REFERENCE_SPACE_TYPE_VIEW, &bounds);
    if (result != XR_SPACE_BOUNDS_UNAVAILABLE || bounds.width != 0.0f ||
        bounds.height != 0.0f) {
        std::fprintf(stderr, "FAIL: xrGetReferenceSpaceBoundsRect(VIEW) returned %d\n", result);
        return false;
    }
    result = xrGetReferenceSpaceBoundsRect(
        session, XR_REFERENCE_SPACE_TYPE_UNBOUNDED_MSFT, &bounds);
    if (result != XR_ERROR_REFERENCE_SPACE_UNSUPPORTED) {
        std::fprintf(stderr, "FAIL: xrGetReferenceSpaceBoundsRect(unsupported) returned %d\n",
                     result);
        return false;
    }

    result = xrDestroySpace(offsetStageSpace);
    if (XR_SUCCEEDED(result)) {
        result = xrDestroySpace(stageSpace);
    }
    if (XR_SUCCEEDED(result)) {
        result = xrDestroySpace(viewSpace);
    }
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: xrDestroySpace(STAGE) returned %d\n", result);
        return false;
    }
    return true;
}

// XR_KHR_visibility_mask reports "no mask available" (zero counts) for every
// mask type, which the spec requires when no mask is known.
bool checkVisibilityMask(XrInstance instance, XrSession session) {
    PFN_xrVoidFunction function = nullptr;
    XrResult result = xrGetInstanceProcAddr(instance, "xrGetVisibilityMaskKHR", &function);
    if (XR_FAILED(result) || function == nullptr) {
        std::fprintf(stderr, "FAIL: xrGetInstanceProcAddr(xrGetVisibilityMaskKHR) returned %d\n",
                     result);
        return false;
    }
    const auto getVisibilityMask = reinterpret_cast<PFN_xrGetVisibilityMaskKHR>(function);
    const XrVisibilityMaskTypeKHR maskTypes[] = {
        XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR,
        XR_VISIBILITY_MASK_TYPE_VISIBLE_TRIANGLE_MESH_KHR,
        XR_VISIBILITY_MASK_TYPE_LINE_LOOP_KHR,
    };
    for (XrVisibilityMaskTypeKHR maskType : maskTypes) {
        for (uint32_t eye = 0; eye < 2; ++eye) {
            XrVisibilityMaskKHR mask{};
            mask.type = XR_TYPE_VISIBILITY_MASK_KHR;
            mask.vertexCountOutput = UINT32_MAX;
            mask.indexCountOutput = UINT32_MAX;
            result = getVisibilityMask(
                session, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, eye, maskType, &mask);
            if (XR_FAILED(result) || mask.vertexCountOutput != 0 ||
                mask.indexCountOutput != 0) {
                std::fprintf(stderr, "FAIL: xrGetVisibilityMaskKHR(count) returned %d\n", result);
                return false;
            }
            XrVector2f vertices[4]{};
            uint32_t indices[6]{};
            mask.vertexCapacityInput = 4;
            mask.indexCapacityInput = 6;
            mask.vertices = vertices;
            mask.indices = indices;
            result = getVisibilityMask(
                session, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, eye, maskType, &mask);
            if (XR_FAILED(result) || mask.vertexCountOutput != 0 ||
                mask.indexCountOutput != 0) {
                std::fprintf(stderr, "FAIL: xrGetVisibilityMaskKHR(values) returned %d\n", result);
                return false;
            }
        }
    }
    XrVisibilityMaskKHR mask{};
    mask.type = XR_TYPE_VISIBILITY_MASK_KHR;
    result = getVisibilityMask(
        session, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2,
        XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &mask);
    if (result != XR_ERROR_VALIDATION_FAILURE) {
        std::fprintf(stderr, "FAIL: xrGetVisibilityMaskKHR(eye 2) returned %d\n", result);
        return false;
    }
    result = getVisibilityMask(
        session, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_MONO, 0,
        XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &mask);
    if (result != XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED) {
        std::fprintf(stderr, "FAIL: xrGetVisibilityMaskKHR(mono) returned %d\n", result);
        return false;
    }
    return true;
}

// OpenComposite restarts its session (temporary device, then the game's
// device) without destroying spaces or action spaces first, and attaches the
// same action sets to every new session. Both must succeed.
bool checkOpenCompositeSessionRestart(
    XrInstance instance,
    const XrSessionCreateInfo& sessionInfo,
    const XrActionSet* attachedActionSets,
    uint32_t attachedActionSetCount,
    XrAction poseAction,
    XrPath leftHandPath) {
    XrSession session = XR_NULL_HANDLE;
    XrResult result = xrCreateSession(instance, &sessionInfo, &session);
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: restarted xrCreateSession returned %d\n", result);
        return false;
    }

    XrReferenceSpaceCreateInfo spaceInfo{};
    spaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    const XrReferenceSpaceType spaceTypes[] = {
        XR_REFERENCE_SPACE_TYPE_STAGE,
        XR_REFERENCE_SPACE_TYPE_LOCAL,
        XR_REFERENCE_SPACE_TYPE_VIEW,
    };
    std::vector<XrSpace> liveSpaces;
    for (XrReferenceSpaceType spaceType : spaceTypes) {
        spaceInfo.referenceSpaceType = spaceType;
        XrSpace space = XR_NULL_HANDLE;
        if (XR_SUCCEEDED(result)) {
            result = xrCreateReferenceSpace(session, &spaceInfo, &space);
            liveSpaces.push_back(space);
        }
    }
    XrActionSpaceCreateInfo actionSpaceInfo{};
    actionSpaceInfo.type = XR_TYPE_ACTION_SPACE_CREATE_INFO;
    actionSpaceInfo.action = poseAction;
    actionSpaceInfo.subactionPath = leftHandPath;
    actionSpaceInfo.poseInActionSpace.orientation.w = 1.0f;
    XrSpace actionSpace = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateActionSpace(session, &actionSpaceInfo, &actionSpace);
        liveSpaces.push_back(actionSpace);
    }
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: restarted session spaces returned %d\n", result);
        xrDestroySession(session);
        return false;
    }

    XrSessionActionSetsAttachInfo attachInfo{};
    attachInfo.type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO;
    attachInfo.countActionSets = attachedActionSetCount;
    attachInfo.actionSets = attachedActionSets;
    result = xrAttachSessionActionSets(session, &attachInfo);
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: re-attach to restarted session returned %d\n", result);
        xrDestroySession(session);
        return false;
    }
    result = xrAttachSessionActionSets(session, &attachInfo);
    if (result != XR_ERROR_ACTIONSETS_ALREADY_ATTACHED) {
        std::fprintf(stderr, "FAIL: second attach to restarted session returned %d\n", result);
        xrDestroySession(session);
        return false;
    }

    // Destroy the session with every space still alive (never begun, as
    // OpenComposite's temporary session may be).
    result = xrDestroySession(session);
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: xrDestroySession with live spaces returned %d\n", result);
        return false;
    }
    for (XrSpace space : liveSpaces) {
        result = xrDestroySpace(space);
        if (result != XR_ERROR_HANDLE_INVALID) {
            std::fprintf(stderr, "FAIL: space outlived its session (%d)\n", result);
            return false;
        }
    }
    return true;
}

// BASALT_EXPECT_HAND_TRACKING=1: the control daemon lists hand_tracking, so
// XR_EXT_hand_tracking must be offered, is enabled, and is exercised end to
// end. Unset or 0: it must not be offered (headless runs and every other
// gate). Against a live headset the real streamer may advertise it, so it is
// then neither required nor enabled.
enum class HandTrackingExpectation {
    kAbsent,
    kPresent,
    kEither,
};

HandTrackingExpectation handTrackingExpectation() {
    const char* value = std::getenv("BASALT_EXPECT_HAND_TRACKING");
    if (value != nullptr && std::strcmp(value, "1") == 0) {
        return HandTrackingExpectation::kPresent;
    }
    if (value != nullptr && std::strcmp(value, "0") == 0) {
        return HandTrackingExpectation::kAbsent;
    }
    if (requireControllerInput() ||
        (requireHeadPose() && !expectInjectedHeadPose())) {
        return HandTrackingExpectation::kEither;
    }
    return HandTrackingExpectation::kAbsent;
}

struct HandTrackingApi {
    PFN_xrCreateHandTrackerEXT create = nullptr;
    PFN_xrDestroyHandTrackerEXT destroy = nullptr;
    PFN_xrLocateHandJointsEXT locate = nullptr;
};

constexpr uint32_t kHandJoints = XR_HAND_JOINT_COUNT_EXT;
constexpr XrSpaceLocationFlags kHandJointTrackedFlags =
    XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
    XR_SPACE_LOCATION_POSITION_VALID_BIT |
    XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
    XR_SPACE_LOCATION_POSITION_TRACKED_BIT;

// Locates every joint, pre-filling the outputs with garbage so the runtime
// must write each one. jointCount and velocityJointCount override the
// well-formed 26 for validation checks.
XrResult locateHand(
    const HandTrackingApi& api,
    XrHandTrackerEXT tracker,
    XrSpace baseSpace,
    XrTime time,
    XrHandJointLocationEXT* joints,
    XrBool32* isActive,
    XrHandJointVelocityEXT* velocities = nullptr,
    uint32_t jointCount = kHandJoints,
    uint32_t velocityJointCount = kHandJoints) {
    for (uint32_t joint = 0; joint < kHandJoints; ++joint) {
        joints[joint].locationFlags = ~XrSpaceLocationFlags{0};
        joints[joint].pose = {{1.0f, 2.0f, 3.0f, 4.0f}, {5.0f, 6.0f, 7.0f}};
        joints[joint].radius = -1.0f;
        if (velocities != nullptr) {
            velocities[joint].velocityFlags = ~XrSpaceVelocityFlags{0};
            velocities[joint].linearVelocity = {9.0f, 9.0f, 9.0f};
            velocities[joint].angularVelocity = {9.0f, 9.0f, 9.0f};
        }
    }
    XrHandJointVelocitiesEXT velocityChain{};
    velocityChain.type = XR_TYPE_HAND_JOINT_VELOCITIES_EXT;
    velocityChain.jointCount = velocityJointCount;
    velocityChain.jointVelocities = velocities;
    XrHandJointLocationsEXT locations{};
    locations.type = XR_TYPE_HAND_JOINT_LOCATIONS_EXT;
    locations.next = velocities != nullptr ? &velocityChain : nullptr;
    locations.isActive = 7;
    locations.jointCount = jointCount;
    locations.jointLocations = joints;
    XrHandJointsLocateInfoEXT locateInfo{};
    locateInfo.type = XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT;
    locateInfo.baseSpace = baseSpace;
    locateInfo.time = time;
    const XrResult result = api.locate(tracker, &locateInfo, &locations);
    if (isActive != nullptr) {
        *isActive = locations.isActive;
    }
    return result;
}

bool handJointsInactive(const XrHandJointLocationEXT* joints) {
    for (uint32_t joint = 0; joint < kHandJoints; ++joint) {
        if (joints[joint].locationFlags != 0 || joints[joint].radius != 0.0f ||
            joints[joint].pose.orientation.w != 1.0f) {
            return false;
        }
    }
    return true;
}

bool handPosesEqual(const XrPosef& a, const XrPosef& b, float tolerance = 0.0002f) {
    return nearlyEqual(a.position.x, b.position.x, tolerance) &&
           nearlyEqual(a.position.y, b.position.y, tolerance) &&
           nearlyEqual(a.position.z, b.position.z, tolerance) &&
           nearlyEqual(a.orientation.x, b.orientation.x, tolerance) &&
           nearlyEqual(a.orientation.y, b.orientation.y, tolerance) &&
           nearlyEqual(a.orientation.z, b.orientation.z, tolerance) &&
           nearlyEqual(a.orientation.w, b.orientation.w, tolerance);
}

// OpenComposite order: both trackers right after xrAttachSessionActionSets,
// then per-frame locates that must succeed even with no hand data yet.
bool checkHandTrackersAfterAttach(
    const HandTrackingApi& api,
    XrSession session,
    XrSpace localSpace,
    XrTime time,
    XrHandTrackerEXT* leftTracker,
    XrHandTrackerEXT* rightTracker) {
    XrHandTrackerCreateInfoEXT createInfo{};
    createInfo.type = XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT;
    createInfo.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;
    createInfo.hand = XR_HAND_LEFT_EXT;
    XrResult result = api.create(session, &createInfo, leftTracker);
    createInfo.hand = XR_HAND_RIGHT_EXT;
    if (XR_SUCCEEDED(result)) {
        result = api.create(session, &createInfo, rightTracker);
    }
    if (XR_FAILED(result) || *leftTracker == XR_NULL_HANDLE ||
        *rightTracker == XR_NULL_HANDLE || *leftTracker == *rightTracker) {
        std::fprintf(stderr, "FAIL: xrCreateHandTrackerEXT(left/right) returned %d\n", result);
        return false;
    }

    XrHandTrackerEXT rejected = XR_NULL_HANDLE;
    createInfo.hand = static_cast<XrHandEXT>(3);
    const XrResult badHand = api.create(session, &createInfo, &rejected);
    createInfo.hand = XR_HAND_LEFT_EXT;
    createInfo.handJointSet = static_cast<XrHandJointSetEXT>(1);
    const XrResult badJointSet = api.create(session, &createInfo, &rejected);
    createInfo.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;
    createInfo.type = XR_TYPE_SPACE_LOCATION;
    const XrResult badType = api.create(session, &createInfo, &rejected);
    createInfo.type = XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT;
    const XrResult badSession = api.create(
        reinterpret_cast<XrSession>(static_cast<uintptr_t>(0x12345)), &createInfo, &rejected);
    if (badHand != XR_ERROR_VALIDATION_FAILURE ||
        badJointSet != XR_ERROR_VALIDATION_FAILURE ||
        badType != XR_ERROR_VALIDATION_FAILURE ||
        badSession != XR_ERROR_HANDLE_INVALID || rejected != XR_NULL_HANDLE) {
        std::fprintf(stderr,
                     "FAIL: xrCreateHandTrackerEXT validation (hand %d, joint set %d, "
                     "type %d, session %d)\n",
                     badHand, badJointSet, badType, badSession);
        return false;
    }

    XrHandJointLocationEXT joints[kHandJoints]{};
    XrHandJointVelocityEXT velocities[kHandJoints]{};
    for (XrHandTrackerEXT tracker : {*leftTracker, *rightTracker}) {
        XrBool32 active = XR_TRUE;
        result = locateHand(api, tracker, localSpace, time, joints, &active, velocities);
        if (result != XR_SUCCESS || active != XR_FALSE || !handJointsInactive(joints) ||
            velocities[0].velocityFlags != 0) {
            std::fprintf(stderr,
                         "FAIL: xrLocateHandJointsEXT before any skeleton returned %d "
                         "(active %u)\n", result, active);
            return false;
        }
    }

    const XrResult shortJoints =
        locateHand(api, *leftTracker, localSpace, time, joints, nullptr, nullptr, 25);
    const XrResult zeroTime =
        locateHand(api, *leftTracker, localSpace, 0, joints, nullptr);
    const XrResult shortVelocities = locateHand(
        api, *leftTracker, localSpace, time, joints, nullptr, velocities,
        kHandJoints, 25);
    const XrResult nullBase =
        locateHand(api, *leftTracker, XR_NULL_HANDLE, time, joints, nullptr);
    if (shortJoints != XR_ERROR_VALIDATION_FAILURE ||
        zeroTime != XR_ERROR_TIME_INVALID ||
        shortVelocities != XR_ERROR_VALIDATION_FAILURE ||
        nullBase != XR_ERROR_HANDLE_INVALID) {
        std::fprintf(stderr,
                     "FAIL: xrLocateHandJointsEXT validation (jointCount 25 %d, time 0 %d, "
                     "velocity jointCount 25 %d, null base %d)\n",
                     shortJoints, zeroTime, shortVelocities, nullBase);
        return false;
    }

    XrHandTrackerEXT extra = XR_NULL_HANDLE;
    result = api.create(session, &createInfo, &extra);
    const XrResult destroyed = XR_SUCCEEDED(result) ? api.destroy(extra) : result;
    const XrResult destroyedAgain = api.destroy(extra);
    const XrResult locateDestroyed =
        locateHand(api, extra, localSpace, time, joints, nullptr);
    if (XR_FAILED(result) || destroyed != XR_SUCCESS ||
        destroyedAgain != XR_ERROR_HANDLE_INVALID ||
        locateDestroyed != XR_ERROR_HANDLE_INVALID) {
        std::fprintf(stderr,
                     "FAIL: destroyed hand tracker (create %d, destroy %d, again %d, "
                     "locate %d)\n",
                     result, destroyed, destroyedAgain, locateDestroyed);
        return false;
    }
    std::puts("PASS: XR_EXT_hand_tracking trackers created after attach; hands are "
              "inactive (XR_SUCCESS) before skeletons; jointCount 25, time 0, bad hand/"
              "joint set, and destroyed handles are rejected");
    return true;
}

// The native daemon's 0.625 haptic marker publishes a left skeleton whose
// palm equals the left controller pose and whose joint i sits at palm +
// (0.001 i, 0.002 i, -0.003 i), radius 0.01 + 0.0001 i; 0.75 untracks the
// left hand and then sends an older skeleton that must be ignored.
bool checkInjectedHandSkeleton(
    const HandTrackingApi& api,
    XrSession session,
    XrHandTrackerEXT leftTracker,
    XrHandTrackerEXT rightTracker,
    XrSpace localSpace,
    XrSpace gripSpace,
    XrTime time,
    const XrHapticActionInfo& hapticInfo,
    XrHapticVibration vibration) {
    vibration.amplitude = 0.625f;
    XrResult result = xrApplyHapticFeedback(
        session, &hapticInfo, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
    XrHandJointLocationEXT joints[kHandJoints]{};
    XrBool32 active = XR_FALSE;
    for (int attempt = 0; XR_SUCCEEDED(result) && attempt < 200; ++attempt) {
        result = locateHand(api, leftTracker, localSpace, time, joints, &active);
        if (XR_SUCCEEDED(result) && active == XR_TRUE) {
            break;
        }
        Sleep(10);
    }
    XrSpaceLocation grip{};
    grip.type = XR_TYPE_SPACE_LOCATION;
    if (XR_SUCCEEDED(result)) {
        result = xrLocateSpace(gripSpace, localSpace, time, &grip);
    }
    if (XR_FAILED(result) || active != XR_TRUE ||
        grip.locationFlags != kHandJointTrackedFlags) {
        std::fprintf(stderr,
                     "FAIL: injected left hand skeleton never became active "
                     "(result %d, active %u, grip flags 0x%llx)\n",
                     result, active,
                     static_cast<unsigned long long>(grip.locationFlags));
        return false;
    }
    const XrPosef palm = joints[XR_HAND_JOINT_PALM_EXT].pose;
    if (!handPosesEqual(palm, grip.pose)) {
        std::fprintf(stderr,
                     "FAIL: palm %.4f %.4f %.4f does not match the grip pose "
                     "%.4f %.4f %.4f in LOCAL\n",
                     palm.position.x, palm.position.y, palm.position.z,
                     grip.pose.position.x, grip.pose.position.y, grip.pose.position.z);
        return false;
    }
    for (uint32_t joint = 0; joint < kHandJoints; ++joint) {
        const float i = static_cast<float>(joint);
        const XrVector3f expectedOffset =
            rotateVector(palm.orientation, {0.001f * i, 0.002f * i, -0.003f * i});
        const XrPosef& pose = joints[joint].pose;
        if (joints[joint].locationFlags != kHandJointTrackedFlags ||
            !nearlyEqual(joints[joint].radius, 0.01f + 0.0001f * i) ||
            !nearlyEqual(pose.position.x - palm.position.x, expectedOffset.x, 0.0002f) ||
            !nearlyEqual(pose.position.y - palm.position.y, expectedOffset.y, 0.0002f) ||
            !nearlyEqual(pose.position.z - palm.position.z, expectedOffset.z, 0.0002f) ||
            !nearlyEqual(pose.orientation.x, palm.orientation.x, 0.0002f) ||
            !nearlyEqual(pose.orientation.y, palm.orientation.y, 0.0002f) ||
            !nearlyEqual(pose.orientation.z, palm.orientation.z, 0.0002f) ||
            !nearlyEqual(pose.orientation.w, palm.orientation.w, 0.0002f)) {
            std::fprintf(stderr, "FAIL: hand joint %u lost its offset, orientation, "
                                 "radius, or flags in LOCAL\n", joint);
            return false;
        }
    }

    // OpenComposite's floor space is STAGE, which shares LOCAL's origin.
    XrReferenceSpaceCreateInfo stageInfo{};
    stageInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    stageInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    stageInfo.poseInReferenceSpace.orientation.w = 1.0f;
    XrSpace stageSpace = XR_NULL_HANDLE;
    result = xrCreateReferenceSpace(session, &stageInfo, &stageSpace);
    XrHandJointLocationEXT stageJoints[kHandJoints]{};
    XrBool32 stageActive = XR_FALSE;
    if (XR_SUCCEEDED(result)) {
        result = locateHand(api, leftTracker, stageSpace, time, stageJoints, &stageActive);
        xrDestroySpace(stageSpace);
    }
    bool stageMatches = XR_SUCCEEDED(result) && stageActive == XR_TRUE;
    for (uint32_t joint = 0; stageMatches && joint < kHandJoints; ++joint) {
        stageMatches = handPosesEqual(stageJoints[joint].pose, joints[joint].pose) &&
                       stageJoints[joint].locationFlags == kHandJointTrackedFlags;
    }
    if (!stageMatches) {
        std::fprintf(stderr, "FAIL: hand joints in STAGE differ from LOCAL (%d)\n", result);
        return false;
    }

    // Relative to the grip action space (OpenComposite's skeletal path) the
    // palm is the grip itself, and the raw joint offsets come back unchanged.
    XrHandJointLocationEXT gripJoints[kHandJoints]{};
    XrHandJointVelocityEXT velocities[kHandJoints]{};
    XrBool32 gripActive = XR_FALSE;
    result = locateHand(api, leftTracker, gripSpace, time, gripJoints, &gripActive, velocities);
    bool gripRelativeOk = XR_SUCCEEDED(result) && gripActive == XR_TRUE;
    for (uint32_t joint = 0; gripRelativeOk && joint < kHandJoints; ++joint) {
        const float i = static_cast<float>(joint);
        const XrPosef expected{{0.0f, 0.0f, 0.0f, 1.0f},
                               {0.001f * i, 0.002f * i, -0.003f * i}};
        gripRelativeOk =
            handPosesEqual(gripJoints[joint].pose, expected) &&
            gripJoints[joint].locationFlags == kHandJointTrackedFlags &&
            velocities[joint].velocityFlags == 0 &&
            velocities[joint].linearVelocity.x == 0.0f &&
            velocities[joint].linearVelocity.y == 0.0f &&
            velocities[joint].linearVelocity.z == 0.0f &&
            velocities[joint].angularVelocity.x == 0.0f &&
            velocities[joint].angularVelocity.y == 0.0f &&
            velocities[joint].angularVelocity.z == 0.0f;
    }
    XrHandJointLocationEXT rightJoints[kHandJoints]{};
    XrBool32 rightActive = XR_TRUE;
    const XrResult rightResult =
        locateHand(api, rightTracker, localSpace, time, rightJoints, &rightActive);
    if (!gripRelativeOk || rightResult != XR_SUCCESS || rightActive != XR_FALSE ||
        !handJointsInactive(rightJoints)) {
        std::fprintf(stderr,
                     "FAIL: grip-relative hand joints/velocities (%d) or inactive right "
                     "hand (%d, active %u)\n", result, rightResult, rightActive);
        return false;
    }
    std::puts("PASS: XR_EXT_hand_tracking left skeleton: palm equals the grip pose in "
              "LOCAL and STAGE, joint offsets and radii survive, grip-relative palm is "
              "identity, chained velocities report no data, right hand stays inactive");

    vibration.amplitude = 0.75f;
    result = xrApplyHapticFeedback(
        session, &hapticInfo, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
    active = XR_TRUE;
    for (int attempt = 0; XR_SUCCEEDED(result) && attempt < 200; ++attempt) {
        result = locateHand(api, leftTracker, localSpace, time, joints, &active);
        if (XR_SUCCEEDED(result) && active == XR_FALSE) {
            break;
        }
        Sleep(10);
    }
    // The daemon follows the untrack with an older skeleton; give it time to
    // arrive, then the hand must still be inactive.
    Sleep(100);
    if (XR_SUCCEEDED(result) && active == XR_FALSE) {
        result = locateHand(api, leftTracker, localSpace, time, joints, &active);
    }
    if (XR_FAILED(result) || active != XR_FALSE || !handJointsInactive(joints)) {
        std::fprintf(stderr,
                     "FAIL: untracked left hand stayed active or a stale skeleton revived "
                     "it (%d, active %u)\n", result, active);
        return false;
    }
    std::puts("PASS: XR_EXT_hand_tracking untrack clears the left hand and a stale "
              "skeleton cannot revive it");
    return true;
}

// OpenComposite locates one frame several times (projection views, eye
// transforms, IPD, then the game's WaitGetPoses through xrLocateSpace). Every
// head query for one predictedDisplayTime must return the sample the first
// query saw, even after a newer sample arrives, so the frame's tracking
// timestamp matches the pose the application rendered with. The daemon's
// 0.875 haptic marker publishes a newer head sample (timestamp 3, 0.25 m
// higher) and then requires the next FrameReady to keep timestamp 2.
bool checkPinnedFrameHeadPose(
    XrSession session,
    XrSpace localSpace,
    XrTime displayTime,
    const XrView (&firstViews)[2],
    const XrHapticActionInfo& hapticInfo,
    XrHapticVibration vibration) {
    vibration.amplitude = 0.875f;
    XrResult result = xrApplyHapticFeedback(
        session, &hapticInfo, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));

    XrViewLocateInfo locateInfo{};
    locateInfo.type = XR_TYPE_VIEW_LOCATE_INFO;
    locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locateInfo.space = localSpace;
    XrViewState viewState{};
    viewState.type = XR_TYPE_VIEW_STATE;
    XrView views[2]{};
    views[0].type = XR_TYPE_VIEW;
    views[1].type = XR_TYPE_VIEW;
    uint32_t viewCount = 0;

    // A time no xrWaitFrame returned sees the newest sample, so it shows
    // when the moved head has arrived.
    locateInfo.displayTime = displayTime + 1;
    bool moved = false;
    for (int attempt = 0; XR_SUCCEEDED(result) && !moved && attempt < 100; ++attempt) {
        result = xrLocateViews(session, &locateInfo, &viewState, 2, &viewCount, views);
        moved = XR_SUCCEEDED(result) &&
                nearlyEqual(views[0].pose.position.y,
                            firstViews[0].pose.position.y + 0.25f, 0.001f);
        if (!moved) {
            Sleep(10);
        }
    }
    if (XR_FAILED(result) || !moved) {
        std::fprintf(stderr, "FAIL: the daemon's newer head sample never arrived (%d)\n",
                     result);
        return false;
    }

    locateInfo.displayTime = displayTime;
    result = xrLocateViews(session, &locateInfo, &viewState, 2, &viewCount, views);
    if (XR_FAILED(result) || !nearlyEqual(views[0].pose.position.y,
                                          firstViews[0].pose.position.y, 0.001f) ||
        !nearlyEqual(views[1].pose.position.y, firstViews[1].pose.position.y, 0.001f)) {
        std::fprintf(stderr,
                     "FAIL: a repeated xrLocateViews for one displayTime returned a newer "
                     "head sample (%d, eye y %.4f, first %.4f)\n",
                     result, views[0].pose.position.y, firstViews[0].pose.position.y);
        return false;
    }

    XrReferenceSpaceCreateInfo viewSpaceInfo{};
    viewSpaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    viewSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    viewSpaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    XrSpace viewSpace = XR_NULL_HANDLE;
    result = xrCreateReferenceSpace(session, &viewSpaceInfo, &viewSpace);
    XrSpaceLocation head{};
    head.type = XR_TYPE_SPACE_LOCATION;
    if (XR_SUCCEEDED(result)) {
        result = xrLocateSpace(viewSpace, localSpace, displayTime, &head);
    }
    const float firstHeadY =
        (firstViews[0].pose.position.y + firstViews[1].pose.position.y) * 0.5f;
    if (viewSpace != XR_NULL_HANDLE) {
        xrDestroySpace(viewSpace);
    }
    if (XR_FAILED(result) || !nearlyEqual(head.pose.position.y, firstHeadY, 0.001f) ||
        !nearlyEqual(head.pose.orientation.w, firstViews[0].pose.orientation.w, 0.001f) ||
        !nearlyEqual(head.pose.orientation.y, firstViews[0].pose.orientation.y, 0.001f)) {
        std::fprintf(stderr,
                     "FAIL: xrLocateSpace(VIEW in LOCAL) for the frame's displayTime "
                     "returned a newer head sample (%d, y %.4f, first %.4f)\n",
                     result, head.pose.position.y, firstHeadY);
        return false;
    }
    std::puts("PASS: every head query for one displayTime returns the first query's sample");
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    SmokeOptions options;
    if (!parseOptions(argc, argv, options)) {
        return 2;
    }

    uint32_t extensionCount = 0;
    XrResult result = xrEnumerateInstanceExtensionProperties(
        nullptr, 0, &extensionCount, nullptr);
    if (XR_FAILED(result)) {
        return fail("xrEnumerateInstanceExtensionProperties(count)", result);
    }

    std::vector<XrExtensionProperties> extensions(extensionCount);
    for (XrExtensionProperties& extension : extensions) {
        extension.type = XR_TYPE_EXTENSION_PROPERTIES;
    }
    result = xrEnumerateInstanceExtensionProperties(
        nullptr, extensionCount, &extensionCount, extensions.data());
    if (XR_FAILED(result)) {
        return fail("xrEnumerateInstanceExtensionProperties(values)", result);
    }

    bool foundD3D11 = false;
    bool foundVisibilityMask = false;
    bool foundHandTracking = false;
    for (const XrExtensionProperties& extension : extensions) {
        if (std::strcmp(extension.extensionName, XR_EXT_HAND_TRACKING_EXTENSION_NAME) == 0 &&
            extension.extensionVersion == XR_EXT_hand_tracking_SPEC_VERSION) {
            foundHandTracking = true;
        }
        if (std::strcmp(extension.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0 &&
            extension.extensionVersion == XR_KHR_D3D11_enable_SPEC_VERSION) {
            foundD3D11 = true;
        }
        if (std::strcmp(extension.extensionName, XR_KHR_VISIBILITY_MASK_EXTENSION_NAME) == 0 &&
            extension.extensionVersion == XR_KHR_visibility_mask_SPEC_VERSION) {
            foundVisibilityMask = true;
        }
    }
    if (!foundD3D11 || !foundVisibilityMask) {
        std::fputs("FAIL: runtime did not advertise XR_KHR_D3D11_enable v11 and "
                   "XR_KHR_visibility_mask\n", stderr);
        return 1;
    }

    const HandTrackingExpectation handTrackingExpected = handTrackingExpectation();
    if ((handTrackingExpected == HandTrackingExpectation::kPresent && !foundHandTracking) ||
        (handTrackingExpected == HandTrackingExpectation::kAbsent && foundHandTracking)) {
        std::fprintf(stderr, "FAIL: XR_EXT_hand_tracking %s\n",
                     foundHandTracking ? "enumerated without the hand_tracking feature"
                                       : "missing although the control file lists hand_tracking");
        return 1;
    }
    const bool handTrackingEnabled =
        handTrackingExpected == HandTrackingExpectation::kPresent;

    std::vector<const char*> enabledExtensions = {
        XR_KHR_D3D11_ENABLE_EXTENSION_NAME,
        XR_KHR_VISIBILITY_MASK_EXTENSION_NAME,
    };
    if (handTrackingEnabled) {
        enabledExtensions.push_back(XR_EXT_HAND_TRACKING_EXTENSION_NAME);
    }
    XrInstanceCreateInfo instanceInfo{};
    instanceInfo.type = XR_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.enabledExtensionCount = static_cast<uint32_t>(enabledExtensions.size());
    instanceInfo.enabledExtensionNames = enabledExtensions.data();
    instanceInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    std::strncpy(instanceInfo.applicationInfo.applicationName, "Basalt D3D11 smoke",
                 XR_MAX_APPLICATION_NAME_SIZE - 1);

    XrInstance instance = XR_NULL_HANDLE;
    result = xrCreateInstance(&instanceInfo, &instance);
    if (XR_FAILED(result)) {
        return fail("xrCreateInstance(D3D11)", result);
    }

    XrSystemGetInfo systemInfo{};
    systemInfo.type = XR_TYPE_SYSTEM_GET_INFO;
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId systemId = XR_NULL_SYSTEM_ID;
    result = xrGetSystem(instance, &systemInfo, &systemId);
    if (XR_FAILED(result)) {
        xrDestroyInstance(instance);
        return fail("xrGetSystem", result);
    }

    // XR_EXT_hand_tracking: entry points and system support exist exactly
    // when the application enabled the offered extension.
    HandTrackingApi handTracking;
    {
        XrSystemHandTrackingPropertiesEXT handTrackingProperties{};
        handTrackingProperties.type = XR_TYPE_SYSTEM_HAND_TRACKING_PROPERTIES_EXT;
        handTrackingProperties.supportsHandTracking =
            handTrackingEnabled ? XR_FALSE : XR_TRUE;
        XrSystemProperties systemProperties{};
        systemProperties.type = XR_TYPE_SYSTEM_PROPERTIES;
        systemProperties.next = &handTrackingProperties;
        result = xrGetSystemProperties(instance, systemId, &systemProperties);
        PFN_xrVoidFunction createVoid = nullptr;
        PFN_xrVoidFunction destroyVoid = nullptr;
        PFN_xrVoidFunction locateVoid = nullptr;
        const XrResult createLookup =
            xrGetInstanceProcAddr(instance, "xrCreateHandTrackerEXT", &createVoid);
        const XrResult destroyLookup =
            xrGetInstanceProcAddr(instance, "xrDestroyHandTrackerEXT", &destroyVoid);
        const XrResult locateLookup =
            xrGetInstanceProcAddr(instance, "xrLocateHandJointsEXT", &locateVoid);
        const bool lookupsOk = handTrackingEnabled
            ? createLookup == XR_SUCCESS && destroyLookup == XR_SUCCESS &&
                  locateLookup == XR_SUCCESS && createVoid != nullptr &&
                  destroyVoid != nullptr && locateVoid != nullptr
            : XR_FAILED(createLookup) && XR_FAILED(destroyLookup) &&
                  XR_FAILED(locateLookup) && createVoid == nullptr &&
                  destroyVoid == nullptr && locateVoid == nullptr;
        if (XR_FAILED(result) || !lookupsOk ||
            handTrackingProperties.supportsHandTracking !=
                (handTrackingEnabled ? XR_TRUE : XR_FALSE)) {
            std::fprintf(stderr,
                         "FAIL: XR_EXT_hand_tracking system support %u / entry points "
                         "(%d %d %d) do not match enabled=%u\n",
                         handTrackingProperties.supportsHandTracking,
                         createLookup, destroyLookup, locateLookup,
                         handTrackingEnabled ? 1u : 0u);
            xrDestroyInstance(instance);
            return fail("XR_EXT_hand_tracking availability", result);
        }
        handTracking.create = reinterpret_cast<PFN_xrCreateHandTrackerEXT>(createVoid);
        handTracking.destroy = reinterpret_cast<PFN_xrDestroyHandTrackerEXT>(destroyVoid);
        handTracking.locate = reinterpret_cast<PFN_xrLocateHandJointsEXT>(locateVoid);
        std::printf(handTrackingEnabled
                        ? "PASS: XR_EXT_hand_tracking enumerated with the hand_tracking "
                          "feature; supportsHandTracking and entry points available\n"
                        : "PASS: XR_EXT_hand_tracking %s; supportsHandTracking false and "
                          "xrCreateHandTrackerEXT unavailable\n",
                    foundHandTracking ? "offered but not enabled" : "not enumerated");
    }

    uint32_t configurationViewCount = 0;
    result = xrEnumerateViewConfigurationViews(
        instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
        0, &configurationViewCount, nullptr);
    XrViewConfigurationView configurationViews[2]{};
    configurationViews[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    configurationViews[1].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    if (XR_SUCCEEDED(result) && configurationViewCount == 2) {
        result = xrEnumerateViewConfigurationViews(
            instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
            2, &configurationViewCount, configurationViews);
    }
    const uint32_t expectedWidth = expectedViewDimension(
        "BASALT_EXPECT_VIEW_WIDTH", 1680);
    const uint32_t expectedHeight = expectedViewDimension(
        "BASALT_EXPECT_VIEW_HEIGHT", 1760);
    if (XR_FAILED(result) || configurationViewCount != 2 ||
        configurationViews[0].recommendedImageRectWidth != expectedWidth ||
        configurationViews[1].recommendedImageRectWidth != expectedWidth ||
        configurationViews[0].recommendedImageRectHeight != expectedHeight ||
        configurationViews[1].recommendedImageRectHeight != expectedHeight ||
        configurationViews[0].maxImageRectWidth != 1680 ||
        configurationViews[0].maxImageRectHeight != 1760) {
        xrDestroyInstance(instance);
        return fail("xrEnumerateViewConfigurationViews dimensions", result);
    }

    PFN_xrVoidFunction requirementsVoid = nullptr;
    result = xrGetInstanceProcAddr(
        instance,
        "xrGetD3D11GraphicsRequirementsKHR",
        &requirementsVoid);
    if (XR_FAILED(result) || requirementsVoid == nullptr) {
        xrDestroyInstance(instance);
        return fail("xrGetInstanceProcAddr(D3D11 requirements)", result);
    }
    const auto getRequirements =
        reinterpret_cast<PFN_xrGetD3D11GraphicsRequirementsKHR>(requirementsVoid);

    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(
        __uuidof(IDXGIFactory1),
        reinterpret_cast<void**>(&factory));
    if (FAILED(hr)) {
        xrDestroyInstance(instance);
        return failHresult("CreateDXGIFactory1", hr);
    }
    IDXGIAdapter1* adapter = nullptr;
    hr = factory->EnumAdapters1(0, &adapter);
    release(factory);
    if (FAILED(hr)) {
        xrDestroyInstance(instance);
        return failHresult("EnumAdapters1(0)", hr);
    }

    const D3D_FEATURE_LEVEL requestedLevels[] = {D3D_FEATURE_LEVEL_11_0};
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL selectedLevel{};
    hr = D3D11CreateDevice(
        adapter,
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        requestedLevels,
        1,
        D3D11_SDK_VERSION,
        &device,
        &selectedLevel,
        &context);
    if (FAILED(hr)) {
        release(adapter);
        xrDestroyInstance(instance);
        return failHresult("D3D11CreateDevice", hr);
    }

    XrGraphicsBindingD3D11KHR binding{};
    binding.type = XR_TYPE_GRAPHICS_BINDING_D3D11_KHR;
    binding.device = device;
    XrSessionCreateInfo sessionInfo{};
    sessionInfo.type = XR_TYPE_SESSION_CREATE_INFO;
    sessionInfo.next = &binding;
    sessionInfo.systemId = systemId;

    XrSession session = XR_NULL_HANDLE;
    result = xrCreateSession(instance, &sessionInfo, &session);
    if (result != XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING || session != XR_NULL_HANDLE) {
        release(context);
        release(device);
        release(adapter);
        xrDestroyInstance(instance);
        return fail("xrCreateSession before requirements", result);
    }

    XrGraphicsRequirementsD3D11KHR requirements{};
    requirements.type = XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR;
    requirements.next = reinterpret_cast<void*>(static_cast<uintptr_t>(1));
    result = getRequirements(instance, systemId, &requirements);
    if (XR_FAILED(result) || requirements.minFeatureLevel != D3D_FEATURE_LEVEL_11_0 ||
        requirements.next != reinterpret_cast<void*>(static_cast<uintptr_t>(1))) {
        release(context);
        release(device);
        release(adapter);
        xrDestroyInstance(instance);
        return fail("xrGetD3D11GraphicsRequirementsKHR", result);
    }

    DXGI_ADAPTER_DESC1 adapterDescription{};
    hr = adapter->GetDesc1(&adapterDescription);
    release(adapter);
    if (FAILED(hr) || !luidEqual(adapterDescription.AdapterLuid, requirements.adapterLuid) ||
        selectedLevel < requirements.minFeatureLevel) {
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return failHresult("D3D11 adapter requirements validation", FAILED(hr) ? hr : E_FAIL);
    }

    result = xrCreateSession(instance, &sessionInfo, &session);
    if (XR_FAILED(result) || session == XR_NULL_HANDLE) {
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSession(D3D11 binding)", result);
    }
    if (expectConnected() && !controlSocketIsNotInheritable()) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return 1;
    }

    uint32_t referenceSpaceCount = 0;
    result = xrEnumerateReferenceSpaces(
        session, 0, &referenceSpaceCount, nullptr);
    XrReferenceSpaceType insufficientSpaces[1]{};
    if (XR_SUCCEEDED(result)) {
        result = xrEnumerateReferenceSpaces(
            session, 1, &referenceSpaceCount, insufficientSpaces);
        if (result != XR_ERROR_SIZE_INSUFFICIENT || referenceSpaceCount != 4) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrEnumerateReferenceSpaces(insufficient)", result);
        }
    }
    std::vector<XrReferenceSpaceType> referenceSpaces(referenceSpaceCount);
    result = xrEnumerateReferenceSpaces(
        session,
        referenceSpaceCount,
        &referenceSpaceCount,
        referenceSpaces.data());
    bool foundViewSpace = false;
    bool foundLocalSpace = false;
    bool foundLocalFloorSpace = false;
    bool foundStageSpace = false;
    for (XrReferenceSpaceType referenceSpace : referenceSpaces) {
        foundViewSpace =
            foundViewSpace || referenceSpace == XR_REFERENCE_SPACE_TYPE_VIEW;
        foundLocalSpace =
            foundLocalSpace || referenceSpace == XR_REFERENCE_SPACE_TYPE_LOCAL;
        foundLocalFloorSpace =
            foundLocalFloorSpace || referenceSpace == XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR;
        foundStageSpace =
            foundStageSpace || referenceSpace == XR_REFERENCE_SPACE_TYPE_STAGE;
    }
    if (XR_FAILED(result) || referenceSpaceCount != 4 ||
        !foundViewSpace || !foundLocalSpace ||
        !foundLocalFloorSpace || !foundStageSpace) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEnumerateReferenceSpaces", result);
    }

    XrReferenceSpaceCreateInfo referenceSpaceInfo{};
    referenceSpaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    referenceSpaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    // Floor-anchored spaces are part of the supported set: OpenVR titles ask
    // for a standing space during initialisation and treat a rejection as a
    // fatal error, so both floor variants must be creatable.
    for (XrReferenceSpaceType floorSpaceType : {XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR,
                                                XR_REFERENCE_SPACE_TYPE_STAGE}) {
        referenceSpaceInfo.referenceSpaceType = floorSpaceType;
        XrSpace floorSpace = XR_NULL_HANDLE;
        result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &floorSpace);
        if (XR_FAILED(result) || floorSpace == XR_NULL_HANDLE) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrCreateReferenceSpace(floor space)", result);
        }
        xrDestroySpace(floorSpace);
    }
    referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_UNBOUNDED_MSFT;
    XrSpace rejectedSpace = XR_NULL_HANDLE;
    result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &rejectedSpace);
    if (result != XR_ERROR_REFERENCE_SPACE_UNSUPPORTED ||
        rejectedSpace != XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateReferenceSpace(UNBOUNDED_MSFT)", result);
    }

    referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    referenceSpaceInfo.poseInReferenceSpace.orientation.w = 0.0f;
    result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &rejectedSpace);
    if (result != XR_ERROR_POSE_INVALID || rejectedSpace != XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateReferenceSpace(invalid pose)", result);
    }

    referenceSpaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    XrSpace viewSpace = XR_NULL_HANDLE;
    result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &viewSpace);
    referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    XrSpace localSpace = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &localSpace);
    }
    if (XR_FAILED(result) || viewSpace == XR_NULL_HANDLE ||
        localSpace == XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateReferenceSpace(VIEW/LOCAL)", result);
    }
    result = xrDestroySpace(viewSpace);
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrDestroySpace(VIEW)", result);
    }
    result = xrDestroySpace(viewSpace);
    if (result != XR_ERROR_HANDLE_INVALID) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("second xrDestroySpace(VIEW)", result);
    }

    if (!expectSessionState(instance, session, XR_SESSION_STATE_IDLE) ||
        !expectSessionState(instance, session, XR_SESSION_STATE_READY) ||
        !expectNoEvent(instance)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return 1;
    }

    XrFrameState frameState{};
    frameState.type = XR_TYPE_FRAME_STATE;
    result = xrWaitFrame(session, nullptr, &frameState);
    if (result != XR_ERROR_SESSION_NOT_RUNNING) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrWaitFrame before xrBeginSession", result);
    }
    result = xrBeginFrame(session, nullptr);
    if (result != XR_ERROR_SESSION_NOT_RUNNING) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrBeginFrame before xrBeginSession", result);
    }

    XrSessionBeginInfo beginInfo{};
    beginInfo.type = XR_TYPE_SESSION_BEGIN_INFO;
    beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    result = xrBeginSession(session, &beginInfo);
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrBeginSession", result);
    }
    result = xrBeginSession(session, &beginInfo);
    if (result != XR_ERROR_SESSION_RUNNING || !expectNoEvent(instance)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("second xrBeginSession", result);
    }
    result = xrEndSession(session);
    if (result != XR_ERROR_SESSION_NOT_STOPPING) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("early xrEndSession", result);
    }
    result = xrBeginFrame(session, nullptr);
    if (result != XR_ERROR_CALL_ORDER_INVALID) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrBeginFrame before xrWaitFrame", result);
    }

    void* const frameStateNext =
        reinterpret_cast<void*>(static_cast<uintptr_t>(1));
    frameState.next = frameStateNext;
    result = xrWaitFrame(session, nullptr, &frameState);
    const XrBool32 expectedShouldRender = expectConnected() ? XR_TRUE : XR_FALSE;
    // The daemon's HELLO_ACK display period paces a connected session;
    // headless sessions keep the 72 Hz default.
    const XrDuration expectedDisplayPeriod = expectConnected()
        ? static_cast<XrDuration>(expectedViewDimension(
              "BASALT_EXPECT_DISPLAY_PERIOD_NS", 13'888'889))
        : 13'888'889;
    if (XR_FAILED(result) || frameState.predictedDisplayTime <= 0 ||
        frameState.predictedDisplayPeriod != expectedDisplayPeriod ||
        frameState.shouldRender != expectedShouldRender ||
        frameState.next != frameStateNext) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("first xrWaitFrame", result);
    }
    result = xrBeginFrame(session, nullptr);
    XrFrameEndInfo frameEndInfo{};
    frameEndInfo.type = XR_TYPE_FRAME_END_INFO;
    frameEndInfo.displayTime = frameState.predictedDisplayTime;
    frameEndInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    if (XR_SUCCEEDED(result)) {
        result = xrEndFrame(session, &frameEndInfo);
    }
    bool firstFrameStatesOk =
        XR_SUCCEEDED(result) &&
        expectSessionState(instance, session, XR_SESSION_STATE_SYNCHRONIZED);
    if (firstFrameStatesOk && expectConnected()) {
        // A connected session becomes visible and focused once frames flow.
        firstFrameStatesOk =
            expectSessionState(instance, session, XR_SESSION_STATE_VISIBLE) &&
            expectSessionState(instance, session, XR_SESSION_STATE_FOCUSED);
    }
    if (!firstFrameStatesOk || !expectNoEvent(instance)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("first complete frame", result);
    }

    // hello_xr-shaped input initialization against the live session.
    XrPath leftHandPath = XR_NULL_PATH;
    result = xrStringToPath(instance, "/user/hand/left", &leftHandPath);
    XrPath rightHandPath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/right", &rightHandPath);
    }
    XrPath headPath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/head", &headPath);
    }

    XrActionSetCreateInfo actionSetInfo{};
    actionSetInfo.type = XR_TYPE_ACTION_SET_CREATE_INFO;
    std::strncpy(actionSetInfo.actionSetName, "gameplay", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(actionSetInfo.localizedActionSetName, "Gameplay",
                 XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    actionSetInfo.priority = 1;
    XrActionSet actionSet = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateActionSet(instance, &actionSetInfo, &actionSet);
    }

    const XrPath handPaths[] = {leftHandPath, rightHandPath};
    XrActionCreateInfo actionInfo{};
    actionInfo.type = XR_TYPE_ACTION_CREATE_INFO;
    actionInfo.actionType = XR_ACTION_TYPE_FLOAT_INPUT;
    actionInfo.countSubactionPaths = 2;
    actionInfo.subactionPaths = handPaths;
    std::strncpy(actionInfo.actionName, "grab_object", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Grab Object",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction grabAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(actionSet, &actionInfo, &grabAction);
    }
    actionInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
    std::strncpy(actionInfo.actionName, "hand_pose", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Hand Pose",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction poseAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(actionSet, &actionInfo, &poseAction);
    }
    actionInfo.actionType = XR_ACTION_TYPE_VIBRATION_OUTPUT;
    std::strncpy(actionInfo.actionName, "vibrate_hand", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Vibrate Hand",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction vibrateAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(actionSet, &actionInfo, &vibrateAction);
    }
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("input object creation", result);
    }

    // A second set binds the same Touch sources at a higher priority. It is
    // attached with Gameplay but activated only by the priority checks below.
    std::memset(actionSetInfo.actionSetName, 0, sizeof(actionSetInfo.actionSetName));
    std::memset(
        actionSetInfo.localizedActionSetName, 0,
        sizeof(actionSetInfo.localizedActionSetName));
    std::strncpy(actionSetInfo.actionSetName, "overlay", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(actionSetInfo.localizedActionSetName, "Overlay",
                 XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    actionSetInfo.priority = 10;
    XrActionSet overlayActionSet = XR_NULL_HANDLE;
    result = xrCreateActionSet(instance, &actionSetInfo, &overlayActionSet);

    actionInfo.actionType = XR_ACTION_TYPE_FLOAT_INPUT;
    std::memset(actionInfo.actionName, 0, sizeof(actionInfo.actionName));
    std::memset(actionInfo.localizedActionName, 0, sizeof(actionInfo.localizedActionName));
    std::strncpy(actionInfo.actionName, "overlay_grab", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Overlay Grab",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction overlayGrabAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(overlayActionSet, &actionInfo, &overlayGrabAction);
    }
    actionInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
    std::memset(actionInfo.actionName, 0, sizeof(actionInfo.actionName));
    std::memset(actionInfo.localizedActionName, 0, sizeof(actionInfo.localizedActionName));
    std::strncpy(actionInfo.actionName, "overlay_pose", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Overlay Pose",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction overlayPoseAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(overlayActionSet, &actionInfo, &overlayPoseAction);
    }
    actionInfo.actionType = XR_ACTION_TYPE_VIBRATION_OUTPUT;
    std::memset(actionInfo.actionName, 0, sizeof(actionInfo.actionName));
    std::memset(actionInfo.localizedActionName, 0, sizeof(actionInfo.localizedActionName));
    std::strncpy(actionInfo.actionName, "overlay_haptic", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Overlay Haptic",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction overlayHapticAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(overlayActionSet, &actionInfo, &overlayHapticAction);
    }
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("priority input object creation", result);
    }

    XrActionSpaceCreateInfo actionSpaceInfo{};
    actionSpaceInfo.type = XR_TYPE_ACTION_SPACE_CREATE_INFO;
    actionSpaceInfo.action = poseAction;
    actionSpaceInfo.subactionPath = leftHandPath;
    actionSpaceInfo.poseInActionSpace.orientation.w = 1.0f;
    XrSpace handSpace = XR_NULL_HANDLE;
    result = xrCreateActionSpace(session, &actionSpaceInfo, &handSpace);
    if (XR_FAILED(result) || handSpace == XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateActionSpace before attach", result);
    }
    actionSpaceInfo.action = grabAction;
    XrSpace rejectedSpace2 = XR_NULL_HANDLE;
    result = xrCreateActionSpace(session, &actionSpaceInfo, &rejectedSpace2);
    if (result != XR_ERROR_ACTION_TYPE_MISMATCH || rejectedSpace2 != XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateActionSpace(non-pose action)", result);
    }

    XrActiveActionSet activeActionSet{actionSet, XR_NULL_PATH};
    XrActionsSyncInfo syncInfo{};
    syncInfo.type = XR_TYPE_ACTIONS_SYNC_INFO;
    syncInfo.countActiveActionSets = 1;
    syncInfo.activeActionSets = &activeActionSet;
    result = xrSyncActions(session, &syncInfo);
    if (result != XR_ERROR_ACTIONSET_NOT_ATTACHED) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrSyncActions before attach", result);
    }

    XrPath touchProfilePath = XR_NULL_PATH;
    result = xrStringToPath(
        instance, "/interaction_profiles/oculus/touch_controller", &touchProfilePath);
    XrPath squeezePath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/left/input/squeeze/value", &squeezePath);
    }
    XrPath gripPosePath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/left/input/grip/pose", &gripPosePath);
    }
    XrPath hapticPath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/left/output/haptic", &hapticPath);
    }
    const XrActionSuggestedBinding suggested[] = {
        {grabAction, squeezePath},
        {poseAction, gripPosePath},
        {vibrateAction, hapticPath},
        {overlayGrabAction, squeezePath},
        {overlayPoseAction, gripPosePath},
        {overlayHapticAction, hapticPath},
    };
    XrInteractionProfileSuggestedBinding suggestedBindings{};
    suggestedBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    suggestedBindings.interactionProfile = touchProfilePath;
    suggestedBindings.countSuggestedBindings = 6;
    suggestedBindings.suggestedBindings = suggested;
    if (XR_SUCCEEDED(result)) {
        result = xrSuggestInteractionProfileBindings(instance, &suggestedBindings);
    }
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("suggest touch bindings", result);
    }

    XrSessionActionSetsAttachInfo attachInfo{};
    attachInfo.type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO;
    const XrActionSet attachedActionSets[] = {actionSet, overlayActionSet};
    attachInfo.countActionSets = 2;
    attachInfo.actionSets = attachedActionSets;
    result = xrAttachSessionActionSets(session, &attachInfo);
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrAttachSessionActionSets", result);
    }
    result = xrAttachSessionActionSets(session, &attachInfo);
    if (result != XR_ERROR_ACTIONSETS_ALREADY_ATTACHED) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("second xrAttachSessionActionSets", result);
    }
    XrHandTrackerEXT leftHandTracker = XR_NULL_HANDLE;
    XrHandTrackerEXT rightHandTracker = XR_NULL_HANDLE;
    if (handTrackingEnabled &&
        !checkHandTrackersAfterAttach(
            handTracking, session, localSpace, frameState.predictedDisplayTime,
            &leftHandTracker, &rightHandTracker)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return 1;
    }
    std::strncpy(actionInfo.actionName, "late_action", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Late Action",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction lateAction = XR_NULL_HANDLE;
    result = xrCreateAction(actionSet, &actionInfo, &lateAction);
    if (result != XR_ERROR_ACTIONSETS_ALREADY_ATTACHED || lateAction != XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateAction after attach", result);
    }
    result = xrSuggestInteractionProfileBindings(instance, &suggestedBindings);
    if (result != XR_ERROR_ACTIONSETS_ALREADY_ATTACHED) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("suggest bindings after attach", result);
    }

    result = xrSyncActions(session, &syncInfo);
    if (result != (expectConnected() ? XR_SUCCESS : XR_SESSION_NOT_FOCUSED)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrSyncActions attached", result);
    }

    XrActionStateGetInfo getInfo{};
    getInfo.type = XR_TYPE_ACTION_STATE_GET_INFO;
    getInfo.action = grabAction;
    getInfo.subactionPath = leftHandPath;
    XrActionStateFloat floatState{};
    floatState.type = XR_TYPE_ACTION_STATE_FLOAT;
    result = xrGetActionStateFloat(session, &getInfo, &floatState);
    const bool injectedController = expectInjectedHeadPose();
    const bool requireController = injectedController || requireControllerInput();
    if (XR_SUCCEEDED(result) && requireController &&
        floatState.isActive != XR_TRUE) {
        // StreamReady only proves that ALVR's sockets are live. A Touch
        // controller can legitimately remain inactive for a short interval
        // while the user wakes or picks it up. The native daemon's injected
        // input is likewise asynchronous: it follows HelloAck, while this first
        // sync runs ~3 ms after session creation. Keep the acceptance gate
        // strict, but do not race that asynchronous acquisition at startup.
        // The injected wait stays well inside the 500 ms pose-freshness window.
        const int attempts = requireControllerInput() ? 3000 : 25;
        if (requireControllerInput()) {
            std::printf("INFO: waiting up to 30 seconds for the left Touch controller; move it now\n");
        }
        for (int attempt = 0; attempt < attempts && floatState.isActive != XR_TRUE;
             ++attempt) {
            result = xrSyncActions(session, &syncInfo);
            if (XR_SUCCEEDED(result)) {
                result = xrGetActionStateFloat(session, &getInfo, &floatState);
            }
            if (XR_FAILED(result)) { break; }
            Sleep(10);
        }
    }
    if (XR_FAILED(result) ||
        floatState.isActive != (requireController ? XR_TRUE : XR_FALSE) ||
        (injectedController && !nearlyEqual(floatState.currentState, 0.75f)) ||
        (!requireController && floatState.currentState != 0.0f) ||
        (requireControllerInput() &&
         (!std::isfinite(floatState.currentState) || floatState.currentState < 0.0f ||
          floatState.currentState > 1.0f)) ||
        (injectedController && floatState.lastChangeTime <= 0) ||
        floatState.changedSinceLastSync != XR_FALSE) {
        std::fprintf(
            stderr,
            "INFO: initial float state active=%u current=%.3f changed=%u "
            "changeTime=%lld requireController=%u injected=%u\n",
            floatState.isActive, floatState.currentState,
            floatState.changedSinceLastSync,
            static_cast<long long>(floatState.lastChangeTime),
            requireController ? 1u : 0u, injectedController ? 1u : 0u);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetActionStateFloat", result);
    }
    XrActionStateBoolean booleanState{};
    booleanState.type = XR_TYPE_ACTION_STATE_BOOLEAN;
    result = xrGetActionStateBoolean(session, &getInfo, &booleanState);
    if (result != XR_ERROR_ACTION_TYPE_MISMATCH) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetActionStateBoolean type mismatch", result);
    }
    getInfo.subactionPath = headPath;
    result = xrGetActionStateFloat(session, &getInfo, &floatState);
    if (result != XR_ERROR_PATH_UNSUPPORTED) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("undeclared subaction path", result);
    }
    getInfo.action = poseAction;
    getInfo.subactionPath = leftHandPath;
    XrActionStatePose poseState{};
    poseState.type = XR_TYPE_ACTION_STATE_POSE;
    result = xrGetActionStatePose(session, &getInfo, &poseState);
    if (XR_SUCCEEDED(result) && requireControllerInput() &&
        poseState.isActive != XR_TRUE) {
        std::printf("INFO: waiting up to 10 seconds for the left Touch controller; move it now\n");
        for (int attempt = 0; attempt < 1000 && poseState.isActive != XR_TRUE; ++attempt) {
            result = xrSyncActions(session, &syncInfo);
            if (XR_SUCCEEDED(result)) {
                result = xrGetActionStatePose(session, &getInfo, &poseState);
            }
            if (XR_FAILED(result)) { break; }
            Sleep(10);
        }
    }
    if (XR_FAILED(result) ||
        poseState.isActive != (requireController ? XR_TRUE : XR_FALSE)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetActionStatePose", result);
    }

    XrInteractionProfileState profileState{};
    profileState.type = XR_TYPE_INTERACTION_PROFILE_STATE;
    result = xrGetCurrentInteractionProfile(session, leftHandPath, &profileState);
    if (XR_FAILED(result) || profileState.interactionProfile !=
            (requireController ? touchProfilePath : XR_NULL_PATH)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetCurrentInteractionProfile", result);
    }
    if (!(requireController
              ? expectInteractionProfileChanged(instance, session)
              : expectNoEvent(instance)) ||
        !expectNoEvent(instance)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return 1;
    }

    XrBoundSourcesForActionEnumerateInfo boundSourcesInfo{};
    boundSourcesInfo.type = XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO;
    boundSourcesInfo.action = grabAction;
    uint32_t boundSourceCount = UINT32_MAX;
    result = xrEnumerateBoundSourcesForAction(
        session, &boundSourcesInfo, 0, &boundSourceCount, nullptr);
    if (XR_FAILED(result) || boundSourceCount != (requireController ? 1u : 0u)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEnumerateBoundSourcesForAction", result);
    }
    XrPath boundSource = XR_NULL_PATH;
    if (requireController) {
        result = xrEnumerateBoundSourcesForAction(
            session, &boundSourcesInfo, 1, &boundSourceCount, &boundSource);
        if (XR_FAILED(result) || boundSourceCount != 1 || boundSource != squeezePath) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrEnumerateBoundSourcesForAction values", result);
        }
    }
    // OpenComposite's activeOriginFromSubaction prefix-matches these sources
    // against "/user/hand/left"; pose and haptic actions must report the
    // left-hand source like the button action does.
    const struct {
        XrAction action;
        XrPath expected;
        const char* label;
    } leftHandSources[] = {
        {poseAction, gripPosePath, "pose"},
        {vibrateAction, hapticPath, "haptic"},
    };
    for (const auto& expectedSource : leftHandSources) {
        boundSourcesInfo.action = expectedSource.action;
        XrPath source = XR_NULL_PATH;
        boundSourceCount = UINT32_MAX;
        result = xrEnumerateBoundSourcesForAction(
            session, &boundSourcesInfo, 1, &boundSourceCount, &source);
        if (XR_FAILED(result) ||
            boundSourceCount != (requireController ? 1u : 0u) ||
            (requireController && source != expectedSource.expected)) {
            std::fprintf(stderr, "FAIL: left-hand %s bound source (count %u)\n",
                         expectedSource.label, boundSourceCount);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrEnumerateBoundSourcesForAction left hand", result);
        }
    }
    boundSourcesInfo.action = grabAction;

    XrInputSourceLocalizedNameGetInfo localizedNameInfo{};
    localizedNameInfo.type = XR_TYPE_INPUT_SOURCE_LOCALIZED_NAME_GET_INFO;
    localizedNameInfo.sourcePath = requireController ? boundSource : squeezePath;
    localizedNameInfo.whichComponents =
        XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT |
        XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT;
    uint32_t localizedNameCount = UINT32_MAX;
    result = xrGetInputSourceLocalizedName(
        session, &localizedNameInfo, 0, &localizedNameCount, nullptr);
    if (requireController) {
        constexpr const char* kLocalized = "Left Hand Squeeze";
        char localizedName[64]{};
        const uint32_t expectedCount = static_cast<uint32_t>(std::strlen(kLocalized) + 1);
        if (XR_FAILED(result) || localizedNameCount != expectedCount) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrGetInputSourceLocalizedName count", result);
        }
        uint32_t shortCount = 0;
        result = xrGetInputSourceLocalizedName(
            session, &localizedNameInfo, expectedCount - 1, &shortCount, localizedName);
        if (result != XR_ERROR_SIZE_INSUFFICIENT || shortCount != expectedCount) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrGetInputSourceLocalizedName short buffer", result);
        }
        result = xrGetInputSourceLocalizedName(
            session, &localizedNameInfo, sizeof(localizedName),
            &localizedNameCount, localizedName);
        if (XR_FAILED(result) || std::strcmp(localizedName, kLocalized) != 0) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrGetInputSourceLocalizedName value", result);
        }
        localizedNameInfo.whichComponents =
            XR_INPUT_SOURCE_LOCALIZED_NAME_INTERACTION_PROFILE_BIT;
        result = xrGetInputSourceLocalizedName(
            session, &localizedNameInfo, sizeof(localizedName),
            &localizedNameCount, localizedName);
        if (XR_FAILED(result) ||
            std::strcmp(localizedName, "Oculus Touch Controller") != 0) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrGetInputSourceLocalizedName profile", result);
        }
    } else if (result != XR_ERROR_PATH_UNSUPPORTED || localizedNameCount != 0) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetInputSourceLocalizedName without source", result);
    }
    localizedNameInfo.whichComponents =
        static_cast<XrInputSourceLocalizedNameFlags>(0x8);
    result = xrGetInputSourceLocalizedName(
        session, &localizedNameInfo, 0, &localizedNameCount, nullptr);
    if (result != XR_ERROR_VALIDATION_FAILURE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetInputSourceLocalizedName invalid flags", result);
    }

    XrHapticActionInfo hapticInfo{};
    hapticInfo.type = XR_TYPE_HAPTIC_ACTION_INFO;
    hapticInfo.action = vibrateAction;
    hapticInfo.subactionPath = leftHandPath;
    XrHapticVibration vibration{};
    vibration.type = XR_TYPE_HAPTIC_VIBRATION;
    vibration.duration = options.visual ? 50'000'000 : XR_MIN_HAPTIC_DURATION;
    vibration.frequency = XR_FREQUENCY_UNSPECIFIED;
    vibration.amplitude = 0.5f;
    const XrResult expectedHapticResult =
        expectConnected() ? XR_SUCCESS : XR_SESSION_NOT_FOCUSED;
    result = xrApplyHapticFeedback(
        session, &hapticInfo, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
    if (result == expectedHapticResult) {
        if (options.visual && XR_SUCCEEDED(result)) {
            Sleep(60);
        }
        result = xrStopHapticFeedback(session, &hapticInfo);
    }
    if (result != expectedHapticResult) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("haptic feedback", result);
    }

    // OpenComposite's TriggerHapticVibrationAction forwards OpenVR values
    // unchanged and aborts the game on any failure (The Lab level select).
    // Each value is spec-valid or normalized, never XR_ERROR_VALIDATION_FAILURE.
    // Connected, each reaches the daemon once on the left hand (11 calls),
    // which checks the normalized sequence: zero amplitude is a stop, never a
    // pulse; durations <= 0 with amplitude play the 5 ms minimum.
    struct OpenCompositeHaptic {
        const char* label;
        XrPath subactionPath;
        XrDuration duration;
        float frequency;
        float amplitude;
    };
    const float infinity = std::numeric_limits<float>::infinity();
    const float notANumber = std::numeric_limits<float>::quiet_NaN();
    const OpenCompositeHaptic openCompositeHaptics[] = {
        // Hand.TriggerHapticPulse(0): seconds 0, frequency 1 / 0.
        {"zero duration, infinite frequency", leftHandPath, 0, infinity, 1.0f},
        // (int)(3.0f * 1e9f) overflows to INT_MIN on x86.
        {"overflowed duration", leftHandPath, INT32_MIN, 320.0f, 1.0f},
        {"amplitude above one", leftHandPath, 50'000'000, -1.0f, 1.5f},
        {"non-finite amplitude", leftHandPath, 10'000'000, notANumber, notANumber},
        // No ulRestrictToDevice: XR_NULL_PATH, frequency unspecified.
        {"null subaction path", XR_NULL_PATH, XR_MIN_HAPTIC_DURATION,
         XR_FREQUENCY_UNSPECIFIED, 0.5f},
        // Silence must not become a pulse, whatever the duration.
        {"zero amplitude, zero duration", leftHandPath, 0, infinity, 0.0f},
        {"zero amplitude, 20 ms", leftHandPath, 20'000'000, 160.0f, 0.0f},
        {"negative amplitude", leftHandPath, 20'000'000, 160.0f, -0.5f},
        // The Lab's teleport hint: Hand.TriggerHapticPulse(500) every 50 ms,
        // i.e. 0.0005 s at 1 / 0.0005 Hz, full amplitude.
        {"500 us hint pulse", leftHandPath, 500'000, 2000.0f, 1.0f},
        // IVRSystem::TriggerHapticPulse(us): us * 1000 ns, amplitude 1.
        {"legacy 3999 us pulse", leftHandPath, 3'999'000,
         XR_FREQUENCY_UNSPECIFIED, 1.0f},
        {"legacy 0 us pulse", leftHandPath, 0, XR_FREQUENCY_UNSPECIFIED, 1.0f},
    };
    for (const OpenCompositeHaptic& haptic : openCompositeHaptics) {
        XrHapticActionInfo ocInfo{};
        ocInfo.type = XR_TYPE_HAPTIC_ACTION_INFO;
        ocInfo.action = vibrateAction;
        ocInfo.subactionPath = haptic.subactionPath;
        XrHapticVibration ocVibration{};
        ocVibration.type = XR_TYPE_HAPTIC_VIBRATION;
        ocVibration.duration = haptic.duration;
        ocVibration.frequency = haptic.frequency;
        ocVibration.amplitude = haptic.amplitude;
        result = xrApplyHapticFeedback(
            session, &ocInfo, reinterpret_cast<const XrHapticBaseHeader*>(&ocVibration));
        if (result != expectedHapticResult) {
            std::fprintf(stderr, "FAIL: OpenComposite haptic (%s)\n", haptic.label);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("OpenComposite haptic values", result);
        }
    }
    {
        // Structurally invalid input still fails validation.
        XrHapticVibration wrongType{};
        wrongType.type = XR_TYPE_HAPTIC_ACTION_INFO;
        wrongType.duration = XR_MIN_HAPTIC_DURATION;
        wrongType.amplitude = 0.5f;
        result = xrApplyHapticFeedback(
            session, &hapticInfo, reinterpret_cast<const XrHapticBaseHeader*>(&wrongType));
        if (result != XR_ERROR_VALIDATION_FAILURE) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("haptic wrong struct type", result);
        }
    }
    std::printf("PASS: OpenComposite haptic values (zero/overflowed duration, "
                "infinite/negative frequency, zero/out-of-range/NaN amplitude, "
                "null subaction, 500 us and legacy microsecond pulses) return %s\n",
                expectedHapticResult == XR_SUCCESS ? "XR_SUCCESS" : "XR_SESSION_NOT_FOCUSED");

    if (injectedController) {
        // The native daemon answers the first haptic with a sparse squeeze
        // delta. Sync until the receiver publishes it, then prove changed is
        // frozen for one sync and clears on the next unchanged sync.
        getInfo.action = grabAction;
        getInfo.subactionPath = leftHandPath;
        for (int attempt = 0; attempt < 100; ++attempt) {
            result = xrSyncActions(session, &syncInfo);
            if (XR_SUCCEEDED(result)) {
                result = xrGetActionStateFloat(session, &getInfo, &floatState);
            }
            if (XR_SUCCEEDED(result) && nearlyEqual(floatState.currentState, 0.25f)) {
                break;
            }
            Sleep(10);
        }
        if (XR_FAILED(result) || !nearlyEqual(floatState.currentState, 0.25f) ||
            floatState.isActive != XR_TRUE ||
            floatState.changedSinceLastSync != XR_TRUE ||
            floatState.lastChangeTime <= 0) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("controller button delta", result);
        }
        const XrTime changeTime = floatState.lastChangeTime;
        result = xrSyncActions(session, &syncInfo);
        if (XR_SUCCEEDED(result)) {
            result = xrGetActionStateFloat(session, &getInfo, &floatState);
        }
        if (XR_FAILED(result) || floatState.changedSinceLastSync != XR_FALSE ||
            floatState.lastChangeTime != changeTime) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("unchanged controller button", result);
        }

        // The Overlay set owns the same squeeze, grip, and haptic sources at a
        // higher priority. Active-set array order must not affect suppression.
        const XrActiveActionSet prioritySets[] = {
            {overlayActionSet, XR_NULL_PATH},
            {actionSet, XR_NULL_PATH},
        };
        syncInfo.countActiveActionSets = 2;
        syncInfo.activeActionSets = prioritySets;
        result = xrSyncActions(session, &syncInfo);
        getInfo.action = grabAction;
        if (XR_SUCCEEDED(result)) {
            result = xrGetActionStateFloat(session, &getInfo, &floatState);
        }
        XrActionStateFloat overlayFloatState{};
        overlayFloatState.type = XR_TYPE_ACTION_STATE_FLOAT;
        getInfo.action = overlayGrabAction;
        if (XR_SUCCEEDED(result)) {
            result = xrGetActionStateFloat(session, &getInfo, &overlayFloatState);
        }
        if (XR_FAILED(result) || floatState.isActive != XR_FALSE ||
            floatState.currentState != 0.0f ||
            overlayFloatState.isActive != XR_TRUE ||
            !nearlyEqual(overlayFloatState.currentState, 0.25f)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("action-set input priority", result);
        }

        getInfo.action = poseAction;
        result = xrGetActionStatePose(session, &getInfo, &poseState);
        XrSpaceLocation suppressedLocation{};
        suppressedLocation.type = XR_TYPE_SPACE_LOCATION;
        if (XR_SUCCEEDED(result)) {
            result = xrLocateSpace(
                handSpace, localSpace, frameState.predictedDisplayTime,
                &suppressedLocation);
        }
        boundSourcesInfo.action = grabAction;
        boundSourceCount = UINT32_MAX;
        if (XR_SUCCEEDED(result)) {
            result = xrEnumerateBoundSourcesForAction(
                session, &boundSourcesInfo, 0, &boundSourceCount, nullptr);
        }
        if (XR_FAILED(result) || poseState.isActive != XR_FALSE ||
            suppressedLocation.locationFlags != 0 || boundSourceCount != 0) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("action-set pose/source priority", result);
        }

        // Suppressed output bindings succeed but must not reach the daemon;
        // its final exact haptic count proves this call remained a no-op.
        result = xrApplyHapticFeedback(
            session, &hapticInfo,
            reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
        if (XR_SUCCEEDED(result)) {
            result = xrStopHapticFeedback(session, &hapticInfo);
        }
        if (XR_FAILED(result)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("suppressed lower-priority haptic", result);
        }

        // Destroying the public high-priority action handle does not remove
        // its underlying source from core priority processing.
        result = xrDestroyAction(overlayGrabAction);
        if (XR_SUCCEEDED(result)) {
            result = xrSyncActions(session, &syncInfo);
        }
        getInfo.action = grabAction;
        if (XR_SUCCEEDED(result)) {
            result = xrGetActionStateFloat(session, &getInfo, &floatState);
        }
        if (XR_FAILED(result) || floatState.isActive != XR_FALSE) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("destroyed-action priority resource", result);
        }

        // Removing Overlay from the active sync immediately restores every
        // Gameplay binding without changing the interaction profile.
        syncInfo.countActiveActionSets = 1;
        syncInfo.activeActionSets = &activeActionSet;
        result = xrSyncActions(session, &syncInfo);
        getInfo.action = grabAction;
        if (XR_SUCCEEDED(result)) {
            result = xrGetActionStateFloat(session, &getInfo, &floatState);
        }
        getInfo.action = poseAction;
        if (XR_SUCCEEDED(result)) {
            result = xrGetActionStatePose(session, &getInfo, &poseState);
        }
        if (XR_FAILED(result) || floatState.isActive != XR_TRUE ||
            poseState.isActive != XR_TRUE || !expectNoEvent(instance)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("action-set priority restore", result);
        }
    }

    const XrTime locateTime = frameState.predictedDisplayTime;
    XrSpaceVelocity controllerVelocity{};
    controllerVelocity.type = XR_TYPE_SPACE_VELOCITY;
    XrSpaceLocation location{};
    location.type = XR_TYPE_SPACE_LOCATION;
    location.next = &controllerVelocity;
    result = xrLocateSpace(handSpace, localSpace, locateTime, &location);
    constexpr XrSpaceLocationFlags kControllerTrackedFlags =
        XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
        XR_SPACE_LOCATION_POSITION_VALID_BIT |
        XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
        XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
    const XrSpaceLocationFlags expectedControllerFlags =
        requireController ? kControllerTrackedFlags : 0;
    if (XR_FAILED(result) || location.locationFlags != expectedControllerFlags ||
        (injectedController &&
         (!nearlyEqual(location.pose.position.x, -0.1f) ||
          !nearlyEqual(location.pose.position.y, 1.2f) ||
          !nearlyEqual(location.pose.position.z, -0.45f) ||
          controllerVelocity.velocityFlags !=
              (XR_SPACE_VELOCITY_LINEAR_VALID_BIT |
               XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) ||
          !nearlyEqual(controllerVelocity.linearVelocity.x, -0.3f) ||
          !nearlyEqual(controllerVelocity.linearVelocity.y, 0.2f) ||
          !nearlyEqual(controllerVelocity.linearVelocity.z, 0.1f) ||
          !nearlyEqual(controllerVelocity.angularVelocity.x, 0.0f) ||
          !nearlyEqual(controllerVelocity.angularVelocity.y, 0.5f) ||
          !nearlyEqual(controllerVelocity.angularVelocity.z, 0.0f)))) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrLocateSpace(action space)", result);
    }

    if (injectedController) {
        // Ask the native daemon to publish mask(timestamp=3, absent), followed
        // by stale motion(timestamp=2). The pose and chained velocity must
        // clear together and remain cleared after the stale packet.
        vibration.amplitude = 0.125f;
        result = xrApplyHapticFeedback(
            session, &hapticInfo,
            reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
        for (int attempt = 0; XR_SUCCEEDED(result) && attempt < 100; ++attempt) {
            result = xrSyncActions(session, &syncInfo);
            getInfo.action = poseAction;
            if (XR_SUCCEEDED(result)) {
                result = xrGetActionStatePose(session, &getInfo, &poseState);
            }
            if (XR_SUCCEEDED(result) && poseState.isActive == XR_FALSE) {
                break;
            }
            Sleep(10);
        }
        controllerVelocity = {};
        controllerVelocity.type = XR_TYPE_SPACE_VELOCITY;
        location = {};
        location.type = XR_TYPE_SPACE_LOCATION;
        location.next = &controllerVelocity;
        if (XR_SUCCEEDED(result)) {
            result = xrLocateSpace(handSpace, localSpace, locateTime, &location);
        }
        if (XR_FAILED(result) || poseState.isActive != XR_FALSE ||
            location.locationFlags != 0 || controllerVelocity.velocityFlags != 0) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("authoritative controller loss", result);
        }

        // A later motion+presence pair restores the same action and its raw
        // velocity. Haptics depend on the retained profile, so this recovery
        // request remains routable while pose tracking is absent.
        vibration.amplitude = 0.25f;
        result = xrApplyHapticFeedback(
            session, &hapticInfo,
            reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
        for (int attempt = 0; XR_SUCCEEDED(result) && attempt < 100; ++attempt) {
            result = xrSyncActions(session, &syncInfo);
            getInfo.action = poseAction;
            if (XR_SUCCEEDED(result)) {
                result = xrGetActionStatePose(session, &getInfo, &poseState);
            }
            if (XR_SUCCEEDED(result) && poseState.isActive == XR_TRUE) {
                break;
            }
            Sleep(10);
        }
        controllerVelocity = {};
        controllerVelocity.type = XR_TYPE_SPACE_VELOCITY;
        location = {};
        location.type = XR_TYPE_SPACE_LOCATION;
        location.next = &controllerVelocity;
        if (XR_SUCCEEDED(result)) {
            result = xrLocateSpace(handSpace, localSpace, locateTime, &location);
        }
        if (XR_FAILED(result) || poseState.isActive != XR_TRUE ||
            location.locationFlags != kControllerTrackedFlags ||
            controllerVelocity.velocityFlags !=
                (XR_SPACE_VELOCITY_LINEAR_VALID_BIT |
                 XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) ||
            !nearlyEqual(controllerVelocity.linearVelocity.x, -0.3f) ||
            !nearlyEqual(controllerVelocity.linearVelocity.y, 0.2f) ||
            !nearlyEqual(controllerVelocity.linearVelocity.z, 0.1f) ||
            !nearlyEqual(controllerVelocity.angularVelocity.y, 0.5f)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("controller tracking recovery", result);
        }
        std::puts(
            "PASS: controller presence clears stale pose/velocity and recovers");

        if (handTrackingEnabled &&
            !checkInjectedHandSkeleton(
                handTracking, session, leftHandTracker, rightHandTracker,
                localSpace, handSpace, locateTime, hapticInfo, vibration)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return 1;
        }
    }

    // Public action destruction must not invalidate the backing resource of
    // an already-created action space (OpenXR action-space lifetime rule).
    result = xrDestroyAction(poseAction);
    if (XR_FAILED(result) || xrDestroyAction(poseAction) != XR_ERROR_HANDLE_INVALID) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrDestroyAction lifetime setup", result);
    }
    XrSpace rejectedDestroyedActionSpace = XR_NULL_HANDLE;
    actionSpaceInfo.action = poseAction;
    result = xrCreateActionSpace(
        session, &actionSpaceInfo, &rejectedDestroyedActionSpace);
    if (result != XR_ERROR_HANDLE_INVALID ||
        rejectedDestroyedActionSpace != XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("create space from destroyed action", result);
    }
    result = xrLocateSpace(handSpace, localSpace, locateTime, &location);
    if (XR_FAILED(result) || location.locationFlags != expectedControllerFlags) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("action space after xrDestroyAction", result);
    }
    if (requireControllerInput()) {
        std::printf(
            "PASS: live left controller reached OpenXR actions "
            "(squeeze %.3f, position %.3f %.3f %.3f)\n",
            floatState.currentState, location.pose.position.x,
            location.pose.position.y, location.pose.position.z);
    }

    referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    location.next = nullptr;
    referenceSpaceInfo.poseInReferenceSpace.position = {1.0f, 2.0f, 3.0f};
    XrSpace offsetSpace = XR_NULL_HANDLE;
    result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &offsetSpace);
    if (XR_SUCCEEDED(result)) {
        result = xrLocateSpace(offsetSpace, localSpace, 0, &location);
        if (result != XR_ERROR_TIME_INVALID) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateSpace invalid time", result);
        }
        result = xrLocateSpace(offsetSpace, localSpace, locateTime, &location);
    }
    constexpr XrSpaceLocationFlags kValidFlags =
        XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    if (XR_FAILED(result) || location.locationFlags != kValidFlags ||
        location.pose.position.x != 1.0f || location.pose.position.y != 2.0f ||
        location.pose.position.z != 3.0f || location.pose.orientation.w != 1.0f) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrLocateSpace(offset LOCAL)", result);
    }
    referenceSpaceInfo.poseInReferenceSpace.position = {0.0f, 0.0f, 0.0f};

    XrViewLocateInfo viewLocateInfo{};
    viewLocateInfo.type = XR_TYPE_VIEW_LOCATE_INFO;
    viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    viewLocateInfo.displayTime = locateTime;
    viewLocateInfo.space = localSpace;
    XrViewState viewState{};
    viewState.type = XR_TYPE_VIEW_STATE;
    constexpr XrViewStateFlags kTrackedViewFlags =
        XR_VIEW_STATE_ORIENTATION_VALID_BIT |
        XR_VIEW_STATE_POSITION_VALID_BIT |
        XR_VIEW_STATE_ORIENTATION_TRACKED_BIT |
        XR_VIEW_STATE_POSITION_TRACKED_BIT;
    const XrViewStateFlags expectedViewFlags =
        requireHeadPose() ? kTrackedViewFlags : 0;
    uint32_t viewCount = 0;
    result = xrLocateViews(session, &viewLocateInfo, &viewState, 0, &viewCount, nullptr);
    for (int attempt = 0;
         XR_SUCCEEDED(result) && requireHeadPose() &&
             viewState.viewStateFlags != expectedViewFlags && attempt < 100;
         ++attempt) {
        Sleep(10);
        result = xrLocateViews(
            session, &viewLocateInfo, &viewState, 0, &viewCount, nullptr);
    }
    if (XR_SUCCEEDED(result) &&
        (viewCount != 2 || viewState.viewStateFlags != expectedViewFlags)) {
        result = XR_ERROR_VALIDATION_FAILURE;
    }
    XrView locatedViews[2]{};
    locatedViews[0].type = XR_TYPE_VIEW;
    locatedViews[1].type = XR_TYPE_VIEW;
    if (XR_SUCCEEDED(result) && viewCount == 2) {
        result = xrLocateViews(
            session, &viewLocateInfo, &viewState, 2, &viewCount, locatedViews);
    } else if (XR_SUCCEEDED(result)) {
        result = XR_ERROR_VALIDATION_FAILURE;
    }
    if (XR_FAILED(result) || viewState.viewStateFlags != expectedViewFlags ||
        locatedViews[0].fov.angleRight <= 0.0f ||
        locatedViews[0].fov.angleLeft >= locatedViews[0].fov.angleRight ||
        locatedViews[0].fov.angleDown >= locatedViews[0].fov.angleUp) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrLocateViews", result);
    }
    if (expectInjectedHeadPose()) {
        // The native daemon injects a nonzero guardian-stage position and a
        // 90-degree yaw. The initial LOCAL origin centers both horizontal
        // position and yaw while preserving Quest floor height.
        if (!nearlyEqual(locatedViews[0].pose.position.x, -0.032f) ||
            !nearlyEqual(locatedViews[1].pose.position.x, 0.032f) ||
            !nearlyEqual(locatedViews[0].fov.angleLeft, -0.85f) ||
            !nearlyEqual(locatedViews[0].fov.angleRight, 0.75f) ||
            !nearlyEqual(locatedViews[1].fov.angleLeft, -0.75f) ||
            !nearlyEqual(locatedViews[1].fov.angleRight, 0.85f) ||
            !nearlyEqual(locatedViews[0].pose.position.y, 1.5f) ||
            !nearlyEqual(locatedViews[0].pose.position.z, 0.0f) ||
            !nearlyEqual(locatedViews[1].pose.position.z, 0.0f) ||
            !nearlyEqual(locatedViews[0].pose.orientation.y, 0.0f) ||
            !nearlyEqual(locatedViews[0].pose.orientation.w, 1.0f)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateViews(live head pose)", XR_ERROR_VALIDATION_FAILURE);
        }

        // Ask the native daemon to turn the injected head another 90 degrees
        // and hold the Quest right-system button. Basalt must recenter LOCAL,
        // notify the application, and expose the current leveled head as the
        // new forward origin without losing floor height.
        vibration.amplitude = 0.375f;
        result = xrApplyHapticFeedback(
            session, &hapticInfo,
            reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
        // STAGE shares LOCAL's origin, so the recenter is announced for both,
        // LOCAL first, with the same changeTime and previous-space pose.
        XrEventDataReferenceSpaceChangePending recenterEvent{};
        XrEventDataReferenceSpaceChangePending stageRecenterEvent{};
        uint32_t receivedRecenters = 0;
        for (int attempt = 0;
             XR_SUCCEEDED(result) && receivedRecenters < 2 && attempt < 100; ++attempt) {
            XrEventDataBuffer eventData{};
            eventData.type = XR_TYPE_EVENT_DATA_BUFFER;
            const XrResult eventResult = xrPollEvent(instance, &eventData);
            if (eventResult == XR_EVENT_UNAVAILABLE) {
                Sleep(20);
                continue;
            }
            if (XR_FAILED(eventResult) ||
                eventData.type != XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING) {
                result = XR_ERROR_RUNTIME_FAILURE;
                break;
            }
            (receivedRecenters == 0 ? recenterEvent : stageRecenterEvent) =
                *reinterpret_cast<const XrEventDataReferenceSpaceChangePending*>(
                    &eventData);
            ++receivedRecenters;
        }
        auto validRecenter = [&](const XrEventDataReferenceSpaceChangePending& event,
                                 XrReferenceSpaceType referenceSpaceType) {
            return event.session == session &&
                   event.referenceSpaceType == referenceSpaceType &&
                   event.changeTime > 0 && event.poseValid == XR_TRUE &&
                   nearlyEqual(event.poseInPreviousSpace.position.x, -0.25f) &&
                   nearlyEqual(event.poseInPreviousSpace.position.y, 0.0f) &&
                   nearlyEqual(event.poseInPreviousSpace.position.z, 0.25f) &&
                   nearlyEqual(event.poseInPreviousSpace.orientation.y, 0.707106781f) &&
                   nearlyEqual(event.poseInPreviousSpace.orientation.w, 0.707106781f);
        };
        if (XR_FAILED(result) || receivedRecenters != 2 ||
            !validRecenter(recenterEvent, XR_REFERENCE_SPACE_TYPE_LOCAL) ||
            !validRecenter(stageRecenterEvent, XR_REFERENCE_SPACE_TYPE_STAGE) ||
            stageRecenterEvent.changeTime != recenterEvent.changeTime) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("Quest reset-view reference-space event", result);
        }

        // The change is time-bounded: an in-flight locate from just before
        // changeTime must still use the previous LOCAL definition.
        viewLocateInfo.displayTime = recenterEvent.changeTime - 1;
        result = xrLocateViews(
            session, &viewLocateInfo, &viewState, 2, &viewCount, locatedViews);
        if (XR_FAILED(result) || viewState.viewStateFlags != kTrackedViewFlags ||
            !nearlyEqual(locatedViews[0].pose.position.x, -0.25f) ||
            !nearlyEqual(locatedViews[1].pose.position.x, -0.25f) ||
            !nearlyEqual(locatedViews[0].pose.position.y, 1.5f) ||
            !nearlyEqual(locatedViews[0].pose.position.z, 0.282f) ||
            !nearlyEqual(locatedViews[1].pose.position.z, 0.218f) ||
            !nearlyEqual(locatedViews[0].pose.orientation.y, 0.707106781f) ||
            !nearlyEqual(locatedViews[0].pose.orientation.w, 0.707106781f)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateViews(before Quest reset changeTime)", result);
        }

        viewLocateInfo.displayTime = recenterEvent.changeTime + 1;
        result = xrLocateViews(
            session, &viewLocateInfo, &viewState, 2, &viewCount, locatedViews);
        if (XR_FAILED(result) || viewState.viewStateFlags != kTrackedViewFlags ||
            !nearlyEqual(locatedViews[0].pose.position.x, -0.032f) ||
            !nearlyEqual(locatedViews[1].pose.position.x, 0.032f) ||
            !nearlyEqual(locatedViews[0].pose.position.y, 1.5f) ||
            !nearlyEqual(locatedViews[0].pose.position.z, 0.0f) ||
            !nearlyEqual(locatedViews[0].pose.orientation.y, 0.0f) ||
            !nearlyEqual(locatedViews[0].pose.orientation.w, 1.0f)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateViews(after Quest reset)", result);
        }
        std::puts("PASS: Quest reset view recenters LOCAL yaw/position and emits event");

        referenceSpaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        XrSpace trackedViewSpace = XR_NULL_HANDLE;
        result = xrCreateReferenceSpace(session, &referenceSpaceInfo, &trackedViewSpace);
        if (XR_SUCCEEDED(result)) {
            result = xrLocateSpace(
                trackedViewSpace, localSpace,
                recenterEvent.changeTime + 1, &location);
        }
        constexpr XrSpaceLocationFlags kTrackedSpaceFlags =
            XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
            XR_SPACE_LOCATION_POSITION_VALID_BIT |
            XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
            XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
        if (XR_FAILED(result) || location.locationFlags != kTrackedSpaceFlags ||
            !nearlyEqual(location.pose.position.x, 0.0f) ||
            !nearlyEqual(location.pose.position.y, 1.5f) ||
            !nearlyEqual(location.pose.position.z, 0.0f) ||
            !nearlyEqual(location.pose.orientation.y, 0.0f) ||
            !nearlyEqual(location.pose.orientation.w, 1.0f)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateSpace(VIEW in LOCAL)", result);
        }
        result = xrDestroySpace(trackedViewSpace);
        if (XR_FAILED(result)) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrDestroySpace(tracked VIEW)", result);
        }
        // The daemon keeps publishing head poses until it releases the reset
        // button, so poll for the 500 ms freshness window to lapse after that
        // instead of assuming how long the hold outlasts the recenter event.
        bool headPoseStale = false;
        for (int attempt = 0; XR_SUCCEEDED(result) && attempt < 100; ++attempt) {
            Sleep(20);
            viewState.viewStateFlags = kTrackedViewFlags;
            result = xrLocateViews(
                session, &viewLocateInfo, &viewState, 0, &viewCount, nullptr);
            if (XR_SUCCEEDED(result) && viewState.viewStateFlags == 0) {
                headPoseStale = true;
                break;
            }
        }
        if (XR_FAILED(result) || !headPoseStale) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateViews(stale head pose)", result);
        }
    } else if (requireHeadPose()) {
        const float headX =
            (locatedViews[0].pose.position.x + locatedViews[1].pose.position.x) * 0.5f;
        const float headY =
            (locatedViews[0].pose.position.y + locatedViews[1].pose.position.y) * 0.5f;
        const float headZ =
            (locatedViews[0].pose.position.z + locatedViews[1].pose.position.z) * 0.5f;
        std::printf(
            "PASS: live head pose reached xrLocateViews "
            "(position %.3f %.3f %.3f)\n",
            headX, headY, headZ);
    } else if (locatedViews[0].pose.position.x != 0.0f ||
               locatedViews[1].pose.position.x != 0.0f) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrLocateViews(missing tracking)", XR_ERROR_VALIDATION_FAILURE);
    }

    XrExtent2Df bounds{1.0f, 1.0f};
    result = xrGetReferenceSpaceBoundsRect(session, XR_REFERENCE_SPACE_TYPE_LOCAL, &bounds);
    if (result != XR_SPACE_BOUNDS_UNAVAILABLE || bounds.width != 0.0f ||
        bounds.height != 0.0f) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrGetReferenceSpaceBoundsRect", result);
    }
    if (!checkStageSpace(session, localSpace, handSpace, locateTime) ||
        !checkVisibilityMask(instance, session)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return 1;
    }

    uint32_t formatCount = 0;
    result = xrEnumerateSwapchainFormats(session, 0, &formatCount, nullptr);
    std::vector<int64_t> formats(formatCount);
    if (XR_SUCCEEDED(result)) {
        result = xrEnumerateSwapchainFormats(
            session, formatCount, &formatCount, formats.data());
    }
    // Only the zero-copy BGRA formats are advertised; other formats (RGBA for
    // OpenComposite) are accepted by xrCreateSwapchain and converted by the
    // runtime compositor.
    if (XR_FAILED(result) || formats.size() != 2 ||
        formats[0] != DXGI_FORMAT_B8G8R8A8_UNORM ||
        formats[1] != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEnumerateSwapchainFormats", result);
    }

    XrSwapchainCreateInfo swapchainInfo{};
    swapchainInfo.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    swapchainInfo.usageFlags =
        XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    // BGRA is the CoreVideo/VideoToolbox-native layout the streamer encodes
    // without conversion; RGBA must not be advertised by this compositor.
    swapchainInfo.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swapchainInfo.sampleCount = 1;
    // The deterministic daemon uses tiny textures for fast pixel checks.
    // The live visual gate uses enough resolution for a controller cursor.
    // Match the headset test's balanced per-eye encode size so projected
    // landmarks move at output-pixel granularity instead of jumping when a
    // 512px diagnostic texture is enlarged to 1152x1216.
    swapchainInfo.width = options.visual ? 1152 : 64;
    swapchainInfo.height = options.visual ? 1216 : 64;
    swapchainInfo.faceCount = 1;
    swapchainInfo.arraySize = 1;
    swapchainInfo.mipCount = 1;

    // RGBA is accepted for the runtime compositor but never exported: the
    // CoreVideo handoff cannot wrap DXMT's RGBA IOSurfaces.
    swapchainInfo.format = DXGI_FORMAT_R8G8B8A8_UNORM;
    XrSwapchain rgbaSwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &rgbaSwapchain);
    bool rgbaPrivate = XR_SUCCEEDED(result) && rgbaSwapchain != XR_NULL_HANDLE;
    if (rgbaPrivate) {
        uint32_t rgbaImageCount = 0;
        XrSwapchainImageD3D11KHR rgbaImages[3]{};
        for (XrSwapchainImageD3D11KHR& image : rgbaImages) {
            image.type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
        }
        result = xrEnumerateSwapchainImages(
            rgbaSwapchain, 3, &rgbaImageCount,
            reinterpret_cast<XrSwapchainImageBaseHeader*>(rgbaImages));
        rgbaPrivate = XR_SUCCEEDED(result);
        for (uint32_t index = 0; rgbaPrivate && index < rgbaImageCount; ++index) {
            D3D11_TEXTURE2D_DESC description{};
            rgbaImages[index].texture->GetDesc(&description);
            uint32_t iosurfaceId = 0;
            UINT iosurfaceIdSize = sizeof(iosurfaceId);
            rgbaPrivate =
                (description.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE) == 0 &&
                FAILED(rgbaImages[index].texture->GetPrivateData(
                    kBasaltIOSurfaceIdGuid, &iosurfaceIdSize, &iosurfaceId));
        }
        const XrResult destroyResult = xrDestroySwapchain(rgbaSwapchain);
        rgbaPrivate = rgbaPrivate && XR_SUCCEEDED(destroyResult);
    }
    swapchainInfo.format = DXGI_FORMAT_BC1_UNORM;
    XrSwapchain compressedSwapchain = XR_NULL_HANDLE;
    const XrResult compressedResult =
        xrCreateSwapchain(session, &swapchainInfo, &compressedSwapchain);
    if (!rgbaPrivate ||
        compressedResult != XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED ||
        compressedSwapchain != XR_NULL_HANDLE) {
        if (compressedSwapchain != XR_NULL_HANDLE) {
            xrDestroySwapchain(compressedSwapchain);
        }
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSwapchain(private RGBA / unsupported BC1)",
                    rgbaPrivate ? compressedResult : result);
    }
    // UE4 hands over a typeless BGRA format for its eye textures; the runtime
    // backs it with typed BGRA instead of rejecting the swapchain.
    swapchainInfo.format = DXGI_FORMAT_B8G8R8A8_TYPELESS;
    XrSwapchain typelessSwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &typelessSwapchain);
    if (XR_FAILED(result) || typelessSwapchain == XR_NULL_HANDLE) {
        if (typelessSwapchain != XR_NULL_HANDLE) {
            xrDestroySwapchain(typelessSwapchain);
        }
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSwapchain(B8G8R8A8_TYPELESS)", result);
    }
    xrDestroySwapchain(typelessSwapchain);

    // A side-by-side image is wider than a single view (UE4 submits 2x1152),
    // so the per-view limit must not be applied to the swapchain image.
    const uint32_t viewWidth = swapchainInfo.width;
    swapchainInfo.width = 1700;
    XrSwapchain wideSwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &wideSwapchain);
    if (XR_FAILED(result) || wideSwapchain == XR_NULL_HANDLE) {
        if (wideSwapchain != XR_NULL_HANDLE) {
            xrDestroySwapchain(wideSwapchain);
        }
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSwapchain(side-by-side width)", result);
    }
    xrDestroySwapchain(wideSwapchain);
    swapchainInfo.width = viewWidth;
    swapchainInfo.format = DXGI_FORMAT_B8G8R8A8_UNORM;

    XrSwapchain swapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &swapchain);
    if (XR_FAILED(result) || swapchain == XR_NULL_HANDLE) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSwapchain", result);
    }

    XrSwapchain secondSwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &secondSwapchain);
    if (XR_FAILED(result) || secondSwapchain == XR_NULL_HANDLE ||
        secondSwapchain == swapchain) {
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("second xrCreateSwapchain", result);
    }

    uint32_t imageCount = 0;
    result = xrEnumerateSwapchainImages(swapchain, 0, &imageCount, nullptr);
    std::vector<XrSwapchainImageD3D11KHR> images(imageCount);
    for (XrSwapchainImageD3D11KHR& image : images) {
        image.type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
    }
    if (XR_SUCCEEDED(result)) {
        result = xrEnumerateSwapchainImages(
            swapchain,
            imageCount,
            &imageCount,
            reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data()));
    }
    if (XR_FAILED(result) || imageCount < 2) {
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEnumerateSwapchainImages", result);
    }

    ID3D11Device1* device1 = nullptr;
    hr = device->QueryInterface(IID_ID3D11Device1, reinterpret_cast<void**>(&device1));
    if (FAILED(hr)) {
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return failHresult("QueryInterface(ID3D11Device1)", hr);
    }

    for (const XrSwapchainImageD3D11KHR& image : images) {
        if (image.texture == nullptr) {
            hr = E_POINTER;
            break;
        }
        D3D11_TEXTURE2D_DESC description{};
        image.texture->GetDesc(&description);
        if (description.Width != swapchainInfo.width ||
            description.Height != swapchainInfo.height ||
            description.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
            description.Usage != D3D11_USAGE_DEFAULT ||
            (description.BindFlags & D3D11_BIND_RENDER_TARGET) == 0 ||
            (description.BindFlags & D3D11_BIND_SHADER_RESOURCE) == 0 ||
            (description.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE) == 0) {
            hr = E_FAIL;
            break;
        }

        IDXGIResource1* resource = nullptr;
        hr = image.texture->QueryInterface(
            IID_IDXGIResource1,
            reinterpret_cast<void**>(&resource));
        HANDLE handle = nullptr;
        ID3D11Texture2D* reopened = nullptr;
        if (SUCCEEDED(hr)) {
            hr = resource->CreateSharedHandle(
                nullptr,
                DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
                nullptr,
                &handle);
        }
        if (SUCCEEDED(hr)) {
            hr = device1->OpenSharedResource1(
                handle,
                IID_ID3D11Texture2D,
                reinterpret_cast<void**>(&reopened));
        }
        release(reopened);
        if (handle != nullptr) {
            CloseHandle(handle);
        }
        release(resource);
        if (FAILED(hr)) {
            break;
        }
    }
    release(device1);
    if (FAILED(hr)) {
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return failHresult("D3D11 swapchain image sharing", hr);
    }

    const char* iosurfaceFailure = nullptr;
    std::set<uint32_t> iosurfaceIds;
    for (const XrSwapchainImageD3D11KHR& image : images) {
        uint32_t iosurfaceId = 0;
        UINT iosurfaceIdSize = sizeof(iosurfaceId);
        const HRESULT query = image.texture->GetPrivateData(
            kBasaltIOSurfaceIdGuid, &iosurfaceIdSize, &iosurfaceId);
        if (expectBasaltIOSurface()) {
            if (FAILED(query) || iosurfaceIdSize != sizeof(iosurfaceId)) {
                iosurfaceFailure = "swapchain texture is missing BASALT_GUID_IOSURFACE_ID";
                break;
            }
            if (iosurfaceId == 0 || !iosurfaceIds.insert(iosurfaceId).second) {
                iosurfaceFailure = "swapchain IOSurfaceIDs are not nonzero and distinct";
                break;
            }
        } else if (SUCCEEDED(query)) {
            iosurfaceFailure = "BASALT_GUID_IOSURFACE_ID present without the fork gate";
            break;
        }
    }
    if (iosurfaceFailure != nullptr) {
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return failHresult(iosurfaceFailure, E_FAIL);
    }
    if (expectBasaltIOSurface()) {
        std::printf("PASS: %u swapchain textures republish distinct IOSurfaceIDs\n",
                    static_cast<unsigned int>(iosurfaceIds.size()));
    }

    // The second swapchain's images back the projection layer's other eye;
    // enumerate them so the render path can clear both.
    uint32_t secondImageCount = 0;
    result = xrEnumerateSwapchainImages(secondSwapchain, 0, &secondImageCount, nullptr);
    std::vector<XrSwapchainImageD3D11KHR> secondImages(secondImageCount);
    for (XrSwapchainImageD3D11KHR& image : secondImages) {
        image.type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
    }
    if (XR_SUCCEEDED(result)) {
        result = xrEnumerateSwapchainImages(
            secondSwapchain,
            secondImageCount,
            &secondImageCount,
            reinterpret_cast<XrSwapchainImageBaseHeader*>(secondImages.data()));
    }
    if (XR_FAILED(result) || secondImageCount < 2) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("second xrEnumerateSwapchainImages", result);
    }

    // Unity uses this shape for Single Pass Instanced rendering: one acquired
    // image whose two array slices are the left and right eyes. Exercise the
    // exact path and submit it once before continuing with the ordinary
    // two-swapchain render loop.
    swapchainInfo.arraySize = 2;
    XrSwapchain arraySwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &arraySwapchain);
    swapchainInfo.arraySize = 1;
    if (XR_FAILED(result) || arraySwapchain == XR_NULL_HANDLE) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSwapchain(two-slice texture array)", result);
    }

    uint32_t arrayImageCount = 0;
    result = xrEnumerateSwapchainImages(
        arraySwapchain, 0, &arrayImageCount, nullptr);
    std::vector<XrSwapchainImageD3D11KHR> arrayImages(arrayImageCount);
    for (XrSwapchainImageD3D11KHR& image : arrayImages) {
        image.type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
    }
    if (XR_SUCCEEDED(result)) {
        result = xrEnumerateSwapchainImages(
            arraySwapchain,
            arrayImageCount,
            &arrayImageCount,
            reinterpret_cast<XrSwapchainImageBaseHeader*>(arrayImages.data()));
    }
    bool validTextureArray = XR_SUCCEEDED(result) && arrayImageCount >= 2;
    for (const XrSwapchainImageD3D11KHR& image : arrayImages) {
        D3D11_TEXTURE2D_DESC description{};
        if (image.texture == nullptr) {
            validTextureArray = false;
            break;
        }
        image.texture->GetDesc(&description);
        uint32_t iosurfaceId = 0;
        UINT iosurfaceIdSize = sizeof(iosurfaceId);
        const HRESULT query = image.texture->GetPrivateData(
            kBasaltIOSurfaceIdGuid, &iosurfaceIdSize, &iosurfaceId);
        if (description.ArraySize != 2 ||
            (description.BindFlags & D3D11_BIND_RENDER_TARGET) == 0 ||
            (description.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE) != 0 ||
            SUCCEEDED(query)) {
            validTextureArray = false;
            break;
        }
    }
    if (!validTextureArray) {
        xrDestroySwapchain(arraySwapchain);
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("two-slice texture-array images", result);
    }

    // Every layered frame renders the shared per-frame color so the control
    // daemon can verify delivered IOSurface contents; the counter matches
    // the runtime's FrameReady numbering (successful layered frames only).
    uint64_t submittedFrames = 1;

    XrSwapchainImageAcquireInfo acquireInfo{};
    acquireInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
    uint32_t arrayImageIndex = UINT32_MAX;
    result = xrAcquireSwapchainImage(
        arraySwapchain, &acquireInfo, &arrayImageIndex);
    XrSwapchainImageWaitInfo waitInfo{};
    waitInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO;
    waitInfo.timeout = XR_INFINITE_DURATION;
    if (XR_SUCCEEDED(result)) {
        result = xrWaitSwapchainImage(arraySwapchain, &waitInfo);
    }
    XrSwapchainImageReleaseInfo releaseInfo{};
    releaseInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    if (XR_SUCCEEDED(result)) {
        if (arrayImageIndex >= arrayImageCount ||
            !clearSwapchainTexture(
                device, context, arrayImages[arrayImageIndex].texture,
                submittedFrames, options.visual, nullptr, nullptr, 0) ||
            !clearSwapchainTexture(
                device, context, arrayImages[arrayImageIndex].texture,
                submittedFrames, options.visual, nullptr, nullptr, 1)) {
            result = XR_ERROR_RUNTIME_FAILURE;
        }
    }
    if (XR_SUCCEEDED(result)) {
        result = xrReleaseSwapchainImage(arraySwapchain, &releaseInfo);
    }
    if (XR_FAILED(result) || arrayImageIndex >= arrayImageCount) {
        xrDestroySwapchain(arraySwapchain);
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("two-slice swapchain acquire/render/release", result);
    }

    // Projection-layer submission: both views select a distinct slice of the
    // same released texture-array image.
    XrCompositionLayerProjectionView projectionViews[2]{};
    for (uint32_t index = 0; index < 2; ++index) {
        XrCompositionLayerProjectionView& view = projectionViews[index];
        view.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
        view.pose = locatedViews[index].pose;
        view.fov = locatedViews[index].fov;
        view.subImage.imageRect = {{0, 0},
                                   {static_cast<int32_t>(swapchainInfo.width),
                                    static_cast<int32_t>(swapchainInfo.height)}};
        view.subImage.imageArrayIndex = index;
        view.subImage.swapchain = arraySwapchain;
    }

    XrCompositionLayerProjection projectionLayer{};
    projectionLayer.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION;
    projectionLayer.space = localSpace;
    projectionLayer.viewCount = 2;
    projectionLayer.views = projectionViews;
    const XrCompositionLayerBaseHeader* submittedLayers[] = {
        reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer)};

    XrFrameState layerFrameState{};
    layerFrameState.type = XR_TYPE_FRAME_STATE;
    result = xrWaitFrame(session, nullptr, &layerFrameState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    frameEndInfo.displayTime = layerFrameState.predictedDisplayTime;
    if (XR_SUCCEEDED(result)) {
        viewLocateInfo.displayTime = layerFrameState.predictedDisplayTime;
        result = xrLocateViews(
            session, &viewLocateInfo, &viewState, 2, &viewCount, locatedViews);
    }
    if (XR_SUCCEEDED(result)) {
        for (uint32_t index = 0; index < 2; ++index) {
            projectionViews[index].pose = locatedViews[index].pose;
            projectionViews[index].fov = locatedViews[index].fov;
        }
    }
    if (XR_SUCCEEDED(result) && expectInjectedHeadPose() &&
        !checkPinnedFrameHeadPose(
            session, localSpace, layerFrameState.predictedDisplayTime,
            locatedViews, hapticInfo, vibration)) {
        result = XR_ERROR_VALIDATION_FAILURE;
    }
    frameEndInfo.layerCount = 1;
    frameEndInfo.layers = submittedLayers;
    if (XR_SUCCEEDED(result)) {
        result = xrEndFrame(session, &frameEndInfo);
    }
    if (XR_FAILED(result)) {
        xrDestroySwapchain(arraySwapchain);
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("two-slice projection layer submission", result);
    }
    result = xrDestroySwapchain(arraySwapchain);
    if (XR_FAILED(result)) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrDestroySwapchain(two-slice texture array)", result);
    }
    std::puts(
        "PASS: two-slice Single Pass Instanced swapchain exported both eyes");

    // The remaining validation loop also covers multiple ordinary
    // swapchains and the runtime's independent acquire/release state.
    projectionViews[0].subImage.swapchain = swapchain;
    projectionViews[0].subImage.imageArrayIndex = 0;
    projectionViews[1].subImage.swapchain = secondSwapchain;
    projectionViews[1].subImage.imageArrayIndex = 0;
    uint32_t imageIndex = UINT32_MAX;
    uint32_t secondImageIndex = UINT32_MAX;

    // Freeze a small constellation in LOCAL from the first tracked view. It
    // remains stationary while the live eye poses move, making head rotation,
    // translation, stereo disparity, and depth visually unambiguous.
    std::vector<XrVector3f> visualWorldAnchors;
    if (options.visual) {
        XrPosef anchor = levelPoseToLocalUp(locatedViews[0].pose);
        anchor.position.x =
            (locatedViews[0].pose.position.x + locatedViews[1].pose.position.x) * 0.5f;
        anchor.position.y =
            (locatedViews[0].pose.position.y + locatedViews[1].pose.position.y) * 0.5f;
        anchor.position.z =
            (locatedViews[0].pose.position.z + locatedViews[1].pose.position.z) * 0.5f;
        auto addAnchor = [&](float x, float y, float z) {
            visualWorldAnchors.push_back(transformPoint(anchor, {x, y, z}));
        };
        for (float depth : {1.0f, 2.5f}) {
            const float halfWidth = depth == 1.0f ? 0.55f : 1.05f;
            const float halfHeight = depth == 1.0f ? 0.40f : 0.75f;
            for (int step = -4; step <= 4; ++step) {
                const float x = halfWidth * static_cast<float>(step) / 4.0f;
                addAnchor(x, -halfHeight, -depth);
                addAnchor(x, halfHeight, -depth);
            }
            for (int step = -3; step <= 3; ++step) {
                const float y = halfHeight * static_cast<float>(step) / 3.0f;
                addAnchor(-halfWidth, y, -depth);
                addAnchor(halfWidth, y, -depth);
            }
        }
        for (int step = 1; step <= 6; ++step) {
            addAnchor(0.0f, 0.0f, -0.45f * static_cast<float>(step));
        }
        for (int depthStep = 1; depthStep <= 5; ++depthStep) {
            for (int xStep = -3; xStep <= 3; ++xStep) {
                addAnchor(0.35f * static_cast<float>(xStep), -0.65f,
                          -0.55f * static_cast<float>(depthStep));
            }
        }
    }

    // hello_xr-shaped render loop: acquire, render the per-frame color into
    // both eyes, release, submit the stereo projection layer. Connected runs
    // deliver each frame to the control daemon, which verifies the pixels.
    if (options.visual) {
        std::printf(
            "INFO: visual controller scene rendering %llu frames; "
            "move/squeeze the left Touch controller\n",
            static_cast<unsigned long long>(options.renderFrames));
        std::fflush(stdout);
    }
    bool visualHapticTriggered = false;
    bool squeezeReadyForPulse = true;
    for (uint64_t loopFrame = 0; loopFrame < options.renderFrames; ++loopFrame) {
        ++submittedFrames;
        VisualControllerMarker visualMarkers[2]{};
        std::vector<VisualControllerMarker> visualLandmarks[2];
        XrFrameState loopFrameState{};
        loopFrameState.type = XR_TYPE_FRAME_STATE;
        result = xrWaitFrame(session, nullptr, &loopFrameState);
        if (XR_SUCCEEDED(result) &&
            loopFrameState.shouldRender != expectedShouldRender) {
            result = XR_ERROR_RUNTIME_FAILURE;
        }
        if (XR_SUCCEEDED(result)) {
            result = xrBeginFrame(session, nullptr);
        }
        if (XR_SUCCEEDED(result)) {
            viewLocateInfo.displayTime = loopFrameState.predictedDisplayTime;
            result = xrLocateViews(
                session, &viewLocateInfo, &viewState, 2, &viewCount, locatedViews);
        }
        if (XR_SUCCEEDED(result)) {
            for (uint32_t index = 0; index < 2; ++index) {
                projectionViews[index].pose = locatedViews[index].pose;
                projectionViews[index].fov = locatedViews[index].fov;
                if (options.visual) {
                    visualLandmarks[index].reserve(visualWorldAnchors.size());
                    for (const XrVector3f& point : visualWorldAnchors) {
                        const VisualControllerMarker landmark =
                            projectWorldMarker(point, locatedViews[index], 0.012f);
                        if (landmark.active) {
                            visualLandmarks[index].push_back(landmark);
                        }
                    }
                }
            }
        }
        if (XR_SUCCEEDED(result) && options.visual) {
            // Keep exercising the public action path during the visual loop.
            // The cursor follows the live controller in LOCAL x/z; squeeze
            // grows its center and shifts it from green toward yellow.
            const XrResult syncResult = xrSyncActions(session, &syncInfo);
            XrActionStateGetInfo liveGetInfo{};
            liveGetInfo.type = XR_TYPE_ACTION_STATE_GET_INFO;
            liveGetInfo.action = grabAction;
            liveGetInfo.subactionPath = leftHandPath;
            XrActionStateFloat liveSqueeze{};
            liveSqueeze.type = XR_TYPE_ACTION_STATE_FLOAT;
            const XrResult squeezeResult = XR_SUCCEEDED(syncResult)
                ? xrGetActionStateFloat(session, &liveGetInfo, &liveSqueeze)
                : syncResult;
            XrSpaceLocation liveHandLocation{};
            liveHandLocation.type = XR_TYPE_SPACE_LOCATION;
            const XrResult locateResult = XR_SUCCEEDED(syncResult)
                ? xrLocateSpace(
                      handSpace, localSpace, loopFrameState.predictedDisplayTime,
                      &liveHandLocation)
                : syncResult;
            constexpr XrSpaceLocationFlags kLiveControllerPosition =
                XR_SPACE_LOCATION_POSITION_VALID_BIT |
                XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
            const bool controllerVisible = XR_SUCCEEDED(squeezeResult) &&
                XR_SUCCEEDED(locateResult) && liveSqueeze.isActive == XR_TRUE &&
                (liveHandLocation.locationFlags & kLiveControllerPosition) ==
                    kLiveControllerPosition;
            if (controllerVisible) {
                for (uint32_t eye = 0; eye < 2; ++eye) {
                    visualMarkers[eye] = projectWorldMarker(
                        liveHandLocation.pose.position, locatedViews[eye],
                        0.035f, liveSqueeze.currentState);
                }
                // Make the visual instruction truthful: each deliberate
                // squeeze emits a perceptible pulse. Hysteresis prevents a
                // noisy analog value near the threshold from spamming ALVR.
                if (liveSqueeze.currentState <= 0.30f) {
                    squeezeReadyForPulse = true;
                } else if (liveSqueeze.currentState >= 0.85f &&
                           squeezeReadyForPulse) {
                    XrHapticVibration squeezePulse{};
                    squeezePulse.type = XR_TYPE_HAPTIC_VIBRATION;
                    squeezePulse.duration = 100'000'000;
                    squeezePulse.frequency = 120.0f;
                    squeezePulse.amplitude = 1.0f;
                    const XrResult pulseResult = xrApplyHapticFeedback(
                        session, &hapticInfo,
                        reinterpret_cast<const XrHapticBaseHeader*>(&squeezePulse));
                    if (XR_FAILED(pulseResult)) {
                        result = pulseResult;
                    } else {
                        visualHapticTriggered = true;
                        squeezeReadyForPulse = false;
                        std::puts("PASS: squeeze haptic pulse dispatched");
                        std::fflush(stdout);
                    }
                }
            }
        }
        if (XR_SUCCEEDED(result)) {
            result = xrAcquireSwapchainImage(swapchain, &acquireInfo, &imageIndex);
        }
        if (XR_SUCCEEDED(result)) {
            result = xrWaitSwapchainImage(swapchain, &waitInfo);
        }
        if (XR_SUCCEEDED(result)) {
            if (imageIndex >= imageCount ||
                !clearSwapchainTexture(device, context, images[imageIndex].texture,
                                       submittedFrames, options.visual,
                                       &visualMarkers[0], &visualLandmarks[0])) {
                result = XR_ERROR_RUNTIME_FAILURE;
            }
        }
        if (XR_SUCCEEDED(result)) {
            result = xrReleaseSwapchainImage(swapchain, &releaseInfo);
        }
        if (XR_SUCCEEDED(result)) {
            result = xrAcquireSwapchainImage(
                secondSwapchain, &acquireInfo, &secondImageIndex);
        }
        if (XR_SUCCEEDED(result)) {
            result = xrWaitSwapchainImage(secondSwapchain, &waitInfo);
        }
        if (XR_SUCCEEDED(result)) {
            if (secondImageIndex >= secondImageCount ||
                !clearSwapchainTexture(device, context,
                                       secondImages[secondImageIndex].texture,
                                       submittedFrames, options.visual,
                                       &visualMarkers[1], &visualLandmarks[1])) {
                result = XR_ERROR_RUNTIME_FAILURE;
            }
        }
        if (XR_SUCCEEDED(result)) {
            result = xrReleaseSwapchainImage(secondSwapchain, &releaseInfo);
        }
        if (XR_SUCCEEDED(result)) {
            frameEndInfo.displayTime = loopFrameState.predictedDisplayTime;
            frameEndInfo.layerCount = 1;
            frameEndInfo.layers = submittedLayers;
            result = xrEndFrame(session, &frameEndInfo);
        }
        if (XR_FAILED(result)) {
            xrDestroySwapchain(secondSwapchain);
            xrDestroySwapchain(swapchain);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("render loop frame", result);
        }
    }
    if (options.visual && requireControllerInput() && !visualHapticTriggered) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("visual squeeze haptic was not triggered", XR_ERROR_RUNTIME_FAILURE);
    }
    std::printf("PASS: %llu-frame stereo render loop submitted%s\n",
                static_cast<unsigned long long>(options.renderFrames),
                expectConnected() ? " and delivered to the control daemon" : "");

    // Quad layers are composited by the runtime (d3d11_compositor_smoke
    // covers them); here only frames that must not reach the daemon are
    // submitted: an invalid quad and an extension layer type that was never
    // enabled.
    XrCompositionLayerQuad quadLayer{};
    quadLayer.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
    quadLayer.space = localSpace;
    quadLayer.subImage = projectionViews[0].subImage;
    quadLayer.pose.orientation.w = 1.0f;
    quadLayer.size = {0.0f, 1.0f};
    for (const XrResult expected :
         {XR_ERROR_VALIDATION_FAILURE, XR_ERROR_LAYER_INVALID}) {
        if (expected == XR_ERROR_LAYER_INVALID) {
            // XR_KHR_composition_layer_cylinder's layer type.
            quadLayer.type = static_cast<XrStructureType>(1000017000);
            quadLayer.size = {1.0f, 1.0f};
        }
        result = xrWaitFrame(session, nullptr, &layerFrameState);
        if (XR_SUCCEEDED(result)) {
            result = xrBeginFrame(session, nullptr);
        }
        frameEndInfo.displayTime = layerFrameState.predictedDisplayTime;
        frameEndInfo.layerCount = 1;
        frameEndInfo.layers = submittedLayers;
        submittedLayers[0] =
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quadLayer);
        if (XR_SUCCEEDED(result)) {
            result = xrEndFrame(session, &frameEndInfo);
            if (result != expected) {
                xrDestroySwapchain(secondSwapchain);
                xrDestroySwapchain(swapchain);
                xrDestroySession(session);
                release(context);
                release(device);
                xrDestroyInstance(instance);
                return fail("invalid quad / unknown layer rejection", result);
            }
            frameEndInfo.layerCount = 0;
            frameEndInfo.layers = nullptr;
            result = xrEndFrame(session, &frameEndInfo);
        }
        if (XR_FAILED(result)) {
            break;
        }
    }
    if (XR_FAILED(result)) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("quad rejection recovery", result);
    }

    submittedLayers[0] =
        reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer);
    projectionViews[0].subImage.imageRect.offset.x =
        static_cast<int32_t>(swapchainInfo.width) / 2;
    result = xrWaitFrame(session, nullptr, &layerFrameState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    frameEndInfo.displayTime = layerFrameState.predictedDisplayTime;
    frameEndInfo.layerCount = 1;
    frameEndInfo.layers = submittedLayers;
    if (XR_SUCCEEDED(result)) {
        result = xrEndFrame(session, &frameEndInfo);
        if (result != XR_ERROR_SWAPCHAIN_RECT_INVALID) {
            xrDestroySwapchain(secondSwapchain);
            xrDestroySwapchain(swapchain);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("out-of-bounds image rect rejection", result);
        }
        frameEndInfo.layerCount = 0;
        frameEndInfo.layers = nullptr;
        result = xrEndFrame(session, &frameEndInfo);
    }
    projectionViews[0].subImage.imageRect.offset.x = 0;
    if (XR_FAILED(result)) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("image rect rejection recovery", result);
    }

    XrSwapchain unreleasedSwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &unreleasedSwapchain);
    projectionViews[0].subImage.swapchain = unreleasedSwapchain;
    if (XR_SUCCEEDED(result)) {
        result = xrWaitFrame(session, nullptr, &layerFrameState);
    }
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    frameEndInfo.displayTime = layerFrameState.predictedDisplayTime;
    frameEndInfo.layerCount = 1;
    frameEndInfo.layers = submittedLayers;
    if (XR_SUCCEEDED(result)) {
        result = xrEndFrame(session, &frameEndInfo);
        if (result != XR_ERROR_LAYER_INVALID) {
            xrDestroySwapchain(unreleasedSwapchain);
            xrDestroySwapchain(secondSwapchain);
            xrDestroySwapchain(swapchain);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("never-released swapchain rejection", result);
        }
        frameEndInfo.layerCount = 0;
        frameEndInfo.layers = nullptr;
        result = xrEndFrame(session, &frameEndInfo);
    }
    projectionViews[0].subImage.swapchain = swapchain;
    if (XR_SUCCEEDED(result)) {
        result = xrDestroySwapchain(unreleasedSwapchain);
    }
    if (XR_FAILED(result)) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("never-released swapchain recovery", result);
    }

    const XrCompositionLayerBaseHeader* overflowLayers
        [XR_MIN_COMPOSITION_LAYERS_SUPPORTED + 1];
    for (auto& layer : overflowLayers) {
        layer = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer);
    }
    result = xrWaitFrame(session, nullptr, &layerFrameState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    frameEndInfo.displayTime = layerFrameState.predictedDisplayTime;
    frameEndInfo.layerCount = XR_MIN_COMPOSITION_LAYERS_SUPPORTED + 1;
    frameEndInfo.layers = overflowLayers;
    if (XR_SUCCEEDED(result)) {
        result = xrEndFrame(session, &frameEndInfo);
        if (result != XR_ERROR_LAYER_LIMIT_EXCEEDED) {
            xrDestroySwapchain(secondSwapchain);
            xrDestroySwapchain(swapchain);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("layer limit rejection", result);
        }
        frameEndInfo.layerCount = 0;
        frameEndInfo.layers = nullptr;
        result = xrEndFrame(session, &frameEndInfo);
    }
    if (XR_FAILED(result)) {
        xrDestroySwapchain(secondSwapchain);
        xrDestroySwapchain(swapchain);
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("layer limit recovery", result);
    }
    frameEndInfo.layerCount = 0;
    frameEndInfo.layers = nullptr;

    result = xrDestroySwapchain(swapchain);
    if (XR_SUCCEEDED(result)) {
        result = xrDestroySwapchain(secondSwapchain);
    }
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrDestroySwapchain", result);
    }

    XrFrameState firstDiscardState{};
    firstDiscardState.type = XR_TYPE_FRAME_STATE;
    XrFrameState secondDiscardState{};
    secondDiscardState.type = XR_TYPE_FRAME_STATE;
    result = xrWaitFrame(session, nullptr, &firstDiscardState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    if (XR_SUCCEEDED(result)) {
        result = xrWaitFrame(session, nullptr, &secondDiscardState);
    }
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
        if (result != XR_FRAME_DISCARDED) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrBeginFrame discard", result);
        }
        frameEndInfo.displayTime = secondDiscardState.predictedDisplayTime;
        result = xrEndFrame(session, &frameEndInfo);
    }
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("discarded frame sequence", result);
    }

    XrFrameState failedEndState{};
    failedEndState.type = XR_TYPE_FRAME_STATE;
    result = xrWaitFrame(session, nullptr, &failedEndState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    if (XR_SUCCEEDED(result)) {
        frameEndInfo.displayTime = 0;
        result = xrEndFrame(session, &frameEndInfo);
    }
    if (result != XR_ERROR_TIME_INVALID) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEndFrame invalid time", result);
    }

    XrFrameState recoveryState{};
    recoveryState.type = XR_TYPE_FRAME_STATE;
    result = xrWaitFrame(session, nullptr, &recoveryState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
        if (result != XR_FRAME_DISCARDED) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrBeginFrame after failed xrEndFrame", result);
        }
        frameEndInfo.displayTime = recoveryState.predictedDisplayTime;
        result = xrEndFrame(session, &frameEndInfo);
    }
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("failed frame recovery", result);
    }
    result = xrEndFrame(session, &frameEndInfo);
    if (result != XR_ERROR_CALL_ORDER_INVALID) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEndFrame without xrBeginFrame", result);
    }

    result = xrRequestExitSession(session);
    bool exitStatesOk = XR_SUCCEEDED(result);
    if (exitStatesOk && expectConnected()) {
        // A focused session unwinds through VISIBLE and SYNCHRONIZED first.
        exitStatesOk =
            expectSessionState(instance, session, XR_SESSION_STATE_VISIBLE) &&
            expectSessionState(instance, session, XR_SESSION_STATE_SYNCHRONIZED);
    }
    if (!exitStatesOk ||
        !expectSessionState(instance, session, XR_SESSION_STATE_STOPPING)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrRequestExitSession", result);
    }
    result = xrEndSession(session);
    if (XR_FAILED(result)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrEndSession", result);
    }
    result = xrWaitFrame(session, nullptr, &frameState);
    if (result != XR_ERROR_SESSION_NOT_RUNNING ||
        !expectSessionState(instance, session, XR_SESSION_STATE_IDLE) ||
        !expectSessionState(instance, session, XR_SESSION_STATE_EXITING) ||
        !expectNoEvent(instance)) {
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("stopped session", result);
    }

    // OpenComposite never destroys its hand trackers before the session;
    // they stay usable until xrDestroySession and die with it.
    if (handTrackingEnabled) {
        XrHandJointLocationEXT joints[kHandJoints]{};
        XrBool32 active = XR_TRUE;
        result = locateHand(
            handTracking, rightHandTracker, localSpace,
            frameState.predictedDisplayTime > 0 ? frameState.predictedDisplayTime : 1,
            joints, &active);
        if (result != XR_SUCCESS) {
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("xrLocateHandJointsEXT before xrDestroySession", result);
        }
    }
    result = xrDestroySession(session);
    if (XR_SUCCEEDED(result)) {
        const XrResult cascadeResult = xrDestroySpace(localSpace);
        if (cascadeResult != XR_ERROR_HANDLE_INVALID) {
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("session-cascaded xrDestroySpace(LOCAL)", cascadeResult);
        }
    }
    if (XR_SUCCEEDED(result) && handTrackingEnabled) {
        const XrResult leftDestroy = handTracking.destroy(leftHandTracker);
        const XrResult rightDestroy = handTracking.destroy(rightHandTracker);
        if (leftDestroy != XR_ERROR_HANDLE_INVALID ||
            rightDestroy != XR_ERROR_HANDLE_INVALID) {
            release(context);
            release(device);
            xrDestroyInstance(instance);
            std::fprintf(stderr, "FAIL: hand trackers outlived their session (%d %d)\n",
                         leftDestroy, rightDestroy);
            return 1;
        }
        std::puts("PASS: XR_EXT_hand_tracking trackers live until xrDestroySession, "
                  "then are invalid");
    }
    // A second session would start a second control-daemon handshake, so the
    // OpenComposite-style restart runs only in headless mode.
    if (XR_SUCCEEDED(result) && !expectConnected() &&
        !checkOpenCompositeSessionRestart(
            instance, sessionInfo, attachedActionSets,
            static_cast<uint32_t>(std::size(attachedActionSets)),
            overlayPoseAction, leftHandPath)) {
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return 1;
    }
    if (XR_SUCCEEDED(result)) {
        result = xrDestroyInstance(instance);
    }
    release(context);
    release(device);
    if (XR_FAILED(result)) {
        return fail("D3D11 teardown", result);
    }

    std::printf(
        "PASS: loader ran spaces, input, projection layers, and two %u-image DXMT swapchains\n",
        imageCount);
    return 0;
}
