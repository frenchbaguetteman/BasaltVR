#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <cerrno>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
    for (const XrExtensionProperties& extension : extensions) {
        if (std::strcmp(extension.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0 &&
            extension.extensionVersion == XR_KHR_D3D11_enable_SPEC_VERSION) {
            foundD3D11 = true;
            break;
        }
    }
    if (!foundD3D11) {
        std::fputs("FAIL: runtime did not advertise XR_KHR_D3D11_enable v11\n", stderr);
        return 1;
    }

    const char* enabledExtensions[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo instanceInfo{};
    instanceInfo.type = XR_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.enabledExtensionCount = 1;
    instanceInfo.enabledExtensionNames = enabledExtensions;
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
    XrSpace rejectedSpace = XR_NULL_HANDLE;

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
    if (XR_FAILED(result) || frameState.predictedDisplayTime <= 0 ||
        frameState.predictedDisplayPeriod <= 0 ||
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
        XrEventDataReferenceSpaceChangePending recenterEvent{};
        bool receivedRecenter = false;
        for (int attempt = 0; XR_SUCCEEDED(result) && attempt < 100; ++attempt) {
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
            recenterEvent = *reinterpret_cast<
                const XrEventDataReferenceSpaceChangePending*>(&eventData);
            receivedRecenter = true;
            break;
        }
        if (XR_FAILED(result) || !receivedRecenter ||
            recenterEvent.session != session ||
            recenterEvent.referenceSpaceType != XR_REFERENCE_SPACE_TYPE_LOCAL ||
            recenterEvent.changeTime <= 0 || recenterEvent.poseValid != XR_TRUE ||
            !nearlyEqual(recenterEvent.poseInPreviousSpace.position.x, -0.25f) ||
            !nearlyEqual(recenterEvent.poseInPreviousSpace.position.y, 0.0f) ||
            !nearlyEqual(recenterEvent.poseInPreviousSpace.position.z, 0.25f) ||
            !nearlyEqual(recenterEvent.poseInPreviousSpace.orientation.y, 0.707106781f) ||
            !nearlyEqual(recenterEvent.poseInPreviousSpace.orientation.w, 0.707106781f)) {
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

    uint32_t formatCount = 0;
    result = xrEnumerateSwapchainFormats(session, 0, &formatCount, nullptr);
    std::vector<int64_t> formats(formatCount);
    if (XR_SUCCEEDED(result)) {
        result = xrEnumerateSwapchainFormats(
            session, formatCount, &formatCount, formats.data());
    }
    bool foundBgra = false;
    for (int64_t format : formats) {
        foundBgra = foundBgra || format == DXGI_FORMAT_B8G8R8A8_UNORM;
    }
    // Advertise only formats the native CoreVideo compositor can wrap. RGBA
    // IOSurfaces must fail at swapchain negotiation instead of rendering a
    // silently black stream.
    if (XR_FAILED(result) || !foundBgra || formats.size() != 2 ||
        formats.front() != DXGI_FORMAT_B8G8R8A8_UNORM) {
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

    swapchainInfo.format = DXGI_FORMAT_R8G8B8A8_UNORM;
    XrSwapchain rgbaSwapchain = XR_NULL_HANDLE;
    result = xrCreateSwapchain(session, &swapchainInfo, &rgbaSwapchain);
    if (result != XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED ||
        rgbaSwapchain != XR_NULL_HANDLE) {
        if (rgbaSwapchain != XR_NULL_HANDLE) {
            xrDestroySwapchain(rgbaSwapchain);
        }
        xrDestroySession(session);
        release(context);
        release(device);
        xrDestroyInstance(instance);
        return fail("xrCreateSwapchain(unsupported RGBA transport)", result);
    }
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

    XrCompositionLayerQuad quadLayer{};
    quadLayer.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
    quadLayer.space = localSpace;
    quadLayer.subImage = projectionViews[0].subImage;
    quadLayer.pose.orientation.w = 1.0f;
    quadLayer.size = {1.0f, 1.0f};
    result = xrWaitFrame(session, nullptr, &layerFrameState);
    if (XR_SUCCEEDED(result)) {
        result = xrBeginFrame(session, nullptr);
    }
    frameEndInfo.displayTime = layerFrameState.predictedDisplayTime;
    submittedLayers[0] = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quadLayer);
    if (XR_SUCCEEDED(result)) {
        result = xrEndFrame(session, &frameEndInfo);
        if (result != XR_ERROR_LAYER_INVALID) {
            xrDestroySwapchain(secondSwapchain);
            xrDestroySwapchain(swapchain);
            xrDestroySession(session);
            release(context);
            release(device);
            xrDestroyInstance(instance);
            return fail("quad layer rejection", result);
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
