// OpenComposite-shaped OpenXR/D3D11 smoke for the runtime compositor.
//
// Headless (stock DXMT, or no BASALT_CONTROL) it checks the API surface the
// compositor added: format enumeration and creation, the 16-swapchain limit,
// quad/flipped-rect/unknown-layer validation, FIFO acquire/wait/release
// order, repeated wait+begin without end, and that a destroyed session's
// state events are never delivered to its successor. With the Basalt DXMT
// fork and the native test daemon in --compositor-scenarios mode it also
// submits one frame per entry of basalt_compositor_scenarios.h; the daemon
// verifies each by IOSurface readback.

#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <vector>

#include "basalt_compositor_scenarios.h"

namespace {

constexpr uint32_t kMaxRuntimeSwapchains = 16;
// XR_KHR_composition_layer_cylinder is never enabled, so its layer type is
// an unknown layer to this runtime.
constexpr XrStructureType kCylinderLayerType = static_cast<XrStructureType>(1000017000);

bool expectConnected() {
    const char* value = std::getenv("BASALT_CONTROL");
    return value != nullptr && value[0] != '\0';
}

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

bool check(bool condition, const char* what) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", what);
    }
    return condition;
}

bool expectResult(XrResult actual, XrResult expected, const char* what) {
    if (actual != expected) {
        std::fprintf(stderr, "FAIL: %s returned XrResult %d, expected %d\n",
                     what, actual, expected);
        return false;
    }
    return true;
}

bool succeeded(XrResult result, const char* what) {
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: %s returned XrResult %d\n", what, result);
        return false;
    }
    return true;
}

bool isBgra(DXGI_FORMAT format) {
    return format == DXGI_FORMAT_B8G8R8A8_UNORM ||
           format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ||
           format == DXGI_FORMAT_B8G8R8A8_TYPELESS;
}

bool isDepth(int64_t format) {
    return format == DXGI_FORMAT_D32_FLOAT || format == DXGI_FORMAT_D24_UNORM_S8_UINT ||
           format == DXGI_FORMAT_D16_UNORM || format == DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
}

struct Swapchain {
    XrSwapchain handle = XR_NULL_HANDLE;
    std::vector<ID3D11Texture2D*> images;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t mipCount = 1;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
};

struct Harness {
    XrInstance instance = XR_NULL_HANDLE;
    XrSystemId systemId = XR_NULL_SYSTEM_ID;
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    XrSession session = XR_NULL_HANDLE;
    XrSpace local = XR_NULL_HANDLE;
    // OpenComposite's tracking space; it shares LOCAL's origin, so quads
    // placed here exercise cross-space location with unchanged pixels.
    XrSpace stage = XR_NULL_HANDLE;
    bool connected = false;
    std::vector<Swapchain> swapchains;

    ~Harness() {
        for (Swapchain& swapchain : swapchains) {
            if (swapchain.handle != XR_NULL_HANDLE) {
                xrDestroySwapchain(swapchain.handle);
            }
        }
        if (session != XR_NULL_HANDLE) {
            xrDestroySession(session);
        }
        if (instance != XR_NULL_HANDLE) {
            xrDestroyInstance(instance);
        }
        release(context);
        release(device);
    }
};

XrSessionState gLastState = XR_SESSION_STATE_UNKNOWN;

// Drains events; every session-scoped event must name the live session.
bool drainEvents(Harness& harness) {
    for (;;) {
        XrEventDataBuffer event{};
        event.type = XR_TYPE_EVENT_DATA_BUFFER;
        const XrResult result = xrPollEvent(harness.instance, &event);
        if (result == XR_EVENT_UNAVAILABLE) {
            return true;
        }
        if (!succeeded(result, "xrPollEvent")) {
            return false;
        }
        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
            const auto* changed =
                reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
            if (!check(changed->session == harness.session,
                       "state event names a session other than the live one")) {
                return false;
            }
            gLastState = changed->state;
        }
    }
}

bool expectState(Harness& harness, XrSessionState state) {
    XrEventDataBuffer event{};
    event.type = XR_TYPE_EVENT_DATA_BUFFER;
    const XrResult result = xrPollEvent(harness.instance, &event);
    const auto* changed = reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
    if (result != XR_SUCCESS || event.type != XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED ||
        changed->session != harness.session || changed->state != state) {
        std::fprintf(stderr,
                     "FAIL: expected state %d for session %p, got XrResult %d type %d "
                     "state %d session %p\n",
                     static_cast<int>(state), static_cast<void*>(harness.session), result,
                     static_cast<int>(event.type),
                     result == XR_SUCCESS ? static_cast<int>(changed->state) : -1,
                     result == XR_SUCCESS ? static_cast<void*>(changed->session) : nullptr);
        return false;
    }
    gLastState = state;
    return true;
}

bool createInstanceAndDevice(Harness& harness) {
    const char* extensions[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo instanceInfo{};
    instanceInfo.type = XR_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.enabledExtensionCount = 1;
    instanceInfo.enabledExtensionNames = extensions;
    instanceInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    std::strncpy(instanceInfo.applicationInfo.applicationName,
                 "Basalt compositor smoke", XR_MAX_APPLICATION_NAME_SIZE - 1);
    if (!succeeded(xrCreateInstance(&instanceInfo, &harness.instance), "xrCreateInstance")) {
        return false;
    }
    XrSystemGetInfo systemInfo{};
    systemInfo.type = XR_TYPE_SYSTEM_GET_INFO;
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    if (!succeeded(xrGetSystem(harness.instance, &systemInfo, &harness.systemId),
                   "xrGetSystem")) {
        return false;
    }
    PFN_xrVoidFunction requirementsVoid = nullptr;
    if (!succeeded(xrGetInstanceProcAddr(harness.instance,
                                         "xrGetD3D11GraphicsRequirementsKHR",
                                         &requirementsVoid),
                   "xrGetInstanceProcAddr")) {
        return false;
    }
    XrGraphicsRequirementsD3D11KHR requirements{};
    requirements.type = XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR;
    if (!succeeded(reinterpret_cast<PFN_xrGetD3D11GraphicsRequirementsKHR>(
                       requirementsVoid)(harness.instance, harness.systemId, &requirements),
                   "xrGetD3D11GraphicsRequirementsKHR")) {
        return false;
    }

    IDXGIFactory1* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                  reinterpret_cast<void**>(&factory)))) {
        return check(false, "CreateDXGIFactory1");
    }
    IDXGIAdapter1* adapter = nullptr;
    const HRESULT adapterResult = factory->EnumAdapters1(0, &adapter);
    release(factory);
    if (FAILED(adapterResult)) {
        return check(false, "EnumAdapters1");
    }
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
    const HRESULT deviceResult = D3D11CreateDevice(
        adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels, 1, D3D11_SDK_VERSION, &harness.device, nullptr, &harness.context);
    release(adapter);
    return check(SUCCEEDED(deviceResult), "D3D11CreateDevice");
}

bool createSession(Harness& harness, XrSession* session) {
    XrGraphicsBindingD3D11KHR binding{};
    binding.type = XR_TYPE_GRAPHICS_BINDING_D3D11_KHR;
    binding.device = harness.device;
    XrSessionCreateInfo sessionInfo{};
    sessionInfo.type = XR_TYPE_SESSION_CREATE_INFO;
    sessionInfo.next = &binding;
    sessionInfo.systemId = harness.systemId;
    return succeeded(xrCreateSession(harness.instance, &sessionInfo, session),
                     "xrCreateSession");
}

bool beginSession(Harness& harness) {
    XrSessionBeginInfo beginInfo{};
    beginInfo.type = XR_TYPE_SESSION_BEGIN_INFO;
    beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    return succeeded(xrBeginSession(harness.session, &beginInfo), "xrBeginSession");
}

bool createSwapchain(
    Harness& harness,
    DXGI_FORMAT format,
    uint32_t width,
    uint32_t height,
    uint32_t mipCount,
    Swapchain* swapchain) {
    XrSwapchainCreateInfo createInfo{};
    createInfo.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    // OpenComposite's usage flags.
    createInfo.usageFlags = XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT |
                            XR_SWAPCHAIN_USAGE_SAMPLED_BIT |
                            XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
    createInfo.format = format;
    createInfo.sampleCount = 1;
    createInfo.width = width;
    createInfo.height = height;
    createInfo.faceCount = 1;
    createInfo.arraySize = 1;
    createInfo.mipCount = mipCount;
    *swapchain = {};
    if (!succeeded(xrCreateSwapchain(harness.session, &createInfo, &swapchain->handle),
                   "xrCreateSwapchain")) {
        std::fprintf(stderr, "      (format %d, %ux%u, %u mips)\n",
                     static_cast<int>(format), width, height, mipCount);
        return false;
    }
    uint32_t count = 0;
    if (!succeeded(xrEnumerateSwapchainImages(swapchain->handle, 0, &count, nullptr),
                   "xrEnumerateSwapchainImages(count)")) {
        return false;
    }
    std::vector<XrSwapchainImageD3D11KHR> images(count);
    for (XrSwapchainImageD3D11KHR& image : images) {
        image.type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
    }
    if (!succeeded(xrEnumerateSwapchainImages(
                       swapchain->handle, count, &count,
                       reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data())),
                   "xrEnumerateSwapchainImages")) {
        return false;
    }
    for (const XrSwapchainImageD3D11KHR& image : images) {
        swapchain->images.push_back(image.texture);
    }
    swapchain->width = width;
    swapchain->height = height;
    swapchain->mipCount = mipCount;
    swapchain->format = format;
    return true;
}

bool destroySwapchain(Swapchain& swapchain) {
    const XrResult result = xrDestroySwapchain(swapchain.handle);
    swapchain.handle = XR_NULL_HANDLE;
    return succeeded(result, "xrDestroySwapchain");
}

using PixelFunction = std::function<uint32_t(uint32_t x, uint32_t y, uint32_t w, uint32_t h)>;

// Uploads exact r,g,b,a bytes (swizzled for BGRA formats) into one mip.
void fillImage(
    Harness& harness,
    const Swapchain& swapchain,
    uint32_t image,
    uint32_t mip,
    const PixelFunction& pixel) {
    const uint32_t width = std::max(1u, swapchain.width >> mip);
    const uint32_t height = std::max(1u, swapchain.height >> mip);
    std::vector<uint32_t> data(static_cast<size_t>(width) * height);
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            uint32_t value = pixel(x, y, width, height);
            if (isBgra(swapchain.format)) {
                value = (value & 0xff00ff00u) | ((value & 0xffu) << 16) |
                        ((value >> 16) & 0xffu);
            }
            data[static_cast<size_t>(y) * width + x] = value;
        }
    }
    harness.context->UpdateSubresource(
        swapchain.images[image], D3D11CalcSubresource(mip, 0, swapchain.mipCount),
        nullptr, data.data(), width * 4, 0);
}

PixelFunction solidPixels(uint32_t color) {
    return [color](uint32_t, uint32_t, uint32_t, uint32_t) { return color; };
}

PixelFunction quadrantPixels() {
    return [](uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
        return kBasaltQuadrantColors[(y >= h / 2 ? 2 : 0) + (x >= w / 2 ? 1 : 0)];
    };
}

PixelFunction halvesPixels(uint32_t top, uint32_t bottom) {
    return [top, bottom](uint32_t, uint32_t y, uint32_t, uint32_t h) {
        return y < h / 2 ? top : bottom;
    };
}

// Acquire, wait, upload every mip, release: one rendered image.
bool renderImage(
    Harness& harness,
    Swapchain& swapchain,
    const PixelFunction& top,
    const PixelFunction* lowerMips = nullptr) {
    XrSwapchainImageAcquireInfo acquireInfo{};
    acquireInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
    uint32_t index = 0;
    XrSwapchainImageWaitInfo waitInfo{};
    waitInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO;
    waitInfo.timeout = XR_INFINITE_DURATION;
    XrSwapchainImageReleaseInfo releaseInfo{};
    releaseInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    if (!succeeded(xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &index),
                   "xrAcquireSwapchainImage") ||
        !succeeded(xrWaitSwapchainImage(swapchain.handle, &waitInfo),
                   "xrWaitSwapchainImage")) {
        return false;
    }
    fillImage(harness, swapchain, index, 0, top);
    for (uint32_t mip = 1; mip < swapchain.mipCount && lowerMips != nullptr; ++mip) {
        fillImage(harness, swapchain, index, mip, *lowerMips);
    }
    return succeeded(xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                     "xrReleaseSwapchainImage");
}

struct Frame {
    XrTime displayTime = 0;
    XrView views[2]{};
};

bool beginFrame(Harness& harness, Frame* frame) {
    XrFrameState frameState{};
    frameState.type = XR_TYPE_FRAME_STATE;
    if (!succeeded(xrWaitFrame(harness.session, nullptr, &frameState), "xrWaitFrame") ||
        !succeeded(xrBeginFrame(harness.session, nullptr), "xrBeginFrame")) {
        return false;
    }
    frame->displayTime = frameState.predictedDisplayTime;
    XrViewLocateInfo locateInfo{};
    locateInfo.type = XR_TYPE_VIEW_LOCATE_INFO;
    locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locateInfo.displayTime = frame->displayTime;
    locateInfo.space = harness.local;
    XrViewState viewState{};
    viewState.type = XR_TYPE_VIEW_STATE;
    frame->views[0].type = XR_TYPE_VIEW;
    frame->views[1].type = XR_TYPE_VIEW;
    uint32_t viewCount = 0;
    return succeeded(xrLocateViews(harness.session, &locateInfo, &viewState, 2,
                                   &viewCount, frame->views),
                     "xrLocateViews");
}

XrResult endFrame(
    Harness& harness,
    const Frame& frame,
    const XrCompositionLayerBaseHeader* const* layers,
    uint32_t layerCount) {
    XrFrameEndInfo endInfo{};
    endInfo.type = XR_TYPE_FRAME_END_INFO;
    endInfo.displayTime = frame.displayTime;
    endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    endInfo.layerCount = layerCount;
    endInfo.layers = layers;
    return xrEndFrame(harness.session, &endInfo);
}

XrRect2Di fullRect(const Swapchain& swapchain) {
    return {{0, 0},
            {static_cast<int32_t>(swapchain.width), static_cast<int32_t>(swapchain.height)}};
}

// The flipped-bounds rect OpenComposite submits for vMin=1, vMax=0.
XrRect2Di flippedRect(const Swapchain& swapchain) {
    return {{0, static_cast<int32_t>(swapchain.height)},
            {static_cast<int32_t>(swapchain.width), -static_cast<int32_t>(swapchain.height)}};
}

struct ProjectionLayer {
    XrCompositionLayerProjectionView views[2]{};
    XrCompositionLayerProjection layer{};

    ProjectionLayer(
        const Harness& harness,
        const Frame& frame,
        const Swapchain& left,
        const Swapchain& right,
        XrRect2Di leftRect,
        XrRect2Di rightRect) {
        const Swapchain* swapchains[2] = {&left, &right};
        const XrRect2Di rects[2] = {leftRect, rightRect};
        for (uint32_t eye = 0; eye < 2; ++eye) {
            views[eye].type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
            views[eye].pose = frame.views[eye].pose;
            views[eye].fov = frame.views[eye].fov;
            views[eye].subImage.swapchain = swapchains[eye]->handle;
            views[eye].subImage.imageRect = rects[eye];
        }
        layer.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION;
        layer.space = harness.local;
        layer.viewCount = 2;
        layer.views = views;
    }

    const XrCompositionLayerBaseHeader* header() const {
        return reinterpret_cast<const XrCompositionLayerBaseHeader*>(&layer);
    }
};

XrCompositionLayerQuad makeQuad(
    const Harness& harness, const Swapchain& swapchain, XrRect2Di rect,
    XrCompositionLayerFlags flags) {
    XrCompositionLayerQuad quad{};
    quad.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
    quad.layerFlags = flags;
    quad.space = harness.local;
    quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    quad.subImage.swapchain = swapchain.handle;
    quad.subImage.imageRect = rect;
    quad.pose.orientation.w = 1.0f;
    quad.pose.position = {0.0f, BASALT_TEST_HEAD_HEIGHT_METERS, -BASALT_QUAD_DISTANCE_METERS};
    quad.size = {BASALT_QUAD_SIZE_METERS, BASALT_QUAD_SIZE_METERS};
    return quad;
}

const XrCompositionLayerBaseHeader* asHeader(const XrCompositionLayerQuad& quad) {
    return reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad);
}

// One rejected xrEndFrame, then the required recovery submission.
bool expectRejectedFrame(
    Harness& harness,
    const std::function<XrResult(const Frame&)>& submit,
    XrResult expected,
    const char* what) {
    Frame frame;
    if (!beginFrame(harness, &frame) || !expectResult(submit(frame), expected, what)) {
        return false;
    }
    return succeeded(endFrame(harness, frame, nullptr, 0), "recovery xrEndFrame");
}

bool testFormats(Harness& harness) {
    uint32_t count = 0;
    if (!succeeded(xrEnumerateSwapchainFormats(harness.session, 0, &count, nullptr),
                   "xrEnumerateSwapchainFormats(count)")) {
        return false;
    }
    std::vector<int64_t> formats(count);
    if (!succeeded(xrEnumerateSwapchainFormats(harness.session, count, &count,
                                               formats.data()),
                   "xrEnumerateSwapchainFormats")) {
        return false;
    }
    // Only the zero-copy BGRA pair is advertised; the compositor formats are
    // accepted by xrCreateSwapchain without being enumerated (exercised below).
    if (!check(count == 2 && formats[0] == DXGI_FORMAT_B8G8R8A8_UNORM &&
                   formats[1] == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
               "only BGRA and BGRA-sRGB should be advertised")) {
        return false;
    }

    // Formats outside the advertised list must still be creatable.
    const int64_t extraFormats[] = {
        DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, DXGI_FORMAT_R8G8B8A8_UNORM,
        DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_D32_FLOAT};
    for (int64_t format : extraFormats) {
        formats.push_back(format);
    }

    // Every advertised and compositor-only format must actually be creatable.
    for (int64_t format : formats) {
        XrSwapchainCreateInfo createInfo{};
        createInfo.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
        createInfo.usageFlags = isDepth(format)
            ? XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
            : XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
        createInfo.format = format;
        createInfo.sampleCount = 1;
        createInfo.width = 16;
        createInfo.height = 16;
        createInfo.faceCount = 1;
        createInfo.arraySize = 1;
        createInfo.mipCount = 1;
        XrSwapchain swapchain = XR_NULL_HANDLE;
        const XrResult result = xrCreateSwapchain(harness.session, &createInfo, &swapchain);
        if (XR_FAILED(result)) {
            std::fprintf(stderr, "FAIL: format %lld cannot be created (%d)\n",
                         static_cast<long long>(format), result);
            return false;
        }
        if (!succeeded(xrDestroySwapchain(swapchain), "xrDestroySwapchain(format)")) {
            return false;
        }
    }

    // A sampled depth swapchain needs a typeless resource underneath.
    XrSwapchainCreateInfo createInfo{};
    createInfo.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    createInfo.usageFlags = XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT |
                            XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    createInfo.format = DXGI_FORMAT_D32_FLOAT;
    createInfo.sampleCount = 1;
    createInfo.width = 64;
    createInfo.height = 64;
    createInfo.faceCount = 1;
    createInfo.arraySize = 1;
    createInfo.mipCount = 1;
    XrSwapchain swapchain = XR_NULL_HANDLE;
    if (!succeeded(xrCreateSwapchain(harness.session, &createInfo, &swapchain),
                   "xrCreateSwapchain(sampled depth)") ||
        !succeeded(xrDestroySwapchain(swapchain), "xrDestroySwapchain(sampled depth)")) {
        return false;
    }

    struct Rejection {
        DXGI_FORMAT format;
        XrSwapchainUsageFlags usage;
        uint32_t width;
        uint32_t mips;
        XrResult expected;
        const char* what;
    };
    const Rejection rejections[] = {
        {DXGI_FORMAT_BC1_UNORM, XR_SWAPCHAIN_USAGE_SAMPLED_BIT, 64, 1,
         XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED, "compressed format"},
        {DXGI_FORMAT_D32_FLOAT, XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT, 64, 1,
         XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED, "depth format as color attachment"},
        {DXGI_FORMAT_R8G8B8A8_UNORM, XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, 64, 1,
         XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED, "color format as depth attachment"},
        {DXGI_FORMAT_R8G8B8A8_UNORM, XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT, 64, 0,
         XR_ERROR_VALIDATION_FAILURE, "zero mip count"},
        {DXGI_FORMAT_R8G8B8A8_UNORM, XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT, 64, 8,
         XR_ERROR_VALIDATION_FAILURE, "more mips than a 64x64 chain has"},
        {DXGI_FORMAT_R8G8B8A8_UNORM, XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT, 4097, 1,
         XR_ERROR_VALIDATION_FAILURE, "width above 4096"},
    };
    for (const Rejection& rejection : rejections) {
        createInfo.format = rejection.format;
        createInfo.usageFlags = rejection.usage;
        createInfo.width = rejection.width;
        createInfo.mipCount = rejection.mips;
        swapchain = XR_NULL_HANDLE;
        if (!expectResult(xrCreateSwapchain(harness.session, &createInfo, &swapchain),
                          rejection.expected, rejection.what) ||
            !check(swapchain == XR_NULL_HANDLE, "rejected swapchain returned a handle")) {
            return false;
        }
    }

    // A full-size 7-mip chain at 64x64 is valid.
    createInfo.format = DXGI_FORMAT_R8G8B8A8_UNORM;
    createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
    createInfo.width = 64;
    createInfo.mipCount = 7;
    return succeeded(xrCreateSwapchain(harness.session, &createInfo, &swapchain),
                     "xrCreateSwapchain(full mip chain)") &&
           succeeded(xrDestroySwapchain(swapchain), "xrDestroySwapchain(full mip chain)");
}

// Up to 16 live swapchains (OpenComposite: two eyes, skybox, overlays).
bool testSwapchainLimit(Harness& harness) {
    std::vector<Swapchain> extra;
    const size_t live = harness.swapchains.size();
    for (size_t index = live; index < kMaxRuntimeSwapchains; ++index) {
        Swapchain swapchain;
        if (!createSwapchain(harness, DXGI_FORMAT_R8G8B8A8_UNORM, 16, 16, 1, &swapchain)) {
            return false;
        }
        extra.push_back(swapchain);
    }
    XrSwapchainCreateInfo createInfo{};
    createInfo.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
    createInfo.format = DXGI_FORMAT_R8G8B8A8_UNORM;
    createInfo.sampleCount = 1;
    createInfo.width = 16;
    createInfo.height = 16;
    createInfo.faceCount = 1;
    createInfo.arraySize = 1;
    createInfo.mipCount = 1;
    XrSwapchain overflow = XR_NULL_HANDLE;
    const bool limited = expectResult(
        xrCreateSwapchain(harness.session, &createInfo, &overflow),
        XR_ERROR_LIMIT_REACHED, "17th live swapchain");
    bool destroyed = true;
    for (Swapchain& swapchain : extra) {
        destroyed = destroySwapchain(swapchain) && destroyed;
    }
    return limited && destroyed;
}

// Acquire/wait/release follow the OpenXR acquisition FIFO even after the
// image ring wraps; the scenario frame then proves which image was released.
bool prepareFifoRelease(Harness& harness, Swapchain& swapchain) {
    XrSwapchainImageAcquireInfo acquireInfo{};
    acquireInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
    XrSwapchainImageWaitInfo waitInfo{};
    waitInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO;
    waitInfo.timeout = XR_INFINITE_DURATION;
    XrSwapchainImageReleaseInfo releaseInfo{};
    releaseInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    if (!expectResult(xrWaitSwapchainImage(swapchain.handle, &waitInfo),
                      XR_ERROR_CALL_ORDER_INVALID, "wait without acquire") ||
        !expectResult(xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                      XR_ERROR_CALL_ORDER_INVALID, "release without wait")) {
        return false;
    }
    uint32_t index = 0;
    for (uint32_t expected = 0; expected < 2; ++expected) {
        if (!succeeded(xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &index),
                       "FIFO warm-up acquire") ||
            !check(index == expected, "FIFO warm-up acquired an unexpected image") ||
            !succeeded(xrWaitSwapchainImage(swapchain.handle, &waitInfo),
                       "FIFO warm-up wait") ||
            !succeeded(xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                       "FIFO warm-up release")) {
            return false;
        }
    }
    uint32_t oldest = 0;
    uint32_t newest = 0;
    uint32_t extra = 0;
    if (!succeeded(xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &oldest),
                   "FIFO acquire oldest") ||
        !succeeded(xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &newest),
                   "FIFO acquire newest") ||
        !check(oldest == BASALT_FIFO_RELEASED_IMAGE && newest == 0,
               "FIFO acquisition did not wrap to images 2 then 0") ||
        !expectResult(xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                      XR_ERROR_CALL_ORDER_INVALID, "release before wait")) {
        return false;
    }
    // Both images hold a distinct color, so the delivered pixels prove which
    // image the runtime treated as waited and released.
    fillImage(harness, swapchain, oldest, 0, solidPixels(kBasaltFifoReleasedColor));
    fillImage(harness, swapchain, newest, 0, solidPixels(kBasaltFifoHeldColor));
    return succeeded(xrWaitSwapchainImage(swapchain.handle, &waitInfo), "FIFO wait") &&
           expectResult(xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &extra),
                        XR_SUCCESS, "FIFO third acquire") &&
           expectResult(xrAcquireSwapchainImage(swapchain.handle, &acquireInfo, &extra),
                        XR_ERROR_CALL_ORDER_INVALID, "acquire with every image held") &&
           succeeded(xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                     "FIFO release oldest");
}

bool finishFifo(Swapchain& swapchain) {
    XrSwapchainImageWaitInfo waitInfo{};
    waitInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO;
    waitInfo.timeout = XR_INFINITE_DURATION;
    XrSwapchainImageReleaseInfo releaseInfo{};
    releaseInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    for (int remaining = 0; remaining < 2; ++remaining) {
        if (!succeeded(xrWaitSwapchainImage(swapchain.handle, &waitInfo), "FIFO drain wait") ||
            !succeeded(xrReleaseSwapchainImage(swapchain.handle, &releaseInfo),
                       "FIFO drain release")) {
            return false;
        }
    }
    return expectResult(xrWaitSwapchainImage(swapchain.handle, &waitInfo),
                        XR_ERROR_CALL_ORDER_INVALID, "wait after drain");
}

// OpenComposite's temporary session may call xrWaitFrame+xrBeginFrame more
// than once without xrEndFrame; neither call may block or fail.
bool testRepeatedBeginWithoutEnd(Harness& harness) {
    Frame frame;
    for (int repeat = 0; repeat < 3; ++repeat) {
        XrFrameState frameState{};
        frameState.type = XR_TYPE_FRAME_STATE;
        if (!succeeded(xrWaitFrame(harness.session, nullptr, &frameState), "repeated xrWaitFrame")) {
            return false;
        }
        frame.displayTime = frameState.predictedDisplayTime;
        if (!expectResult(xrBeginFrame(harness.session, nullptr),
                          repeat == 0 ? XR_SUCCESS : XR_FRAME_DISCARDED,
                          "repeated xrBeginFrame")) {
            return false;
        }
    }
    return succeeded(endFrame(harness, frame, nullptr, 0), "xrEndFrame after repeats");
}

bool testLayerValidation(
    Harness& harness,
    Swapchain& eye,
    Swapchain& unreleased,
    Swapchain& depth) {
    const XrCompositionLayerFlags blend = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
    auto quadFrame = [&](const XrCompositionLayerQuad& quad) {
        return [&harness, quad](const Frame& frame) {
            const XrCompositionLayerBaseHeader* layers[] = {asHeader(quad)};
            return endFrame(harness, frame, layers, 1);
        };
    };

    XrCompositionLayerQuad quad = makeQuad(harness, eye, fullRect(eye), blend);
    quad.size = {0.0f, 1.0f};
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_VALIDATION_FAILURE,
                             "quad with zero width")) {
        return false;
    }
    quad = makeQuad(harness, eye, fullRect(eye), blend);
    quad.eyeVisibility = static_cast<XrEyeVisibility>(7);
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_VALIDATION_FAILURE,
                             "quad with invalid eye visibility")) {
        return false;
    }
    quad = makeQuad(harness, eye, fullRect(eye), blend);
    quad.pose.orientation.w = 0.0f;
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_POSE_INVALID,
                             "quad with invalid pose")) {
        return false;
    }
    quad = makeQuad(harness, eye, fullRect(eye), blend);
    quad.space = XR_NULL_HANDLE;
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_HANDLE_INVALID,
                             "quad without a space")) {
        return false;
    }
    quad = makeQuad(harness, unreleased, fullRect(unreleased), blend);
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_LAYER_INVALID,
                             "quad on a never-released swapchain")) {
        return false;
    }
    quad = makeQuad(harness, depth, fullRect(depth), blend);
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_LAYER_INVALID,
                             "quad sourcing a depth swapchain")) {
        return false;
    }
    quad = makeQuad(harness, eye, fullRect(eye), blend);
    quad.subImage.imageRect = {{0, 0}, {static_cast<int32_t>(eye.width), 0}};
    if (!expectRejectedFrame(harness, quadFrame(quad), XR_ERROR_SWAPCHAIN_RECT_INVALID,
                             "quad with a zero-height rect")) {
        return false;
    }

    // A negative extent spans [offset + extent, offset): it must stay in
    // bounds, and an unflipped out-of-bounds rect is still rejected.
    const XrRect2Di badRects[] = {
        {{0, 0}, {static_cast<int32_t>(eye.width), -static_cast<int32_t>(eye.height)}},
        {{0, static_cast<int32_t>(eye.height) + 1},
         {static_cast<int32_t>(eye.width), -static_cast<int32_t>(eye.height)}},
        {{static_cast<int32_t>(eye.width), 0},
         {-static_cast<int32_t>(eye.width) - 1, static_cast<int32_t>(eye.height)}},
        {{1, 0}, {static_cast<int32_t>(eye.width), static_cast<int32_t>(eye.height)}},
    };
    for (const XrRect2Di& rect : badRects) {
        auto submit = [&](const Frame& frame) {
            ProjectionLayer projection(harness, frame, eye, eye, rect, fullRect(eye));
            const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
            return endFrame(harness, frame, layers, 1);
        };
        if (!expectRejectedFrame(harness, submit, XR_ERROR_SWAPCHAIN_RECT_INVALID,
                                 "out-of-bounds projection rect")) {
            return false;
        }
    }

    XrCompositionLayerQuad unknown = makeQuad(harness, eye, fullRect(eye), blend);
    unknown.type = kCylinderLayerType;
    return expectRejectedFrame(harness, quadFrame(unknown), XR_ERROR_LAYER_INVALID,
                               "unknown (cylinder) layer type");
}

// Each scenario submits exactly one frame; connected, the daemon verifies
// it as FrameReady number `scenario` (basalt_compositor_scenarios.h).
bool runScenarios(Harness& harness, Swapchain& left, Swapchain& right) {
    Frame frame;

    // f: direct BGRA swapchains are exported zero-copy.
    if (!renderImage(harness, left, solidPixels(kBasaltDirectColor)) ||
        !renderImage(harness, right, solidPixels(kBasaltDirectColor)) ||
        !beginFrame(harness, &frame)) {
        return false;
    }
    if (harness.connected &&
        !check(std::fabs(frame.views[0].pose.position.x + BASALT_TEST_IPD_METERS * 0.5f) <
                       0.0001f &&
                   std::fabs(frame.views[0].pose.position.y - BASALT_TEST_HEAD_HEIGHT_METERS) <
                       0.0001f,
               "xrLocateViews did not return the daemon's injected head pose")) {
        return false;
    }
    {
        ProjectionLayer projection(harness, frame, left, right, fullRect(left), fullRect(right));
        const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
        if (!succeeded(endFrame(harness, frame, layers, 1), "direct scenario xrEndFrame")) {
            return false;
        }
    }

    // a: R8G8B8A8_UNORM_SRGB bytes arrive unchanged (both eyes, one swapchain).
    Swapchain srgb;
    if (!createSwapchain(harness, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, 96, 80, 1, &srgb)) {
        return false;
    }
    harness.swapchains.push_back(srgb);
    if (!renderImage(harness, srgb, solidPixels(kBasaltSrgbColor)) ||
        !beginFrame(harness, &frame)) {
        return false;
    }
    {
        ProjectionLayer projection(harness, frame, srgb, srgb, fullRect(srgb), fullRect(srgb));
        const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
        if (!succeeded(endFrame(harness, frame, layers, 1), "sRGB scenario xrEndFrame")) {
            return false;
        }
    }

    // b: a 4-mip BGRA chain is composited from mip 0 only.
    Swapchain mipmapped;
    if (!createSwapchain(harness, DXGI_FORMAT_B8G8R8A8_UNORM, 256, 256, 4, &mipmapped)) {
        return false;
    }
    harness.swapchains.push_back(mipmapped);
    const PixelFunction wrongMip = solidPixels(kBasaltWrongMipColor);
    if (!renderImage(harness, mipmapped, quadrantPixels(), &wrongMip) ||
        !beginFrame(harness, &frame)) {
        return false;
    }
    {
        ProjectionLayer projection(
            harness, frame, mipmapped, mipmapped, fullRect(mipmapped), fullRect(mipmapped));
        const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
        if (!succeeded(endFrame(harness, frame, layers, 1), "mipmapped scenario xrEndFrame")) {
            return false;
        }
    }

    // b: an oversized UNORM swapchain is scaled into the stream size.
    Swapchain oversized;
    if (!createSwapchain(harness, DXGI_FORMAT_R8G8B8A8_UNORM, 2016, 2240, 1, &oversized)) {
        return false;
    }
    harness.swapchains.push_back(oversized);
    if (!renderImage(harness, oversized, quadrantPixels()) || !beginFrame(harness, &frame)) {
        return false;
    }
    {
        ProjectionLayer projection(
            harness, frame, oversized, oversized, fullRect(oversized), fullRect(oversized));
        const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
        if (!succeeded(endFrame(harness, frame, layers, 1), "oversized scenario xrEndFrame")) {
            return false;
        }
    }

    // c: a negative-height rect on an exported swapchain is flipped.
    const PixelFunction halves = halvesPixels(kBasaltFlipTopColor, kBasaltFlipBottomColor);
    if (!renderImage(harness, left, halves) || !renderImage(harness, right, halves) ||
        !beginFrame(harness, &frame)) {
        return false;
    }
    {
        ProjectionLayer projection(
            harness, frame, left, right, flippedRect(left), flippedRect(right));
        const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
        if (!succeeded(endFrame(harness, frame, layers, 1), "flipped scenario xrEndFrame")) {
            return false;
        }
    }

    // d: an unpremultiplied, alpha-blended quad over the opaque projection.
    Swapchain quadImage;
    if (!createSwapchain(harness, DXGI_FORMAT_R8G8B8A8_UNORM, 32, 32, 1, &quadImage)) {
        return false;
    }
    harness.swapchains.push_back(quadImage);
    if (!renderImage(harness, left, solidPixels(kBasaltProjectionColor)) ||
        !renderImage(harness, right, solidPixels(kBasaltProjectionColor)) ||
        !renderImage(harness, quadImage, solidPixels(kBasaltQuadColor)) ||
        !beginFrame(harness, &frame)) {
        return false;
    }
    {
        ProjectionLayer projection(harness, frame, left, right, fullRect(left), fullRect(right));
        XrCompositionLayerQuad quad = makeQuad(
            harness, quadImage, fullRect(quadImage),
            XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT |
                XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT);
        // Located from STAGE into the projection's LOCAL space.
        quad.space = harness.stage;
        const XrCompositionLayerBaseHeader* layers[] = {projection.header(), asHeader(quad)};
        if (!succeeded(endFrame(harness, frame, layers, 2), "quad scenario xrEndFrame")) {
            return false;
        }
    }

    // A quad-only frame shaped like OpenComposite's skybox: flipped bounds,
    // source-alpha blending, no projection layer.
    Swapchain sky;
    if (!createSwapchain(harness, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, 64, 64, 1, &sky)) {
        return false;
    }
    harness.swapchains.push_back(sky);
    if (!renderImage(harness, sky, halvesPixels(kBasaltSkyTopColor, kBasaltSkyBottomColor)) ||
        !beginFrame(harness, &frame)) {
        return false;
    }
    {
        XrCompositionLayerQuad quad = makeQuad(
            harness, sky, flippedRect(sky),
            XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT);
        // Eye poses come from views located in the quad's STAGE space.
        quad.space = harness.stage;
        const XrCompositionLayerBaseHeader* layers[] = {asHeader(quad)};
        if (!succeeded(endFrame(harness, frame, layers, 1), "quad-only scenario xrEndFrame")) {
            return false;
        }
    }

    // e: wait/release in acquisition order on a direct swapchain.
    Swapchain fifo;
    if (!createSwapchain(harness, DXGI_FORMAT_B8G8R8A8_UNORM, 64, 64, 1, &fifo)) {
        return false;
    }
    harness.swapchains.push_back(fifo);
    if (!prepareFifoRelease(harness, fifo) || !beginFrame(harness, &frame)) {
        return false;
    }
    {
        ProjectionLayer projection(harness, frame, fifo, fifo, fullRect(fifo), fullRect(fifo));
        const XrCompositionLayerBaseHeader* layers[] = {projection.header()};
        if (!succeeded(endFrame(harness, frame, layers, 1), "FIFO scenario xrEndFrame")) {
            return false;
        }
    }
    return finishFifo(fifo);
}

bool endSessionCleanly(Harness& harness) {
    // Destroying an exported swapchain waits until the daemon consumed every
    // queued frame; destroying the session alone drops frames in flight.
    for (Swapchain& swapchain : harness.swapchains) {
        if (!destroySwapchain(swapchain)) {
            return false;
        }
    }
    if (!succeeded(xrRequestExitSession(harness.session), "xrRequestExitSession")) {
        return false;
    }
    bool stopping = false;
    for (int attempt = 0; attempt < 8 && !stopping; ++attempt) {
        if (!drainEvents(harness)) {
            return false;
        }
        stopping = gLastState == XR_SESSION_STATE_STOPPING;
    }
    if (!check(stopping, "session did not reach STOPPING") ||
        !succeeded(xrEndSession(harness.session), "xrEndSession") ||
        !drainEvents(harness) ||
        !check(gLastState == XR_SESSION_STATE_EXITING, "session did not reach EXITING")) {
        return false;
    }
    const XrResult result = xrDestroySession(harness.session);
    harness.session = XR_NULL_HANDLE;
    harness.local = XR_NULL_HANDLE;
    harness.stage = XR_NULL_HANDLE;
    harness.swapchains.clear();
    return succeeded(result, "xrDestroySession");
}

// OpenComposite starts on a temporary session, may destroy it at any time,
// and aborts on a state event for anything but its current session.
bool testSessionReplacement(Harness& harness) {
    if (!createSession(harness, &harness.session) || !expectState(harness, XR_SESSION_STATE_IDLE) ||
        !expectState(harness, XR_SESSION_STATE_READY) || !beginSession(harness)) {
        return false;
    }
    XrReferenceSpaceCreateInfo spaceInfo{};
    spaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    if (!succeeded(xrCreateReferenceSpace(harness.session, &spaceInfo, &harness.local),
                   "xrCreateReferenceSpace(temporary LOCAL)") ||
        !testRepeatedBeginWithoutEnd(harness)) {
        return false;
    }
    // Leave a begun frame and an exit request's state events pending, then
    // destroy the session (and, implicitly, its space) without draining.
    XrFrameState frameState{};
    frameState.type = XR_TYPE_FRAME_STATE;
    if (!succeeded(xrWaitFrame(harness.session, nullptr, &frameState), "temporary xrWaitFrame") ||
        !succeeded(xrBeginFrame(harness.session, nullptr), "temporary xrBeginFrame") ||
        !succeeded(xrRequestExitSession(harness.session), "temporary xrRequestExitSession") ||
        !succeeded(xrDestroySession(harness.session), "temporary xrDestroySession")) {
        return false;
    }
    harness.session = XR_NULL_HANDLE;
    harness.local = XR_NULL_HANDLE;

    if (!createSession(harness, &harness.session) ||
        !expectState(harness, XR_SESSION_STATE_IDLE) ||
        !expectState(harness, XR_SESSION_STATE_READY)) {
        return false;
    }
    XrEventDataBuffer event{};
    event.type = XR_TYPE_EVENT_DATA_BUFFER;
    if (!expectResult(xrPollEvent(harness.instance, &event), XR_EVENT_UNAVAILABLE,
                      "stale events after session replacement")) {
        return false;
    }
    const XrResult result = xrDestroySession(harness.session);
    harness.session = XR_NULL_HANDLE;
    return succeeded(result, "replacement xrDestroySession");
}

int run() {
    Harness harness;
    harness.connected = expectConnected();
    if (!createInstanceAndDevice(harness) || !createSession(harness, &harness.session) ||
        !expectState(harness, XR_SESSION_STATE_IDLE) ||
        !expectState(harness, XR_SESSION_STATE_READY) || !beginSession(harness)) {
        return 1;
    }
    XrReferenceSpaceCreateInfo spaceInfo{};
    spaceInfo.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    if (!succeeded(xrCreateReferenceSpace(harness.session, &spaceInfo, &harness.local),
                   "xrCreateReferenceSpace(LOCAL)")) {
        return 1;
    }
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    if (!succeeded(xrCreateReferenceSpace(harness.session, &spaceInfo, &harness.stage),
                   "xrCreateReferenceSpace(STAGE)")) {
        return 1;
    }

    // The direct BGRA eye swapchains come first: their registration is what
    // makes the test daemon start streaming its deterministic head pose.
    Swapchain left;
    Swapchain right;
    if (!createSwapchain(harness, DXGI_FORMAT_B8G8R8A8_UNORM, 64, 64, 1, &left)) {
        return 1;
    }
    harness.swapchains.push_back(left);
    if (!createSwapchain(harness, DXGI_FORMAT_B8G8R8A8_UNORM, 64, 64, 1, &right)) {
        return 1;
    }
    harness.swapchains.push_back(right);
    if (!testFormats(harness) || !testSwapchainLimit(harness) ||
        !testRepeatedBeginWithoutEnd(harness)) {
        return 1;
    }
    std::puts("PASS: swapchain formats, mip/size/limit validation, and repeated "
              "wait+begin without end");

    Swapchain unreleased;
    Swapchain depth;
    if (!createSwapchain(harness, DXGI_FORMAT_R8G8B8A8_UNORM, 32, 32, 1, &unreleased)) {
        return 1;
    }
    harness.swapchains.push_back(unreleased);
    XrSwapchainCreateInfo depthInfo{};
    depthInfo.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    depthInfo.usageFlags = XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    depthInfo.format = DXGI_FORMAT_D32_FLOAT;
    depthInfo.sampleCount = 1;
    depthInfo.width = 32;
    depthInfo.height = 32;
    depthInfo.faceCount = 1;
    depthInfo.arraySize = 1;
    depthInfo.mipCount = 1;
    if (!succeeded(xrCreateSwapchain(harness.session, &depthInfo, &depth.handle),
                   "xrCreateSwapchain(depth)")) {
        return 1;
    }
    harness.swapchains.push_back(depth);
    {
        XrSwapchainImageAcquireInfo acquireInfo{};
        acquireInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
        XrSwapchainImageWaitInfo waitInfo{};
        waitInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO;
        waitInfo.timeout = XR_INFINITE_DURATION;
        XrSwapchainImageReleaseInfo releaseInfo{};
        releaseInfo.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
        uint32_t index = 0;
        if (!succeeded(xrAcquireSwapchainImage(depth.handle, &acquireInfo, &index),
                       "depth acquire") ||
            !succeeded(xrWaitSwapchainImage(depth.handle, &waitInfo), "depth wait") ||
            !succeeded(xrReleaseSwapchainImage(depth.handle, &releaseInfo), "depth release") ||
            !renderImage(harness, left, solidPixels(kBasaltDirectColor))) {
            return 1;
        }
    }
    if (!testLayerValidation(harness, left, unreleased, depth)) {
        return 1;
    }
    std::puts("PASS: quad, flipped-rect, depth-source, and unknown-layer validation");

    if (!runScenarios(harness, left, right)) {
        return 1;
    }
    std::printf("PASS: %d compositor scenario frames submitted%s\n", BASALT_SCENARIO_COUNT,
                harness.connected ? " and delivered to the control daemon" : " (headless)");

    if (!endSessionCleanly(harness) || !testSessionReplacement(harness)) {
        return 1;
    }
    std::puts("PASS: temporary session replacement delivers only current-session events");
    return 0;
}

}  // namespace

int main() {
    const int status = run();
    if (status == 0) {
        std::puts("PASS: OpenComposite-shaped compositor smoke");
    }
    return status;
}
