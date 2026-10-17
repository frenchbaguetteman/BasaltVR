#include "runtime.hpp"

#include "control.hpp"

#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <cstring>

namespace {

constexpr uintptr_t kFirstSessionHandle = static_cast<uintptr_t>(0x20000);
constexpr uintptr_t kSessionHandleStride = static_cast<uintptr_t>(0x10);
constexpr D3D_FEATURE_LEVEL kMinimumFeatureLevel = D3D_FEATURE_LEVEL_11_0;

SRWLOCK gGraphicsLock = SRWLOCK_INIT;
XrInstance gRequirementsInstance = XR_NULL_HANDLE;
LUID gRequiredAdapterLuid{};
uintptr_t gNextSessionHandle = kFirstSessionHandle;
XrSession gLiveSession = XR_NULL_HANDLE;
XrInstance gSessionInstance = XR_NULL_HANDLE;
ID3D11Device* gSessionDevice = nullptr;

INIT_ONCE gCapabilityOnce = INIT_ONCE_STATIC_INIT;
bool gD3D11RuntimeAvailable = false;
LUID gCapabilityAdapterLuid{};

bool luidEqual(const LUID& left, const LUID& right) {
    return left.LowPart == right.LowPart && left.HighPart == right.HighPart;
}

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

HRESULT probeD3D11Sharing(LUID* luid) {
    constexpr uint32_t kWidth = 2;
    constexpr uint32_t kHeight = 2;
    constexpr uint32_t kPixels[kWidth * kHeight] = {
        0xff030201,
        0xff060504,
        0xff090807,
        0xff0c0b0a,
    };

    IDXGIFactory1* factory = nullptr;
    HRESULT result = CreateDXGIFactory1(
        __uuidof(IDXGIFactory1),
        reinterpret_cast<void**>(&factory));
    if (FAILED(result)) {
        return result;
    }

    IDXGIAdapter1* adapter = nullptr;
    result = factory->EnumAdapters1(0, &adapter);
    factory->Release();
    if (FAILED(result)) {
        return result;
    }

    DXGI_ADAPTER_DESC1 description{};
    result = adapter->GetDesc1(&description);
    if (FAILED(result)) {
        release(adapter);
        return result;
    }

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL selectedFeatureLevel{};
    const D3D_FEATURE_LEVEL featureLevels[] = {kMinimumFeatureLevel};
    result = D3D11CreateDevice(
        adapter,
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        featureLevels,
        1,
        D3D11_SDK_VERSION,
        &device,
        &selectedFeatureLevel,
        &context);
    release(adapter);
    if (FAILED(result) || selectedFeatureLevel < kMinimumFeatureLevel) {
        release(context);
        release(device);
        return FAILED(result) ? result : E_FAIL;
    }

    ID3D11Device1* device1 = nullptr;
    result = device->QueryInterface(IID_ID3D11Device1, reinterpret_cast<void**>(&device1));
    if (FAILED(result)) {
        release(context);
        release(device);
        return result;
    }

    D3D11_TEXTURE2D_DESC sharedDescription{};
    sharedDescription.Width = kWidth;
    sharedDescription.Height = kHeight;
    sharedDescription.MipLevels = 1;
    sharedDescription.ArraySize = 1;
    sharedDescription.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sharedDescription.SampleDesc.Count = 1;
    sharedDescription.Usage = D3D11_USAGE_DEFAULT;
    sharedDescription.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    sharedDescription.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;

    D3D11_SUBRESOURCE_DATA initialData{};
    initialData.pSysMem = kPixels;
    initialData.SysMemPitch = kWidth * sizeof(uint32_t);

    ID3D11Texture2D* sharedTexture = nullptr;
    result = device->CreateTexture2D(&sharedDescription, &initialData, &sharedTexture);
    IDXGIResource1* sharedResource = nullptr;
    HANDLE sharedHandle = nullptr;
    ID3D11Texture2D* reopenedTexture = nullptr;
    ID3D11Texture2D* stagingTexture = nullptr;

    if (SUCCEEDED(result)) {
        result = sharedTexture->QueryInterface(
            IID_IDXGIResource1,
            reinterpret_cast<void**>(&sharedResource));
    }
    if (SUCCEEDED(result)) {
        result = sharedResource->CreateSharedHandle(
            nullptr,
            DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
            nullptr,
            &sharedHandle);
    }
    if (SUCCEEDED(result)) {
        result = device1->OpenSharedResource1(
            sharedHandle,
            IID_ID3D11Texture2D,
            reinterpret_cast<void**>(&reopenedTexture));
    }
    if (SUCCEEDED(result)) {
        D3D11_TEXTURE2D_DESC stagingDescription = sharedDescription;
        stagingDescription.Usage = D3D11_USAGE_STAGING;
        stagingDescription.BindFlags = 0;
        stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        stagingDescription.MiscFlags = 0;
        result = device->CreateTexture2D(&stagingDescription, nullptr, &stagingTexture);
    }
    if (SUCCEEDED(result)) {
        context->CopyResource(stagingTexture, reopenedTexture);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        result = context->Map(stagingTexture, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(result)) {
            for (uint32_t row = 0; row < kHeight; ++row) {
                const auto* actual = static_cast<const uint8_t*>(mapped.pData) + row * mapped.RowPitch;
                const auto* expected = reinterpret_cast<const uint8_t*>(kPixels) +
                                       row * kWidth * sizeof(uint32_t);
                if (std::memcmp(actual, expected, kWidth * sizeof(uint32_t)) != 0) {
                    result = E_FAIL;
                    break;
                }
            }
            context->Unmap(stagingTexture, 0);
        }
    }

    release(stagingTexture);
    release(reopenedTexture);
    if (sharedHandle != nullptr) {
        CloseHandle(sharedHandle);
    }
    release(sharedResource);
    release(sharedTexture);
    release(device1);
    release(context);
    release(device);

    if (SUCCEEDED(result)) {
        *luid = description.AdapterLuid;
    }
    return result;
}

BOOL CALLBACK initializeCapability(PINIT_ONCE, PVOID, PVOID*) {
    LUID adapterLuid{};
    if (SUCCEEDED(probeD3D11Sharing(&adapterLuid))) {
        gCapabilityAdapterLuid = adapterLuid;
        gD3D11RuntimeAvailable = true;
    }
    return TRUE;
}

HRESULT deviceAdapterLuid(ID3D11Device* device, LUID* luid) {
    if (device == nullptr || luid == nullptr) {
        return E_POINTER;
    }

    IDXGIDevice* dxgiDevice = nullptr;
    HRESULT result = device->QueryInterface(
        __uuidof(IDXGIDevice),
        reinterpret_cast<void**>(&dxgiDevice));
    if (FAILED(result)) {
        return result;
    }

    IDXGIAdapter* adapter = nullptr;
    result = dxgiDevice->GetAdapter(&adapter);
    dxgiDevice->Release();
    if (FAILED(result)) {
        return result;
    }

    DXGI_ADAPTER_DESC description{};
    result = adapter->GetDesc(&description);
    adapter->Release();
    if (SUCCEEDED(result)) {
        *luid = description.AdapterLuid;
    }
    return result;
}

const XrGraphicsBindingD3D11KHR* findD3D11Binding(const void* next) {
    const auto* structure = static_cast<const XrBaseInStructure*>(next);
    while (structure != nullptr) {
        if (structure->type == XR_TYPE_GRAPHICS_BINDING_D3D11_KHR) {
            return reinterpret_cast<const XrGraphicsBindingD3D11KHR*>(structure);
        }
        structure = structure->next;
    }
    return nullptr;
}

}  // namespace

namespace basalt {

bool isD3D11RuntimeAvailable() {
    InitOnceExecuteOnce(&gCapabilityOnce, initializeCapability, nullptr, nullptr);
    return gD3D11RuntimeAvailable;
}

XrResult XRAPI_CALL getD3D11GraphicsRequirements(
    XrInstance instance,
    XrSystemId systemId,
    XrGraphicsRequirementsD3D11KHR* graphicsRequirements) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!isD3D11ExtensionEnabled(instance)) {
        return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    if (systemId != kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    if (graphicsRequirements == nullptr ||
        graphicsRequirements->type != XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (!isD3D11RuntimeAvailable()) {
        return XR_ERROR_RUNTIME_FAILURE;
    }

    graphicsRequirements->adapterLuid = gCapabilityAdapterLuid;
    graphicsRequirements->minFeatureLevel = kMinimumFeatureLevel;

    AcquireSRWLockExclusive(&gGraphicsLock);
    gRequirementsInstance = instance;
    gRequiredAdapterLuid = gCapabilityAdapterLuid;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createSession(
    XrInstance instance,
    const XrSessionCreateInfo* createInfo,
    XrSession* session) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (session == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *session = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_SESSION_CREATE_INFO ||
        createInfo->createFlags != 0) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->systemId != kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    if (!isD3D11ExtensionEnabled(instance)) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }

    AcquireSRWLockShared(&gGraphicsLock);
    const bool requirementsQueried = gRequirementsInstance == instance;
    const LUID requiredAdapterLuid = gRequiredAdapterLuid;
    ReleaseSRWLockShared(&gGraphicsLock);
    if (!requirementsQueried) {
        return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    }

    const XrGraphicsBindingD3D11KHR* binding = findD3D11Binding(createInfo->next);
    if (binding == nullptr || binding->device == nullptr) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    if (binding->device->GetFeatureLevel() < kMinimumFeatureLevel) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    ID3D11Device1* device1 = nullptr;
    if (FAILED(binding->device->QueryInterface(
            IID_ID3D11Device1,
            reinterpret_cast<void**>(&device1)))) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    device1->Release();

    LUID deviceLuid{};
    if (FAILED(deviceAdapterLuid(binding->device, &deviceLuid)) ||
        !luidEqual(deviceLuid, requiredAdapterLuid)) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }

    AcquireSRWLockExclusive(&gGraphicsLock);
    if (gLiveSession != XR_NULL_HANDLE) {
        ReleaseSRWLockExclusive(&gGraphicsLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    if (gNextSessionHandle > UINTPTR_MAX - kSessionHandleStride) {
        ReleaseSRWLockExclusive(&gGraphicsLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    gLiveSession = reinterpret_cast<XrSession>(gNextSessionHandle);
    gNextSessionHandle += kSessionHandleStride;
    gSessionInstance = instance;
    binding->device->AddRef();
    gSessionDevice = binding->device;
    *session = gLiveSession;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    initializeSessionLifecycle(instance, *session);
    controlSessionCreated(*session, binding->device);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroySession(XrSession session) {
    if (session == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gGraphicsLock);
    if (session != gLiveSession) {
        ReleaseSRWLockExclusive(&gGraphicsLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    ID3D11Device* device = gSessionDevice;
    gLiveSession = XR_NULL_HANDLE;
    gSessionInstance = XR_NULL_HANDLE;
    gSessionDevice = nullptr;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    controlSessionDestroyed(session);
    invalidateSessionLifecycle(session);
    invalidateSpacesForSession(session);
    invalidateHandTrackersForSession(session);
    invalidateSwapchainForSession(session);
    invalidateInputForSession(session);
    release(device);
    return XR_SUCCESS;
}

bool isValidSession(XrSession session) {
    if (session == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gGraphicsLock);
    const bool valid = session == gLiveSession;
    ReleaseSRWLockShared(&gGraphicsLock);
    return valid;
}

ID3D11Device* retainSessionDevice(XrSession session) {
    AcquireSRWLockShared(&gGraphicsLock);
    ID3D11Device* device = nullptr;
    if (session == gLiveSession && gSessionDevice != nullptr) {
        gSessionDevice->AddRef();
        device = gSessionDevice;
    }
    ReleaseSRWLockShared(&gGraphicsLock);
    return device;
}

void invalidateSessionForInstance(XrInstance instance) {
    XrSession session = XR_NULL_HANDLE;
    ID3D11Device* device = nullptr;
    AcquireSRWLockExclusive(&gGraphicsLock);
    if (gSessionInstance == instance) {
        session = gLiveSession;
        device = gSessionDevice;
        gLiveSession = XR_NULL_HANDLE;
        gSessionInstance = XR_NULL_HANDLE;
        gSessionDevice = nullptr;
    }
    if (gRequirementsInstance == instance) {
        gRequirementsInstance = XR_NULL_HANDLE;
        gRequiredAdapterLuid = {};
    }
    ReleaseSRWLockExclusive(&gGraphicsLock);
    if (session != XR_NULL_HANDLE) {
        controlSessionDestroyed(session);
        invalidateSessionLifecycle(session);
        invalidateSpacesForSession(session);
        invalidateHandTrackersForSession(session);
        invalidateSwapchainForSession(session);
        invalidateInputForSession(session);
    }
    release(device);
}

}  // namespace basalt
