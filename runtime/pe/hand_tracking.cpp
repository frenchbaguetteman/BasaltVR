#include "runtime.hpp"

#include <windows.h>

#include <array>
#include <cstdint>

#include "control.hpp"
#include "pose_math.hpp"

// XR_EXT_hand_tracking over the streamer's HAND_SKELETON messages.
//
// OpenComposite creates both trackers right after xrAttachSessionActionSets,
// locates joints every frame against the grip action space (or STAGE), and
// aborts the game on any failed XrResult. It never destroys its trackers
// before xrDestroySession and ignores xrDestroyHandTrackerEXT results. So a
// well-formed call always succeeds: a hand that cannot be located right now
// is isActive = XR_FALSE, never an error.

namespace {

using basalt::identityPose;
using basalt::poseCompose;
using basalt::poseInvert;

constexpr uintptr_t kFirstHandTrackerHandle = static_cast<uintptr_t>(0x70000);
constexpr uintptr_t kHandTrackerHandleStride = static_cast<uintptr_t>(0x10);
constexpr size_t kMaxHandTrackers = 16;
constexpr uint32_t kJointCount = XR_HAND_JOINT_COUNT_EXT;
static_assert(kJointCount == basalt::kControlHandJointCount, "joint count");

struct HandTrackerRecord {
    XrHandTrackerEXT handle = XR_NULL_HANDLE;
    XrSession session = XR_NULL_HANDLE;
    uint32_t hand = 0;  // 0 left, 1 right
};

SRWLOCK gHandTrackerLock = SRWLOCK_INIT;
uintptr_t gNextHandTrackerHandle = kFirstHandTrackerHandle;
std::array<HandTrackerRecord, kMaxHandTrackers> gHandTrackers{};

HandTrackerRecord* findHandTrackerLocked(XrHandTrackerEXT handTracker) {
    if (handTracker == XR_NULL_HANDLE) {
        return nullptr;
    }
    for (HandTrackerRecord& record : gHandTrackers) {
        if (record.handle == handTracker) {
            return &record;
        }
    }
    return nullptr;
}

XrHandJointVelocitiesEXT* findChainedVelocities(void* next) {
    auto* structure = static_cast<XrBaseOutStructure*>(next);
    while (structure != nullptr) {
        if (structure->type == XR_TYPE_HAND_JOINT_VELOCITIES_EXT) {
            return reinterpret_cast<XrHandJointVelocitiesEXT*>(structure);
        }
        structure = structure->next;
    }
    return nullptr;
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL createHandTracker(
    XrSession session,
    const XrHandTrackerCreateInfoEXT* createInfo,
    XrHandTrackerEXT* handTracker) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (handTracker == nullptr || createInfo == nullptr ||
        createInfo->type != XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT ||
        (createInfo->hand != XR_HAND_LEFT_EXT &&
         createInfo->hand != XR_HAND_RIGHT_EXT) ||
        createInfo->handJointSet != XR_HAND_JOINT_SET_DEFAULT_EXT) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gHandTrackerLock);
    // Recheck under the lock so a concurrent xrDestroySession, which
    // invalidates trackers under this lock, cannot leave an orphan.
    if (!isValidSession(session)) {
        ReleaseSRWLockExclusive(&gHandTrackerLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    HandTrackerRecord* available = nullptr;
    for (HandTrackerRecord& record : gHandTrackers) {
        if (record.handle == XR_NULL_HANDLE) {
            available = &record;
            break;
        }
    }
    if (available == nullptr ||
        gNextHandTrackerHandle > UINTPTR_MAX - kHandTrackerHandleStride) {
        ReleaseSRWLockExclusive(&gHandTrackerLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    available->handle = reinterpret_cast<XrHandTrackerEXT>(gNextHandTrackerHandle);
    gNextHandTrackerHandle += kHandTrackerHandleStride;
    available->session = session;
    available->hand = createInfo->hand == XR_HAND_LEFT_EXT ? 0u : 1u;
    *handTracker = available->handle;
    ReleaseSRWLockExclusive(&gHandTrackerLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroyHandTracker(XrHandTrackerEXT handTracker) {
    AcquireSRWLockExclusive(&gHandTrackerLock);
    HandTrackerRecord* record = findHandTrackerLocked(handTracker);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gHandTrackerLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    *record = {};
    ReleaseSRWLockExclusive(&gHandTrackerLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL locateHandJoints(
    XrHandTrackerEXT handTracker,
    const XrHandJointsLocateInfoEXT* locateInfo,
    XrHandJointLocationsEXT* locations) {
    AcquireSRWLockShared(&gHandTrackerLock);
    const HandTrackerRecord* found = findHandTrackerLocked(handTracker);
    const HandTrackerRecord tracker = found != nullptr ? *found : HandTrackerRecord{};
    ReleaseSRWLockShared(&gHandTrackerLock);
    if (found == nullptr) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (locateInfo == nullptr ||
        locateInfo->type != XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT ||
        locations == nullptr || locations->type != XR_TYPE_HAND_JOINT_LOCATIONS_EXT ||
        locations->jointCount != kJointCount || locations->jointLocations == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    XrHandJointVelocitiesEXT* velocities = findChainedVelocities(locations->next);
    if (velocities != nullptr &&
        (velocities->jointCount != kJointCount || velocities->jointVelocities == nullptr)) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!isSpaceForSession(locateInfo->baseSpace, tracker.session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (locateInfo->time <= 0) {
        return XR_ERROR_TIME_INVALID;
    }

    ControlHandSkeleton skeleton{};
    XrPosef baseInLocal{};
    const bool active =
        controlHandSkeleton(tracker.session, tracker.hand, locateInfo->time, &skeleton) &&
        locateSpaceInLocal(
            locateInfo->baseSpace, tracker.session, locateInfo->time, &baseInLocal);

    constexpr XrSpaceLocationFlags kTrackedFlags =
        XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
        XR_SPACE_LOCATION_POSITION_VALID_BIT |
        XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
        XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
    const XrPosef baseFromLocal = poseInvert(baseInLocal);
    for (uint32_t joint = 0; joint < kJointCount; ++joint) {
        XrHandJointLocationEXT& location = locations->jointLocations[joint];
        if (active) {
            location.locationFlags = kTrackedFlags;
            location.pose = poseCompose(baseFromLocal, skeleton.jointPosesInLocal[joint]);
            location.radius = skeleton.jointRadii[joint];
        } else {
            location.locationFlags = 0;
            location.pose = identityPose();
            location.radius = 0.0f;
        }
    }
    locations->isActive = active ? XR_TRUE : XR_FALSE;

    // ALVR sends no joint velocities.
    if (velocities != nullptr) {
        for (uint32_t joint = 0; joint < kJointCount; ++joint) {
            XrHandJointVelocityEXT& velocity = velocities->jointVelocities[joint];
            velocity.velocityFlags = 0;
            velocity.linearVelocity = {0.0f, 0.0f, 0.0f};
            velocity.angularVelocity = {0.0f, 0.0f, 0.0f};
        }
    }
    return XR_SUCCESS;
}

void invalidateHandTrackersForSession(XrSession session) {
    AcquireSRWLockExclusive(&gHandTrackerLock);
    for (HandTrackerRecord& record : gHandTrackers) {
        if (record.session == session) {
            record = {};
        }
    }
    ReleaseSRWLockExclusive(&gHandTrackerLock);
}

// The runtime allows one live instance, so every tracker belongs to it.
void invalidateHandTrackersForInstance(XrInstance) {
    AcquireSRWLockExclusive(&gHandTrackerLock);
    for (HandTrackerRecord& record : gHandTrackers) {
        record = {};
    }
    ReleaseSRWLockExclusive(&gHandTrackerLock);
}

}  // namespace basalt
