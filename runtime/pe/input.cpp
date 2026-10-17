#include "runtime.hpp"

#include <windows.h>

#include <array>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iterator>

#include "control.hpp"

namespace {

constexpr uintptr_t kFirstActionSetHandle = static_cast<uintptr_t>(0x50000);
constexpr uintptr_t kFirstActionHandle = static_cast<uintptr_t>(0x60000);
constexpr uintptr_t kInputHandleStride = static_cast<uintptr_t>(0x10);
// Leave room for a production engine's separate UI, gameplay, and system
// action sets. These are static records, so an explicit ceiling keeps the PE
// runtime allocation-free while avoiding an artificially small hello_xr-only
// limit.
constexpr size_t kMaxActionSets = 64;
constexpr size_t kMaxActions = 512;
constexpr size_t kMaxSubactionPaths = 4;
constexpr size_t kMaxTouchBindings = 1024;
constexpr uint64_t kQuestTouchProfileId = 0x0812fd85c84384a6ULL;

struct ProfileComponentDefinition {
    const char* subpath;
    XrActionType type;
    // Bit N restricts the component to userPaths[N]; zero means every user.
    uint32_t userMask = 0;
};

struct InteractionProfileDefinition {
    const char* path;
    const char* title;
    const char* const* userPaths;
    size_t userPathCount;
    const ProfileComponentDefinition* components;
    size_t componentCount;
};

constexpr const char* kHandUsers[] = {"/user/hand/left", "/user/hand/right"};
constexpr const char* kHeadUser[] = {"/user/head"};
constexpr const char* kGamepadUser[] = {"/user/gamepad"};

#define PROFILE_COMPONENT(path, type) {path, type, 0}
constexpr ProfileComponentDefinition kSimpleComponents[] = {
    PROFILE_COMPONENT("/input/select/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/menu/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/output/haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT),
};
constexpr ProfileComponentDefinition kDaydreamComponents[] = {
    PROFILE_COMPONENT("/input/select/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/trackpad/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
};
constexpr ProfileComponentDefinition kViveComponents[] = {
    PROFILE_COMPONENT("/input/system/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/squeeze/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/menu/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trigger/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trigger/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/trackpad/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/output/haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT),
};
constexpr ProfileComponentDefinition kViveProComponents[] = {
    PROFILE_COMPONENT("/input/system/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/volume_up/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/volume_down/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/mute_mic/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
};
constexpr ProfileComponentDefinition kMotionComponents[] = {
    PROFILE_COMPONENT("/input/menu/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/squeeze/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trigger/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/trackpad/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/output/haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT),
};
constexpr ProfileComponentDefinition kXboxComponents[] = {
    PROFILE_COMPONENT("/input/menu/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/view/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/a/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/b/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/x/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/y/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/dpad_down/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/dpad_right/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/dpad_up/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/dpad_left/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/shoulder_left/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/shoulder_right/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_left/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_right/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trigger_left/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trigger_right/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_left", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_left/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_left/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_right", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_right/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick_right/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/output/haptic_left", XR_ACTION_TYPE_VIBRATION_OUTPUT),
    PROFILE_COMPONENT("/output/haptic_right", XR_ACTION_TYPE_VIBRATION_OUTPUT),
    PROFILE_COMPONENT("/output/haptic_left_trigger", XR_ACTION_TYPE_VIBRATION_OUTPUT),
    PROFILE_COMPONENT("/output/haptic_right_trigger", XR_ACTION_TYPE_VIBRATION_OUTPUT),
};
constexpr ProfileComponentDefinition kGoComponents[] = {
    PROFILE_COMPONENT("/input/system/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trigger/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/back/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/trackpad/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
};
constexpr ProfileComponentDefinition kTouchComponents[] = {
    {"/input/x/click", XR_ACTION_TYPE_BOOLEAN_INPUT, 1},
    {"/input/x/touch", XR_ACTION_TYPE_BOOLEAN_INPUT, 1},
    {"/input/y/click", XR_ACTION_TYPE_BOOLEAN_INPUT, 1},
    {"/input/y/touch", XR_ACTION_TYPE_BOOLEAN_INPUT, 1},
    {"/input/menu/click", XR_ACTION_TYPE_BOOLEAN_INPUT, 1},
    {"/input/a/click", XR_ACTION_TYPE_BOOLEAN_INPUT, 2},
    {"/input/a/touch", XR_ACTION_TYPE_BOOLEAN_INPUT, 2},
    {"/input/b/click", XR_ACTION_TYPE_BOOLEAN_INPUT, 2},
    {"/input/b/touch", XR_ACTION_TYPE_BOOLEAN_INPUT, 2},
    {"/input/system/click", XR_ACTION_TYPE_BOOLEAN_INPUT, 2},
    PROFILE_COMPONENT("/input/squeeze/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trigger/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trigger/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbstick", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbrest/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/output/haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT),
};
constexpr ProfileComponentDefinition kIndexComponents[] = {
    PROFILE_COMPONENT("/input/system/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/system/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/a/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/a/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/b/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/b/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/squeeze/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/squeeze/force", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trigger/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trigger/value", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trigger/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbstick", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/click", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/thumbstick/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/trackpad", XR_ACTION_TYPE_VECTOR2F_INPUT),
    PROFILE_COMPONENT("/input/trackpad/x", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/y", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/force", XR_ACTION_TYPE_FLOAT_INPUT),
    PROFILE_COMPONENT("/input/trackpad/touch", XR_ACTION_TYPE_BOOLEAN_INPUT),
    PROFILE_COMPONENT("/input/grip/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/input/aim/pose", XR_ACTION_TYPE_POSE_INPUT),
    PROFILE_COMPONENT("/output/haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT),
};
#undef PROFILE_COMPONENT

#define PROFILE(path, title, users, components) \
    {path, title, users, std::size(users), components, std::size(components)}
constexpr InteractionProfileDefinition kInteractionProfiles[] = {
    PROFILE("/interaction_profiles/khr/simple_controller", "Khronos Simple Controller",
            kHandUsers, kSimpleComponents),
    PROFILE("/interaction_profiles/google/daydream_controller", "Google Daydream Controller",
            kHandUsers, kDaydreamComponents),
    PROFILE("/interaction_profiles/htc/vive_controller", "HTC Vive Controller",
            kHandUsers, kViveComponents),
    PROFILE("/interaction_profiles/htc/vive_pro", "HTC Vive Pro",
            kHeadUser, kViveProComponents),
    PROFILE("/interaction_profiles/microsoft/motion_controller",
            "Microsoft Mixed Reality Motion Controller", kHandUsers, kMotionComponents),
    PROFILE("/interaction_profiles/microsoft/xbox_controller", "Microsoft Xbox Controller",
            kGamepadUser, kXboxComponents),
    PROFILE("/interaction_profiles/oculus/go_controller", "Oculus Go Controller",
            kHandUsers, kGoComponents),
    PROFILE("/interaction_profiles/oculus/touch_controller", "Oculus Touch Controller",
            kHandUsers, kTouchComponents),
    PROFILE("/interaction_profiles/valve/index_controller", "Valve Index Controller",
            kHandUsers, kIndexComponents),
};
#undef PROFILE

struct ActionSetRecord {
    XrActionSet handle = XR_NULL_HANDLE;
    bool handleAlive = false;
    XrInstance instance = XR_NULL_HANDLE;
    char name[XR_MAX_ACTION_SET_NAME_SIZE] = {};
    char localizedName[XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE] = {};
    uint32_t priority = 0;
    bool attached = false;
    XrSession attachedSession = XR_NULL_HANDLE;
};

enum class BindingKind : uint32_t {
    kUnknown,
    kBinary,
    kScalar,
    kVector2,
    kGripPose,
    kAimPose,
    kHaptic,
};

struct SyncedActionState {
    bool selected = false;
    uint32_t selectedHandMask = 0;
    bool isActive = false;
    bool changed = false;
    bool booleanValue = false;
    float floatValue = 0.0f;
    XrVector2f vectorValue{};
    XrTime lastChangeTime = 0;
    uint32_t poseHand = UINT32_MAX;
    BindingKind poseKind = BindingKind::kUnknown;
};

struct ActionRecord {
    XrAction handle = XR_NULL_HANDLE;
    bool handleAlive = false;
    XrActionSet actionSet = XR_NULL_HANDLE;
    char name[XR_MAX_ACTION_NAME_SIZE] = {};
    char localizedName[XR_MAX_LOCALIZED_ACTION_NAME_SIZE] = {};
    XrActionType actionType = XR_ACTION_TYPE_MAX_ENUM;
    uint32_t subactionPathCount = 0;
    XrPath subactionPaths[kMaxSubactionPaths] = {};
    // Index 0 is XR_NULL_PATH aggregate, then left and right.
    SyncedActionState synced[3]{};
};

struct TouchBindingRecord {
    XrAction action = XR_NULL_HANDLE;
    XrPath sourcePath = XR_NULL_PATH;
    uint32_t hand = UINT32_MAX;
    BindingKind kind = BindingKind::kUnknown;
    uint64_t inputIdX = 0;
    uint64_t inputIdY = 0;
    uint32_t sourceGroup = 0;
    bool enabledAfterSync = false;
};

struct TouchSourceDefinition {
    const char* path;
    uint32_t hand;
    BindingKind kind;
    uint64_t inputIdX;
    uint64_t inputIdY;
    uint32_t sourceGroup;
    const char* localizedComponent;
};

enum TouchSourceGroup : uint32_t {
    kSourceX = 1,
    kSourceY,
    kSourceMenu,
    kSourceSqueeze,
    kSourceTrigger,
    kSourceThumbstick,
    kSourceThumbrest,
    kSourceA,
    kSourceB,
    kSourceSystem,
    kSourceGrip,
    kSourceAim,
    kSourceHaptic,
};

constexpr TouchSourceDefinition kTouchSources[] = {
    {"/user/hand/left/input/x/click", 0, BindingKind::kBinary, 0xb1a13c485685e33cULL, 0, kSourceX, "X Button"},
    {"/user/hand/left/input/x/touch", 0, BindingKind::kBinary, 0xc3d476432e89d9ddULL, 0, kSourceX, "X Button"},
    {"/user/hand/left/input/y/click", 0, BindingKind::kBinary, 0x521496d23e3e9883ULL, 0, kSourceY, "Y Button"},
    {"/user/hand/left/input/y/touch", 0, BindingKind::kBinary, 0x117d0816b380e1f2ULL, 0, kSourceY, "Y Button"},
    {"/user/hand/left/input/menu/click", 0, BindingKind::kBinary, 0x6268a669e87cf910ULL, 0, kSourceMenu, "Menu Button"},
    {"/user/hand/left/input/squeeze/value", 0, BindingKind::kScalar, 0x01f1b9c689804b82ULL, 0, kSourceSqueeze, "Squeeze"},
    {"/user/hand/left/input/trigger/value", 0, BindingKind::kScalar, 0x0b66bbe3dc2dc49fULL, 0, kSourceTrigger, "Trigger"},
    {"/user/hand/left/input/trigger/touch", 0, BindingKind::kBinary, 0x4fa57f59dbae033aULL, 0, kSourceTrigger, "Trigger"},
    {"/user/hand/left/input/thumbstick", 0, BindingKind::kVector2, 0xc3d709ed0d794ea1ULL, 0xcb7d928706263554ULL, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/left/input/thumbstick/x", 0, BindingKind::kScalar, 0xc3d709ed0d794ea1ULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/left/input/thumbstick/y", 0, BindingKind::kScalar, 0xcb7d928706263554ULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/left/input/thumbstick/click", 0, BindingKind::kBinary, 0xdfc8a61273cf2569ULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/left/input/thumbstick/touch", 0, BindingKind::kBinary, 0x0966df80f4989bfcULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/left/input/thumbrest/touch", 0, BindingKind::kBinary, 0x3ce1c9ed4d12f3c2ULL, 0, kSourceThumbrest, "Thumb Rest"},
    {"/user/hand/right/input/a/click", 1, BindingKind::kBinary, 0xc72a0ba6ca52fba7ULL, 0, kSourceA, "A Button"},
    {"/user/hand/right/input/a/touch", 1, BindingKind::kBinary, 0x07aedc78fdf1bf2aULL, 0, kSourceA, "A Button"},
    {"/user/hand/right/input/b/click", 1, BindingKind::kBinary, 0x955047466e34669bULL, 0, kSourceB, "B Button"},
    {"/user/hand/right/input/b/touch", 1, BindingKind::kBinary, 0xdd8323caa5e48729ULL, 0, kSourceB, "B Button"},
    {"/user/hand/right/input/system/click", 1, BindingKind::kBinary, basalt::kAlvrRightSystemClickPathId, 0, kSourceSystem, "System Button"},
    {"/user/hand/right/input/squeeze/value", 1, BindingKind::kScalar, 0xdd5935cc005136f1ULL, 0, kSourceSqueeze, "Squeeze"},
    {"/user/hand/right/input/trigger/value", 1, BindingKind::kScalar, 0xede7e982d5eedf21ULL, 0, kSourceTrigger, "Trigger"},
    {"/user/hand/right/input/trigger/touch", 1, BindingKind::kBinary, 0xe0a7e848dde340b0ULL, 0, kSourceTrigger, "Trigger"},
    {"/user/hand/right/input/thumbstick", 1, BindingKind::kVector2, 0xd7c23648f060c6dfULL, 0xcee8c338e02e0131ULL, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/right/input/thumbstick/x", 1, BindingKind::kScalar, 0xd7c23648f060c6dfULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/right/input/thumbstick/y", 1, BindingKind::kScalar, 0xcee8c338e02e0131ULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/right/input/thumbstick/click", 1, BindingKind::kBinary, 0x00ac9a92f4453d61ULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/right/input/thumbstick/touch", 1, BindingKind::kBinary, 0xef43fe49dfc87556ULL, 0, kSourceThumbstick, "Thumbstick"},
    {"/user/hand/right/input/thumbrest/touch", 1, BindingKind::kBinary, 0x947e5a8f8780c92dULL, 0, kSourceThumbrest, "Thumb Rest"},
    {"/user/hand/left/input/grip/pose", 0, BindingKind::kGripPose, 0, 0, kSourceGrip, "Grip Pose"},
    {"/user/hand/right/input/grip/pose", 1, BindingKind::kGripPose, 0, 0, kSourceGrip, "Grip Pose"},
    {"/user/hand/left/input/aim/pose", 0, BindingKind::kAimPose, 0, 0, kSourceAim, "Aim Pose"},
    {"/user/hand/right/input/aim/pose", 1, BindingKind::kAimPose, 0, 0, kSourceAim, "Aim Pose"},
    {"/user/hand/left/output/haptic", 0, BindingKind::kHaptic, 0, 0, kSourceHaptic, "Haptic"},
    {"/user/hand/right/output/haptic", 1, BindingKind::kHaptic, 0, 0, kSourceHaptic, "Haptic"},
};

SRWLOCK gInputLock = SRWLOCK_INIT;
uintptr_t gNextActionSetHandle = kFirstActionSetHandle;
uintptr_t gNextActionHandle = kFirstActionHandle;
std::array<ActionSetRecord, kMaxActionSets> gActionSets{};
std::array<ActionRecord, kMaxActions> gActions{};
std::array<TouchBindingRecord, kMaxTouchBindings> gTouchBindings{};
size_t gTouchBindingCount = 0;
XrPath gTouchProfilePath = XR_NULL_PATH;
XrPath gCurrentInteractionProfiles[2]{};
XrSession gAttachedSession = XR_NULL_HANDLE;

XrTime inputTimeNow() {
    LARGE_INTEGER counter{};
    LARGE_INTEGER frequency{};
    if (!QueryPerformanceCounter(&counter) || !QueryPerformanceFrequency(&frequency) ||
        frequency.QuadPart <= 0) {
        return static_cast<XrTime>(GetTickCount64()) * 1'000'000;
    }
    const int64_t seconds = counter.QuadPart / frequency.QuadPart;
    const int64_t remainder = counter.QuadPart % frequency.QuadPart;
    return static_cast<XrTime>(seconds) * 1'000'000'000 +
           static_cast<XrTime>((remainder * 1'000'000'000) / frequency.QuadPart);
}

const TouchSourceDefinition* findTouchSource(XrPath path) {
    for (const TouchSourceDefinition& source : kTouchSources) {
        if (basalt::pathStringEquals(path, source.path)) {
            return &source;
        }
    }
    return nullptr;
}

const InteractionProfileDefinition* findInteractionProfile(XrPath path) {
    for (const InteractionProfileDefinition& profile : kInteractionProfiles) {
        if (basalt::pathStringEquals(path, profile.path)) {
            return &profile;
        }
    }
    return nullptr;
}

bool profileAllowsBinding(
    const InteractionProfileDefinition& profile,
    XrPath bindingPath) {
    char fullPath[XR_MAX_PATH_LENGTH]{};
    for (size_t userIndex = 0; userIndex < profile.userPathCount; ++userIndex) {
        for (size_t componentIndex = 0;
             componentIndex < profile.componentCount;
             ++componentIndex) {
            const ProfileComponentDefinition& component =
                profile.components[componentIndex];
            if (component.userMask != 0 &&
                (component.userMask & (1u << userIndex)) == 0) {
                continue;
            }
            const int length = std::snprintf(
                fullPath, sizeof(fullPath), "%s%s",
                profile.userPaths[userIndex], component.subpath);
            if (length > 0 && static_cast<size_t>(length) < sizeof(fullPath) &&
                basalt::pathStringEquals(bindingPath, fullPath)) {
                return true;
            }
        }
    }
    return false;
}

int handForSubactionPath(XrPath path) {
    if (path == XR_NULL_PATH) {
        return -1;
    }
    if (basalt::pathStringEquals(path, "/user/hand/left")) {
        return 0;
    }
    if (basalt::pathStringEquals(path, "/user/hand/right")) {
        return 1;
    }
    return -2;
}

const basalt::ControlButtonState* findButton(
    const basalt::ControlInputSnapshot& snapshot,
    uint64_t pathId) {
    for (uint32_t index = 0; index < snapshot.buttonCount; ++index) {
        if (snapshot.buttons[index].pathId == pathId) {
            return &snapshot.buttons[index];
        }
    }
    return nullptr;
}

bool actionDeclaresSubaction(const ActionRecord& action, XrPath path) {
    if (path == XR_NULL_PATH) {
        return true;
    }
    for (uint32_t index = 0; index < action.subactionPathCount; ++index) {
        if (action.subactionPaths[index] == path) {
            return true;
        }
    }
    return false;
}

bool isNameCharacter(char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= '0' && character <= '9') ||
           character == '-' || character == '_' || character == '.';
}

// Names must be non-empty single path segments; localized names must be
// non-empty NUL-terminated strings.
bool isWellFormedName(const char* name, size_t maxSize) {
    if (std::memchr(name, '\0', maxSize) == nullptr || name[0] == '\0') {
        return false;
    }
    for (const char* character = name; *character != '\0'; ++character) {
        if (!isNameCharacter(*character)) {
            return false;
        }
    }
    return true;
}

bool isWellFormedLocalizedName(const char* name, size_t maxSize) {
    return std::memchr(name, '\0', maxSize) != nullptr && name[0] != '\0';
}

bool isSupportedActionType(XrActionType actionType) {
    return actionType == XR_ACTION_TYPE_BOOLEAN_INPUT ||
           actionType == XR_ACTION_TYPE_FLOAT_INPUT ||
           actionType == XR_ACTION_TYPE_VECTOR2F_INPUT ||
           actionType == XR_ACTION_TYPE_POSE_INPUT ||
           actionType == XR_ACTION_TYPE_VIBRATION_OUTPUT;
}

ActionSetRecord* findActionSetLocked(XrActionSet actionSet) {
    if (actionSet == XR_NULL_HANDLE) {
        return nullptr;
    }
    for (ActionSetRecord& record : gActionSets) {
        if (record.handleAlive && record.handle == actionSet) {
            return &record;
        }
    }
    return nullptr;
}

ActionSetRecord* findActionSetResourceLocked(XrActionSet actionSet) {
    if (actionSet == XR_NULL_HANDLE) {
        return nullptr;
    }
    for (ActionSetRecord& record : gActionSets) {
        if (record.handle == actionSet) {
            return &record;
        }
    }
    return nullptr;
}

ActionRecord* findActionLocked(XrAction action) {
    if (action == XR_NULL_HANDLE) {
        return nullptr;
    }
    for (ActionRecord& record : gActions) {
        if (record.handleAlive && record.handle == action) {
            return &record;
        }
    }
    return nullptr;
}

ActionRecord* findActionResourceLocked(XrAction action) {
    if (action == XR_NULL_HANDLE) {
        return nullptr;
    }
    for (ActionRecord& record : gActions) {
        if (record.handle == action) {
            return &record;
        }
    }
    return nullptr;
}

// Shared validation for the xrGetActionState* family and haptics: the action
// must exist, belong to a set attached to this session, match the queried
// type, and the subaction path must be XR_NULL_PATH or declared at creation.
XrResult validateActionQueryLocked(
    XrSession session,
    XrAction action,
    XrActionType expectedType,
    XrPath subactionPath) {
    const ActionRecord* record = findActionLocked(action);
    if (record == nullptr) {
        return XR_ERROR_HANDLE_INVALID;
    }
    const ActionSetRecord* actionSet = findActionSetLocked(record->actionSet);
    if (actionSet == nullptr || !actionSet->attached ||
        actionSet->attachedSession != session) {
        return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    }
    if (record->actionType != expectedType) {
        return XR_ERROR_ACTION_TYPE_MISMATCH;
    }
    if (subactionPath != XR_NULL_PATH) {
        if (!basalt::isKnownPath(subactionPath)) {
            return XR_ERROR_PATH_INVALID;
        }
        bool declared = false;
        for (uint32_t index = 0; index < record->subactionPathCount; ++index) {
            if (record->subactionPaths[index] == subactionPath) {
                declared = true;
                break;
            }
        }
        if (!declared) {
            return XR_ERROR_PATH_UNSUPPORTED;
        }
    }
    return XR_SUCCESS;
}

bool bindingCompatible(XrActionType actionType, BindingKind kind) {
    switch (actionType) {
    case XR_ACTION_TYPE_BOOLEAN_INPUT:
        return kind == BindingKind::kBinary || kind == BindingKind::kScalar;
    case XR_ACTION_TYPE_FLOAT_INPUT:
        return kind == BindingKind::kScalar || kind == BindingKind::kBinary;
    case XR_ACTION_TYPE_VECTOR2F_INPUT:
        return kind == BindingKind::kVector2;
    case XR_ACTION_TYPE_POSE_INPUT:
        return kind == BindingKind::kGripPose || kind == BindingKind::kAimPose;
    case XR_ACTION_TYPE_VIBRATION_OUTPUT:
        return kind == BindingKind::kHaptic;
    default:
        return false;
    }
}

SyncedActionState* stateForPath(ActionRecord* action, XrPath subactionPath) {
    const int hand = handForSubactionPath(subactionPath);
    if (hand == -1) {
        return &action->synced[0];
    }
    if (hand == 0 || hand == 1) {
        return &action->synced[hand + 1];
    }
    return nullptr;
}

bool bindingSelectedLocked(const TouchBindingRecord& binding) {
    const ActionRecord* action = findActionResourceLocked(binding.action);
    const ActionSetRecord* set = action == nullptr
        ? nullptr : findActionSetResourceLocked(action->actionSet);
    return action != nullptr && set != nullptr && set->attachedSession != XR_NULL_HANDLE &&
           binding.hand < 2 && bindingCompatible(action->actionType, binding.kind) &&
           action->synced[binding.hand + 1].selected;
}

void resolveBindingPrioritiesLocked() {
    for (size_t index = 0; index < gTouchBindingCount; ++index) {
        TouchBindingRecord& binding = gTouchBindings[index];
        binding.enabledAfterSync = false;
        if (!bindingSelectedLocked(binding)) {
            continue;
        }
        const ActionRecord* action = findActionResourceLocked(binding.action);
        const ActionSetRecord* set = findActionSetResourceLocked(action->actionSet);
        uint32_t maximumPriority = set->priority;
        for (size_t otherIndex = 0; otherIndex < gTouchBindingCount; ++otherIndex) {
            const TouchBindingRecord& other = gTouchBindings[otherIndex];
            if (other.hand != binding.hand ||
                other.sourceGroup != binding.sourceGroup ||
                !bindingSelectedLocked(other)) {
                continue;
            }
            const ActionRecord* otherAction = findActionResourceLocked(other.action);
            const ActionSetRecord* otherSet =
                findActionSetResourceLocked(otherAction->actionSet);
            maximumPriority = (std::max)(maximumPriority, otherSet->priority);
        }
        binding.enabledAfterSync = set->priority == maximumPriority;
    }
}

void syncOneState(
    ActionRecord& action,
    SyncedActionState& state,
    int requestedHand,
    const basalt::ControlInputSnapshot& snapshot,
    bool focused) {
    const bool wasActive = state.isActive;
    const bool oldBoolean = state.booleanValue;
    const float oldFloat = state.floatValue;
    const XrVector2f oldVector = state.vectorValue;
    const bool selected = state.selected;

    state.isActive = false;
    state.changed = false;
    state.booleanValue = false;
    state.floatValue = 0.0f;
    state.vectorValue = {0.0f, 0.0f};
    state.poseHand = UINT32_MAX;
    state.poseKind = BindingKind::kUnknown;
    if (!selected || !focused) {
        state.lastChangeTime = 0;
        return;
    }

    bool resolved = false;
    XrTime physicalChangeTime = state.lastChangeTime;
    for (size_t index = 0; index < gTouchBindingCount; ++index) {
        const TouchBindingRecord& binding = gTouchBindings[index];
        if (!binding.enabledAfterSync || binding.action != action.handle ||
            (requestedHand >= 0 && binding.hand != static_cast<uint32_t>(requestedHand)) ||
            (requestedHand < 0 &&
             (state.selectedHandMask & (1u << binding.hand)) == 0) ||
            !bindingCompatible(action.actionType, binding.kind)) {
            continue;
        }
        const basalt::ControlControllerState& controller =
            snapshot.controllers[binding.hand];
        if (!controller.profileActive || controller.profileId != kQuestTouchProfileId) {
            continue;
        }

        if (action.actionType == XR_ACTION_TYPE_POSE_INPUT) {
            // Aggregate actions choose the first currently tracked source.
            // A profile-only stale left hand must not mask a live right hand.
            if (controller.poseActive && !state.isActive) {
                state.poseHand = binding.hand;
                state.poseKind = binding.kind;
            }
            resolved = true;
            state.isActive = state.isActive || controller.poseActive;
            continue;
        }

        // ALVR button/profile state is retained, but it is only actionable
        // while the corresponding controller motion remains fresh.
        if (!controller.poseActive) {
            continue;
        }

        if (action.actionType == XR_ACTION_TYPE_BOOLEAN_INPUT) {
            const basalt::ControlButtonState* button =
                findButton(snapshot, binding.inputIdX);
            const bool value = button != nullptr &&
                basalt::controlButtonPressed(button->valueType, button->value);
            state.booleanValue = state.booleanValue || value;
            if (button != nullptr) {
                physicalChangeTime = (std::max)(physicalChangeTime,
                                                button->lastChangeTime);
            }
            resolved = true;
        } else if (action.actionType == XR_ACTION_TYPE_FLOAT_INPUT) {
            const basalt::ControlButtonState* button =
                findButton(snapshot, binding.inputIdX);
            const float value = button == nullptr ? 0.0f : button->value;
            if (!resolved || std::fabs(value) > std::fabs(state.floatValue)) {
                state.floatValue = value;
                if (button != nullptr) {
                    physicalChangeTime = button->lastChangeTime;
                }
            }
            resolved = true;
        } else if (action.actionType == XR_ACTION_TYPE_VECTOR2F_INPUT) {
            const basalt::ControlButtonState* x = findButton(snapshot, binding.inputIdX);
            const basalt::ControlButtonState* y = findButton(snapshot, binding.inputIdY);
            const XrVector2f value{x == nullptr ? 0.0f : x->value,
                                   y == nullptr ? 0.0f : y->value};
            const float oldLength = state.vectorValue.x * state.vectorValue.x +
                                    state.vectorValue.y * state.vectorValue.y;
            const float newLength = value.x * value.x + value.y * value.y;
            if (!resolved || newLength > oldLength) {
                state.vectorValue = value;
                physicalChangeTime = (std::max)(
                    x == nullptr ? 0 : x->lastChangeTime,
                    y == nullptr ? 0 : y->lastChangeTime);
            }
            resolved = true;
        }
    }
    if (action.actionType != XR_ACTION_TYPE_POSE_INPUT) {
        state.isActive = resolved;
    }

    if (!state.isActive) {
        state.lastChangeTime = 0;
        return;
    }
    if (!wasActive) {
        state.lastChangeTime = physicalChangeTime;
        return;
    }
    switch (action.actionType) {
    case XR_ACTION_TYPE_BOOLEAN_INPUT:
        state.changed = oldBoolean != state.booleanValue;
        break;
    case XR_ACTION_TYPE_FLOAT_INPUT:
        state.changed = oldFloat != state.floatValue;
        break;
    case XR_ACTION_TYPE_VECTOR2F_INPUT:
        state.changed = oldVector.x != state.vectorValue.x ||
                        oldVector.y != state.vectorValue.y;
        break;
    default:
        break;
    }
    if (state.changed) {
        state.lastChangeTime = physicalChangeTime > 0
            ? physicalChangeTime : inputTimeNow();
    }
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL createActionSet(
    XrInstance instance,
    const XrActionSetCreateInfo* createInfo,
    XrActionSet* actionSet) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (actionSet == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *actionSet = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_ACTION_SET_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!isWellFormedName(createInfo->actionSetName, XR_MAX_ACTION_SET_NAME_SIZE)) {
        return XR_ERROR_NAME_INVALID;
    }
    if (!isWellFormedLocalizedName(
            createInfo->localizedActionSetName,
            XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE)) {
        return XR_ERROR_LOCALIZED_NAME_INVALID;
    }

    AcquireSRWLockExclusive(&gInputLock);
    ActionSetRecord* available = nullptr;
    for (ActionSetRecord& record : gActionSets) {
        if (record.handle == XR_NULL_HANDLE) {
            if (available == nullptr) {
                available = &record;
            }
            continue;
        }
        if (!record.handleAlive) {
            continue;
        }
        if (std::strcmp(record.name, createInfo->actionSetName) == 0) {
            ReleaseSRWLockExclusive(&gInputLock);
            return XR_ERROR_NAME_DUPLICATED;
        }
        if (std::strcmp(record.localizedName, createInfo->localizedActionSetName) == 0) {
            ReleaseSRWLockExclusive(&gInputLock);
            return XR_ERROR_LOCALIZED_NAME_DUPLICATED;
        }
    }
    if (available == nullptr ||
        gNextActionSetHandle > UINTPTR_MAX - kInputHandleStride) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_LIMIT_REACHED;
    }

    available->handle = reinterpret_cast<XrActionSet>(gNextActionSetHandle);
    available->handleAlive = true;
    gNextActionSetHandle += kInputHandleStride;
    available->instance = instance;
    std::strcpy(available->name, createInfo->actionSetName);
    std::strcpy(available->localizedName, createInfo->localizedActionSetName);
    available->priority = createInfo->priority;
    available->attached = false;
    available->attachedSession = XR_NULL_HANDLE;
    *actionSet = available->handle;
    ReleaseSRWLockExclusive(&gInputLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroyActionSet(XrActionSet actionSet) {
    if (actionSet == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gInputLock);
    ActionSetRecord* record = findActionSetLocked(actionSet);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    for (ActionRecord& action : gActions) {
        if (action.actionSet == actionSet) {
            action.handleAlive = false;
        }
    }
    record->handleAlive = false;
    ReleaseSRWLockExclusive(&gInputLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createAction(
    XrActionSet actionSet,
    const XrActionCreateInfo* createInfo,
    XrAction* action) {
    if (action == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *action = XR_NULL_HANDLE;
    if (actionSet == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (createInfo == nullptr || createInfo->type != XR_TYPE_ACTION_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!isWellFormedName(createInfo->actionName, XR_MAX_ACTION_NAME_SIZE)) {
        return XR_ERROR_NAME_INVALID;
    }
    if (!isWellFormedLocalizedName(
            createInfo->localizedActionName,
            XR_MAX_LOCALIZED_ACTION_NAME_SIZE)) {
        return XR_ERROR_LOCALIZED_NAME_INVALID;
    }
    if (!isSupportedActionType(createInfo->actionType)) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->countSubactionPaths > 0 && createInfo->subactionPaths == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->countSubactionPaths > kMaxSubactionPaths) {
        return XR_ERROR_PATH_UNSUPPORTED;
    }
    for (uint32_t index = 0; index < createInfo->countSubactionPaths; ++index) {
        const XrPath path = createInfo->subactionPaths[index];
        if (!isKnownPath(path)) {
            return XR_ERROR_PATH_INVALID;
        }
        if (!isTopLevelUserPath(path)) {
            return XR_ERROR_PATH_UNSUPPORTED;
        }
        for (uint32_t previous = 0; previous < index; ++previous) {
            if (createInfo->subactionPaths[previous] == path) {
                return XR_ERROR_PATH_UNSUPPORTED;
            }
        }
    }

    AcquireSRWLockExclusive(&gInputLock);
    ActionSetRecord* setRecord = findActionSetLocked(actionSet);
    if (setRecord == nullptr) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (setRecord->attached) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
    }

    ActionRecord* available = nullptr;
    for (ActionRecord& record : gActions) {
        if (record.handle == XR_NULL_HANDLE) {
            if (available == nullptr) {
                available = &record;
            }
            continue;
        }
        if (!record.handleAlive) {
            continue;
        }
        if (record.actionSet != actionSet) {
            continue;
        }
        if (std::strcmp(record.name, createInfo->actionName) == 0) {
            ReleaseSRWLockExclusive(&gInputLock);
            return XR_ERROR_NAME_DUPLICATED;
        }
        if (std::strcmp(record.localizedName, createInfo->localizedActionName) == 0) {
            ReleaseSRWLockExclusive(&gInputLock);
            return XR_ERROR_LOCALIZED_NAME_DUPLICATED;
        }
    }
    if (available == nullptr ||
        gNextActionHandle > UINTPTR_MAX - kInputHandleStride) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_LIMIT_REACHED;
    }

    available->handle = reinterpret_cast<XrAction>(gNextActionHandle);
    available->handleAlive = true;
    gNextActionHandle += kInputHandleStride;
    available->actionSet = actionSet;
    std::strcpy(available->name, createInfo->actionName);
    std::strcpy(available->localizedName, createInfo->localizedActionName);
    available->actionType = createInfo->actionType;
    available->subactionPathCount = createInfo->countSubactionPaths;
    for (uint32_t index = 0; index < createInfo->countSubactionPaths; ++index) {
        available->subactionPaths[index] = createInfo->subactionPaths[index];
    }
    *action = available->handle;
    ReleaseSRWLockExclusive(&gInputLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroyAction(XrAction action) {
    if (action == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gInputLock);
    ActionRecord* record = findActionLocked(action);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    record->handleAlive = false;
    ReleaseSRWLockExclusive(&gInputLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL suggestInteractionProfileBindings(
    XrInstance instance,
    const XrInteractionProfileSuggestedBinding* suggestedBindings) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (suggestedBindings == nullptr ||
        suggestedBindings->type != XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING ||
        suggestedBindings->countSuggestedBindings == 0 ||
        suggestedBindings->suggestedBindings == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!isKnownPath(suggestedBindings->interactionProfile)) {
        return XR_ERROR_PATH_INVALID;
    }
    const InteractionProfileDefinition* profile =
        findInteractionProfile(suggestedBindings->interactionProfile);
    if (profile == nullptr) {
        return XR_ERROR_PATH_UNSUPPORTED;
    }

    AcquireSRWLockShared(&gInputLock);
    XrResult result = XR_SUCCESS;
    for (uint32_t index = 0;
         index < suggestedBindings->countSuggestedBindings && XR_SUCCEEDED(result);
         ++index) {
        const XrActionSuggestedBinding& binding =
            suggestedBindings->suggestedBindings[index];
        const ActionRecord* action = findActionLocked(binding.action);
        if (action == nullptr) {
            result = XR_ERROR_HANDLE_INVALID;
            break;
        }
        const ActionSetRecord* actionSet = findActionSetLocked(action->actionSet);
        if (actionSet != nullptr && actionSet->attached) {
            result = XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
            break;
        }
        if (!isKnownPath(binding.binding)) {
            result = XR_ERROR_PATH_INVALID;
        } else if (!profileAllowsBinding(*profile, binding.binding)) {
            result = XR_ERROR_PATH_UNSUPPORTED;
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result) ||
        !pathStringEquals(
            suggestedBindings->interactionProfile,
            "/interaction_profiles/oculus/touch_controller")) {
        return result;
    }
    if (suggestedBindings->countSuggestedBindings > kMaxTouchBindings) {
        return XR_ERROR_LIMIT_REACHED;
    }

    std::array<TouchBindingRecord, kMaxTouchBindings> replacements{};
    for (uint32_t index = 0; index < suggestedBindings->countSuggestedBindings; ++index) {
        const XrActionSuggestedBinding& suggestion =
            suggestedBindings->suggestedBindings[index];
        const TouchSourceDefinition* source = findTouchSource(suggestion.binding);
        if (source == nullptr) {
            return XR_ERROR_PATH_UNSUPPORTED;
        }
        replacements[index] = {
            suggestion.action,
            suggestion.binding,
            source->hand,
            source->kind,
            source->inputIdX,
            source->inputIdY,
            source->sourceGroup,
            false,
        };
    }

    AcquireSRWLockExclusive(&gInputLock);
    for (uint32_t index = 0; index < suggestedBindings->countSuggestedBindings; ++index) {
        const ActionRecord* action = findActionLocked(replacements[index].action);
        const ActionSetRecord* set =
            action == nullptr ? nullptr : findActionSetLocked(action->actionSet);
        if (action == nullptr || set == nullptr) {
            result = XR_ERROR_HANDLE_INVALID;
            break;
        }
        if (set->attached) {
            result = XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
            break;
        }
    }
    if (XR_SUCCEEDED(result)) {
        gTouchBindings = replacements;
        gTouchBindingCount = suggestedBindings->countSuggestedBindings;
        gTouchProfilePath = suggestedBindings->interactionProfile;
    }
    ReleaseSRWLockExclusive(&gInputLock);
    return result;
}

XrResult XRAPI_CALL attachSessionActionSets(
    XrSession session,
    const XrSessionActionSetsAttachInfo* attachInfo) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (attachInfo == nullptr ||
        attachInfo->type != XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO ||
        attachInfo->countActionSets == 0 || attachInfo->actionSets == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gInputLock);
    // xrDestroySession invalidates input attachments while holding this lock.
    // Recheck after acquiring it so a destroyed session cannot gain a new
    // attachment between the initial validation and the commit below.
    if (!isValidSession(session)) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (gAttachedSession == session) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
    }
    for (uint32_t index = 0; index < attachInfo->countActionSets; ++index) {
        const ActionSetRecord* record =
            findActionSetLocked(attachInfo->actionSets[index]);
        if (record == nullptr) {
            ReleaseSRWLockExclusive(&gInputLock);
            return XR_ERROR_HANDLE_INVALID;
        }
        // Attachment is permanent for the life of the action set, even after
        // its session is destroyed; a duplicate handle in this call is
        // harmless and behaves like a single occurrence.
        if (record->attached) {
            ReleaseSRWLockExclusive(&gInputLock);
            return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
        }
    }

    gAttachedSession = session;
    for (uint32_t index = 0; index < attachInfo->countActionSets; ++index) {
        ActionSetRecord* record = findActionSetLocked(attachInfo->actionSets[index]);
        record->attached = true;
        record->attachedSession = session;
    }
    ReleaseSRWLockExclusive(&gInputLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getCurrentInteractionProfile(
    XrSession session,
    XrPath topLevelUserPath,
    XrInteractionProfileState* interactionProfile) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (interactionProfile == nullptr ||
        interactionProfile->type != XR_TYPE_INTERACTION_PROFILE_STATE) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    const bool attached = gAttachedSession == session;
    const int hand = handForSubactionPath(topLevelUserPath);
    const XrPath currentProfile = hand >= 0 ? gCurrentInteractionProfiles[hand]
                                             : XR_NULL_PATH;
    ReleaseSRWLockShared(&gInputLock);
    if (!attached) {
        return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    }
    if (!isKnownPath(topLevelUserPath)) {
        return XR_ERROR_PATH_INVALID;
    }
    if (!isTopLevelUserPath(topLevelUserPath)) {
        return XR_ERROR_PATH_UNSUPPORTED;
    }

    interactionProfile->interactionProfile = currentProfile;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL syncActions(
    XrSession session,
    const XrActionsSyncInfo* syncInfo) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (syncInfo == nullptr || syncInfo->type != XR_TYPE_ACTIONS_SYNC_INFO ||
        (syncInfo->countActiveActionSets > 0 && syncInfo->activeActionSets == nullptr)) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    XrResult result = XR_SUCCESS;
    for (uint32_t index = 0;
         index < syncInfo->countActiveActionSets && XR_SUCCEEDED(result);
         ++index) {
        const XrActiveActionSet& active = syncInfo->activeActionSets[index];
        const ActionSetRecord* record = findActionSetLocked(active.actionSet);
        if (record == nullptr) {
            result = XR_ERROR_HANDLE_INVALID;
            break;
        }
        if (!record->attached || record->attachedSession != session) {
            result = XR_ERROR_ACTIONSET_NOT_ATTACHED;
            break;
        }
        if (active.subactionPath == XR_NULL_PATH) {
            continue;
        }
        if (!isKnownPath(active.subactionPath)) {
            result = XR_ERROR_PATH_INVALID;
            break;
        }
        bool declared = false;
        for (const ActionRecord& action : gActions) {
            if (action.handle == XR_NULL_HANDLE ||
                action.actionSet != active.actionSet) {
                continue;
            }
            for (uint32_t path = 0; path < action.subactionPathCount; ++path) {
                if (action.subactionPaths[path] == active.subactionPath) {
                    declared = true;
                    break;
                }
            }
            if (declared) {
                break;
            }
        }
        if (!declared) {
            result = XR_ERROR_PATH_UNSUPPORTED;
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    basalt::ControlInputSnapshot snapshot{};
    controlInputSnapshot(session, &snapshot);
    const bool focused = isSessionFocused(session);

    AcquireSRWLockExclusive(&gInputLock);
    if (gAttachedSession != session) {
        ReleaseSRWLockExclusive(&gInputLock);
        return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    }
    for (ActionRecord& action : gActions) {
        for (SyncedActionState& state : action.synced) {
            state.selected = false;
            state.selectedHandMask = 0;
        }
    }
    for (uint32_t index = 0; index < syncInfo->countActiveActionSets; ++index) {
        const XrActiveActionSet& active = syncInfo->activeActionSets[index];
        const int selectedHand = handForSubactionPath(active.subactionPath);
        for (ActionRecord& action : gActions) {
            if (action.handle == XR_NULL_HANDLE || action.actionSet != active.actionSet) {
                continue;
            }
            if (!actionDeclaresSubaction(action, active.subactionPath)) {
                continue;
            }
            SyncedActionState& aggregate = action.synced[0];
            aggregate.selected = true;
            aggregate.selectedHandMask |= selectedHand == -1
                ? 3u : selectedHand >= 0
                    ? 1u << static_cast<uint32_t>(selectedHand) : 0u;
            if (selectedHand >= 0) {
                action.synced[selectedHand + 1].selected = true;
                action.synced[selectedHand + 1].selectedHandMask =
                    1u << static_cast<uint32_t>(selectedHand);
            } else if (selectedHand == -1) {
                action.synced[1].selected = true;
                action.synced[1].selectedHandMask = 1;
                action.synced[2].selected = true;
                action.synced[2].selectedHandMask = 2;
            }
        }
    }

    resolveBindingPrioritiesLocked();

    for (ActionRecord& action : gActions) {
        if (action.handle == XR_NULL_HANDLE) {
            continue;
        }
        const ActionSetRecord* set = findActionSetLocked(action.actionSet);
        if (set == nullptr || set->attachedSession != session) {
            continue;
        }
        syncOneState(action, action.synced[0], -1, snapshot, focused);
        syncOneState(action, action.synced[1], 0, snapshot, focused);
        syncOneState(action, action.synced[2], 1, snapshot, focused);
    }
    bool interactionProfileChanged = false;
    for (uint32_t handIndex = 0; handIndex < 2; ++handIndex) {
        const basalt::ControlControllerState& controller =
            snapshot.controllers[handIndex];
        const XrPath nextProfile =
            gTouchProfilePath != XR_NULL_PATH && controller.profileActive &&
                    controller.profileId == kQuestTouchProfileId
                ? gTouchProfilePath
                : XR_NULL_PATH;
        interactionProfileChanged = interactionProfileChanged ||
            gCurrentInteractionProfiles[handIndex] != nextProfile;
        gCurrentInteractionProfiles[handIndex] = nextProfile;
    }
    ReleaseSRWLockExclusive(&gInputLock);
    if (interactionProfileChanged) {
        queueInteractionProfileChanged(session);
    }
    return focused ? XR_SUCCESS : XR_SESSION_NOT_FOCUSED;
}

XrResult XRAPI_CALL getActionStateBoolean(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStateBoolean* state) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (getInfo == nullptr || getInfo->type != XR_TYPE_ACTION_STATE_GET_INFO ||
        state == nullptr || state->type != XR_TYPE_ACTION_STATE_BOOLEAN) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    const XrResult result = validateActionQueryLocked(
        session, getInfo->action, XR_ACTION_TYPE_BOOLEAN_INPUT, getInfo->subactionPath);
    SyncedActionState synced{};
    if (XR_SUCCEEDED(result)) {
        ActionRecord* action = findActionLocked(getInfo->action);
        const SyncedActionState* selected = stateForPath(action, getInfo->subactionPath);
        if (selected != nullptr) { synced = *selected; }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    const bool active = synced.isActive && isSessionFocused(session);
    state->currentState = active && synced.booleanValue ? XR_TRUE : XR_FALSE;
    state->changedSinceLastSync = active && synced.changed ? XR_TRUE : XR_FALSE;
    state->lastChangeTime = active ? synced.lastChangeTime : 0;
    state->isActive = active ? XR_TRUE : XR_FALSE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getActionStateFloat(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStateFloat* state) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (getInfo == nullptr || getInfo->type != XR_TYPE_ACTION_STATE_GET_INFO ||
        state == nullptr || state->type != XR_TYPE_ACTION_STATE_FLOAT) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    const XrResult result = validateActionQueryLocked(
        session, getInfo->action, XR_ACTION_TYPE_FLOAT_INPUT, getInfo->subactionPath);
    SyncedActionState synced{};
    if (XR_SUCCEEDED(result)) {
        ActionRecord* action = findActionLocked(getInfo->action);
        const SyncedActionState* selected = stateForPath(action, getInfo->subactionPath);
        if (selected != nullptr) { synced = *selected; }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    const bool active = synced.isActive && isSessionFocused(session);
    state->currentState = active ? synced.floatValue : 0.0f;
    state->changedSinceLastSync = active && synced.changed ? XR_TRUE : XR_FALSE;
    state->lastChangeTime = active ? synced.lastChangeTime : 0;
    state->isActive = active ? XR_TRUE : XR_FALSE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getActionStateVector2f(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStateVector2f* state) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (getInfo == nullptr || getInfo->type != XR_TYPE_ACTION_STATE_GET_INFO ||
        state == nullptr || state->type != XR_TYPE_ACTION_STATE_VECTOR2F) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    const XrResult result = validateActionQueryLocked(
        session, getInfo->action, XR_ACTION_TYPE_VECTOR2F_INPUT, getInfo->subactionPath);
    SyncedActionState synced{};
    if (XR_SUCCEEDED(result)) {
        ActionRecord* action = findActionLocked(getInfo->action);
        const SyncedActionState* selected = stateForPath(action, getInfo->subactionPath);
        if (selected != nullptr) { synced = *selected; }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    const bool active = synced.isActive && isSessionFocused(session);
    state->currentState = active ? synced.vectorValue : XrVector2f{0.0f, 0.0f};
    state->changedSinceLastSync = active && synced.changed ? XR_TRUE : XR_FALSE;
    state->lastChangeTime = active ? synced.lastChangeTime : 0;
    state->isActive = active ? XR_TRUE : XR_FALSE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getActionStatePose(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStatePose* state) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (getInfo == nullptr || getInfo->type != XR_TYPE_ACTION_STATE_GET_INFO ||
        state == nullptr || state->type != XR_TYPE_ACTION_STATE_POSE) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    const XrResult result = validateActionQueryLocked(
        session, getInfo->action, XR_ACTION_TYPE_POSE_INPUT, getInfo->subactionPath);
    SyncedActionState synced{};
    if (XR_SUCCEEDED(result)) {
        ActionRecord* action = findActionLocked(getInfo->action);
        const SyncedActionState* selected = stateForPath(action, getInfo->subactionPath);
        if (selected != nullptr) { synced = *selected; }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    state->isActive = synced.isActive && isSessionFocused(session) ? XR_TRUE : XR_FALSE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL enumerateBoundSourcesForAction(
    XrSession session,
    const XrBoundSourcesForActionEnumerateInfo* enumerateInfo,
    uint32_t sourceCapacityInput,
    uint32_t* sourceCountOutput,
    XrPath* sources) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (enumerateInfo == nullptr ||
        enumerateInfo->type != XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO ||
        sourceCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (sourceCapacityInput > 0 && sources == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gInputLock);
    const ActionRecord* action = findActionLocked(enumerateInfo->action);
    XrResult result = XR_SUCCESS;
    std::array<XrPath, kMaxTouchBindings> resolvedSources{};
    uint32_t resolvedCount = 0;
    if (action == nullptr) {
        result = XR_ERROR_HANDLE_INVALID;
    } else {
        const ActionSetRecord* actionSet = findActionSetLocked(action->actionSet);
        if (actionSet == nullptr || !actionSet->attached ||
            actionSet->attachedSession != session) {
            result = XR_ERROR_ACTIONSET_NOT_ATTACHED;
        } else {
            for (size_t index = 0; index < gTouchBindingCount; ++index) {
                const TouchBindingRecord& binding = gTouchBindings[index];
                if (!binding.enabledAfterSync || binding.action != action->handle ||
                    !bindingCompatible(action->actionType, binding.kind) ||
                    gCurrentInteractionProfiles[binding.hand] == XR_NULL_PATH) {
                    continue;
                }
                bool duplicate = false;
                for (uint32_t previous = 0; previous < resolvedCount; ++previous) {
                    if (resolvedSources[previous] == binding.sourcePath) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    resolvedSources[resolvedCount++] = binding.sourcePath;
                }
            }
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    *sourceCountOutput = resolvedCount;
    if (sourceCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (sourceCapacityInput < resolvedCount) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (uint32_t index = 0; index < resolvedCount; ++index) {
        sources[index] = resolvedSources[index];
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getInputSourceLocalizedName(
    XrSession session,
    const XrInputSourceLocalizedNameGetInfo* getInfo,
    uint32_t bufferCapacityInput,
    uint32_t* bufferCountOutput,
    char* buffer) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    constexpr XrInputSourceLocalizedNameFlags kKnownNameFlags =
        XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT |
        XR_INPUT_SOURCE_LOCALIZED_NAME_INTERACTION_PROFILE_BIT |
        XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT;
    if (getInfo == nullptr ||
        getInfo->type != XR_TYPE_INPUT_SOURCE_LOCALIZED_NAME_GET_INFO ||
        getInfo->whichComponents == 0 ||
        (getInfo->whichComponents & ~kKnownNameFlags) != 0 ||
        bufferCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (bufferCapacityInput > 0 && buffer == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (!isKnownPath(getInfo->sourcePath)) {
        return XR_ERROR_PATH_INVALID;
    }
    const TouchSourceDefinition* source = findTouchSource(getInfo->sourcePath);

    AcquireSRWLockShared(&gInputLock);
    const bool attached = gAttachedSession == session;
    bool resolved = false;
    if (attached && source != nullptr &&
        gCurrentInteractionProfiles[source->hand] != XR_NULL_PATH) {
        for (size_t index = 0; index < gTouchBindingCount; ++index) {
            const TouchBindingRecord& binding = gTouchBindings[index];
            if (binding.enabledAfterSync &&
                binding.sourcePath == getInfo->sourcePath &&
                binding.hand == source->hand) {
                resolved = true;
                break;
            }
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (!attached) {
        return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    }
    if (!resolved) {
        *bufferCountOutput = 0;
        return XR_ERROR_PATH_UNSUPPORTED;
    }

    const char* parts[3]{};
    size_t partCount = 0;
    if ((getInfo->whichComponents &
         XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT) != 0) {
        parts[partCount++] = source->hand == 0 ? "Left Hand" : "Right Hand";
    }
    if ((getInfo->whichComponents &
         XR_INPUT_SOURCE_LOCALIZED_NAME_INTERACTION_PROFILE_BIT) != 0) {
        parts[partCount++] = "Oculus Touch Controller";
    }
    if ((getInfo->whichComponents &
         XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT) != 0) {
        parts[partCount++] = source->localizedComponent;
    }

    char localized[256]{};
    size_t used = 0;
    for (size_t index = 0; index < partCount; ++index) {
        const int written = std::snprintf(
            localized + used, sizeof(localized) - used,
            "%s%s", index == 0 ? "" : " ", parts[index]);
        if (written < 0 || static_cast<size_t>(written) >= sizeof(localized) - used) {
            return XR_ERROR_RUNTIME_FAILURE;
        }
        used += static_cast<size_t>(written);
    }
    const uint32_t required = static_cast<uint32_t>(used + 1);
    *bufferCountOutput = required;
    if (bufferCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (bufferCapacityInput < required) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    std::memcpy(buffer, localized, required);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL applyHapticFeedback(
    XrSession session,
    const XrHapticActionInfo* hapticActionInfo,
    const XrHapticBaseHeader* hapticFeedback) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (hapticActionInfo == nullptr ||
        hapticActionInfo->type != XR_TYPE_HAPTIC_ACTION_INFO ||
        hapticFeedback == nullptr || hapticFeedback->type != XR_TYPE_HAPTIC_VIBRATION) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    const auto* vibration = reinterpret_cast<const XrHapticVibration*>(hapticFeedback);
    if (vibration->duration < XR_MIN_HAPTIC_DURATION ||
        !std::isfinite(vibration->frequency) || vibration->frequency < 0.0f ||
        !std::isfinite(vibration->amplitude) ||
        vibration->amplitude < 0.0f || vibration->amplitude > 1.0f) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    basalt::ControlInputSnapshot input{};
    controlInputSnapshot(session, &input);
    bool hands[2]{};
    AcquireSRWLockShared(&gInputLock);
    const XrResult result = validateActionQueryLocked(
        session,
        hapticActionInfo->action,
        XR_ACTION_TYPE_VIBRATION_OUTPUT,
        hapticActionInfo->subactionPath);
    if (XR_SUCCEEDED(result)) {
        const int requestedHand = handForSubactionPath(hapticActionInfo->subactionPath);
        for (size_t index = 0; index < gTouchBindingCount; ++index) {
            const TouchBindingRecord& binding = gTouchBindings[index];
            if (binding.enabledAfterSync &&
                binding.action == hapticActionInfo->action &&
                binding.kind == BindingKind::kHaptic &&
                (requestedHand == -1 ||
                 (requestedHand >= 0 &&
                  binding.hand == static_cast<uint32_t>(requestedHand))) &&
                gCurrentInteractionProfiles[binding.hand] != XR_NULL_PATH &&
                input.controllers[binding.hand].profileActive &&
                input.controllers[binding.hand].profileId == kQuestTouchProfileId) {
                hands[binding.hand] = true;
            }
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    if (!isSessionFocused(session)) {
        return XR_SESSION_NOT_FOCUSED;
    }
    const uint64_t duration = vibration->duration == XR_MIN_HAPTIC_DURATION
        ? 20'000'000ULL : static_cast<uint64_t>(vibration->duration);
    for (uint32_t hand = 0; hand < 2; ++hand) {
        if (hands[hand]) {
            controlSendHaptic(
                session, static_cast<ControlHand>(hand), duration,
                vibration->frequency, vibration->amplitude);
        }
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL stopHapticFeedback(
    XrSession session,
    const XrHapticActionInfo* hapticActionInfo) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (hapticActionInfo == nullptr ||
        hapticActionInfo->type != XR_TYPE_HAPTIC_ACTION_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    basalt::ControlInputSnapshot input{};
    controlInputSnapshot(session, &input);
    bool hands[2]{};
    AcquireSRWLockShared(&gInputLock);
    const XrResult result = validateActionQueryLocked(
        session,
        hapticActionInfo->action,
        XR_ACTION_TYPE_VIBRATION_OUTPUT,
        hapticActionInfo->subactionPath);
    if (XR_SUCCEEDED(result)) {
        const int requestedHand = handForSubactionPath(hapticActionInfo->subactionPath);
        for (size_t index = 0; index < gTouchBindingCount; ++index) {
            const TouchBindingRecord& binding = gTouchBindings[index];
            if (binding.enabledAfterSync &&
                binding.action == hapticActionInfo->action &&
                binding.kind == BindingKind::kHaptic &&
                (requestedHand == -1 ||
                 (requestedHand >= 0 &&
                  binding.hand == static_cast<uint32_t>(requestedHand))) &&
                gCurrentInteractionProfiles[binding.hand] != XR_NULL_PATH &&
                input.controllers[binding.hand].profileActive &&
                input.controllers[binding.hand].profileId == kQuestTouchProfileId) {
                hands[binding.hand] = true;
            }
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (XR_FAILED(result)) {
        return result;
    }

    if (!isSessionFocused(session)) {
        return XR_SESSION_NOT_FOCUSED;
    }
    for (uint32_t hand = 0; hand < 2; ++hand) {
        if (hands[hand]) {
            controlSendHaptic(
                session, static_cast<ControlHand>(hand), 0, 0.0f, 0.0f);
        }
    }
    return XR_SUCCESS;
}

bool getActionForSpace(
    XrAction action,
    XrActionType* actionType,
    bool* allowsSubactionPath,
    XrPath subactionPath) {
    AcquireSRWLockShared(&gInputLock);
    const ActionRecord* record = findActionLocked(action);
    bool found = false;
    if (record != nullptr) {
        found = true;
        if (actionType != nullptr) {
            *actionType = record->actionType;
        }
        if (allowsSubactionPath != nullptr) {
            bool declared = subactionPath == XR_NULL_PATH;
            for (uint32_t index = 0;
                 !declared && index < record->subactionPathCount;
                 ++index) {
                declared = record->subactionPaths[index] == subactionPath;
            }
            *allowsSubactionPath = declared;
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    return found;
}

bool getActionPoseSource(
    XrSession session,
    XrAction action,
    XrPath subactionPath,
    uint32_t* hand,
    bool* aimPose) {
    if (hand == nullptr || aimPose == nullptr) {
        return false;
    }
    AcquireSRWLockShared(&gInputLock);
    const ActionRecord* record = findActionResourceLocked(action);
    bool available = false;
    if (record != nullptr && record->actionType == XR_ACTION_TYPE_POSE_INPUT) {
        const ActionSetRecord* set = findActionSetResourceLocked(record->actionSet);
        ActionRecord* mutableRecord = const_cast<ActionRecord*>(record);
        const SyncedActionState* state = stateForPath(mutableRecord, subactionPath);
        if (set != nullptr && set->attachedSession == session && state != nullptr &&
            state->selected && state->isActive && state->poseHand < 2 &&
            (state->poseKind == BindingKind::kGripPose ||
             state->poseKind == BindingKind::kAimPose)) {
            *hand = state->poseHand;
            *aimPose = state->poseKind == BindingKind::kAimPose;
            available = true;
        }
    }
    ReleaseSRWLockShared(&gInputLock);
    if (!available || !isSessionFocused(session)) {
        return false;
    }
    basalt::ControlInputSnapshot snapshot{};
    return basalt::controlInputSnapshot(session, &snapshot) && *hand < 2 &&
           snapshot.controllers[*hand].poseActive;
}

void invalidateInputForSession(XrSession session) {
    AcquireSRWLockExclusive(&gInputLock);
    if (gAttachedSession == session) {
        gAttachedSession = XR_NULL_HANDLE;
        gCurrentInteractionProfiles[0] = XR_NULL_PATH;
        gCurrentInteractionProfiles[1] = XR_NULL_PATH;
    }
    for (ActionSetRecord& record : gActionSets) {
        if (record.attachedSession == session) {
            // A destroyed session releases its attachment. OpenComposite
            // rebuilds its session once it learns the application's graphics
            // API (XrBackend::CheckOrInitCompositors) and re-attaches the same
            // action sets; keeping `attached` set made that second attach fail
            // with XR_ERROR_ACTIONSETS_ALREADY_ATTACHED, which OpenComposite
            // treats as fatal. Real runtimes accept the re-attach.
            record.attached = false;
            record.attachedSession = XR_NULL_HANDLE;
        }
    }
    ReleaseSRWLockExclusive(&gInputLock);
}

void invalidateInputForInstance(XrInstance instance) {
    AcquireSRWLockExclusive(&gInputLock);
    // Only one instance is ever live, so any attached session belonged to it;
    // clearing unconditionally also covers sets destroyed before the instance.
    gAttachedSession = XR_NULL_HANDLE;
    gTouchBindingCount = 0;
    gTouchProfilePath = XR_NULL_PATH;
    gCurrentInteractionProfiles[0] = XR_NULL_PATH;
    gCurrentInteractionProfiles[1] = XR_NULL_PATH;
    gTouchBindings = {};
    for (ActionSetRecord& setRecord : gActionSets) {
        if (setRecord.instance != instance) {
            continue;
        }
        for (ActionRecord& action : gActions) {
            if (action.actionSet == setRecord.handle) {
                action = {};
            }
        }
        setRecord = {};
    }
    ReleaseSRWLockExclusive(&gInputLock);
}

}  // namespace basalt
