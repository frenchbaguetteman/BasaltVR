#pragma once

#include <windows.h>

#include <d3d11.h>

#include <openxr/openxr.h>

#include <cstdint>

// Runtime-side layer compositor. The native streamer consumes exactly two
// BGRA IOSurface eye images per frame and crops each by its unflipped image
// rect, so any frame it cannot take directly (non-BGRA, mipmapped, or
// oversized swapchains, quad layers, or flipped rects) is drawn on the game's
// immediate context into a runtime-owned BGRA output swapchain, which is
// registered with the daemon like an application swapchain. Frames that
// already satisfy the direct export rules (including side-by-side images with
// one rect per eye) never touch this path.

namespace basalt {

// Per-swapchain facts xrEndFrame needs to validate a layer and choose between
// the direct export and the compositor.
struct SwapchainLayerState {
    XrSession session = XR_NULL_HANDLE;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t arraySize = 0;
    bool hasReleasedImage = false;
    uint32_t lastReleasedIndex = 0;
    // Registered with the daemon and exported zero-copy by IOSurfaceID.
    bool exported = false;
    // Depth swapchains are private and can never be a layer's color source.
    bool depth = false;
};

bool getSwapchainLayerState(XrSwapchain swapchain, SwapchainLayerState* state);

// A sampling view of one swapchain image and array slice (mip 0 only).
// decodeSrgb is set for UNORM 8/10-bit sources: the streamer treats their
// bytes as display-encoded, so the compositor decodes them to linear and the
// sRGB output view re-encodes the same bytes. sRGB sources decode in the
// view; float sources are linear.
struct SwapchainSampleSource {
    ID3D11ShaderResourceView* view = nullptr;
    bool arrayView = false;
    bool decodeSrgb = false;
    uint32_t width = 0;
    uint32_t height = 0;
};

// Returns an AddRef'd view; the caller releases source->view.
bool retainSwapchainSampleSource(
    XrSwapchain swapchain,
    uint32_t imageIndex,
    uint32_t arraySlice,
    SwapchainSampleSource* source);

struct CompositionSubImage {
    XrSwapchain swapchain = XR_NULL_HANDLE;
    uint32_t imageIndex = 0;
    uint32_t imageArrayIndex = 0;
    XrRect2Di rect{};
};

enum class CompositionLayerKind : uint32_t {
    kProjection = 0,
    kQuad = 1,
};

// One validated layer, captured in submission order. Projection layers use
// subImages/poses/fovs per eye; quad layers use subImages[0], pose, and size.
struct CompositionLayer {
    CompositionLayerKind kind = CompositionLayerKind::kProjection;
    XrCompositionLayerFlags layerFlags = 0;
    XrSpace space = XR_NULL_HANDLE;
    CompositionSubImage subImages[2]{};
    XrPosef poses[2]{};
    XrFovf fovs[2]{};
    XrEyeVisibility eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    XrPosef pose{};
    XrExtent2Df size{};
};

// Only the first projection layer is displayed, matching the direct path;
// later projection layers are validated but not captured.
struct CompositionFrame {
    uint32_t layerCount = 0;
    CompositionLayer layers[XR_MIN_COMPOSITION_LAYERS_SUPPORTED]{};
};

// Draws the frame into the next output ring image pair on the session
// device's immediate context and queues FrameReady for it. Must be called on
// the xrEndFrame thread without runtime locks held. Returns false when no
// FrameReady was queued (headless, compositor unavailable, or disconnect).
bool compositorSubmitFrame(
    XrSession session,
    XrTime displayTime,
    uint64_t questTrackingTimestampNanoseconds,
    const CompositionFrame& frame);

// Releases the session's compositor resources. The daemon handoff closes
// first during session teardown, so the output surfaces are no longer read.
void compositorSessionDestroyed(XrSession session);

}  // namespace basalt
