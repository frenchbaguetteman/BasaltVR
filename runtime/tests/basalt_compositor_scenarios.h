#ifndef BASALT_COMPOSITOR_SCENARIOS_H
#define BASALT_COMPOSITOR_SCENARIOS_H

/*
 * Shared by the Wine-side compositor smoke (d3d11_compositor_smoke.cpp) and
 * the native control test daemon (--compositor-scenarios). The smoke submits
 * exactly one FrameReady-producing frame per scenario, in this order, so the
 * runtime's 1-based FrameReady number selects the scenario the daemon must
 * verify by IOSurface readback. Colors are r,g,b,a memory bytes; composited
 * output is BGRA (DXGI 91), so the daemon compares b,g,r,a.
 */

#include <math.h>
#include <stdint.h>

/* The daemon's control file advertises this per-eye size; it is also the
 * runtime compositor's output size. */
#define BASALT_COMPOSITOR_VIEW_WIDTH 512u
#define BASALT_COMPOSITOR_VIEW_HEIGHT 512u

/* Quest calibration the daemon sends in VIEW_CONFIG (IPD, then per eye
 * left/right/up/down), and the head pose height it injects. */
#define BASALT_TEST_IPD_METERS 0.064f
static const float kBasaltTestEyeFov[2][4] = {
    {-0.85f, 0.75f, 0.80f, -0.78f},
    {-0.75f, 0.85f, 0.80f, -0.78f},
};
#define BASALT_TEST_HEAD_HEIGHT_METERS 1.5f

enum {
    /* f: BGRA swapchains already in the direct shape keep the zero-copy
     * export (the frame references the application's own swapchain). */
    BASALT_SCENARIO_DIRECT = 1,
    /* a: an R8G8B8A8_UNORM_SRGB swapchain arrives with identical bytes. */
    BASALT_SCENARIO_SRGB_RGBA = 2,
    /* b: a 4-mip BGRA swapchain arrives scaled from mip 0 only. */
    BASALT_SCENARIO_MIPMAPPED = 3,
    /* b: an oversized 2016x2240 R8G8B8A8_UNORM swapchain arrives scaled. */
    BASALT_SCENARIO_OVERSIZED = 4,
    /* c: a negative-height rect arrives flipped. */
    BASALT_SCENARIO_FLIPPED = 5,
    /* d: an alpha-blended quad over an opaque projection. */
    BASALT_SCENARIO_QUAD = 6,
    /* A quad-only frame (OpenComposite's skybox shape: flipped, blended). */
    BASALT_SCENARIO_QUAD_ONLY = 7,
    /* e: wait/release follow acquisition order, not image index order. */
    BASALT_SCENARIO_FIFO = 8,
    BASALT_SCENARIO_COUNT = 8,
};

#define BASALT_RGBA(r, g, b, a) \
    ((uint32_t)(r) | ((uint32_t)(g) << 8) | ((uint32_t)(b) << 16) | ((uint32_t)(a) << 24))

static const uint32_t kBasaltDirectColor = BASALT_RGBA(23, 141, 77, 255);
static const uint32_t kBasaltSrgbColor = BASALT_RGBA(201, 87, 33, 255);
/* Quadrant pattern: top-left, top-right, bottom-left, bottom-right. */
static const uint32_t kBasaltQuadrantColors[4] = {
    BASALT_RGBA(200, 30, 30, 255),
    BASALT_RGBA(30, 200, 30, 255),
    BASALT_RGBA(30, 30, 200, 255),
    BASALT_RGBA(220, 220, 40, 255),
};
/* Lower mip levels must never be sampled. */
static const uint32_t kBasaltWrongMipColor = BASALT_RGBA(255, 0, 255, 255);
static const uint32_t kBasaltFlipTopColor = BASALT_RGBA(250, 250, 250, 255);
static const uint32_t kBasaltFlipBottomColor = BASALT_RGBA(10, 60, 110, 255);
static const uint32_t kBasaltProjectionColor = BASALT_RGBA(40, 90, 200, 255);
/* Unpremultiplied source color with roughly half coverage. */
static const uint32_t kBasaltQuadColor = BASALT_RGBA(230, 60, 30, 128);
static const uint32_t kBasaltSkyTopColor = BASALT_RGBA(180, 120, 20, 255);
static const uint32_t kBasaltSkyBottomColor = BASALT_RGBA(20, 160, 180, 255);
/* FIFO: image 2 is the oldest acquisition, image 0 the newest. */
static const uint32_t kBasaltFifoReleasedColor = BASALT_RGBA(17, 220, 140, 255);
static const uint32_t kBasaltFifoHeldColor = BASALT_RGBA(140, 17, 220, 255);
#define BASALT_FIFO_RELEASED_IMAGE 2u

/* The quad layer: LOCAL pose (0, head height, -distance), identity
 * orientation, square size. */
#define BASALT_QUAD_DISTANCE_METERS 1.0f
#define BASALT_QUAD_SIZE_METERS 0.5f

static inline double basaltSrgbToLinear(double encoded) {
    return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4);
}

static inline double basaltLinearToSrgb(double linear) {
    if (linear <= 0.0) {
        return 0.0;
    }
    if (linear >= 1.0) {
        return 1.0;
    }
    return linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}

/* Projects a point in an eye's view space (-Z forward, +Y up) to output
 * pixel coordinates with the runtime's asymmetric-FOV convention. */
static inline void basaltProjectToPixel(
    uint32_t eye, float x, float y, float z, float* pixelX, float* pixelY) {
    const float tanLeft = tanf(kBasaltTestEyeFov[eye][0]);
    const float tanRight = tanf(kBasaltTestEyeFov[eye][1]);
    const float tanUp = tanf(kBasaltTestEyeFov[eye][2]);
    const float tanDown = tanf(kBasaltTestEyeFov[eye][3]);
    const float ndcX = (x / -z - (tanRight + tanLeft) * 0.5f) * 2.0f / (tanRight - tanLeft);
    const float ndcY = (y / -z - (tanUp + tanDown) * 0.5f) * 2.0f / (tanUp - tanDown);
    *pixelX = (ndcX + 1.0f) * 0.5f * (float)BASALT_COMPOSITOR_VIEW_WIDTH;
    *pixelY = (1.0f - ndcY) * 0.5f * (float)BASALT_COMPOSITOR_VIEW_HEIGHT;
}

/* Quad center and corner offsets, in each eye's view space. The injected
 * head has identity orientation at LOCAL (0, head height, 0). */
static inline void basaltQuadCenterPixel(uint32_t eye, float* pixelX, float* pixelY) {
    const float eyeX = eye == 0 ? -BASALT_TEST_IPD_METERS * 0.5f : BASALT_TEST_IPD_METERS * 0.5f;
    basaltProjectToPixel(eye, -eyeX, 0.0f, -BASALT_QUAD_DISTANCE_METERS, pixelX, pixelY);
}

static inline void basaltQuadOffsetPixel(
    uint32_t eye, float offsetX, float offsetY, float* pixelX, float* pixelY) {
    const float eyeX = eye == 0 ? -BASALT_TEST_IPD_METERS * 0.5f : BASALT_TEST_IPD_METERS * 0.5f;
    basaltProjectToPixel(
        eye, -eyeX + offsetX, offsetY, -BASALT_QUAD_DISTANCE_METERS, pixelX, pixelY);
}

#endif
