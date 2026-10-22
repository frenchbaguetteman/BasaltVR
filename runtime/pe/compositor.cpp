#include "compositor.hpp"

#include <windows.h>

#include <d3d11.h>
// Declarations only; d3dcompiler is loaded at run time, never linked.
#include <d3dcompiler.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "control.hpp"
#include "pose_math.hpp"
#include "runtime.hpp"

namespace {

using basalt::poseCompose;
using basalt::poseInvert;
using basalt::quaternionRotate;

// Three frames of two eyes. xrWaitFrame admits a new frame only while at
// most one is unconsumed, so at most two queued frames can still be read
// when the next one is drawn; the third ring slot is therefore always free.
// The slot's previous frame is still waited on (normally a no-op) so a
// broken budget can never overwrite an image the daemon may be reading.
constexpr uint32_t kOutputFrames = 3;
constexpr uint32_t kOutputImageCount = kOutputFrames * 2;
// Output swapchain ids live outside the application handle range (which
// counts up from 0x30000 in 0x10 steps); each session takes a new one.
constexpr uint64_t kOutputSwapchainIdBase = 0xb5a1'0c00'0000'0000ULL;
constexpr DXGI_FORMAT kOutputFormat = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
constexpr ULONGLONG kDiagnosticIntervalMs = 2000;
constexpr float kNearPlaneMeters = 0.01f;
constexpr float kFarPlaneMeters = 1000.0f;

// One draw: a textured quad given by four clip-space corners (top-left,
// top-right, bottom-left, bottom-right) and the source rect's corner UVs.
// A negative imageRect extent swaps the UVs and so flips the image.
constexpr char kShaderSource[] = R"(
cbuffer DrawConstants : register(b0) {
    float4 corners[4];
    float4 uvRect;
    float4 uvClamp;
    float4 options;
};

#ifdef SOURCE_ARRAY
Texture2DArray<float4> sourceImage : register(t0);
#else
Texture2D<float4> sourceImage : register(t0);
#endif
SamplerState linearClamp : register(s0);

struct Interpolants {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

Interpolants vsMain(uint vertexId : SV_VertexID) {
    Interpolants result;
    float2 corner = float2(vertexId & 1, vertexId >> 1);
    result.position = corners[vertexId];
    result.uv = lerp(uvRect.xy, uvRect.zw, corner);
    return result;
}

float3 srgbToLinear(float3 encoded) {
    float3 low = encoded / 12.92;
    float3 high = pow((encoded + 0.055) / 1.055, 2.4);
    return lerp(high, low, step(encoded, 0.04045));
}

float4 psMain(Interpolants input) : SV_Target {
    float2 uv = clamp(input.uv, uvClamp.xy, uvClamp.zw);
#ifdef SOURCE_ARRAY
    float4 color = sourceImage.SampleLevel(linearClamp, float3(uv, 0.0), 0.0);
#else
    float4 color = sourceImage.SampleLevel(linearClamp, uv, 0.0);
#endif
    if (options.x > 0.5) {
        color.rgb = srgbToLinear(saturate(color.rgb));
    }
    if (options.y > 0.5) {
        color.rgb *= color.a;
    }
    if (options.z > 0.5) {
        color.a = 1.0;
    }
    return color;
}
)";

struct DrawConstants {
    float corners[4][4];
    float uvRect[4];
    float uvClamp[4];
    // x: decode sRGB-encoded UNORM bytes, y: premultiply unpremultiplied
    // color, z: opaque layer (alpha forced to one).
    float options[4];
};
static_assert(sizeof(DrawConstants) % 16 == 0);

using D3DCompileProc = HRESULT(WINAPI*)(
    LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO*, ID3DInclude*,
    LPCSTR, LPCSTR, UINT, UINT, ID3DBlob**, ID3DBlob**);

// Bytecode is compiled once per process through the d3dcompiler that Wine
// ships (vkd3d-shader); the build machine has no offline HLSL compiler. The
// blobs, and so the compiler DLL implementing them, live for the process.
struct ShaderBytecode {
    ID3DBlob* vertex = nullptr;
    ID3DBlob* pixel = nullptr;
    ID3DBlob* arrayPixel = nullptr;
};

INIT_ONCE gShaderInit = INIT_ONCE_STATIC_INIT;
ShaderBytecode gShaders{};
bool gShadersValid = false;

struct CompositorState {
    XrSession session = XR_NULL_HANDLE;
    // Set when setup failed for this session; the compositor then stays off
    // instead of retrying (and logging) every frame.
    bool failed = false;
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    ID3D11VertexShader* vertexShader = nullptr;
    ID3D11PixelShader* pixelShader = nullptr;
    ID3D11PixelShader* arrayPixelShader = nullptr;
    ID3D11Buffer* constants = nullptr;
    ID3D11SamplerState* sampler = nullptr;
    ID3D11BlendState* alphaBlend = nullptr;
    ID3D11RasterizerState* rasterizer = nullptr;
    ID3D11DepthStencilState* depthDisabled = nullptr;
    std::array<ID3D11Texture2D*, kOutputImageCount> outputs{};
    std::array<ID3D11RenderTargetView*, kOutputImageCount> outputViews{};
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t swapchainId = 0;
    bool registered = false;
    uint32_t nextSlot = 0;
    std::array<uint64_t, kOutputFrames> slotFrames{};
    // Diagnostics, logged every kDiagnosticIntervalMs: frame and failure
    // counts, the layer shapes, and one centre texel of the first eye's
    // source and output, read back one interval later so it never stalls.
    ULONGLONG nextDiagnosticTick = 0;
    uint64_t composited = 0;
    uint64_t sourceFailures = 0;
    ID3D11Texture2D* sourceProbe = nullptr;
    ID3D11Texture2D* outputProbe = nullptr;
    uint32_t sourceProbeTexelBytes = 0;
    uint64_t probeFrame = 0;
};

SRWLOCK gCompositorLock = SRWLOCK_INIT;
CompositorState gState{};
uint64_t gNextOutputGeneration = 1;

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

bool compileShader(
    D3DCompileProc compile,
    const char* entryPoint,
    const char* const* profiles,
    const D3D_SHADER_MACRO* defines,
    ID3DBlob** bytecode) {
    for (const char* const* profile = profiles; *profile != nullptr; ++profile) {
        ID3DBlob* code = nullptr;
        ID3DBlob* errors = nullptr;
        const HRESULT result = compile(
            kShaderSource, sizeof(kShaderSource) - 1, "basalt_compositor.hlsl",
            defines, nullptr, entryPoint, *profile, 0, 0, &code, &errors);
        if (SUCCEEDED(result) && code != nullptr) {
            *bytecode = code;
            release(errors);
            return true;
        }
        if (errors != nullptr) {
            basalt::runtimeLog("compositor %s/%s: %.*s",
                         entryPoint, *profile,
                         static_cast<int>(errors->GetBufferSize()),
                         static_cast<const char*>(errors->GetBufferPointer()));
        }
        release(code);
        release(errors);
    }
    return false;
}

BOOL CALLBACK initializeShaders(PINIT_ONCE, PVOID, PVOID*) {
    HMODULE compiler = LoadLibraryW(L"d3dcompiler_47.dll");
    if (compiler == nullptr) {
        compiler = LoadLibraryW(L"d3dcompiler_43.dll");
    }
    if (compiler == nullptr) {
        basalt::runtimeLog("compositor has no d3dcompiler DLL");
        return TRUE;
    }
    D3DCompileProc compile = nullptr;
    FARPROC address = GetProcAddress(compiler, "D3DCompile");
    static_assert(sizeof(compile) == sizeof(address));
    std::memcpy(&compile, &address, sizeof(address));
    if (compile != nullptr) {
        static constexpr const char* kVertexProfiles[] = {"vs_5_0", "vs_4_0", nullptr};
        static constexpr const char* kPixelProfiles[] = {"ps_5_0", "ps_4_0", nullptr};
        static constexpr D3D_SHADER_MACRO kArrayDefines[] = {
            {"SOURCE_ARRAY", "1"}, {nullptr, nullptr}};
        gShadersValid =
            compileShader(compile, "vsMain", kVertexProfiles, nullptr, &gShaders.vertex) &&
            compileShader(compile, "psMain", kPixelProfiles, nullptr, &gShaders.pixel) &&
            compileShader(
                compile, "psMain", kPixelProfiles, kArrayDefines, &gShaders.arrayPixel);
    }
    if (!gShadersValid) {
        release(gShaders.vertex);
        release(gShaders.pixel);
        release(gShaders.arrayPixel);
        FreeLibrary(compiler);
    }
    return TRUE;
}

void releaseStateLocked(CompositorState* state) {
    release(state->sourceProbe);
    release(state->outputProbe);
    for (ID3D11RenderTargetView*& view : state->outputViews) {
        release(view);
    }
    for (ID3D11Texture2D*& texture : state->outputs) {
        release(texture);
    }
    release(state->depthDisabled);
    release(state->rasterizer);
    release(state->alphaBlend);
    release(state->sampler);
    release(state->constants);
    release(state->arrayPixelShader);
    release(state->pixelShader);
    release(state->vertexShader);
    release(state->context);
    release(state->device);
    *state = {};
}

bool createPipelineLocked(CompositorState* state) {
    ID3D11Device* device = state->device;
    if (FAILED(device->CreateVertexShader(
            gShaders.vertex->GetBufferPointer(), gShaders.vertex->GetBufferSize(), nullptr,
            &state->vertexShader)) ||
        FAILED(device->CreatePixelShader(
            gShaders.pixel->GetBufferPointer(), gShaders.pixel->GetBufferSize(), nullptr,
            &state->pixelShader)) ||
        FAILED(device->CreatePixelShader(
            gShaders.arrayPixel->GetBufferPointer(), gShaders.arrayPixel->GetBufferSize(), nullptr,
            &state->arrayPixelShader))) {
        return false;
    }

    D3D11_BUFFER_DESC constantsDescription{};
    constantsDescription.ByteWidth = sizeof(DrawConstants);
    constantsDescription.Usage = D3D11_USAGE_DYNAMIC;
    constantsDescription.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    constantsDescription.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(device->CreateBuffer(&constantsDescription, nullptr, &state->constants))) {
        return false;
    }

    D3D11_SAMPLER_DESC samplerDescription{};
    samplerDescription.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    samplerDescription.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDescription.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDescription.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDescription.MaxAnisotropy = 1;
    samplerDescription.ComparisonFunc = D3D11_COMPARISON_NEVER;
    samplerDescription.MaxLOD = D3D11_FLOAT32_MAX;
    if (FAILED(device->CreateSamplerState(&samplerDescription, &state->sampler))) {
        return false;
    }

    // Premultiplied "over"; unpremultiplied sources are premultiplied in the
    // shader. Destination alpha stays at the cleared 1.
    D3D11_BLEND_DESC blendDescription{};
    D3D11_RENDER_TARGET_BLEND_DESC& target = blendDescription.RenderTarget[0];
    target.BlendEnable = TRUE;
    target.SrcBlend = D3D11_BLEND_ONE;
    target.DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    target.BlendOp = D3D11_BLEND_OP_ADD;
    target.SrcBlendAlpha = D3D11_BLEND_ZERO;
    target.DestBlendAlpha = D3D11_BLEND_ONE;
    target.BlendOpAlpha = D3D11_BLEND_OP_ADD;
    target.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(device->CreateBlendState(&blendDescription, &state->alphaBlend))) {
        return false;
    }

    // Quads are visible from both sides; depth clipping discards geometry
    // behind the eye.
    D3D11_RASTERIZER_DESC rasterizerDescription{};
    rasterizerDescription.FillMode = D3D11_FILL_SOLID;
    rasterizerDescription.CullMode = D3D11_CULL_NONE;
    rasterizerDescription.DepthClipEnable = TRUE;
    if (FAILED(device->CreateRasterizerState(
            &rasterizerDescription, &state->rasterizer))) {
        return false;
    }

    D3D11_DEPTH_STENCIL_DESC depthDescription{};
    depthDescription.DepthEnable = FALSE;
    depthDescription.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    depthDescription.DepthFunc = D3D11_COMPARISON_ALWAYS;
    depthDescription.StencilEnable = FALSE;
    return SUCCEEDED(device->CreateDepthStencilState(
        &depthDescription, &state->depthDisabled));
}

// Output images use the sRGB format so the hardware encodes the linear
// shader result back into the display-encoded bytes the streamer expects.
bool createOutputsLocked(CompositorState* state, std::array<uint32_t, kOutputImageCount>* ids) {
    D3D11_TEXTURE2D_DESC description{};
    description.Width = state->width;
    description.Height = state->height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = kOutputFormat;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
    D3D11_RENDER_TARGET_VIEW_DESC viewDescription{};
    viewDescription.Format = kOutputFormat;
    viewDescription.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
    for (uint32_t index = 0; index < kOutputImageCount; ++index) {
        if (FAILED(state->device->CreateTexture2D(
                &description, nullptr, &state->outputs[index])) ||
            FAILED(state->device->CreateRenderTargetView(
                state->outputs[index], &viewDescription,
                &state->outputViews[index]))) {
            return false;
        }
        (*ids)[index] = basalt::queryTextureIOSurfaceId(state->outputs[index]);
        if ((*ids)[index] == 0) {
            return false;
        }
    }
    return true;
}

// Prepares the session's pipeline and registered output swapchain once.
bool ensureStateLocked(XrSession session) {
    if (gState.session == session) {
        return !gState.failed;
    }
    releaseStateLocked(&gState);
    gState.session = session;
    gState.failed = true;

    InitOnceExecuteOnce(&gShaderInit, initializeShaders, nullptr, nullptr);
    if (!gShadersValid) {
        basalt::runtimeLog("compositor shaders unavailable");
        return false;
    }
    gState.device = basalt::retainSessionDevice(session);
    if (gState.device == nullptr) {
        return false;
    }
    gState.device->GetImmediateContext(&gState.context);
    gState.width = basalt::kMaxViewWidth;
    gState.height = basalt::kMaxViewHeight;
    basalt::controlConfiguredViewSize(&gState.width, &gState.height);

    std::array<uint32_t, kOutputImageCount> iosurfaceIds{};
    if (!createPipelineLocked(&gState) ||
        !createOutputsLocked(&gState, &iosurfaceIds)) {
        basalt::runtimeLog("compositor resource setup failed");
        return false;
    }
    gState.swapchainId = kOutputSwapchainIdBase + gNextOutputGeneration++;
    basalt::controlRegisterSwapchain(
        reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(gState.swapchainId)),
        gState.width, gState.height, kOutputFormat,
        iosurfaceIds.data(), kOutputImageCount);
    // A rejected registration disconnects the daemon.
    gState.registered = basalt::controlActive(session);
    if (!gState.registered) {
        return false;
    }
    gState.failed = false;
    basalt::runtimeLog("compositor active (%ux%u, %u output images)",
                       gState.width, gState.height, kOutputImageCount);
    return true;
}

XrVector3f transformPoint(const XrPosef& pose, const XrVector3f& point) {
    const XrVector3f rotated = quaternionRotate(pose.orientation, point);
    return {pose.position.x + rotated.x,
            pose.position.y + rotated.y,
            pose.position.z + rotated.z};
}

// OpenXR view space looks down -Z with +Y up. The asymmetric frustum maps
// the FOV edges to clip-space ±w and depth into D3D's [0, w] range.
void projectToClip(const XrFovf& fov, const XrVector3f& point, float clip[4]) {
    const float tanLeft = std::tan(fov.angleLeft);
    const float tanRight = std::tan(fov.angleRight);
    const float tanUp = std::tan(fov.angleUp);
    const float tanDown = std::tan(fov.angleDown);
    const float depthScale = kFarPlaneMeters / (kFarPlaneMeters - kNearPlaneMeters);
    clip[0] = (2.0f * point.x + (tanRight + tanLeft) * point.z) / (tanRight - tanLeft);
    clip[1] = (2.0f * point.y + (tanUp + tanDown) * point.z) / (tanUp - tanDown);
    clip[2] = -point.z * depthScale - kNearPlaneMeters * depthScale;
    clip[3] = -point.z;
}

void setSourceRect(
    const XrRect2Di& rect,
    uint32_t width,
    uint32_t height,
    DrawConstants* constants) {
    const float u0 = static_cast<float>(rect.offset.x) / static_cast<float>(width);
    const float v0 = static_cast<float>(rect.offset.y) / static_cast<float>(height);
    const float u1 = static_cast<float>(
        static_cast<int64_t>(rect.offset.x) + rect.extent.width) / static_cast<float>(width);
    const float v1 = static_cast<float>(
        static_cast<int64_t>(rect.offset.y) + rect.extent.height) / static_cast<float>(height);
    constants->uvRect[0] = u0;
    constants->uvRect[1] = v0;
    constants->uvRect[2] = u1;
    constants->uvRect[3] = v1;
    // Keep bilinear taps inside the rect so a neighbouring eye or atlas
    // entry cannot bleed in at the edge.
    const float halfTexelU = 0.5f / static_cast<float>(width);
    const float halfTexelV = 0.5f / static_cast<float>(height);
    float minU = (u0 < u1 ? u0 : u1) + halfTexelU;
    float maxU = (u0 < u1 ? u1 : u0) - halfTexelU;
    float minV = (v0 < v1 ? v0 : v1) + halfTexelV;
    float maxV = (v0 < v1 ? v1 : v0) - halfTexelV;
    if (minU > maxU) {
        minU = maxU = (u0 + u1) * 0.5f;
    }
    if (minV > maxV) {
        minV = maxV = (v0 + v1) * 0.5f;
    }
    constants->uvClamp[0] = minU;
    constants->uvClamp[1] = minV;
    constants->uvClamp[2] = maxU;
    constants->uvClamp[3] = maxV;
}

// One resolved draw for one eye.
struct EyeDraw {
    basalt::SwapchainSampleSource source{};
    DrawConstants constants{};
    bool blend = false;
    // For diagnostics only.
    uint32_t arraySlice = 0;
    XrRect2Di rect{};
};

uint32_t texelBytes(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R16G16B16A16_TYPELESS:
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
    case DXGI_FORMAT_R16G16B16A16_UNORM:
        return 8;
    default:
        return 4;
    }
}

// Copies the mip-0 texel at the centre of `rect` into a new 1x1 staging
// texture; the caller maps it later. Returns null if it cannot.
ID3D11Texture2D* probeTexel(
    ID3D11DeviceContext* context,
    ID3D11Resource* resource,
    uint32_t arraySlice,
    const XrRect2Di& rect,
    uint32_t* bytes) {
    ID3D11Texture2D* texture = nullptr;
    if (resource == nullptr ||
        FAILED(resource->QueryInterface(__uuidof(ID3D11Texture2D),
                                        reinterpret_cast<void**>(&texture)))) {
        return nullptr;
    }
    D3D11_TEXTURE2D_DESC description{};
    texture->GetDesc(&description);
    const int64_t centerX = static_cast<int64_t>(rect.offset.x) + rect.extent.width / 2;
    const int64_t centerY = static_cast<int64_t>(rect.offset.y) + rect.extent.height / 2;
    const UINT x = static_cast<UINT>(
        centerX < 0 ? 0 : (centerX >= description.Width ? description.Width - 1 : centerX));
    const UINT y = static_cast<UINT>(
        centerY < 0 ? 0 : (centerY >= description.Height ? description.Height - 1 : centerY));
    D3D11_TEXTURE2D_DESC stagingDescription{};
    stagingDescription.Width = 1;
    stagingDescription.Height = 1;
    stagingDescription.MipLevels = 1;
    stagingDescription.ArraySize = 1;
    stagingDescription.Format = description.Format;
    stagingDescription.SampleDesc.Count = 1;
    stagingDescription.Usage = D3D11_USAGE_STAGING;
    stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device* device = nullptr;
    texture->GetDevice(&device);
    ID3D11Texture2D* probe = nullptr;
    if (device == nullptr ||
        FAILED(device->CreateTexture2D(&stagingDescription, nullptr, &probe))) {
        release(device);
        release(texture);
        return nullptr;
    }
    release(device);
    const D3D11_BOX box{x, y, 0, x + 1, y + 1, 1};
    context->CopySubresourceRegion(
        probe, 0, 0, 0, 0, texture,
        D3D11CalcSubresource(0, arraySlice, description.MipLevels), &box);
    release(texture);
    *bytes = texelBytes(description.Format);
    return probe;
}

// Formats a probe's bytes as hex (memory order) without waiting on the GPU.
void describeProbe(
    ID3D11DeviceContext* context, ID3D11Texture2D* probe, uint32_t bytes,
    char* text, size_t size) {
    D3D11_MAPPED_SUBRESOURCE mapped{};
    const HRESULT result = probe == nullptr
        ? E_POINTER
        : context->Map(probe, 0, D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
    if (FAILED(result)) {
        std::snprintf(text, size, "unavailable (0x%08lx)", static_cast<unsigned long>(result));
        return;
    }
    const auto* data = static_cast<const uint8_t*>(mapped.pData);
    size_t used = 0;
    for (uint32_t index = 0; index < bytes && used + 3 < size; ++index) {
        used += static_cast<size_t>(std::snprintf(
            text + used, size - used, "%s%02x", index == 0 ? "" : " ", data[index]));
    }
    context->Unmap(probe, 0);
}

// Appends "kind fmt WxH image/slice rect (x,y wxh)" for one resolved draw.
void describeDraw(const char* kind, const EyeDraw& draw, char* text, size_t size) {
    const size_t used = std::strlen(text);
    if (used + 1 >= size) {
        return;
    }
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    DXGI_FORMAT viewFormat = DXGI_FORMAT_UNKNOWN;
    if (draw.source.view != nullptr) {
        D3D11_SHADER_RESOURCE_VIEW_DESC viewDescription{};
        draw.source.view->GetDesc(&viewDescription);
        viewFormat = viewDescription.Format;
        ID3D11Resource* resource = nullptr;
        draw.source.view->GetResource(&resource);
        ID3D11Texture2D* texture = nullptr;
        if (resource != nullptr &&
            SUCCEEDED(resource->QueryInterface(__uuidof(ID3D11Texture2D),
                                               reinterpret_cast<void**>(&texture)))) {
            D3D11_TEXTURE2D_DESC description{};
            texture->GetDesc(&description);
            format = description.Format;
        }
        release(texture);
        release(resource);
    }
    std::snprintf(text + used, size - used,
                  " %s[fmt %d view %d %ux%u slice %u rect %d,%d %dx%d%s%s]", kind,
                  static_cast<int>(format), static_cast<int>(viewFormat),
                  draw.source.width, draw.source.height, draw.arraySlice,
                  draw.rect.offset.x, draw.rect.offset.y, draw.rect.extent.width,
                  draw.rect.extent.height, draw.source.decodeSrgb ? " srgb-decode" : "",
                  draw.blend ? " blend" : "");
}

// The D3D11 pipeline state the compositor overwrites on the game's context.
// DXMT does not implement SwapDeviceContextState, so this is saved and
// restored explicitly. DXMT has no class linkage, so shaders are restored
// without class instances.
struct SavedContextState {
    ID3D11InputLayout* inputLayout = nullptr;
    D3D11_PRIMITIVE_TOPOLOGY topology = D3D11_PRIMITIVE_TOPOLOGY_UNDEFINED;
    ID3D11VertexShader* vertexShader = nullptr;
    ID3D11HullShader* hullShader = nullptr;
    ID3D11DomainShader* domainShader = nullptr;
    ID3D11GeometryShader* geometryShader = nullptr;
    ID3D11PixelShader* pixelShader = nullptr;
    ID3D11Buffer* vertexConstants = nullptr;
    ID3D11Buffer* pixelConstants = nullptr;
    ID3D11ShaderResourceView* pixelResource = nullptr;
    ID3D11SamplerState* pixelSampler = nullptr;
    ID3D11RasterizerState* rasterizer = nullptr;
    UINT viewportCount = 0;
    D3D11_VIEWPORT viewports[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE]{};
    UINT scissorCount = 0;
    D3D11_RECT scissors[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE]{};
    ID3D11BlendState* blend = nullptr;
    FLOAT blendFactor[4]{};
    UINT sampleMask = 0;
    ID3D11DepthStencilState* depthStencil = nullptr;
    UINT stencilRef = 0;
    ID3D11RenderTargetView* renderTargets[D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT]{};
    ID3D11DepthStencilView* depthStencilView = nullptr;
    // DXMT's OMSetRenderTargets unbinds every output-merger UAV.
    ID3D11UnorderedAccessView* unorderedAccess[D3D11_PS_CS_UAV_REGISTER_COUNT]{};
};

void saveContextState(ID3D11DeviceContext* context, SavedContextState* saved) {
    context->IAGetInputLayout(&saved->inputLayout);
    context->IAGetPrimitiveTopology(&saved->topology);
    context->VSGetShader(&saved->vertexShader, nullptr, nullptr);
    context->HSGetShader(&saved->hullShader, nullptr, nullptr);
    context->DSGetShader(&saved->domainShader, nullptr, nullptr);
    context->GSGetShader(&saved->geometryShader, nullptr, nullptr);
    context->PSGetShader(&saved->pixelShader, nullptr, nullptr);
    context->VSGetConstantBuffers(0, 1, &saved->vertexConstants);
    context->PSGetConstantBuffers(0, 1, &saved->pixelConstants);
    context->PSGetShaderResources(0, 1, &saved->pixelResource);
    context->PSGetSamplers(0, 1, &saved->pixelSampler);
    context->RSGetState(&saved->rasterizer);
    saved->viewportCount = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    context->RSGetViewports(&saved->viewportCount, saved->viewports);
    saved->scissorCount = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    context->RSGetScissorRects(&saved->scissorCount, saved->scissors);
    context->OMGetBlendState(&saved->blend, saved->blendFactor, &saved->sampleMask);
    context->OMGetDepthStencilState(&saved->depthStencil, &saved->stencilRef);
    context->OMGetRenderTargetsAndUnorderedAccessViews(
        D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT, saved->renderTargets,
        &saved->depthStencilView, 0, D3D11_PS_CS_UAV_REGISTER_COUNT,
        saved->unorderedAccess);
}

// Restores and releases everything saveContextState captured. Shader inputs
// are rebound before the render targets, so the game's own bindings come
// back exactly as they were.
void restoreContextState(ID3D11DeviceContext* context, SavedContextState* saved) {
    context->IASetInputLayout(saved->inputLayout);
    context->IASetPrimitiveTopology(saved->topology);
    context->VSSetShader(saved->vertexShader, nullptr, 0);
    context->HSSetShader(saved->hullShader, nullptr, 0);
    context->DSSetShader(saved->domainShader, nullptr, 0);
    context->GSSetShader(saved->geometryShader, nullptr, 0);
    context->PSSetShader(saved->pixelShader, nullptr, 0);
    context->VSSetConstantBuffers(0, 1, &saved->vertexConstants);
    context->PSSetConstantBuffers(0, 1, &saved->pixelConstants);
    context->PSSetShaderResources(0, 1, &saved->pixelResource);
    context->PSSetSamplers(0, 1, &saved->pixelSampler);
    context->RSSetState(saved->rasterizer);
    context->RSSetViewports(saved->viewportCount, saved->viewports);
    context->RSSetScissorRects(saved->scissorCount, saved->scissors);
    context->OMSetBlendState(saved->blend, saved->blendFactor, saved->sampleMask);
    context->OMSetDepthStencilState(saved->depthStencil, saved->stencilRef);

    UINT renderTargetCount = 0;
    for (UINT slot = 0; slot < D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT; ++slot) {
        if (saved->renderTargets[slot] != nullptr) {
            renderTargetCount = slot + 1;
        }
    }
    UINT firstAccess = D3D11_PS_CS_UAV_REGISTER_COUNT;
    UINT accessEnd = 0;
    for (UINT slot = 0; slot < D3D11_PS_CS_UAV_REGISTER_COUNT; ++slot) {
        if (saved->unorderedAccess[slot] != nullptr) {
            firstAccess = firstAccess < slot ? firstAccess : slot;
            accessEnd = slot + 1;
        }
    }
    if (accessEnd == 0) {
        context->OMSetRenderTargets(
            renderTargetCount, saved->renderTargets, saved->depthStencilView);
    } else {
        // UINT(-1) keeps each append/consume counter at its current value.
        UINT initialCounts[D3D11_PS_CS_UAV_REGISTER_COUNT];
        for (UINT& count : initialCounts) {
            count = UINT32_MAX;
        }
        context->OMSetRenderTargetsAndUnorderedAccessViews(
            renderTargetCount, saved->renderTargets, saved->depthStencilView,
            firstAccess, accessEnd - firstAccess,
            saved->unorderedAccess + firstAccess, initialCounts);
    }

    release(saved->inputLayout);
    release(saved->vertexShader);
    release(saved->hullShader);
    release(saved->domainShader);
    release(saved->geometryShader);
    release(saved->pixelShader);
    release(saved->vertexConstants);
    release(saved->pixelConstants);
    release(saved->pixelResource);
    release(saved->pixelSampler);
    release(saved->rasterizer);
    release(saved->blend);
    release(saved->depthStencil);
    for (ID3D11RenderTargetView*& view : saved->renderTargets) {
        release(view);
    }
    release(saved->depthStencilView);
    for (ID3D11UnorderedAccessView*& view : saved->unorderedAccess) {
        release(view);
    }
}

void setOptions(
    const basalt::SwapchainSampleSource& source,
    XrCompositionLayerFlags layerFlags,
    DrawConstants* constants,
    bool* blend) {
    const bool sourceAlpha =
        (layerFlags & XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT) != 0;
    constants->options[0] = source.decodeSrgb ? 1.0f : 0.0f;
    constants->options[1] = sourceAlpha &&
        (layerFlags & XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT) != 0
        ? 1.0f : 0.0f;
    constants->options[2] = sourceAlpha ? 0.0f : 1.0f;
    *blend = sourceAlpha;
}

}  // namespace

namespace basalt {

bool compositorSubmitFrame(
    XrSession session,
    XrTime displayTime,
    uint64_t questTrackingTimestampNanoseconds,
    const CompositionFrame& frame) {
    if (frame.layerCount == 0 || !controlActive(session)) {
        return false;
    }

    AcquireSRWLockExclusive(&gCompositorLock);
    if (!ensureStateLocked(session)) {
        ReleaseSRWLockExclusive(&gCompositorLock);
        return false;
    }

    // Eye poses come from the displayed projection layer. A quad-only frame
    // (loading screens, OpenComposite's skybox) uses the views located at
    // the frame's display time in the first quad's space.
    const CompositionLayer* projection = nullptr;
    for (uint32_t index = 0; index < frame.layerCount; ++index) {
        if (frame.layers[index].kind == CompositionLayerKind::kProjection) {
            projection = &frame.layers[index];
            break;
        }
    }
    XrSpace eyeSpace = XR_NULL_HANDLE;
    XrPosef eyePoses[2]{};
    XrFovf eyeFovs[2]{};
    uint64_t trackingTimestamp = questTrackingTimestampNanoseconds;
    if (projection != nullptr) {
        eyeSpace = projection->space;
        for (uint32_t eye = 0; eye < 2; ++eye) {
            eyePoses[eye] = projection->poses[eye];
            eyeFovs[eye] = projection->fovs[eye];
        }
    } else {
        eyeSpace = frame.layers[0].space;
        XrViewLocateInfo locateInfo{};
        locateInfo.type = XR_TYPE_VIEW_LOCATE_INFO;
        locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        locateInfo.displayTime = displayTime;
        locateInfo.space = eyeSpace;
        XrViewState viewState{};
        viewState.type = XR_TYPE_VIEW_STATE;
        XrView views[2]{};
        views[0].type = XR_TYPE_VIEW;
        views[1].type = XR_TYPE_VIEW;
        uint32_t viewCount = 0;
        if (XR_FAILED(locateViews(
                session, &locateInfo, &viewState, 2, &viewCount, views))) {
            ReleaseSRWLockExclusive(&gCompositorLock);
            return false;
        }
        for (uint32_t eye = 0; eye < 2; ++eye) {
            eyePoses[eye] = views[eye].pose;
            eyeFovs[eye] = views[eye].fov;
        }
        trackingTimestamp = locatedViewsQuestTimestamp(session, displayTime);
    }

    // Resolve every draw before touching the context: locating spaces takes
    // runtime locks, and sources may have been destroyed by another thread.
    std::array<std::array<EyeDraw, XR_MIN_COMPOSITION_LAYERS_SUPPORTED>, 2> draws{};
    std::array<uint32_t, 2> drawCounts{};
    for (uint32_t index = 0; index < frame.layerCount; ++index) {
        const CompositionLayer& layer = frame.layers[index];
        if (layer.kind == CompositionLayerKind::kProjection) {
            if (&layer != projection) {
                continue;
            }
            for (uint32_t eye = 0; eye < 2; ++eye) {
                const CompositionSubImage& subImage = layer.subImages[eye];
                EyeDraw& draw = draws[eye][drawCounts[eye]];
                if (!retainSwapchainSampleSource(
                        subImage.swapchain, subImage.imageIndex,
                        subImage.imageArrayIndex, &draw.source)) {
                    ++gState.sourceFailures;
                    continue;
                }
                draw.arraySlice = subImage.imageArrayIndex;
                draw.rect = subImage.rect;
                // The projection view keeps its pose and FOV in FrameReady,
                // so it fills the whole output image.
                const float fullscreen[4][4] = {
                    {-1.0f, 1.0f, 0.0f, 1.0f}, {1.0f, 1.0f, 0.0f, 1.0f},
                    {-1.0f, -1.0f, 0.0f, 1.0f}, {1.0f, -1.0f, 0.0f, 1.0f},
                };
                std::memcpy(draw.constants.corners, fullscreen, sizeof(fullscreen));
                setSourceRect(subImage.rect, draw.source.width, draw.source.height,
                              &draw.constants);
                setOptions(draw.source, layer.layerFlags, &draw.constants, &draw.blend);
                ++drawCounts[eye];
            }
            continue;
        }

        XrPosef quadInEyeSpace = layer.pose;
        if (layer.space != eyeSpace) {
            XrSpaceLocation location{};
            location.type = XR_TYPE_SPACE_LOCATION;
            constexpr XrSpaceLocationFlags kLocated =
                XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
                XR_SPACE_LOCATION_POSITION_VALID_BIT;
            if (XR_FAILED(locateSpace(layer.space, eyeSpace, displayTime, &location)) ||
                (location.locationFlags & kLocated) != kLocated) {
                continue;
            }
            quadInEyeSpace = poseCompose(location.pose, layer.pose);
        }
        const float halfWidth = layer.size.width * 0.5f;
        const float halfHeight = layer.size.height * 0.5f;
        const XrVector3f corners[4] = {
            {-halfWidth, halfHeight, 0.0f}, {halfWidth, halfHeight, 0.0f},
            {-halfWidth, -halfHeight, 0.0f}, {halfWidth, -halfHeight, 0.0f},
        };
        for (uint32_t eye = 0; eye < 2; ++eye) {
            const XrEyeVisibility hiddenFrom =
                eye == 0 ? XR_EYE_VISIBILITY_RIGHT : XR_EYE_VISIBILITY_LEFT;
            if (layer.eyeVisibility == hiddenFrom) {
                continue;
            }
            const CompositionSubImage& subImage = layer.subImages[0];
            EyeDraw& draw = draws[eye][drawCounts[eye]];
            if (!retainSwapchainSampleSource(
                    subImage.swapchain, subImage.imageIndex,
                    subImage.imageArrayIndex, &draw.source)) {
                ++gState.sourceFailures;
                continue;
            }
            draw.arraySlice = subImage.imageArrayIndex;
            draw.rect = subImage.rect;
            const XrPosef eyeFromQuad =
                poseCompose(poseInvert(eyePoses[eye]), quadInEyeSpace);
            for (uint32_t corner = 0; corner < 4; ++corner) {
                projectToClip(eyeFovs[eye], transformPoint(eyeFromQuad, corners[corner]),
                              draw.constants.corners[corner]);
            }
            setSourceRect(subImage.rect, draw.source.width, draw.source.height,
                          &draw.constants);
            setOptions(draw.source, layer.layerFlags, &draw.constants, &draw.blend);
            ++drawCounts[eye];
        }
    }

    // Never redraw an image the daemon may still be reading.
    const uint32_t slot = gState.nextSlot;
    const bool slotFree = controlWaitForFrameConsumed(session, gState.slotFrames[slot]);
    uint64_t frameNumber = 0;
    if (slotFree) {
        ID3D11DeviceContext* context = gState.context;
        SavedContextState saved{};
        saveContextState(context, &saved);

        context->IASetInputLayout(nullptr);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        context->VSSetShader(gState.vertexShader, nullptr, 0);
        context->HSSetShader(nullptr, nullptr, 0);
        context->DSSetShader(nullptr, nullptr, 0);
        context->GSSetShader(nullptr, nullptr, 0);
        context->VSSetConstantBuffers(0, 1, &gState.constants);
        context->PSSetConstantBuffers(0, 1, &gState.constants);
        context->PSSetSamplers(0, 1, &gState.sampler);
        context->RSSetState(gState.rasterizer);
        D3D11_VIEWPORT viewport{};
        viewport.Width = static_cast<float>(gState.width);
        viewport.Height = static_cast<float>(gState.height);
        viewport.MaxDepth = 1.0f;
        context->RSSetViewports(1, &viewport);
        context->OMSetDepthStencilState(gState.depthDisabled, 0);
        const FLOAT blendFactor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
        // Clearing the sRGB view to opaque black writes zero bytes.
        const FLOAT black[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        for (uint32_t eye = 0; eye < 2; ++eye) {
            ID3D11RenderTargetView* target = gState.outputViews[slot * 2 + eye];
            ID3D11ShaderResourceView* noResource = nullptr;
            // Unbind the previous source before the target changes.
            context->PSSetShaderResources(0, 1, &noResource);
            context->OMSetRenderTargets(1, &target, nullptr);
            context->ClearRenderTargetView(target, black);
            for (uint32_t index = 0; index < drawCounts[eye]; ++index) {
                EyeDraw& draw = draws[eye][index];
                D3D11_MAPPED_SUBRESOURCE mapped{};
                if (FAILED(context->Map(
                        gState.constants, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
                    continue;
                }
                std::memcpy(mapped.pData, &draw.constants, sizeof(draw.constants));
                context->Unmap(gState.constants, 0);
                context->PSSetShader(
                    draw.source.arrayView ? gState.arrayPixelShader : gState.pixelShader,
                    nullptr, 0);
                context->PSSetShaderResources(0, 1, &draw.source.view);
                context->OMSetBlendState(
                    draw.blend ? gState.alphaBlend : nullptr, blendFactor, 0xffffffffu);
                context->Draw(4, 0);
            }
        }

        const ULONGLONG now = GetTickCount64();
        if (now >= gState.nextDiagnosticTick) {
            gState.nextDiagnosticTick = now + kDiagnosticIntervalMs;
            // The previous interval's probes have long finished.
            if (gState.probeFrame != 0) {
                char sourceText[64] = "none";
                char outputText[64] = "none";
                if (gState.sourceProbe != nullptr) {
                    describeProbe(context, gState.sourceProbe, gState.sourceProbeTexelBytes,
                                  sourceText, sizeof(sourceText));
                }
                describeProbe(context, gState.outputProbe, 4, outputText, sizeof(outputText));
                basalt::runtimeLog(
                    "compositor frame %llu centre texel: left source [%s], left output BGRA [%s]",
                    static_cast<unsigned long long>(gState.probeFrame), sourceText, outputText);
            }
            release(gState.sourceProbe);
            release(gState.outputProbe);
            char layers[768] = "";
            for (uint32_t index = 0; index < drawCounts[0]; ++index) {
                describeDraw(index == 0 && projection != nullptr ? "projection" : "quad",
                             draws[0][index], layers, sizeof(layers));
            }
            basalt::runtimeLog(
                "compositor frame %llu: %u layer(s), left eye draws%s; %llu frames "
                "composited, %llu unusable sources",
                static_cast<unsigned long long>(gState.composited + 1), frame.layerCount,
                drawCounts[0] == 0 ? " none (black)" : layers,
                static_cast<unsigned long long>(gState.composited),
                static_cast<unsigned long long>(gState.sourceFailures));
            if (drawCounts[0] > 0 && draws[0][0].source.view != nullptr) {
                ID3D11Resource* resource = nullptr;
                draws[0][0].source.view->GetResource(&resource);
                gState.sourceProbe = probeTexel(
                    context, resource, draws[0][0].arraySlice, draws[0][0].rect,
                    &gState.sourceProbeTexelBytes);
                release(resource);
            }
            uint32_t outputBytes = 0;
            const XrRect2Di outputRect{
                {0, 0},
                {static_cast<int32_t>(gState.width), static_cast<int32_t>(gState.height)}};
            gState.outputProbe = probeTexel(
                context, gState.outputs[slot * 2], 0, outputRect, &outputBytes);
            gState.probeFrame = gState.composited + 1;
        }
        restoreContextState(context, &saved);

        ControlFrameView views[2]{};
        for (uint32_t eye = 0; eye < 2; ++eye) {
            views[eye].swapchainId = gState.swapchainId;
            views[eye].imageIndex = slot * 2 + eye;
            views[eye].imageArrayIndex = 0;
            views[eye].rect = {{0, 0},
                               {static_cast<int32_t>(gState.width),
                                static_cast<int32_t>(gState.height)}};
            views[eye].pose = eyePoses[eye];
            views[eye].fov = eyeFovs[eye];
        }
        // FrameReady's fence is signalled after these draws on the same
        // immediate context, so the daemon reads only finished pixels.
        frameNumber = controlFrameReady(displayTime, trackingTimestamp, views, 2, false);
        if (frameNumber != 0) {
            ++gState.composited;
            gState.slotFrames[slot] = frameNumber;
            gState.nextSlot = (slot + 1) % kOutputFrames;
        }
    }
    ReleaseSRWLockExclusive(&gCompositorLock);

    for (auto& eyeDraws : draws) {
        for (EyeDraw& draw : eyeDraws) {
            release(draw.source.view);
        }
    }
    return frameNumber != 0;
}

void compositorSessionDestroyed(XrSession session) {
    AcquireSRWLockExclusive(&gCompositorLock);
    if (gState.session != session) {
        ReleaseSRWLockExclusive(&gCompositorLock);
        return;
    }
    const bool registered = gState.registered;
    const uint64_t swapchainId = gState.swapchainId;
    if (registered) {
        // Session teardown has already closed the control connection, making
        // this a no-op there; the surfaces must outlive any daemon retain.
        controlUnregisterSwapchain(
            reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(swapchainId)));
    }
    releaseStateLocked(&gState);
    ReleaseSRWLockExclusive(&gCompositorLock);
}

}  // namespace basalt
