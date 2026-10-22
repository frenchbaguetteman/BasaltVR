#include "runtime.hpp"

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>

#include <array>
#include <cstdint>

#include "compositor.hpp"
#include "control.hpp"

namespace {

constexpr uintptr_t kFirstSwapchainHandle = static_cast<uintptr_t>(0x30000);
constexpr uintptr_t kSwapchainHandleStride = static_cast<uintptr_t>(0x10);
constexpr uint32_t kSwapchainImageCount = 3;
constexpr uint32_t kMaxArraySize = 2;
// OpenComposite keeps two eye swapchains, a skybox, and one swapchain per
// textured overlay alive. Only direct swapchains are registered with the
// daemon, which places no limit on their number.
constexpr size_t kMaxSwapchains = 16;
// Composited swapchains are scaled into the stream's per-eye size, so they
// may exceed the direct export limit (OpenComposite mirrors the game's own
// render target size).
constexpr uint32_t kMaxSwapchainDimension = 4096;

struct SwapchainFormat {
    DXGI_FORMAT format;
    // View format the compositor samples through; UNKNOWN for depth.
    DXGI_FORMAT sampleFormat;
    // Typeless resource format used when a depth swapchain is also sampled.
    DXGI_FORMAT sampledDepthFormat;
    bool decodeSrgb;
    bool depth;
    bool advertised;
};

constexpr SwapchainFormat kSwapchainFormats[] = {
    // Runtime order is preference order. The native CoreVideo handoff can
    // wrap BGRA IOSurfaces directly (zero copy), while CVPixelBuffer rejects
    // DXMT's RGBA IOSurfaces. Every other format is accepted for the
    // runtime compositor, which converts it into a BGRA output image. Only
    // the BGRA pair is advertised unless BASALT_ADVERTISE_ALL_FORMATS=1.
    {DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, true},
    {DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
     DXGI_FORMAT_UNKNOWN, false, false, true},
    {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
     DXGI_FORMAT_UNKNOWN, false, false, true},
    {DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, true},
    {DXGI_FORMAT_B8G8R8X8_UNORM_SRGB, DXGI_FORMAT_B8G8R8X8_UNORM_SRGB,
     DXGI_FORMAT_UNKNOWN, false, false, true},
    {DXGI_FORMAT_B8G8R8X8_UNORM, DXGI_FORMAT_B8G8R8X8_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, true},
    {DXGI_FORMAT_R10G10B10A2_UNORM, DXGI_FORMAT_R10G10B10A2_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, true},
    {DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R16G16B16A16_FLOAT,
     DXGI_FORMAT_UNKNOWN, false, false, true},
    {DXGI_FORMAT_R11G11B10_FLOAT, DXGI_FORMAT_R11G11B10_FLOAT,
     DXGI_FORMAT_UNKNOWN, false, false, true},
    {DXGI_FORMAT_D32_FLOAT, DXGI_FORMAT_UNKNOWN,
     DXGI_FORMAT_R32_TYPELESS, false, true, true},
    {DXGI_FORMAT_D24_UNORM_S8_UINT, DXGI_FORMAT_UNKNOWN,
     DXGI_FORMAT_R24G8_TYPELESS, false, true, true},
    {DXGI_FORMAT_D16_UNORM, DXGI_FORMAT_UNKNOWN,
     DXGI_FORMAT_R16_TYPELESS, false, true, true},
    {DXGI_FORMAT_D32_FLOAT_S8X24_UINT, DXGI_FORMAT_UNKNOWN,
     DXGI_FORMAT_R32G8X24_TYPELESS, false, true, true},
    // Typeless variants are accepted for applications that create their own
    // typed views, but never advertised. Their bytes are sampled as UNORM
    // (or float), like the matching typed formats.
    {DXGI_FORMAT_R8G8B8A8_TYPELESS, DXGI_FORMAT_R8G8B8A8_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, false},
    {DXGI_FORMAT_B8G8R8A8_TYPELESS, DXGI_FORMAT_B8G8R8A8_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, false},
    {DXGI_FORMAT_B8G8R8X8_TYPELESS, DXGI_FORMAT_B8G8R8X8_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, false},
    {DXGI_FORMAT_R10G10B10A2_TYPELESS, DXGI_FORMAT_R10G10B10A2_UNORM,
     DXGI_FORMAT_UNKNOWN, true, false, false},
    {DXGI_FORMAT_R16G16B16A16_TYPELESS, DXGI_FORMAT_R16G16B16A16_FLOAT,
     DXGI_FORMAT_UNKNOWN, false, false, false},
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
    // Compositor sampling views, created on first composited use.
    std::array<
        std::array<ID3D11ShaderResourceView*, kMaxArraySize>,
        kSwapchainImageCount>
        sampleViews{};
    std::array<ImageState, kSwapchainImageCount> imageStates{};
    // Acquired and waited images, oldest acquisition first. Wait and release
    // act on the oldest eligible image (OpenXR 1.0 §10.4), which the image
    // index cannot express once acquisition wraps around the ring.
    std::array<uint32_t, kSwapchainImageCount> acquireOrder{};
    uint32_t acquireCount = 0;
    uint32_t nextAcquireIndex = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t arraySize = 0;
    const SwapchainFormat* format = nullptr;
    // Satisfies the direct export rules and its IOSurfaces were registered.
    bool exported = false;
    bool everReleased = false;
    uint32_t lastReleasedIndex = 0;
};

using SampleViews = std::array<
    std::array<ID3D11ShaderResourceView*, kMaxArraySize>,
    kSwapchainImageCount>;

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

const SwapchainFormat* findFormat(int64_t format) {
    for (const SwapchainFormat& supported : kSwapchainFormats) {
        if (format == static_cast<int64_t>(supported.format)) {
            return &supported;
        }
    }
    return nullptr;
}

// The pre-compositor rules: the streamer can consume these images directly.
bool isDirectExportShape(const XrSwapchainCreateInfo& createInfo) {
    return (createInfo.format == DXGI_FORMAT_B8G8R8A8_UNORM ||
            createInfo.format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) &&
           createInfo.mipCount == 1 &&
           createInfo.width <= basalt::kMaxViewWidth &&
           createInfo.height <= basalt::kMaxViewHeight;
}

uint32_t maxMipCount(uint32_t width, uint32_t height) {
    uint32_t largest = width > height ? width : height;
    uint32_t levels = 1;
    while (largest > 1) {
        largest /= 2;
        ++levels;
    }
    return levels;
}

// Advertises only formats this device can create, render, and sample (or
// use as depth), so an accepted format never fails at swapchain creation.
bool deviceSupportsFormat(ID3D11Device* device, const SwapchainFormat& format) {
    UINT support = 0;
    if (FAILED(device->CheckFormatSupport(format.format, &support))) {
        return false;
    }
    const UINT required = format.depth
        ? D3D11_FORMAT_SUPPORT_TEXTURE2D | D3D11_FORMAT_SUPPORT_DEPTH_STENCIL
        : D3D11_FORMAT_SUPPORT_TEXTURE2D | D3D11_FORMAT_SUPPORT_RENDER_TARGET |
              D3D11_FORMAT_SUPPORT_SHADER_SAMPLE;
    return (support & required) == required;
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
    if ((usageFlags & XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
        bindFlags |= D3D11_BIND_DEPTH_STENCIL;
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

void releaseSampleViews(SampleViews& views) {
    for (auto& image : views) {
        for (ID3D11ShaderResourceView*& view : image) {
            release(view);
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

    ID3D11Device* device = retainSessionDevice(session);
    if (device == nullptr) {
        return XR_ERROR_HANDLE_INVALID;
    }
    // Only the two zero-copy BGRA formats are advertised by default, so engines
    // that pick their own preferred format from this list (Unity's OpenXR
    // plugin) stay on the direct path. xrCreateSwapchain deliberately accepts
    // every format in kSwapchainFormats even though the spec says a format
    // that was not enumerated should fail with
    // XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED: OpenVR translation layers such as
    // OpenComposite never enumerate and create swapchains in the game's own
    // texture format. BASALT_ADVERTISE_ALL_FORMATS=1 advertises everything.
    char advertiseAll[2] = {};
    const bool allFormats =
        GetEnvironmentVariableA("BASALT_ADVERTISE_ALL_FORMATS", advertiseAll,
                                sizeof(advertiseAll)) == 1 &&
        advertiseAll[0] == '1';
    std::array<int64_t, sizeof(kSwapchainFormats) / sizeof(kSwapchainFormats[0])>
        advertised{};
    uint32_t advertisedCount = 0;
    for (const SwapchainFormat& format : kSwapchainFormats) {
        const bool direct = format.format == DXGI_FORMAT_B8G8R8A8_UNORM ||
                            format.format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
        if (direct || (allFormats && format.advertised &&
                       deviceSupportsFormat(device, format))) {
            advertised[advertisedCount++] = static_cast<int64_t>(format.format);
        }
    }
    release(device);

    *formatCountOutput = advertisedCount;
    if (formatCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (formats == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (formatCapacityInput < advertisedCount) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (uint32_t index = 0; index < advertisedCount; ++index) {
        formats[index] = advertised[index];
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
        createInfo->width > kMaxSwapchainDimension ||
        createInfo->height > kMaxSwapchainDimension ||
        createInfo->arraySize == 0 || createInfo->arraySize > kMaxArraySize ||
        createInfo->faceCount != 1 || createInfo->mipCount == 0 ||
        createInfo->mipCount > maxMipCount(createInfo->width, createInfo->height) ||
        createInfo->sampleCount != 1) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    const SwapchainFormat* format = findFormat(createInfo->format);
    if (format == nullptr) {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }
    constexpr XrSwapchainUsageFlags kColorOnlyUsage =
        XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
        XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT;
    if (format->depth
            ? (createInfo->usageFlags & kColorOnlyUsage) != 0
            : (createInfo->usageFlags &
               XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }
    const bool direct = !format->depth && isDirectExportShape(*createInfo);

    ID3D11Device* device = retainSessionDevice(session);
    if (device == nullptr) {
        return XR_ERROR_HANDLE_INVALID;
    }

    const bool sampledDepth = format->depth &&
        (createInfo->usageFlags & XR_SWAPCHAIN_USAGE_SAMPLED_BIT) != 0;
    D3D11_TEXTURE2D_DESC description{};
    description.Width = createInfo->width;
    description.Height = createInfo->height;
    description.MipLevels = createInfo->mipCount;
    description.ArraySize = createInfo->arraySize;
    // A sampled depth texture needs a typeless resource so that both depth
    // and shader-resource views can be created over it.
    description.Format = sampledDepth
        ? format->sampledDepthFormat : static_cast<DXGI_FORMAT>(createInfo->format);
    description.SampleDesc.Count = createInfo->sampleCount;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = bindFlagsForUsage(createInfo->usageFlags);
    if (!format->depth) {
        // Any color swapchain may be drawn by the runtime compositor.
        description.BindFlags |= D3D11_BIND_SHADER_RESOURCE;
    }
    // A simple direct swapchain image is exported. A texture array cannot be
    // IOSurface-backed, so it remains private and receives per-slice export
    // textures below. Composited and depth swapchains are never exported.
    description.MiscFlags = direct && createInfo->arraySize == 1
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
    if (SUCCEEDED(result) && direct && createInfo->arraySize > 1) {
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
    for (auto& image : available->sampleViews) {
        image.fill(nullptr);
    }
    available->imageStates.fill(ImageState::Available);
    available->acquireOrder.fill(0);
    available->acquireCount = 0;
    available->nextAcquireIndex = 0;
    available->width = createInfo->width;
    available->height = createInfo->height;
    available->arraySize = createInfo->arraySize;
    available->format = format;
    available->exported = false;
    available->everReleased = false;
    available->lastReleasedIndex = 0;
    *swapchain = available->handle;
    ReleaseSRWLockExclusive(&gSwapchainLock);

    if (direct && controlActive(session)) {
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
            // A rejected registration disconnects the daemon, after which no
            // frame is delivered, so the flag cannot reference a stale id.
            AcquireSRWLockExclusive(&gSwapchainLock);
            SwapchainRecord* record = findSwapchainLocked(*swapchain);
            if (record != nullptr) {
                record->exported = true;
            }
            ReleaseSRWLockExclusive(&gSwapchainLock);
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
    SampleViews sampleViews{};
    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    textures = record->textures;
    exportTextures = record->exportTextures;
    sampleViews = record->sampleViews;
    const bool exported = record->exported;
    record->textures.fill(nullptr);
    for (auto& image : record->exportTextures) {
        image.fill(nullptr);
    }
    for (auto& image : record->sampleViews) {
        image.fill(nullptr);
    }
    *record = {};
    ReleaseSRWLockExclusive(&gSwapchainLock);
    // The daemon holds IOSurface retains until this ack (or disconnect), so
    // the textures may only be released afterwards.
    if (exported) {
        controlUnregisterSwapchain(swapchain);
    }
    releaseSampleViews(sampleViews);
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
            record->acquireOrder[record->acquireCount++] = candidate;
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
    // Waited images always form a prefix of the acquisition order, so the
    // first still-acquired entry is the oldest image not yet waited.
    for (uint32_t position = 0; position < record->acquireCount; ++position) {
        ImageState& state = record->imageStates[record->acquireOrder[position]];
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
    // The oldest acquired image is the oldest waited one whenever any image
    // has been waited.
    const uint32_t index = record->acquireOrder[0];
    if (record->acquireCount == 0 ||
        record->imageStates[index] != ImageState::Waited) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_CALL_ORDER_INVALID;
    }
    record->imageStates[index] = ImageState::Available;
    for (uint32_t position = 1; position < record->acquireCount; ++position) {
        record->acquireOrder[position - 1] = record->acquireOrder[position];
    }
    --record->acquireCount;
    record->everReleased = true;
    record->lastReleasedIndex = index;
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_SUCCESS;
}

bool getSwapchainSubmitState(
    XrSwapchain swapchain,
    XrSession* session,
    uint32_t* width,
    uint32_t* height,
    uint32_t* arraySize,
    bool* hasReleasedImage,
    uint32_t* lastReleasedIndex) {
    SwapchainLayerState state{};
    if (!getSwapchainLayerState(swapchain, &state)) {
        return false;
    }
    if (session != nullptr) {
        *session = state.session;
    }
    if (width != nullptr) {
        *width = state.width;
    }
    if (height != nullptr) {
        *height = state.height;
    }
    if (arraySize != nullptr) {
        *arraySize = state.arraySize;
    }
    if (hasReleasedImage != nullptr) {
        *hasReleasedImage = state.hasReleasedImage;
    }
    if (lastReleasedIndex != nullptr) {
        *lastReleasedIndex = state.lastReleasedIndex;
    }
    return true;
}

bool getSwapchainLayerState(XrSwapchain swapchain, SwapchainLayerState* state) {
    if (swapchain == XR_NULL_HANDLE || state == nullptr) {
        return false;
    }
    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record != nullptr) {
        state->session = record->session;
        state->width = record->width;
        state->height = record->height;
        state->arraySize = record->arraySize;
        state->hasReleasedImage = record->everReleased;
        state->lastReleasedIndex = record->lastReleasedIndex;
        state->exported = record->exported;
        state->depth = record->format != nullptr && record->format->depth;
    }
    ReleaseSRWLockShared(&gSwapchainLock);
    return record != nullptr;
}

bool retainSwapchainSampleSource(
    XrSwapchain swapchain,
    uint32_t imageIndex,
    uint32_t arraySlice,
    SwapchainSampleSource* source) {
    if (swapchain == XR_NULL_HANDLE || source == nullptr ||
        imageIndex >= kSwapchainImageCount || arraySlice >= kMaxArraySize) {
        return false;
    }
    *source = {};

    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record == nullptr || record->format == nullptr || record->format->depth ||
        arraySlice >= record->arraySize ||
        record->textures[imageIndex] == nullptr) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return false;
    }
    source->arrayView = record->arraySize > 1;
    source->decodeSrgb = record->format->decodeSrgb;
    source->width = record->width;
    source->height = record->height;
    source->view = record->sampleViews[imageIndex][arraySlice];
    if (source->view != nullptr) {
        source->view->AddRef();
        ReleaseSRWLockShared(&gSwapchainLock);
        return true;
    }
    ID3D11Texture2D* texture = record->textures[imageIndex];
    texture->AddRef();
    const DXGI_FORMAT sampleFormat = record->format->sampleFormat;
    ReleaseSRWLockShared(&gSwapchainLock);

    // Create the view outside the lock, then publish it unless another
    // thread won the race. Mip 0 only: applications render the top level.
    D3D11_SHADER_RESOURCE_VIEW_DESC description{};
    description.Format = sampleFormat;
    if (source->arrayView) {
        description.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
        description.Texture2DArray.MostDetailedMip = 0;
        description.Texture2DArray.MipLevels = 1;
        description.Texture2DArray.FirstArraySlice = arraySlice;
        description.Texture2DArray.ArraySize = 1;
    } else {
        description.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
        description.Texture2D.MostDetailedMip = 0;
        description.Texture2D.MipLevels = 1;
    }
    ID3D11Device* device = nullptr;
    texture->GetDevice(&device);
    ID3D11ShaderResourceView* view = nullptr;
    const HRESULT result = device != nullptr
        ? device->CreateShaderResourceView(texture, &description, &view)
        : E_FAIL;
    release(device);
    release(texture);
    if (FAILED(result) || view == nullptr) {
        return false;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* current = findSwapchainLocked(swapchain);
    if (current == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        release(view);
        return false;
    }
    ID3D11ShaderResourceView*& cached = current->sampleViews[imageIndex][arraySlice];
    if (cached == nullptr) {
        cached = view;
        view->AddRef();
    } else {
        release(view);
        view = cached;
        view->AddRef();
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    source->view = view;
    return true;
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
    std::array<SampleViews, kMaxSwapchains> sampleViews{};
    std::array<XrSwapchain, kMaxSwapchains> handles{};
    std::array<bool, kMaxSwapchains> exported{};
    size_t textureSetCount = 0;
    AcquireSRWLockExclusive(&gSwapchainLock);
    for (SwapchainRecord& record : gSwapchains) {
        if (record.session == session) {
            textures[textureSetCount] = record.textures;
            exportTextures[textureSetCount] = record.exportTextures;
            sampleViews[textureSetCount] = record.sampleViews;
            handles[textureSetCount] = record.handle;
            exported[textureSetCount] = record.exported;
            ++textureSetCount;
            record.textures.fill(nullptr);
            for (auto& image : record.exportTextures) {
                image.fill(nullptr);
            }
            for (auto& image : record.sampleViews) {
                image.fill(nullptr);
            }
            record = {};
        }
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    for (size_t index = 0; index < textureSetCount; ++index) {
        // Session teardown has already closed the control connection, making
        // this a no-op there; it matters on other invalidation orderings.
        if (exported[index]) {
            controlUnregisterSwapchain(handles[index]);
        }
        releaseSampleViews(sampleViews[index]);
        releaseTextures(textures[index]);
        releaseExportTextures(exportTextures[index]);
    }
    compositorSessionDestroyed(session);
}

}  // namespace basalt
