// 8x MSAA on a Metal device that supports at most 4x (Apple GPUs).
//
// Source 2 (Robot Repair, Half-Life: Alyx) Auto-Fidelity picks 8x MSAA and
// creates its eye render targets without checking support. Stock DXMT v0.80
// returns E_INVALIDARG ("sample count 8 is not supported"), so the game drew
// into nothing and submitted an all-zero eye texture. The Basalt fork
// (patch 0006) creates such textures with the largest supported count, keeps
// the requested count in the D3D11 description, and wraps Texture2DMS sample
// indices into the real count. This probe checks, on an 8x colour + depth
// target: creation and description, clear + ResolveSubresource, a draw with
// depth (pipeline and attachment sample counts agree), and a resolve shader
// built for 8 samples (Texture2DMS<float4, 8>, Load(pos, 0..7)) that must
// average to the drawn colour instead of reading past the last sample.

#include <d3d11.h>
#include <d3dcompiler.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

constexpr UINT kSize = 64;
constexpr UINT kSamples = 8;

[[noreturn]] void fail(const char *what, HRESULT hr = S_OK) {
    std::fprintf(stderr, "FAIL: dxmt_msaa_probe: %s (hr 0x%08lx)\n", what,
                 static_cast<unsigned long>(hr));
    std::exit(1);
}

void check(HRESULT hr, const char *what) {
    if (FAILED(hr)) fail(what, hr);
}

template <typename T> void release(T *&object) {
    if (object) object->Release();
    object = nullptr;
}

ID3DBlob *compile(const char *source, const char *entry, const char *target) {
    ID3DBlob *code = nullptr;
    ID3DBlob *errors = nullptr;
    HRESULT hr = D3DCompile(source, std::strlen(source), nullptr, nullptr, nullptr,
                            entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code,
                            &errors);
    if (FAILED(hr)) {
        if (errors)
            std::fprintf(stderr, "%s\n", static_cast<const char *>(errors->GetBufferPointer()));
        fail("D3DCompile", hr);
    }
    release(errors);
    return code;
}

constexpr char kShaders[] = R"(
struct VsOut { float4 pos : SV_POSITION; };
VsOut vs_main(uint id : SV_VERTEXID) {
    VsOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0.5, 1);
    return o;
}
float4 ps_colour(VsOut i) : SV_TARGET { return float4(1.0, 0.25, 0.0, 1.0); }

Texture2DMS<float4, 8> msaa_source : register(t0);
float4 ps_resolve8(VsOut i) : SV_TARGET {
    float4 sum = 0;
    [unroll] for (int s = 0; s < 8; ++s)
        sum += msaa_source.Load(int2(i.pos.xy), s);
    return sum / 8;
}
)";

// Centre texel of a single-sample RGBA8 texture.
uint32_t readCentre(ID3D11Device *device, ID3D11DeviceContext *context,
                    ID3D11Texture2D *texture) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = 1;
    desc.Height = 1;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *staging = nullptr;
    check(device->CreateTexture2D(&desc, nullptr, &staging), "staging texture");
    D3D11_BOX box{kSize / 2, kSize / 2, 0, kSize / 2 + 1, kSize / 2 + 1, 1};
    context->CopySubresourceRegion(staging, 0, 0, 0, 0, texture, 0, &box);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    check(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped), "map staging");
    uint32_t value = *static_cast<const uint32_t *>(mapped.pData);
    context->Unmap(staging, 0);
    release(staging);
    return value;
}

void expectTexel(const char *label, uint32_t got, const uint8_t (&want)[4]) {
    for (int c = 0; c < 4; ++c) {
        int g = static_cast<int>((got >> (8 * c)) & 0xff);
        if (std::abs(g - want[c]) > 1) {
            std::fprintf(stderr,
                         "FAIL: dxmt_msaa_probe: %s: got %02x %02x %02x %02x, want "
                         "%02x %02x %02x %02x\n",
                         label, got & 0xff, (got >> 8) & 0xff, (got >> 16) & 0xff,
                         got >> 24, want[0], want[1], want[2], want[3]);
            std::exit(1);
        }
    }
    std::printf("PASS: %s (%02x %02x %02x %02x)\n", label, got & 0xff, (got >> 8) & 0xff,
                (got >> 16) & 0xff, got >> 24);
}

} // namespace

int main() {
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1,
                            D3D11_SDK_VERSION, &device, nullptr, &context),
          "D3D11CreateDevice");

    UINT quality8 = 0;
    check(device->CheckMultisampleQualityLevels(DXGI_FORMAT_R8G8B8A8_UNORM, kSamples,
                                                &quality8),
          "CheckMultisampleQualityLevels(8)");
    std::printf("NOTE: CheckMultisampleQualityLevels(RGBA8, 8x) = %u\n", quality8);

    // 1. 8x colour and depth targets are created and keep their description.
    D3D11_TEXTURE2D_DESC colourDesc{};
    colourDesc.Width = kSize;
    colourDesc.Height = kSize;
    colourDesc.MipLevels = 1;
    colourDesc.ArraySize = 1;
    colourDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    colourDesc.SampleDesc.Count = kSamples;
    colourDesc.Usage = D3D11_USAGE_DEFAULT;
    colourDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D *colour = nullptr;
    check(device->CreateTexture2D(&colourDesc, nullptr, &colour), "8x colour texture");
    D3D11_TEXTURE2D_DESC depthDesc = colourDesc;
    depthDesc.Format = DXGI_FORMAT_D32_FLOAT;
    depthDesc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    ID3D11Texture2D *depth = nullptr;
    check(device->CreateTexture2D(&depthDesc, nullptr, &depth), "8x depth texture");
    D3D11_TEXTURE2D_DESC readBack{};
    colour->GetDesc(&readBack);
    if (readBack.SampleDesc.Count != kSamples) fail("GetDesc lost the 8x sample count");
    std::printf("PASS: 8x colour + depth targets created, GetDesc reports %u samples\n",
                readBack.SampleDesc.Count);

    ID3D11RenderTargetView *rtv = nullptr;
    check(device->CreateRenderTargetView(colour, nullptr, &rtv), "8x RTV");
    ID3D11DepthStencilView *dsv = nullptr;
    check(device->CreateDepthStencilView(depth, nullptr, &dsv), "8x DSV");
    ID3D11ShaderResourceView *srv = nullptr;
    check(device->CreateShaderResourceView(colour, nullptr, &srv), "8x SRV");

    D3D11_TEXTURE2D_DESC resolvedDesc = colourDesc;
    resolvedDesc.SampleDesc.Count = 1;
    resolvedDesc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *resolved = nullptr;
    check(device->CreateTexture2D(&resolvedDesc, nullptr, &resolved), "resolve target");
    ID3D11RenderTargetView *resolvedRtv = nullptr;
    check(device->CreateRenderTargetView(resolved, nullptr, &resolvedRtv), "resolve RTV");

    // 2. Clear + hardware resolve.
    const float clear[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    context->ClearRenderTargetView(rtv, clear);
    context->ResolveSubresource(resolved, 0, colour, 0, DXGI_FORMAT_R8G8B8A8_UNORM);
    expectTexel("8x clear + ResolveSubresource", readCentre(device, context, resolved),
                {0x40, 0x80, 0xbf, 0xff});

    // 3. Draw with the 8x depth target bound.
    ID3DBlob *vsCode = compile(kShaders, "vs_main", "vs_5_0");
    ID3DBlob *psColourCode = compile(kShaders, "ps_colour", "ps_5_0");
    ID3DBlob *psResolveCode = compile(kShaders, "ps_resolve8", "ps_5_0");
    ID3D11VertexShader *vs = nullptr;
    ID3D11PixelShader *psColour = nullptr;
    ID3D11PixelShader *psResolve = nullptr;
    check(device->CreateVertexShader(vsCode->GetBufferPointer(), vsCode->GetBufferSize(),
                                     nullptr, &vs),
          "vertex shader");
    check(device->CreatePixelShader(psColourCode->GetBufferPointer(),
                                    psColourCode->GetBufferSize(), nullptr, &psColour),
          "colour pixel shader");
    check(device->CreatePixelShader(psResolveCode->GetBufferPointer(),
                                    psResolveCode->GetBufferSize(), nullptr, &psResolve),
          "8-sample resolve pixel shader");

    D3D11_VIEWPORT viewport{0, 0, kSize, kSize, 0, 1};
    context->RSSetViewports(1, &viewport);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->ClearDepthStencilView(dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
    context->OMSetRenderTargets(1, &rtv, dsv);
    context->VSSetShader(vs, nullptr, 0);
    context->PSSetShader(psColour, nullptr, 0);
    context->Draw(3, 0);
    context->ResolveSubresource(resolved, 0, colour, 0, DXGI_FORMAT_R8G8B8A8_UNORM);
    expectTexel("8x draw with 8x depth + ResolveSubresource",
                readCentre(device, context, resolved), {0xff, 0x40, 0x00, 0xff});

    // 4. A resolve shader written for 8 samples reads only real samples.
    const float black[4] = {0, 0, 0, 0};
    context->OMSetRenderTargets(1, &resolvedRtv, nullptr);
    context->ClearRenderTargetView(resolvedRtv, black);
    context->PSSetShader(psResolve, nullptr, 0);
    context->PSSetShaderResources(0, 1, &srv);
    context->Draw(3, 0);
    ID3D11ShaderResourceView *nullSrv = nullptr;
    context->PSSetShaderResources(0, 1, &nullSrv);
    context->OMSetRenderTargets(0, nullptr, nullptr);
    expectTexel("Texture2DMS<float4, 8> Load(pos, 0..7) average",
                readCentre(device, context, resolved), {0xff, 0x40, 0x00, 0xff});

    release(vsCode);
    release(psColourCode);
    release(psResolveCode);
    release(vs);
    release(psColour);
    release(psResolve);
    release(resolvedRtv);
    release(resolved);
    release(srv);
    release(dsv);
    release(rtv);
    release(depth);
    release(colour);
    release(context);
    release(device);
    std::printf("PASS: dxmt_msaa_probe: 8x MSAA works on a %s-sample device\n",
                quality8 ? "8" : "4");
    return 0;
}
