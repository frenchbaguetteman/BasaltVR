#include "runtime.hpp"

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>

#include <array>
#include <cstdint>

#include "control.hpp"

namespace {

constexpr uintptr_t kFirstSwapchainHandle = static_cast<uintptr_t>(0x30000);
constexpr uintptr_t kSwapchainHandleStride = static_cast<uintptr_t>(0x10);
constexpr uint32_t kSwapchainImageCount = 3;
constexpr uint32_t kMaxArraySize = 2;
constexpr size_t kMaxSwapchains = 4;

constexpr std::array<DXGI_FORMAT, 2> kSupportedFormats = {
    // Runtime order is preference order. The native CoreVideo handoff can
    // wrap BGRA IOSurfaces directly, while CVPixelBuffer rejects DXMT's RGBA
    // IOSurfaces. Do not advertise formats the compositor cannot deliver.
    DXGI_FORMAT_B8G8R8A8_UNORM,
    DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
};

enum class ImageState {
    Available,
    Acquired,
    Waited,
};

struct SwapchainRecord {
    XrSwapchain handle = XR_NULL_HANDLE;
    XrSession session = XR_NULL_HANDLE;
    std::array<ID3D11Texture2D*, kSwapchainImageCount> textures{};
    // Array swapchains stay private to the game/DXMT device. Each array
    // slice is copied into one simple IOSurface-backed 2D texture before the
    // frame fence is signalled so the native daemon can map it zero-copy.
    std::array<
        std::array<ID3D11Texture2D*, kMaxArraySize>,
        kSwapchainImageCount>
        exportTextures{};
    std::array<ImageState, kSwapchainImageCount> imageStates{};
    uint32_t nextAcquireIndex = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t arraySize = 0;
    bool everReleased = false;
    uint32_t lastReleasedIndex = 0;
};

SRWLOCK gSwapchainLock = SRWLOCK_INIT;
uintptr_t gNextSwapchainHandle = kFirstSwapchainHandle;
std::array<SwapchainRecord, kMaxSwapchains> gSwapchains{};

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

// UE4 titles create their eye textures as B8G8R8A8_TYPELESS and rely on their
// own resource views for the sRGB/linear interpretation, then hand that format
// straight to xrCreateSwapchain. Back the request with the typed BGRA format
// the compositor can export instead of rejecting the swapchain.
DXGI_FORMAT normalizeFormat(int64_t format) {
    if (format == static_cast<int64_t>(DXGI_FORMAT_B8G8R8A8_TYPELESS)) {
        return DXGI_FORMAT_B8G8R8A8_UNORM;
    }
    return static_cast<DXGI_FORMAT>(format);
}

bool isSupportedFormat(int64_t format) {
    const DXGI_FORMAT normalized = normalizeFormat(format);
    for (DXGI_FORMAT supported : kSupportedFormats) {
        if (normalized == supported) {
            return true;
        }
    }
    return false;
}

UINT bindFlagsForUsage(XrSwapchainUsageFlags usageFlags) {
    UINT bindFlags = 0;
    if ((usageFlags & XR_SWAPCHAIN_USAGE_SAMPLED_BIT) != 0) {
        bindFlags |= D3D11_BIND_SHADER_RESOURCE;
    }
    if ((usageFlags & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT) != 0) {
        bindFlags |= D3D11_BIND_RENDER_TARGET;
    }
    if ((usageFlags & XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT) != 0) {
        bindFlags |= D3D11_BIND_UNORDERED_ACCESS;
    }
    return bindFlags;
}

void releaseTextures(std::array<ID3D11Texture2D*, kSwapchainImageCount>& textures) {
    for (ID3D11Texture2D*& texture : textures) {
        release(texture);
    }
}

void releaseExportTextures(
    std::array<
        std::array<ID3D11Texture2D*, kMaxArraySize>,
        kSwapchainImageCount>& textures) {
    for (auto& image : textures) {
        for (ID3D11Texture2D*& texture : image) {
            release(texture);
        }
    }
}

SwapchainRecord* findSwapchainLocked(XrSwapchain swapchain) {
    for (SwapchainRecord& record : gSwapchains) {
        if (record.handle == swapchain) {
            return &record;
        }
    }
    return nullptr;
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL enumerateSwapchainFormats(
    XrSession session,
    uint32_t formatCapacityInput,
    uint32_t* formatCountOutput,
    int64_t* formats) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (formatCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *formatCountOutput = static_cast<uint32_t>(kSupportedFormats.size());
    if (formatCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (formats == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (formatCapacityInput < kSupportedFormats.size()) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (size_t index = 0; index < kSupportedFormats.size(); ++index) {
        formats[index] = static_cast<int64_t>(kSupportedFormats[index]);
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createSwapchain(
    XrSession session,
    const XrSwapchainCreateInfo* createInfo,
    XrSwapchain* swapchain) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (swapchain == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *swapchain = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_SWAPCHAIN_CREATE_INFO ||
        createInfo->createFlags != 0 || createInfo->usageFlags == 0 ||
        createInfo->width == 0 || createInfo->height == 0 ||
        createInfo->width > basalt::kMaxSwapchainWidth ||
        createInfo->height > basalt::kMaxSwapchainHeight ||
        createInfo->arraySize == 0 || createInfo->arraySize > kMaxArraySize ||
        createInfo->faceCount != 1 || createInfo->mipCount != 1 ||
        createInfo->sampleCount != 1) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!isSupportedFormat(createInfo->format)) {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }
    if ((createInfo->usageFlags & XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }

    ID3D11Device* device = retainSessionDevice(session);
    if (device == nullptr) {
        return XR_ERROR_HANDLE_INVALID;
    }

    D3D11_TEXTURE2D_DESC description{};
    description.Width = createInfo->width;
    description.Height = createInfo->height;
    description.MipLevels = createInfo->mipCount;
    description.ArraySize = createInfo->arraySize;
    description.Format = normalizeFormat(createInfo->format);
    description.SampleDesc.Count = createInfo->sampleCount;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = bindFlagsForUsage(createInfo->usageFlags);
    // A simple swapchain image is exported directly. A texture array cannot
    // be IOSurface-backed, so it remains private and receives per-slice
    // export textures below.
    description.MiscFlags = createInfo->arraySize == 1
        ? D3D11_RESOURCE_MISC_SHARED_NTHANDLE : 0;

    std::array<ID3D11Texture2D*, kSwapchainImageCount> textures{};
    std::array<
        std::array<ID3D11Texture2D*, kMaxArraySize>,
        kSwapchainImageCount>
        exportTextures{};
    HRESULT result = S_OK;
    for (ID3D11Texture2D*& texture : textures) {
        result = device->CreateTexture2D(&description, nullptr, &texture);
        if (FAILED(result)) {
            break;
        }
    }
    if (SUCCEEDED(result) && createInfo->arraySize > 1) {
        D3D11_TEXTURE2D_DESC exportDescription = description;
        exportDescription.ArraySize = 1;
        exportDescription.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        exportDescription.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
        for (uint32_t image = 0;
             image < kSwapchainImageCount && SUCCEEDED(result); ++image) {
            for (uint32_t slice = 0; slice < createInfo->arraySize; ++slice) {
                result = device->CreateTexture2D(
                    &exportDescription, nullptr,
                    &exportTextures[image][slice]);
                if (FAILED(result)) {
                    break;
                }
            }
        }
    }
    release(device);
    if (FAILED(result)) {
        releaseTextures(textures);
        releaseExportTextures(exportTextures);
        return XR_ERROR_RUNTIME_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    if (!isValidSession(session)) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        releaseTextures(textures);
        releaseExportTextures(exportTextures);
        return XR_ERROR_HANDLE_INVALID;
    }
    SwapchainRecord* available = nullptr;
    for (SwapchainRecord& record : gSwapchains) {
        if (record.handle == XR_NULL_HANDLE) {
            available = &record;
            break;
        }
    }
    if (available == nullptr ||
        gNextSwapchainHandle > UINTPTR_MAX - kSwapchainHandleStride) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        releaseTextures(textures);
        releaseExportTextures(exportTextures);
        return XR_ERROR_LIMIT_REACHED;
    }

    available->handle = reinterpret_cast<XrSwapchain>(gNextSwapchainHandle);
    gNextSwapchainHandle += kSwapchainHandleStride;
    available->session = session;
    available->textures = textures;
    available->exportTextures = exportTextures;
    available->imageStates.fill(ImageState::Available);
    available->nextAcquireIndex = 0;
    available->width = createInfo->width;
    available->height = createInfo->height;
    available->arraySize = createInfo->arraySize;
    available->everReleased = false;
    available->lastReleasedIndex = 0;
    *swapchain = available->handle;
    ReleaseSRWLockExclusive(&gSwapchainLock);

    if (controlActive(session)) {
        std::array<uint32_t, kSwapchainImageCount * kMaxArraySize> iosurfaceIds{};
        bool allBacked = true;
        for (uint32_t image = 0; image < kSwapchainImageCount; ++image) {
            for (uint32_t slice = 0; slice < createInfo->arraySize; ++slice) {
                ID3D11Texture2D* exported = createInfo->arraySize == 1
                    ? textures[image] : exportTextures[image][slice];
                const uint32_t flatIndex =
                    image * createInfo->arraySize + slice;
                iosurfaceIds[flatIndex] = queryTextureIOSurfaceId(exported);
                allBacked = allBacked && iosurfaceIds[flatIndex] != 0;
            }
        }
        if (allBacked) {
            controlRegisterSwapchain(
                *swapchain,
                createInfo->width,
                createInfo->height,
                createInfo->format,
                iosurfaceIds.data(),
                kSwapchainImageCount * createInfo->arraySize);
        }
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroySwapchain(XrSwapchain swapchain) {
    if (swapchain == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    std::array<ID3D11Texture2D*, kSwapchainImageCount> textures{};
    std::array<
        std::array<ID3D11Texture2D*, kMaxArraySize>,
        kSwapchainImageCount>
        exportTextures{};
    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    textures = record->textures;
    exportTextures = record->exportTextures;
    record->textures.fill(nullptr);
    for (auto& image : record->exportTextures) {
        image.fill(nullptr);
    }
    *record = {};
    ReleaseSRWLockExclusive(&gSwapchainLock);
    // The daemon holds IOSurface retains until this ack (or disconnect), so
    // the textures may only be released afterwards.
    controlUnregisterSwapchain(swapchain);
    releaseTextures(textures);
    releaseExportTextures(exportTextures);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL enumerateSwapchainImages(
    XrSwapchain swapchain,
    uint32_t imageCapacityInput,
    uint32_t* imageCountOutput,
    XrSwapchainImageBaseHeader* images) {
    if (imageCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    *imageCountOutput = kSwapchainImageCount;
    if (imageCapacityInput == 0) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_SUCCESS;
    }
    if (images == nullptr) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (imageCapacityInput < kSwapchainImageCount) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_ERROR_SIZE_INSUFFICIENT;
    }

    auto* d3dImages = reinterpret_cast<XrSwapchainImageD3D11KHR*>(images);
    for (uint32_t index = 0; index < kSwapchainImageCount; ++index) {
        if (d3dImages[index].type != XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR) {
            ReleaseSRWLockShared(&gSwapchainLock);
            return XR_ERROR_VALIDATION_FAILURE;
        }
    }
    for (uint32_t index = 0; index < kSwapchainImageCount; ++index) {
        d3dImages[index].texture = record->textures[index];
    }
    ReleaseSRWLockShared(&gSwapchainLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL acquireSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageAcquireInfo* acquireInfo,
    uint32_t* index) {
    if (index == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *index = UINT32_MAX;
    if (acquireInfo == nullptr || acquireInfo->type != XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    for (uint32_t offset = 0; offset < kSwapchainImageCount; ++offset) {
        const uint32_t candidate =
            (record->nextAcquireIndex + offset) % kSwapchainImageCount;
        if (record->imageStates[candidate] == ImageState::Available) {
            record->imageStates[candidate] = ImageState::Acquired;
            record->nextAcquireIndex = (candidate + 1) % kSwapchainImageCount;
            *index = candidate;
            ReleaseSRWLockExclusive(&gSwapchainLock);
            return XR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_ERROR_CALL_ORDER_INVALID;
}

XrResult XRAPI_CALL waitSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageWaitInfo* waitInfo) {
    if (waitInfo == nullptr || waitInfo->type != XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    for (ImageState& state : record->imageStates) {
        if (state == ImageState::Acquired) {
            state = ImageState::Waited;
            ReleaseSRWLockExclusive(&gSwapchainLock);
            return XR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_ERROR_CALL_ORDER_INVALID;
}

XrResult XRAPI_CALL releaseSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageReleaseInfo* releaseInfo) {
    if (releaseInfo == nullptr || releaseInfo->type != XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    for (uint32_t index = 0; index < kSwapchainImageCount; ++index) {
        if (record->imageStates[index] == ImageState::Waited) {
            record->imageStates[index] = ImageState::Available;
            record->everReleased = true;
            record->lastReleasedIndex = index;
            ReleaseSRWLockExclusive(&gSwapchainLock);
            return XR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_ERROR_CALL_ORDER_INVALID;
}

bool getSwapchainSubmitState(
    XrSwapchain swapchain,
    XrSession* session,
    uint32_t* width,
    uint32_t* height,
    uint32_t* arraySize,
    bool* hasReleasedImage,
    uint32_t* lastReleasedIndex) {
    if (swapchain == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record != nullptr) {
        if (session != nullptr) {
            *session = record->session;
        }
        if (width != nullptr) {
            *width = record->width;
        }
        if (height != nullptr) {
            *height = record->height;
        }
        if (arraySize != nullptr) {
            *arraySize = record->arraySize;
        }
        if (hasReleasedImage != nullptr) {
            *hasReleasedImage = record->everReleased;
        }
        if (lastReleasedIndex != nullptr) {
            *lastReleasedIndex = record->lastReleasedIndex;
        }
    }
    ReleaseSRWLockShared(&gSwapchainLock);
    return record != nullptr;
}

bool prepareSwapchainViewForExport(
    ID3D11DeviceContext* context,
    ControlFrameView* view) {
    if (context == nullptr || view == nullptr ||
        view->imageIndex >= kSwapchainImageCount) {
        return false;
    }
    const XrSwapchain swapchain =
        reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(view->swapchainId));
    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record == nullptr || view->imageArrayIndex >= record->arraySize) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return false;
    }
    const uint32_t sourceImage = view->imageIndex;
    const uint32_t sourceSlice = view->imageArrayIndex;
    if (record->arraySize > 1) {
        ID3D11Texture2D* destination =
            record->exportTextures[sourceImage][sourceSlice];
        ID3D11Texture2D* source = record->textures[sourceImage];
        if (destination == nullptr || source == nullptr) {
            ReleaseSRWLockShared(&gSwapchainLock);
            return false;
        }
        context->CopySubresourceRegion(
            destination, 0, 0, 0, 0,
            source, D3D11CalcSubresource(0, sourceSlice, 1), nullptr);
    }
    view->imageIndex = sourceImage * record->arraySize + sourceSlice;
    view->imageArrayIndex = 0;
    ReleaseSRWLockShared(&gSwapchainLock);
    return true;
}

void invalidateSwapchainForSession(XrSession session) {
    std::array<
        std::array<ID3D11Texture2D*, kSwapchainImageCount>,
        kMaxSwapchains>
        textures{};
    std::array<
        std::array<
            std::array<ID3D11Texture2D*, kMaxArraySize>,
            kSwapchainImageCount>,
        kMaxSwapchains>
        exportTextures{};
    std::array<XrSwapchain, kMaxSwapchains> handles{};
    size_t textureSetCount = 0;
    AcquireSRWLockExclusive(&gSwapchainLock);
    for (SwapchainRecord& record : gSwapchains) {
        if (record.session == session) {
            textures[textureSetCount] = record.textures;
            exportTextures[textureSetCount] = record.exportTextures;
            handles[textureSetCount] = record.handle;
            ++textureSetCount;
            record.textures.fill(nullptr);
            for (auto& image : record.exportTextures) {
                image.fill(nullptr);
            }
            record = {};
        }
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    for (size_t index = 0; index < textureSetCount; ++index) {
        // Session teardown has already closed the control connection, making
        // this a no-op there; it matters on other invalidation orderings.
        controlUnregisterSwapchain(handles[index]);
        releaseTextures(textures[index]);
        releaseExportTextures(exportTextures[index]);
    }
}

}  // namespace basalt
