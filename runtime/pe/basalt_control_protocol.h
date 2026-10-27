#ifndef BASALT_CONTROL_PROTOCOL_H
#define BASALT_CONTROL_PROTOCOL_H

/*
 * Wire protocol between the BasaltVR PE runtime (Wine, winsock client) and
 * the native streamer daemon (docs/DXMT-INTEROP.md §4). Shared by the
 * runtime and the native test daemon; C so both can include it.
 *
 * Transport: loopback TCP. The daemon listens on 127.0.0.1 on an ephemeral
 * port and writes "<port> <token> <per_eye_width> <per_eye_height>\n" to a
 * file; the launcher passes that
 * file's Windows-visible path to the game bottle as BASALT_CONTROL. The
 * token is 32 lowercase hex characters and must be echoed in Hello.
 * Width and height are optional for compatibility; when absent or outside
 * BASALT_CONTROL_{MIN_VIEW_DIMENSION,MAX_VIEW_WIDTH,MAX_VIEW_HEIGHT} (or
 * odd), the runtime recommends its maximum per-eye size instead.
 *
 * Framing, all little-endian, no padding (fields are written sequentially,
 * not as C structs):
 *   u32 length   — byte count of everything after this field
 *   u16 type     — BASALT_MSG_*
 *   payload      — per-type layout below
 *
 * Payloads:
 *   HELLO (runtime → daemon)
 *     u16 protocol_version, char token[32], u64 session_id,
 *     u16 renderer_length, char renderer[]   — adapter/DXMT description
 *   HELLO_ACK (daemon → runtime)
 *     u16 accepted_protocol_version, u64 display_period_ns
 *     — the headset refresh period xrWaitFrame paces to (the Quest rate the
 *     daemon negotiated). Outside BASALT_CONTROL_{MIN,MAX}_DISPLAY_PERIOD_NS
 *     the runtime keeps BASALT_CONTROL_DEFAULT_DISPLAY_PERIOD_NS (72 Hz).
 *   CREATE_SWAPCHAIN (runtime → daemon)
 *     u64 swapchain_id, u32 width, u32 height, u32 dxgi_format,
 *     u32 image_count, u32 iosurface_id[image_count]
 *   SWAPCHAIN_ACK (daemon → runtime)
 *     u64 swapchain_id, u32 generation
 *   DESTROY_SWAPCHAIN (runtime → daemon)
 *     u64 swapchain_id
 *   DESTROY_SWAPCHAIN_ACK (daemon → runtime)
 *     u64 swapchain_id
 *   FRAME_READY (runtime → daemon; sent only after the frame fence completed)
 *     u64 frame_number, s64 display_time, u64 quest_tracking_timestamp_ns,
 *     u32 view_count, per view:
 *       u64 swapchain_id, u32 image_index, u32 image_array_index,
 *       s32 rect_x, s32 rect_y, s32 rect_width, s32 rect_height,
 *       f32 orientation[4] (xyzw), f32 position[3],
 *       f32 fov_left, f32 fov_right, f32 fov_up, f32 fov_down
 *   FRAME_CONSUMED (daemon → runtime; sent after asynchronous Metal source read)
 *     u64 frame_number
 *   HEAD_POSE (daemon → runtime; latest sample wins)
 *     u64 target_timestamp_ns,
 *     f32 orientation[4] (xyzw), f32 position[3]
 *   CONTROLLER_MOTION (daemon → runtime; latest sample wins per hand)
 *     u64 target_timestamp_ns, u32 hand (0 left, 1 right), u32 reserved,
 *     f32 orientation[4] (xyzw), f32 position[3],
 *     f32 linear_velocity[3], f32 angular_velocity[3]
 *   BUTTON_STATE (daemon → runtime; retained until replaced/disconnect)
 *     u64 ALVR path_id, u32 value_type (0 binary, 1 scalar), f32 value
 *   HAPTIC (runtime → daemon)
 *     u32 hand (0 left, 1 right), u64 duration_ns, f32 frequency, f32 amplitude
 *   INTERACTION_PROFILE (daemon → runtime; retained until disconnect)
 *     u32 hand (0 left, 1 right), u64 ALVR profile_id
 *   INPUT_RESET (daemon → runtime; ALVR control session ended/replaced)
 *     empty; clears controller, profile, and button state atomically
 *   VIEW_CONFIG (daemon → runtime; retained calibration)
 *     f32 ipd_meters, then per eye (left, right):
 *     f32 angle_left, angle_right, angle_up, angle_down
 *   CONTROLLER_MASK (daemon → runtime; authoritative tracking presence)
 *     u64 tracking_timestamp_ns, u32 active_mask (bit 0 left, bit 1 right),
 *     u32 reserved (zero)
 *   TEARDOWN (either direction)
 *     u32 reason (BASALT_TEARDOWN_*)
 */

#define BASALT_CONTROL_PROTOCOL_VERSION 10u
#define BASALT_CONTROL_TOKEN_LENGTH 32u
#define BASALT_CONTROL_MAX_MESSAGE_LENGTH 4096u
/* Display period bounds for HELLO_ACK: 240 Hz to 30 Hz; default 72 Hz. */
#define BASALT_CONTROL_MIN_DISPLAY_PERIOD_NS 4166666u
#define BASALT_CONTROL_MAX_DISPLAY_PERIOD_NS 33333334u
#define BASALT_CONTROL_DEFAULT_DISPLAY_PERIOD_NS 13888889u
/* Per-eye view size bounds. The maximum is also the runtime's advertised and
 * accepted swapchain limit. */
#define BASALT_CONTROL_MIN_VIEW_DIMENSION 256u
#define BASALT_CONTROL_MAX_VIEW_WIDTH 1680u
#define BASALT_CONTROL_MAX_VIEW_HEIGHT 1760u

enum {
    BASALT_MSG_HELLO = 1,
    BASALT_MSG_HELLO_ACK = 2,
    BASALT_MSG_CREATE_SWAPCHAIN = 3,
    BASALT_MSG_SWAPCHAIN_ACK = 4,
    BASALT_MSG_DESTROY_SWAPCHAIN = 5,
    BASALT_MSG_DESTROY_SWAPCHAIN_ACK = 6,
    BASALT_MSG_FRAME_READY = 7,
    BASALT_MSG_TEARDOWN = 8,
    BASALT_MSG_HEAD_POSE = 9,
    BASALT_MSG_CONTROLLER_MOTION = 10,
    BASALT_MSG_BUTTON_STATE = 11,
    BASALT_MSG_HAPTIC = 12,
    BASALT_MSG_INTERACTION_PROFILE = 13,
    BASALT_MSG_INPUT_RESET = 14,
    BASALT_MSG_VIEW_CONFIG = 15,
    BASALT_MSG_CONTROLLER_MASK = 16,
    BASALT_MSG_FRAME_CONSUMED = 17,
};

enum {
    BASALT_TEARDOWN_SESSION_ENDED = 1,
    BASALT_TEARDOWN_PROTOCOL_ERROR = 2,
};

#endif
