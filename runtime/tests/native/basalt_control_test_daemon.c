/*
 * Native test daemon for the BasaltVR control socket (docs/DXMT-INTEROP.md
 * §4). Plays the streamer daemon's role against the PE runtime under Wine:
 * listens on 127.0.0.1, writes "<port> <token> [<width> <height>]" to the
 * control file, then
 * validates the Hello handshake, swapchain registration (every IOSurfaceID
 * must resolve via IOSurfaceLookup with matching dimensions), FrameReady
 * consistency, and teardown. Exits 0 only if at least --expect-frames
 * FrameReady messages referencing registered swapchains arrived.
 *
 * Usage: basalt_control_test_daemon --control-file <path> [--expect-frames N]
 *        [--frame-delay-ms N] [--view-width N --view-height N]
 *        [--verify-clears | --compositor-scenarios]
 *
 * --compositor-scenarios pairs with d3d11_compositor_smoke.exe: every
 * FrameReady is checked against basalt_compositor_scenarios.h by reading
 * the referenced IOSurfaces (the application's own direct swapchain or the
 * runtime compositor's output; exact or blended pixels at known places) and,
 * for the side-by-side scenario, each eye's image rect.
 */

#include <IOSurface/IOSurfaceRef.h>

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../../pe/basalt_control_protocol.h"
#include "../basalt_compositor_scenarios.h"
#include "../basalt_test_colors.h"

/* The runtime keeps up to 16 application swapchains plus one compositor
 * output swapchain; only direct ones are registered, but allow them all. */
#define MAX_SWAPCHAINS 24
#define MAX_IMAGES 8
#define ACCEPT_TIMEOUT_SECONDS 60
#define READ_TIMEOUT_SECONDS 30

typedef struct {
    uint64_t id;
    uint32_t width;
    uint32_t height;
    uint32_t dxgi_format;
    uint32_t image_count;
    IOSurfaceRef surfaces[MAX_IMAGES];
    bool live;
} Swapchain;

#define DXGI_FORMAT_B8G8R8A8_UNORM_VALUE 87u
#define DXGI_FORMAT_B8G8R8A8_UNORM_SRGB_VALUE 91u
#define COMPOSITOR_OUTPUT_IMAGE_COUNT 6u
#define APPLICATION_IMAGE_COUNT 3u

/* The shared color formula packs r,g,b,a memory bytes (RGBA8); BGRA8
 * surfaces store b,g,r,a, so swap the red and blue bytes to compare. */
static uint32_t expected_pixel_for(const Swapchain* swapchain, uint64_t frame_number) {
    const uint32_t rgba = basaltTestClearColor(frame_number);
    if (swapchain->dxgi_format == DXGI_FORMAT_B8G8R8A8_UNORM_VALUE) {
        return (rgba & 0xff00ff00u) | ((rgba & 0xffu) << 16) | ((rgba >> 16) & 0xffu);
    }
    return rgba;
}

static Swapchain g_swapchains[MAX_SWAPCHAINS];
static uint64_t g_frames_received = 0;
static uint64_t g_last_frame_number = 0;
static bool g_verify_clears = false;
static bool g_compositor_scenarios = false;
static uint64_t g_haptics_received = 0;
static bool g_refresh_tracking = false;
static bool g_head_turned = false;
static unsigned int g_frame_delay_ms = 0;
static unsigned int g_view_width = 0;
static unsigned int g_view_height = 0;

static uint16_t read_u16(const uint8_t* p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t read_u32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t read_u64(const uint8_t* p) { uint64_t v; memcpy(&v, p, 8); return v; }
static float read_f32(const uint8_t* p) { float v; memcpy(&v, p, 4); return v; }

static bool recv_all(int fd, void* data, size_t size) {
    uint8_t* cursor = data;
    while (size > 0) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval timeout = {READ_TIMEOUT_SECONDS, 0};
        const int ready = select(fd + 1, &fds, NULL, NULL, &timeout);
        if (ready <= 0) {
            return false;
        }
        const ssize_t received = recv(fd, cursor, size, 0);
        if (received <= 0) {
            return false;
        }
        cursor += received;
        size -= (size_t)received;
    }
    return true;
}

static bool send_all(int fd, const void* data, size_t length) {
    const uint8_t* cursor = data;
    while (length > 0) {
        const ssize_t sent = send(fd, cursor, length, 0);
        if (sent <= 0) {
            return false;
        }
        cursor += sent;
        length -= (size_t)sent;
    }
    return true;
}

static bool send_message(int fd, uint16_t type, const uint8_t* payload, size_t length) {
    uint8_t header[6];
    const uint32_t frame_length = (uint32_t)(sizeof(type) + length);
    memcpy(header, &frame_length, 4);
    memcpy(header + 4, &type, 2);
    return send_all(fd, header, sizeof(header)) &&
           (length == 0 || send_all(fd, payload, length));
}

static bool send_head_pose(int fd, uint64_t timestamp) {
    uint8_t payload[8 + 7 * sizeof(float)];
    /* Start at 90-degree yaw, then turn another 90 degrees before the reset
     * gesture. Both poses have nonzero guardian-stage positions so the smoke
     * can verify yaw and horizontal position recenter together. */
    const float initial_pose[7] = {
        0.0f, 0.707106781f, 0.0f, 0.707106781f,
        0.25f, 1.5f, -0.5f,
    };
    const float turned_pose[7] = {
        0.0f, 1.0f, 0.0f, 0.0f,
        0.5f, 1.5f, -0.25f,
    };
    const float* pose = g_head_turned ? turned_pose : initial_pose;
    memcpy(payload, &timestamp, sizeof(timestamp));
    memcpy(payload + sizeof(timestamp), pose, 7 * sizeof(float));
    return send_message(fd, BASALT_MSG_HEAD_POSE, payload, sizeof(payload));
}

static bool send_controller_motion(int fd, uint64_t timestamp, uint32_t hand) {
    uint8_t payload[8 + 4 + 4 + 13 * sizeof(float)] = {0};
    const float motion[13] = {
        0.0f, 0.0f, 0.0f, 1.0f,
        hand == 0 ? -0.2f : 0.2f, 1.2f, -0.4f,
        0.1f, 0.2f, 0.3f, 0.0f, 0.5f, 0.0f,
    };
    memcpy(payload, &timestamp, 8);
    memcpy(payload + 8, &hand, 4);
    memcpy(payload + 16, motion, sizeof(motion));
    return send_message(fd, BASALT_MSG_CONTROLLER_MOTION, payload, sizeof(payload));
}

static bool send_controller_mask(int fd, uint64_t timestamp, uint32_t active_mask) {
    uint8_t payload[16] = {0};
    memcpy(payload, &timestamp, 8);
    memcpy(payload + 8, &active_mask, 4);
    return send_message(fd, BASALT_MSG_CONTROLLER_MASK, payload, sizeof(payload));
}

static bool send_touch_profile(int fd, uint32_t hand) {
    uint8_t payload[12];
    const uint64_t profile_id = UINT64_C(0x0812fd85c84384a6);
    memcpy(payload, &hand, 4);
    memcpy(payload + 4, &profile_id, 8);
    return send_message(fd, BASALT_MSG_INTERACTION_PROFILE, payload, sizeof(payload));
}

static bool send_view_config(int fd) {
    const float values[9] = {
        BASALT_TEST_IPD_METERS,
        kBasaltTestEyeFov[0][0], kBasaltTestEyeFov[0][1],
        kBasaltTestEyeFov[0][2], kBasaltTestEyeFov[0][3],
        kBasaltTestEyeFov[1][0], kBasaltTestEyeFov[1][1],
        kBasaltTestEyeFov[1][2], kBasaltTestEyeFov[1][3],
    };
    return send_message(
        fd, BASALT_MSG_VIEW_CONFIG,
        (const uint8_t*)values, sizeof(values));
}

static bool send_button_state(
    int fd, uint64_t path_id, uint32_t value_type, float value) {
    uint8_t payload[16];
    memcpy(payload, &path_id, 8);
    memcpy(payload + 8, &value_type, 4);
    memcpy(payload + 12, &value, 4);
    return send_message(fd, BASALT_MSG_BUTTON_STATE, payload, sizeof(payload));
}

// ALVR path hashes bound in runtime/pe/input.cpp. Value type 1 is analog,
// 0 is a digital 0/1 button.
static bool send_left_squeeze(int fd, float value) {
    return send_button_state(fd, UINT64_C(0x01f1b9c689804b82), 1, value);
}

static bool send_right_system_click(int fd, float value) {
    return send_button_state(fd, UINT64_C(0x19729bd97073d474), 0, value);
}

static bool handle_haptic(int fd, const uint8_t* payload, size_t length) {
    if (length != 20 || read_u32(payload) > 1) {
        fprintf(stderr, "FAIL: invalid Haptic payload length/hand\n");
        return false;
    }
    const uint64_t duration = read_u64(payload + 4);
    const float frequency = read_f32(payload + 12);
    const float amplitude = read_f32(payload + 16);
    if (!__builtin_isfinite(frequency) || !__builtin_isfinite(amplitude) ||
        frequency < 0.0f || amplitude < 0.0f || amplitude > 1.0f) {
        fprintf(stderr, "FAIL: invalid Haptic values\n");
        return false;
    }
    ++g_haptics_received;
    printf("daemon: haptic hand %u duration %" PRIu64 " amplitude %.2f\n",
           read_u32(payload), duration, amplitude);
    // Two deliberately unusual amplitudes are test-only synchronization
    // markers. They let the PE smoke deterministically prove that a newer
    // authoritative presence mask clears an already-published pose and that
    // a later motion+mask pair restores it without stale motion winning.
    if (duration != 0 && __builtin_fabsf(amplitude - 0.125f) < 0.0001f) {
        return send_controller_mask(fd, 3, 0) &&
               send_controller_motion(fd, 2, 0);  // stale: must not resurrect
    }
    if (duration != 0 && __builtin_fabsf(amplitude - 0.25f) < 0.0001f) {
        return send_controller_motion(fd, 4, 0) &&
               send_controller_mask(fd, 4, 1);
    }
    // Hold the right system click while publishing a turned head pose. This
    // deterministically exercises the runtime's Quest reset-view gesture and
    // reference-space-change event without introducing a test-only protocol.
    // Hold for 1 s: the runtime measures its 600 ms threshold between receipt
    // times, so a loaded machine can delay the press well past a few frames.
    if (duration != 0 && __builtin_fabsf(amplitude - 0.375f) < 0.0001f) {
        g_head_turned = true;
        if (!send_head_pose(fd, 2) || !send_right_system_click(fd, 1.0f)) {
            return false;
        }
        for (int sample = 0; sample < 20; ++sample) {
            usleep(50000);
            if (!send_head_pose(fd, 2)) {
                return false;
            }
        }
        return send_right_system_click(fd, 0.0f);
    }
    // Model a replacement ALVR session: InputReset, then the retained input
    // state again under a restarted Quest clock (timestamps below the old 2).
    if (duration != 0 && __builtin_fabsf(amplitude - 0.625f) < 0.0001f) {
        return send_message(fd, BASALT_MSG_INPUT_RESET, NULL, 0) &&
               send_touch_profile(fd, 0) &&
               send_touch_profile(fd, 1) &&
               send_left_squeeze(fd, 0.25f) &&
               send_head_pose(fd, 1) &&
               send_controller_motion(fd, 1, 0) &&
               send_controller_mask(fd, 1, 1);
    }
    // Interleave a sparse button delta with reverse haptic traffic. The next
    // xrSyncActions must observe this as a change, without disturbing other
    // retained inputs.
    return duration == 0 || send_left_squeeze(fd, 0.25f);
}

static Swapchain* find_swapchain(uint64_t id) {
    for (int i = 0; i < MAX_SWAPCHAINS; ++i) {
        if (g_swapchains[i].live && g_swapchains[i].id == id) {
            return &g_swapchains[i];
        }
    }
    return NULL;
}

static void release_swapchain(Swapchain* swapchain) {
    for (uint32_t i = 0; i < swapchain->image_count; ++i) {
        if (swapchain->surfaces[i] != NULL) {
            IOSurfaceDecrementUseCount(swapchain->surfaces[i]);
            CFRelease(swapchain->surfaces[i]);
            swapchain->surfaces[i] = NULL;
        }
    }
    swapchain->live = false;
}

static bool handle_create_swapchain(int fd, const uint8_t* payload, size_t length) {
    if (length < 24) {
        fprintf(stderr, "FAIL: CreateSwapchain payload too short (%zu)\n", length);
        return false;
    }
    const uint64_t id = read_u64(payload);
    const uint32_t width = read_u32(payload + 8);
    const uint32_t height = read_u32(payload + 12);
    const uint32_t format = read_u32(payload + 16);
    const uint32_t image_count = read_u32(payload + 20);
    if (image_count == 0 || image_count > MAX_IMAGES ||
        length != 24 + (size_t)image_count * 4) {
        fprintf(stderr, "FAIL: CreateSwapchain image count %u / length %zu\n",
                image_count, length);
        return false;
    }
    if (find_swapchain(id) != NULL) {
        fprintf(stderr, "FAIL: duplicate swapchain id %" PRIu64 "\n", id);
        return false;
    }
    Swapchain* slot = NULL;
    for (int i = 0; i < MAX_SWAPCHAINS; ++i) {
        if (!g_swapchains[i].live) {
            slot = &g_swapchains[i];
            break;
        }
    }
    if (slot == NULL) {
        fprintf(stderr, "FAIL: too many swapchains\n");
        return false;
    }
    memset(slot, 0, sizeof(*slot));
    slot->id = id;
    slot->width = width;
    slot->height = height;
    slot->dxgi_format = format;
    slot->image_count = image_count;

    for (uint32_t i = 0; i < image_count; ++i) {
        const uint32_t iosurface_id = read_u32(payload + 24 + i * 4);
        IOSurfaceRef surface = IOSurfaceLookup((IOSurfaceID)iosurface_id);
        if (surface == NULL) {
            fprintf(stderr, "FAIL: IOSurfaceLookup(%u) failed for swapchain %" PRIu64 "\n",
                    iosurface_id, id);
            release_swapchain(slot);
            return false;
        }
        /* IDs are untrusted input: the surface must match the registration. */
        if (IOSurfaceGetWidth(surface) != width || IOSurfaceGetHeight(surface) != height) {
            fprintf(stderr, "FAIL: surface %u is %zux%zu, expected %ux%u\n", iosurface_id,
                    IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), width, height);
            CFRelease(surface);
            release_swapchain(slot);
            return false;
        }
        IOSurfaceIncrementUseCount(surface);
        slot->surfaces[i] = surface;
    }
    slot->live = true;
    printf("daemon: swapchain %" PRIu64 " registered (%ux%u, format %u, %u images)\n",
           id, width, height, format, image_count);

    uint8_t ack[12];
    memcpy(ack, &id, 8);
    const uint32_t generation = 1;
    memcpy(ack + 8, &generation, 4);
    /* Deliberately interleave tracking before an expected ACK. This proves
     * the runtime has one receiver/demultiplexer instead of treating the
     * next daemon message as the synchronous reply. */
    const bool sent = send_head_pose(fd, 2) &&
                      send_controller_motion(fd, 2, 0) &&
                      send_controller_mask(fd, 2, 1) &&
                      send_message(fd, BASALT_MSG_SWAPCHAIN_ACK, ack, sizeof(ack));
    if (sent) {
        // The smoke intentionally proves that the first injected pose can
        // become stale before swapchain creation. Once rendering is possible,
        // model the live Quest by keeping that deterministic sample fresh.
        g_refresh_tracking = true;
    }
    return sent;
}

static bool handle_destroy_swapchain(int fd, const uint8_t* payload, size_t length) {
    if (length != 8) {
        fprintf(stderr, "FAIL: DestroySwapchain payload length %zu\n", length);
        return false;
    }
    const uint64_t id = read_u64(payload);
    Swapchain* swapchain = find_swapchain(id);
    if (swapchain == NULL) {
        fprintf(stderr, "FAIL: DestroySwapchain for unknown id %" PRIu64 "\n", id);
        return false;
    }
    release_swapchain(swapchain);
    printf("daemon: swapchain %" PRIu64 " destroyed\n", id);
    return send_message(fd, BASALT_MSG_DESTROY_SWAPCHAIN_ACK, payload, 8);
}

/* Reads one pixel's b,g,r,a bytes (packed little-endian) from a BGRA
 * surface. */
static bool read_bgra_pixel(IOSurfaceRef surface, uint32_t x, uint32_t y, uint32_t* pixel) {
    if (x >= IOSurfaceGetWidth(surface) || y >= IOSurfaceGetHeight(surface) ||
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) {
        return false;
    }
    const uint8_t* base = IOSurfaceGetBaseAddress(surface);
    memcpy(pixel, base + (size_t)y * IOSurfaceGetBytesPerRow(surface) + (size_t)x * 4,
           sizeof(*pixel));
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return true;
}

static uint32_t rgba_to_bgra(uint32_t rgba) {
    return (rgba & 0xff00ff00u) | ((rgba & 0xffu) << 16) | ((rgba >> 16) & 0xffu);
}

/* Linear-light "over" of an unpremultiplied source, re-encoded to sRGB,
 * which is what the runtime compositor's sRGB output view produces. */
static uint32_t blend_over_rgba(uint32_t source, uint32_t destination) {
    const double alpha = (double)(source >> 24) / 255.0;
    uint32_t result = 0xff000000u;
    for (int channel = 0; channel < 3; ++channel) {
        const double s = basaltSrgbToLinear((double)((source >> (channel * 8)) & 0xffu) / 255.0);
        const double d = basaltSrgbToLinear(
            (double)((destination >> (channel * 8)) & 0xffu) / 255.0);
        const double encoded = basaltLinearToSrgb(s * alpha + d * (1.0 - alpha));
        result |= (uint32_t)lround(encoded * 255.0) << (channel * 8);
    }
    return result;
}

static bool expect_pixel(
    uint64_t frame_number, uint32_t view, IOSurfaceRef surface,
    float x, float y, uint32_t expected_rgba, int tolerance, const char* what) {
    const uint32_t px = (uint32_t)x;
    const uint32_t py = (uint32_t)y;
    uint32_t pixel = 0;
    if (!read_bgra_pixel(surface, px, py, &pixel)) {
        fprintf(stderr, "FAIL: frame %" PRIu64 " view %u: cannot read pixel %u,%u (%s)\n",
                frame_number, view, px, py, what);
        return false;
    }
    const uint32_t expected = rgba_to_bgra(expected_rgba);
    for (int channel = 0; channel < 4; ++channel) {
        const int actual_byte = (int)((pixel >> (channel * 8)) & 0xffu);
        const int expected_byte = (int)((expected >> (channel * 8)) & 0xffu);
        if (abs(actual_byte - expected_byte) > tolerance) {
            fprintf(stderr,
                    "FAIL: frame %" PRIu64 " view %u pixel %u,%u (%s) is BGRA 0x%08x, "
                    "expected 0x%08x (tolerance %d)\n",
                    frame_number, view, px, py, what, pixel, expected, tolerance);
            return false;
        }
    }
    return true;
}

static bool is_compositor_output(const Swapchain* swapchain) {
    return swapchain->dxgi_format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB_VALUE &&
           swapchain->image_count == COMPOSITOR_OUTPUT_IMAGE_COUNT &&
           swapchain->width == BASALT_COMPOSITOR_VIEW_WIDTH &&
           swapchain->height == BASALT_COMPOSITOR_VIEW_HEIGHT;
}

static bool is_application_direct(const Swapchain* swapchain) {
    return swapchain->dxgi_format == DXGI_FORMAT_B8G8R8A8_UNORM_VALUE &&
           swapchain->image_count == APPLICATION_IMAGE_COUNT;
}

/* Checks one view of a compositor scenario frame; rect is the view's
 * x, y, width, height. */
static bool verify_scenario_view(
    uint64_t frame_number, uint32_t view, const Swapchain* swapchain,
    uint32_t image_index, const int32_t rect[4]) {
    const float width = (float)BASALT_COMPOSITOR_VIEW_WIDTH;
    const float height = (float)BASALT_COMPOSITOR_VIEW_HEIGHT;
    IOSurfaceRef surface = swapchain->surfaces[image_index];
    const bool direct_expected =
        frame_number == BASALT_SCENARIO_DIRECT || frame_number == BASALT_SCENARIO_FIFO ||
        frame_number == BASALT_SCENARIO_SIDE_BY_SIDE;
    if (frame_number > BASALT_SCENARIO_COUNT) {
        fprintf(stderr, "FAIL: unexpected extra FrameReady %" PRIu64 "\n", frame_number);
        return false;
    }
    if (direct_expected ? !is_application_direct(swapchain)
                        : !is_compositor_output(swapchain)) {
        fprintf(stderr,
                "FAIL: scenario %" PRIu64 " view %u referenced swapchain %" PRIu64
                " (%ux%u, format %u, %u images); expected the %s\n",
                frame_number, view, swapchain->id, swapchain->width, swapchain->height,
                swapchain->dxgi_format, swapchain->image_count,
                direct_expected ? "application's own BGRA swapchain"
                                : "runtime compositor output");
        return false;
    }
    switch (frame_number) {
    case BASALT_SCENARIO_DIRECT:
        return expect_pixel(frame_number, view, surface, 0, 0, kBasaltDirectColor, 0, "direct") &&
               expect_pixel(frame_number, view, surface, 33, 47, kBasaltDirectColor, 0, "direct");
    case BASALT_SCENARIO_SRGB_RGBA:
        return expect_pixel(frame_number, view, surface, 0, 0, kBasaltSrgbColor, 0, "corner") &&
               expect_pixel(frame_number, view, surface, width - 1, height - 1,
                            kBasaltSrgbColor, 0, "corner") &&
               expect_pixel(frame_number, view, surface, width * 0.5f, height * 0.5f,
                            kBasaltSrgbColor, 0, "center") &&
               expect_pixel(frame_number, view, surface, 17, height * 0.6f,
                            kBasaltSrgbColor, 0, "edge");
    case BASALT_SCENARIO_MIPMAPPED:
    case BASALT_SCENARIO_OVERSIZED:
        return expect_pixel(frame_number, view, surface, width * 0.25f, height * 0.25f,
                            kBasaltQuadrantColors[0], 0, "top-left quadrant") &&
               expect_pixel(frame_number, view, surface, width * 0.75f, height * 0.25f,
                            kBasaltQuadrantColors[1], 0, "top-right quadrant") &&
               expect_pixel(frame_number, view, surface, width * 0.25f, height * 0.75f,
                            kBasaltQuadrantColors[2], 0, "bottom-left quadrant") &&
               expect_pixel(frame_number, view, surface, width * 0.75f, height * 0.75f,
                            kBasaltQuadrantColors[3], 0, "bottom-right quadrant");
    case BASALT_SCENARIO_FLIPPED:
        return expect_pixel(frame_number, view, surface, width * 0.5f, height * 0.25f,
                            kBasaltFlipBottomColor, 0, "flipped top") &&
               expect_pixel(frame_number, view, surface, width * 0.5f, height * 0.75f,
                            kBasaltFlipTopColor, 0, "flipped bottom");
    case BASALT_SCENARIO_QUAD: {
        float center_x = 0.0f;
        float center_y = 0.0f;
        float inner_x = 0.0f;
        float inner_y = 0.0f;
        float outside_x = 0.0f;
        float outside_y = 0.0f;
        basaltQuadCenterPixel(view, &center_x, &center_y);
        basaltQuadOffsetPixel(view, 0.15f, -0.15f, &inner_x, &inner_y);
        basaltQuadOffsetPixel(view, BASALT_QUAD_SIZE_METERS, 0.0f, &outside_x, &outside_y);
        const uint32_t blended = blend_over_rgba(kBasaltQuadColor, kBasaltProjectionColor);
        return expect_pixel(frame_number, view, surface, center_x, center_y,
                            blended, 2, "quad center") &&
               expect_pixel(frame_number, view, surface, inner_x, inner_y,
                            blended, 2, "inside quad") &&
               expect_pixel(frame_number, view, surface, outside_x, outside_y,
                            kBasaltProjectionColor, 0, "beside quad") &&
               expect_pixel(frame_number, view, surface, 5, 5,
                            kBasaltProjectionColor, 0, "projection corner");
    }
    case BASALT_SCENARIO_QUAD_ONLY: {
        float upper_x = 0.0f;
        float upper_y = 0.0f;
        float lower_x = 0.0f;
        float lower_y = 0.0f;
        basaltQuadOffsetPixel(view, 0.0f, 0.12f, &upper_x, &upper_y);
        basaltQuadOffsetPixel(view, 0.0f, -0.12f, &lower_x, &lower_y);
        /* The negative-height rect shows the image upside down. */
        return expect_pixel(frame_number, view, surface, upper_x, upper_y,
                            kBasaltSkyBottomColor, 0, "upper quad half") &&
               expect_pixel(frame_number, view, surface, lower_x, lower_y,
                            kBasaltSkyTopColor, 0, "lower quad half") &&
               expect_pixel(frame_number, view, surface, 5, 5,
                            BASALT_RGBA(0, 0, 0, 255), 0, "cleared background");
    }
    case BASALT_SCENARIO_FIFO:
        if (image_index != BASALT_FIFO_RELEASED_IMAGE) {
            fprintf(stderr,
                    "FAIL: FIFO scenario view %u delivered image %u, expected the oldest "
                    "acquired image %u\n",
                    view, image_index, BASALT_FIFO_RELEASED_IMAGE);
            return false;
        }
        return expect_pixel(frame_number, view, surface, 0, 0,
                            kBasaltFifoReleasedColor, 0, "released image");
    case BASALT_SCENARIO_SIDE_BY_SIDE: {
        /* The typeless image is registered as B8G8R8A8_UNORM (checked
         * above), and each eye selects its half of it by rect. */
        const int32_t half = (int32_t)(BASALT_SIDE_BY_SIDE_WIDTH / 2);
        const float seam = (float)half;
        if (swapchain->width != BASALT_SIDE_BY_SIDE_WIDTH ||
            swapchain->height != BASALT_SIDE_BY_SIDE_HEIGHT ||
            rect[0] != (view == 0 ? 0 : half) || rect[1] != 0 || rect[2] != half ||
            rect[3] != (int32_t)BASALT_SIDE_BY_SIDE_HEIGHT) {
            fprintf(stderr,
                    "FAIL: side-by-side view %u is %ux%u rect %d,%d %dx%d; expected the "
                    "%ux%u image's %s half\n",
                    view, swapchain->width, swapchain->height, rect[0], rect[1], rect[2],
                    rect[3], BASALT_SIDE_BY_SIDE_WIDTH, BASALT_SIDE_BY_SIDE_HEIGHT,
                    view == 0 ? "left" : "right");
            return false;
        }
        return expect_pixel(frame_number, view, surface, seam - 1.0f, 0,
                            kBasaltSideBySideLeftColor, 0, "left of the seam") &&
               expect_pixel(frame_number, view, surface, seam, 0,
                            kBasaltSideBySideRightColor, 0, "right of the seam") &&
               expect_pixel(frame_number, view, surface,
                            (float)rect[0] + (float)half * 0.5f,
                            (float)BASALT_SIDE_BY_SIDE_HEIGHT * 0.5f,
                            view == 0 ? kBasaltSideBySideLeftColor
                                      : kBasaltSideBySideRightColor,
                            0, "eye rect center");
    }
    default:
        fprintf(stderr, "FAIL: unexpected FrameReady %" PRIu64 "\n", frame_number);
        return false;
    }
}

static bool handle_frame_ready(int fd, const uint8_t* payload, size_t length) {
    if (length < 28) {
        fprintf(stderr, "FAIL: FrameReady payload too short (%zu)\n", length);
        return false;
    }
    const uint64_t frame_number = read_u64(payload);
    const int64_t display_time = (int64_t)read_u64(payload + 8);
    const uint64_t tracking_timestamp = read_u64(payload + 16);
    const uint32_t view_count = read_u32(payload + 24);
    if (view_count == 0 || view_count > 2 ||
        length != 28 + (size_t)view_count * 76) {
        fprintf(stderr, "FAIL: FrameReady view count %u / length %zu\n", view_count, length);
        return false;
    }
    if (tracking_timestamp != 2) {
        const float first_x = view_count > 0 ? read_f32(payload + 28 + 48) : 0.0f;
        const float first_y = view_count > 0 ? read_f32(payload + 28 + 52) : 0.0f;
        const float first_z = view_count > 0 ? read_f32(payload + 28 + 56) : 0.0f;
        fprintf(stderr,
                "FAIL: FrameReady carried tracking timestamp %" PRIu64
                ", expected the xrLocateViews sample timestamp 2 "
                "(first-eye position %.4f %.4f %.4f)\n",
                tracking_timestamp, first_x, first_y, first_z);
        return false;
    }
    if (frame_number <= g_last_frame_number) {
        fprintf(stderr, "FAIL: FrameReady numbers not increasing (%" PRIu64 " after %" PRIu64 ")\n",
                frame_number, g_last_frame_number);
        return false;
    }
    g_last_frame_number = frame_number;

    for (uint32_t i = 0; i < view_count; ++i) {
        const uint8_t* view = payload + 28 + i * 76;
        const uint64_t swapchain_id = read_u64(view);
        const uint32_t image_index = read_u32(view + 8);
        const Swapchain* swapchain = find_swapchain(swapchain_id);
        if (swapchain == NULL) {
            fprintf(stderr, "FAIL: FrameReady references unknown swapchain %" PRIu64 "\n",
                    swapchain_id);
            return false;
        }
        if (image_index >= swapchain->image_count) {
            fprintf(stderr, "FAIL: FrameReady image index %u out of range\n", image_index);
            return false;
        }
        if (g_compositor_scenarios) {
            const int32_t rect[4] = {
                (int32_t)read_u32(view + 16), (int32_t)read_u32(view + 20),
                (int32_t)read_u32(view + 24), (int32_t)read_u32(view + 28)};
            if (!verify_scenario_view(frame_number, i, swapchain, image_index, rect)) {
                return false;
            }
            /* Both composited eyes come from one output ring slot. */
            if (is_compositor_output(swapchain) && view_count == 2 && i == 1 &&
                (read_u64(payload + 28) != swapchain_id ||
                 read_u32(payload + 28 + 8) + 1 != image_index ||
                 image_index % 2 != 1)) {
                fprintf(stderr, "FAIL: composited eyes are not one output slot pair\n");
                return false;
            }
        }
        const float expected_x = i == 0 ? -0.032f : 0.032f;
        const float expected_z = 0.0f;
        const float orientation_y = read_f32(view + 36);
        const float orientation_w = read_f32(view + 44);
        const float position_x = read_f32(view + 48);
        const float position_y = read_f32(view + 52);
        const float position_z = read_f32(view + 56);
        if (__builtin_fabsf(orientation_y) > 0.0001f ||
            __builtin_fabsf(orientation_w - 1.0f) > 0.0001f ||
            __builtin_fabsf(position_x - expected_x) > 0.0001f ||
            __builtin_fabsf(position_y - 1.5f) > 0.0001f ||
            __builtin_fabsf(position_z - expected_z) > 0.0001f) {
            fprintf(stderr,
                    "FAIL: FrameReady view %u did not carry injected head pose "
                    "(w %.4f, position %.4f %.4f %.4f)\n",
                    i, orientation_w, position_x, position_y, position_z);
            return false;
        }
        if (g_verify_clears) {
            /* The fence-gated FrameReady contract means the frame's pixels
             * must already be visible here, zero-copy, in this process. */
            IOSurfaceRef surface = swapchain->surfaces[image_index];
            if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) {
                fprintf(stderr, "FAIL: IOSurfaceLock for frame %" PRIu64 "\n", frame_number);
                return false;
            }
            uint32_t pixel = 0;
            memcpy(&pixel, IOSurfaceGetBaseAddress(surface), sizeof(pixel));
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            const uint32_t expected = expected_pixel_for(swapchain, frame_number);
            if (pixel != expected) {
                fprintf(stderr,
                        "FAIL: frame %" PRIu64 " view %u pixel 0x%08x, expected 0x%08x\n",
                        frame_number, i, pixel, expected);
                return false;
            }
        }
    }
    ++g_frames_received;
    if (g_compositor_scenarios) {
        printf("daemon: compositor scenario %" PRIu64 " verified\n", frame_number);
    }
    if (g_frames_received <= 3) {
        printf("daemon: frame %" PRIu64 " ready (display time %" PRId64 ", %u views)\n",
               frame_number, display_time, view_count);
    }
    // A continuously readable frame socket can prevent the select timeout in
    // the main loop from firing. Refresh tracking here as well so an
    // intentionally slow consumer does not make the test pose expire while
    // it is exercising frame backpressure.
    if (g_refresh_tracking && !send_head_pose(fd, 2)) {
        return false;
    }
    if (g_frame_delay_ms > 0) {
        usleep((useconds_t)g_frame_delay_ms * 1000);
    }
    uint8_t consumed[8];
    memcpy(consumed, &frame_number, sizeof(frame_number));
    return send_message(fd, BASALT_MSG_FRAME_CONSUMED, consumed, sizeof(consumed));
}

int main(int argc, char** argv) {
    const char* control_file = NULL;
    uint64_t expect_frames = 1;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--control-file") == 0 && i + 1 < argc) {
            control_file = argv[++i];
        } else if (strcmp(argv[i], "--expect-frames") == 0 && i + 1 < argc) {
            expect_frames = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--verify-clears") == 0) {
            g_verify_clears = true;
        } else if (strcmp(argv[i], "--compositor-scenarios") == 0) {
            g_compositor_scenarios = true;
        } else if (strcmp(argv[i], "--frame-delay-ms") == 0 && i + 1 < argc) {
            g_frame_delay_ms = (unsigned int)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--view-width") == 0 && i + 1 < argc) {
            g_view_width = (unsigned int)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--view-height") == 0 && i + 1 < argc) {
            g_view_height = (unsigned int)strtoul(argv[++i], NULL, 10);
        } else {
            control_file = NULL;  // Reported as a usage error below.
            break;
        }
    }
    if (control_file == NULL || (g_view_width == 0) != (g_view_height == 0) ||
        (g_verify_clears && g_compositor_scenarios) ||
        (g_compositor_scenarios &&
         (g_view_width != BASALT_COMPOSITOR_VIEW_WIDTH ||
          g_view_height != BASALT_COMPOSITOR_VIEW_HEIGHT))) {
        fprintf(stderr, "usage: %s --control-file <path> [--expect-frames N] "
                        "[--frame-delay-ms N] [--view-width N --view-height N] "
                        "[--verify-clears | --compositor-scenarios]\n",
                argv[0]);
        return 2;
    }

    const int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener, (struct sockaddr*)&address, sizeof(address)) != 0 ||
        listen(listener, 1) != 0) {
        perror("bind/listen");
        return 1;
    }
    socklen_t address_length = sizeof(address);
    if (getsockname(listener, (struct sockaddr*)&address, &address_length) != 0) {
        perror("getsockname");
        return 1;
    }
    const uint16_t port = ntohs(address.sin_port);

    char token[BASALT_CONTROL_TOKEN_LENGTH + 1];
    for (unsigned i = 0; i < BASALT_CONTROL_TOKEN_LENGTH; ++i) {
        token[i] = "0123456789abcdef"[arc4random_uniform(16)];
    }
    token[BASALT_CONTROL_TOKEN_LENGTH] = '\0';

    FILE* file = fopen(control_file, "w");
    if (file == NULL) {
        perror("control file");
        return 1;
    }
    if (g_view_width > 0) {
        fprintf(file, "%u %s %u %u\n", port, token, g_view_width, g_view_height);
    } else {
        fprintf(file, "%u %s\n", port, token);
    }
    fclose(file);
    printf("daemon: listening on 127.0.0.1:%u\n", port);
    fflush(stdout);

    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(listener, &fds);
    struct timeval accept_timeout = {ACCEPT_TIMEOUT_SECONDS, 0};
    if (select(listener + 1, &fds, NULL, NULL, &accept_timeout) <= 0) {
        fprintf(stderr, "FAIL: no runtime connected within %d s\n", ACCEPT_TIMEOUT_SECONDS);
        return 1;
    }
    const int fd = accept(listener, NULL, NULL);
    close(listener);
    if (fd < 0) {
        perror("accept");
        return 1;
    }
    const int no_delay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &no_delay, sizeof(no_delay));

    bool ok = true;
    bool got_teardown = false;
    bool hello_done = false;
    while (ok) {
        if (g_refresh_tracking) {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(fd, &readable);
            struct timeval tracking_interval = {0, 50000};
            const int ready = select(
                fd + 1, &readable, NULL, NULL, &tracking_interval);
            if (ready < 0) {
                ok = false;
                break;
            }
            if (ready == 0) {
                ok = send_head_pose(fd, 2);
                continue;
            }
        }
        uint8_t header[6];
        if (!recv_all(fd, header, sizeof(header))) {
            break;  /* EOF: acceptable after teardown */
        }
        const uint32_t frame_length = read_u32(header);
        const uint16_t type = read_u16(header + 4);
        if (frame_length < 2 || frame_length > BASALT_CONTROL_MAX_MESSAGE_LENGTH) {
            fprintf(stderr, "FAIL: bad frame length %u\n", frame_length);
            ok = false;
            break;
        }
        const size_t payload_length = frame_length - 2;
        uint8_t payload[BASALT_CONTROL_MAX_MESSAGE_LENGTH];
        if (payload_length > 0 && !recv_all(fd, payload, payload_length)) {
            fprintf(stderr, "FAIL: truncated message type %u\n", type);
            ok = false;
            break;
        }

        if (!hello_done) {
            if (type != BASALT_MSG_HELLO ||
                payload_length < 2 + BASALT_CONTROL_TOKEN_LENGTH + 8 + 2) {
                fprintf(stderr, "FAIL: expected Hello first (got type %u)\n", type);
                ok = false;
                break;
            }
            const uint16_t version = read_u16(payload);
            if (version != BASALT_CONTROL_PROTOCOL_VERSION) {
                fprintf(stderr, "FAIL: protocol version %u\n", version);
                ok = false;
                break;
            }
            if (memcmp(payload + 2, token, BASALT_CONTROL_TOKEN_LENGTH) != 0) {
                fprintf(stderr, "FAIL: Hello token mismatch\n");
                ok = false;
                break;
            }
            const uint64_t session_id = read_u64(payload + 2 + BASALT_CONTROL_TOKEN_LENGTH);
            const uint16_t renderer_length =
                read_u16(payload + 2 + BASALT_CONTROL_TOKEN_LENGTH + 8);
            char renderer[257] = {0};
            if (payload_length == 2 + BASALT_CONTROL_TOKEN_LENGTH + 8 + 2 + renderer_length &&
                renderer_length <= 256) {
                memcpy(renderer, payload + 2 + BASALT_CONTROL_TOKEN_LENGTH + 8 + 2,
                       renderer_length);
            } else {
                fprintf(stderr, "FAIL: Hello renderer length %u\n", renderer_length);
                ok = false;
                break;
            }
            printf("daemon: hello from session %" PRIu64 " (%s)\n", session_id, renderer);
            uint8_t ack[2];
            const uint16_t accepted = BASALT_CONTROL_PROTOCOL_VERSION;
            memcpy(ack, &accepted, 2);
            ok = send_message(fd, BASALT_MSG_HELLO_ACK, ack, sizeof(ack));
            if (ok) {
                ok = send_view_config(fd) &&
                     send_head_pose(fd, 1) &&
                     send_touch_profile(fd, 0) &&
                     send_touch_profile(fd, 1) &&
                     send_left_squeeze(fd, 0.75f) &&
                     send_controller_motion(fd, 1, 0) &&
                     send_controller_mask(fd, 1, 1);
            }
            hello_done = true;
            continue;
        }

        switch (type) {
        case BASALT_MSG_CREATE_SWAPCHAIN:
            ok = handle_create_swapchain(fd, payload, payload_length);
            break;
        case BASALT_MSG_DESTROY_SWAPCHAIN:
            ok = handle_destroy_swapchain(fd, payload, payload_length);
            break;
        case BASALT_MSG_FRAME_READY:
            ok = handle_frame_ready(fd, payload, payload_length);
            break;
        case BASALT_MSG_HAPTIC:
            ok = handle_haptic(fd, payload, payload_length);
            break;
        case BASALT_MSG_TEARDOWN:
            got_teardown = true;
            printf("daemon: teardown received\n");
            break;
        default:
            fprintf(stderr, "FAIL: unexpected message type %u\n", type);
            ok = false;
            break;
        }
        if (got_teardown) {
            break;
        }
    }
    close(fd);

    for (int i = 0; i < MAX_SWAPCHAINS; ++i) {
        if (g_swapchains[i].live) {
            release_swapchain(&g_swapchains[i]);
        }
    }

    if (!ok) {
        return 1;
    }
    if (!hello_done) {
        fprintf(stderr, "FAIL: runtime never completed the Hello handshake\n");
        return 1;
    }
    if (g_frames_received < expect_frames) {
        fprintf(stderr,
                "FAIL: received %" PRIu64 " FrameReady messages, expected at least %" PRIu64 "\n",
                g_frames_received, expect_frames);
        return 1;
    }
    if (g_compositor_scenarios) {
        if (g_frames_received != BASALT_SCENARIO_COUNT) {
            fprintf(stderr,
                    "FAIL: received %" PRIu64 " compositor scenario frames, expected %d\n",
                    g_frames_received, BASALT_SCENARIO_COUNT);
            return 1;
        }
        printf("PASS: control daemon verified %" PRIu64
               " compositor scenarios by IOSurface readback%s\n",
               g_frames_received, got_teardown ? " (clean teardown)" : "");
        return 0;
    }
    if (g_haptics_received != 6) {
        fprintf(stderr,
                "FAIL: received %" PRIu64 " haptic commands, expected exactly 6\n",
                g_haptics_received);
        return 1;
    }
    printf("PASS: control daemon validated hello, swapchains, %" PRIu64
           " frames, and %" PRIu64 " haptic commands%s%s\n",
           g_frames_received, g_haptics_received,
           g_verify_clears ? " with pixel verification" : "",
           got_teardown ? " (clean teardown)" : "");
    return 0;
}
