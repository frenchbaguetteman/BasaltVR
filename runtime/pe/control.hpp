#pragma once

#include <windows.h>

#include <d3d11.h>

#include <openxr/openxr.h>

#include <cstdint>

// Control-socket client to the native streamer daemon (docs/DXMT-INTEROP.md
// §4). Every entry point is a safe no-op when the daemon handoff is not
// active: without the DXMT_BASALT_IOSURFACE gate, the fork's IOSurfaceID
// private data, or a reachable daemon, the runtime behaves exactly as before
// (headless, shouldRender false). A socket failure after connection
// disconnects and returns to that behavior; it never fails an OpenXR call.

namespace basalt {

// Queries the Basalt DXMT fork's IOSurfaceID for a texture; 0 when absent.
uint32_t queryTextureIOSurfaceId(ID3D11Texture2D* texture);

// Third capability probe plus daemon handshake; called after session
// creation succeeds. Headless on any failure.
void controlSessionCreated(XrSession session, ID3D11Device* device);
void controlSessionDestroyed(XrSession session);

// True only while the daemon handshake is complete for the live session.
bool controlActive(XrSession session);

// Reads the optional per-eye render size from the BASALT_CONTROL handoff.
// This is available before session creation so OpenXR system/view queries can
// advertise the stream's actual target size to the application.
bool controlConfiguredViewSize(uint32_t* width, uint32_t* height);

// Blocks frame production while two submitted frames are still unconsumed by
// the daemon (an app that calls xrWaitFrame(N+1) before xrEndFrame(N) can
// have one more in flight). This is the end-to-end backpressure boundary: it
// covers the GPU fence, control socket, compositor, and encoder admission
// instead of allowing latency to accumulate in any of those queues.
bool controlWaitForFrameBudget(XrSession session);
// Records a predictedDisplayTime returned by xrWaitFrame, so a later recenter
// takes effect only after every frame the application may be rendering.
void controlNotePredictedDisplayTime(XrSession session, XrTime predictedDisplayTime);

// Returns the latest fresh ALVR head pose (LOCAL-from-HEAD), selecting the
// previous LOCAL definition for locateTime values before a pending recenter's
// changeTime. The Quest timestamp is preserved only for ordering because it is
// not in the runtime's XrTime clock domain. False means disconnected, missing,
// or stale tracking. A zero locateTime selects the current definition.
bool controlHeadPose(
    XrSession session,
    XrTime locateTime,
    uint64_t* questTimestampNanoseconds,
    XrPosef* poseInLocal);

enum class ControlHand : uint32_t {
    kLeft = 0,
    kRight = 1,
};

constexpr uint32_t kControlButtonCapacity = 64;

struct ControlControllerState {
    bool poseActive;
    bool profileActive;
    uint64_t questTimestampNanoseconds;
    uint64_t profileId;
    XrPosef poseInLocal;
    // ALVR's already-predicted motion velocities, expressed in LOCAL.
    // They are exposed through XrSpaceVelocity but never used to extrapolate
    // the received pose a second time.
    XrVector3f linearVelocity;
    XrVector3f angularVelocity;
};

struct ControlButtonState {
    uint64_t pathId;
    uint32_t valueType;
    float value;
    XrTime lastChangeTime;
};

// valueType 0 is a digital 0/1 button; 1 is an analog value pressed at 0.5.
inline bool controlButtonPressed(uint32_t valueType, float value) {
    return valueType == 0 ? value != 0.0f : value >= 0.5f;
}

struct ControlInputSnapshot {
    ControlControllerState controllers[2];
    uint32_t buttonCount;
    ControlButtonState buttons[kControlButtonCapacity];
};

// Returns the latest calibrated Quest eye geometry. False means the daemon
// has not supplied it yet; callers retain conservative prototype defaults.
bool controlViewConfig(
    XrSession session,
    float* ipdMeters,
    XrFovf fov[2]);

// Atomically copies the live controller/profile/button state used by one
// xrSyncActions call. Controller pose activity includes the freshness gate;
// sparse button values persist until the control connection is replaced.
bool controlInputSnapshot(
    XrSession session,
    ControlInputSnapshot* snapshot,
    XrTime locateTime = 0);

// Sends one resolved OpenXR haptic command to the streamer. A zero duration
// and amplitude is the stop representation.
bool controlSendHaptic(
    XrSession session,
    ControlHand hand,
    uint64_t durationNanoseconds,
    float frequency,
    float amplitude);

// Registers a swapchain's images; on daemon rejection or socket failure the
// runtime disconnects and continues headless.
void controlRegisterSwapchain(
    XrSwapchain swapchain,
    uint32_t width,
    uint32_t height,
    int64_t dxgiFormat,
    const uint32_t* iosurfaceIds,
    uint32_t imageCount);

// Sends DestroySwapchain and waits for the ack (bounded) so the caller may
// release the D3D11 textures afterwards; the daemon holds surface retains
// until this exchange or the socket closes.
void controlUnregisterSwapchain(XrSwapchain swapchain);

struct ControlFrameView {
    uint64_t swapchainId;
    uint32_t imageIndex;
    uint32_t imageArrayIndex;
    XrRect2Di rect;
    XrPosef pose;
    XrFovf fov;
};

// Copies one submitted array slice into its IOSurface-backed 2D export
// texture and rewrites imageIndex to the flattened registered-surface index.
// Simple non-array swapchains remain direct and are only normalized.
bool prepareSwapchainViewForExport(
    ID3D11DeviceContext* context,
    ControlFrameView* view);

// Queues FrameReady: signals the session fence with a monotonic frame
// number on the caller's thread (must be the xrEndFrame thread, which owns
// the immediate context per XR_KHR_D3D11_enable), and a waiter thread sends
// the message only after the fence completes (Phase 1 frame-done contract).
// exportViews runs prepareSwapchainViewForExport on application views; the
// compositor passes false for its already-exported output images. Returns
// the queued frame number, or 0 when nothing was queued.
uint64_t controlFrameReady(
    int64_t displayTime,
    uint64_t questTrackingTimestampNanoseconds,
    const ControlFrameView* views,
    uint32_t viewCount,
    bool exportViews);

// Blocks until the daemon has consumed frameNumber (finished its Metal reads
// of that frame's surfaces), so a runtime-owned image can be redrawn. False
// on disconnect or timeout; frameNumber 0 returns true immediately.
bool controlWaitForFrameConsumed(XrSession session, uint64_t frameNumber);

}  // namespace basalt
