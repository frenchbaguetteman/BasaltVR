#include "runtime.hpp"

#include <windows.h>

#include <array>
#include <cmath>
#include <cstdint>

#include "control.hpp"
#include "pose_math.hpp"

namespace {

using basalt::identityPose;
using basalt::poseCompose;
using basalt::poseInvert;
using basalt::quaternionMultiply;
using basalt::quaternionRotate;

constexpr uintptr_t kFirstSpaceHandle = static_cast<uintptr_t>(0x40000);
constexpr uintptr_t kSpaceHandleStride = static_cast<uintptr_t>(0x10);
constexpr size_t kMaxSpaces = 64;
constexpr std::array<XrReferenceSpaceType, 4> kSupportedReferenceSpaces = {
    XR_REFERENCE_SPACE_TYPE_VIEW,
    XR_REFERENCE_SPACE_TYPE_LOCAL,
    XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR,
    XR_REFERENCE_SPACE_TYPE_STAGE,
};

// The headset supplies LOCAL-from-HEAD. These eye values are conservative
// fallbacks until the control protocol delivers the Quest's calibrated IPD/FOV.
constexpr float kEyeOffsetMeters = 0.063f / 2.0f;
constexpr float kEyeFovHalfAngleRadians = 0.785398163f;
constexpr uint32_t kViewCount = 2;

enum class SpaceKind {
    kReference,
    kAction,
};

struct SpaceRecord {
    XrSpace handle = XR_NULL_HANDLE;
    XrSession session = XR_NULL_HANDLE;
    SpaceKind kind = SpaceKind::kReference;
    XrReferenceSpaceType referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    XrAction action = XR_NULL_HANDLE;
    XrPath subactionPath = XR_NULL_PATH;
    XrPosef pose{};
};

SRWLOCK gSpaceLock = SRWLOCK_INIT;
struct LocatedViewsSample {
    XrSession session = XR_NULL_HANDLE;
    XrTime displayTime = 0;
    uint64_t questTimestamp = 0;
};
constexpr size_t kLocatedViewsSampleCapacity = 16;
std::array<LocatedViewsSample, kLocatedViewsSampleCapacity> gLocatedViewsSamples{};
size_t gNextLocatedViewsSample = 0;

void recordLocatedViewsSample(
    XrSession session, XrTime displayTime, uint64_t questTimestamp) {
    AcquireSRWLockExclusive(&gSpaceLock);
    for (LocatedViewsSample& sample : gLocatedViewsSamples) {
        if (sample.session == session && sample.displayTime == displayTime) {
            sample.questTimestamp = questTimestamp;
            ReleaseSRWLockExclusive(&gSpaceLock);
            return;
        }
    }
    gLocatedViewsSamples[gNextLocatedViewsSample] = {
        session, displayTime, questTimestamp};
    gNextLocatedViewsSample =
        (gNextLocatedViewsSample + 1) % kLocatedViewsSampleCapacity;
    ReleaseSRWLockExclusive(&gSpaceLock);
}
uintptr_t gNextSpaceHandle = kFirstSpaceHandle;
std::array<SpaceRecord, kMaxSpaces> gSpaces{};

bool poseValid(const XrPosef& pose) {
    const XrQuaternionf& orientation = pose.orientation;
    if (!std::isfinite(orientation.x) || !std::isfinite(orientation.y) ||
        !std::isfinite(orientation.z) || !std::isfinite(orientation.w) ||
        !std::isfinite(pose.position.x) || !std::isfinite(pose.position.y) ||
        !std::isfinite(pose.position.z)) {
        return false;
    }

    const double norm = std::sqrt(
        static_cast<double>(orientation.x) * orientation.x +
        static_cast<double>(orientation.y) * orientation.y +
        static_cast<double>(orientation.z) * orientation.z +
        static_cast<double>(orientation.w) * orientation.w);
    return norm >= 0.99 && norm <= 1.01;
}

SpaceRecord* findSpaceLocked(XrSpace space) {
    for (SpaceRecord& record : gSpaces) {
        if (record.handle == space) {
            return &record;
        }
    }
    return nullptr;
}

XrResult reserveSpaceLocked(SpaceRecord** available) {
    *available = nullptr;
    for (SpaceRecord& record : gSpaces) {
        if (record.handle == XR_NULL_HANDLE) {
            *available = &record;
            break;
        }
    }
    if (*available == nullptr ||
        gNextSpaceHandle > UINTPTR_MAX - kSpaceHandleStride) {
        return XR_ERROR_LIMIT_REACHED;
    }
    return XR_SUCCESS;
}

void setChainedSpaceVelocity(
    void* next,
    XrSpaceVelocityFlags flags,
    const XrVector3f& linear,
    const XrVector3f& angular) {
    auto* structure = static_cast<XrBaseOutStructure*>(next);
    while (structure != nullptr) {
        if (structure->type == XR_TYPE_SPACE_VELOCITY) {
            auto* velocity = reinterpret_cast<XrSpaceVelocity*>(structure);
            velocity->velocityFlags = flags;
            velocity->linearVelocity = linear;
            velocity->angularVelocity = angular;
        }
        structure = structure->next;
    }
}

XrVector3f vectorCross(const XrVector3f& a, const XrVector3f& b) {
    return {
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    };
}

XrVector3f vectorAdd(const XrVector3f& a, const XrVector3f& b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL enumerateReferenceSpaces(
    XrSession session,
    uint32_t spaceCapacityInput,
    uint32_t* spaceCountOutput,
    XrReferenceSpaceType* spaces) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (spaceCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *spaceCountOutput = static_cast<uint32_t>(kSupportedReferenceSpaces.size());
    if (spaceCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (spaces == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (spaceCapacityInput < kSupportedReferenceSpaces.size()) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (size_t index = 0; index < kSupportedReferenceSpaces.size(); ++index) {
        spaces[index] = kSupportedReferenceSpaces[index];
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createReferenceSpace(
    XrSession session,
    const XrReferenceSpaceCreateInfo* createInfo,
    XrSpace* space) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (space == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *space = XR_NULL_HANDLE;
    if (createInfo == nullptr ||
        createInfo->type != XR_TYPE_REFERENCE_SPACE_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    bool knownType = false;
    for (XrReferenceSpaceType supported : kSupportedReferenceSpaces) {
        knownType = knownType || supported == createInfo->referenceSpaceType;
    }
    if (!knownType) {
        return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;
    }
    if (!poseValid(createInfo->poseInReferenceSpace)) {
        return XR_ERROR_POSE_INVALID;
    }

    AcquireSRWLockExclusive(&gSpaceLock);
    if (!isValidSession(session)) {
        ReleaseSRWLockExclusive(&gSpaceLock);
        return XR_ERROR_HANDLE_INVALID;
    }

    SpaceRecord* available = nullptr;
    const XrResult reserveResult = reserveSpaceLocked(&available);
    if (XR_FAILED(reserveResult)) {
        ReleaseSRWLockExclusive(&gSpaceLock);
        return reserveResult;
    }

    available->handle = reinterpret_cast<XrSpace>(gNextSpaceHandle);
    gNextSpaceHandle += kSpaceHandleStride;
    available->session = session;
    available->kind = SpaceKind::kReference;
    available->referenceSpaceType = createInfo->referenceSpaceType;
    available->action = XR_NULL_HANDLE;
    available->subactionPath = XR_NULL_PATH;
    available->pose = createInfo->poseInReferenceSpace;
    *space = available->handle;
    ReleaseSRWLockExclusive(&gSpaceLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createActionSpace(
    XrSession session,
    const XrActionSpaceCreateInfo* createInfo,
    XrSpace* space) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (space == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *space = XR_NULL_HANDLE;
    if (createInfo == nullptr ||
        createInfo->type != XR_TYPE_ACTION_SPACE_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    XrActionType actionType = XR_ACTION_TYPE_MAX_ENUM;
    bool allowsSubactionPath = false;
    if (!getActionForSpace(
            createInfo->action, &actionType, &allowsSubactionPath,
            createInfo->subactionPath)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (actionType != XR_ACTION_TYPE_POSE_INPUT) {
        return XR_ERROR_ACTION_TYPE_MISMATCH;
    }
    if (createInfo->subactionPath != XR_NULL_PATH &&
        !isKnownPath(createInfo->subactionPath)) {
        return XR_ERROR_PATH_INVALID;
    }
    if (!allowsSubactionPath) {
        return XR_ERROR_PATH_UNSUPPORTED;
    }
    if (!poseValid(createInfo->poseInActionSpace)) {
        return XR_ERROR_POSE_INVALID;
    }

    AcquireSRWLockExclusive(&gSpaceLock);
    if (!isValidSession(session)) {
        ReleaseSRWLockExclusive(&gSpaceLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    // Recheck under the space lock so a concurrent xrDestroyAction cannot
    // leave the new space referencing a destroyed action.
    if (!getActionForSpace(createInfo->action, nullptr, nullptr, XR_NULL_PATH)) {
        ReleaseSRWLockExclusive(&gSpaceLock);
        return XR_ERROR_HANDLE_INVALID;
    }

    SpaceRecord* available = nullptr;
    const XrResult reserveResult = reserveSpaceLocked(&available);
    if (XR_FAILED(reserveResult)) {
        ReleaseSRWLockExclusive(&gSpaceLock);
        return reserveResult;
    }

    available->handle = reinterpret_cast<XrSpace>(gNextSpaceHandle);
    gNextSpaceHandle += kSpaceHandleStride;
    available->session = session;
    available->kind = SpaceKind::kAction;
    available->action = createInfo->action;
    available->subactionPath = createInfo->subactionPath;
    available->pose = createInfo->poseInActionSpace;
    *space = available->handle;
    ReleaseSRWLockExclusive(&gSpaceLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL locateSpace(
    XrSpace space,
    XrSpace baseSpace,
    XrTime time,
    XrSpaceLocation* location) {
    if (location == nullptr || location->type != XR_TYPE_SPACE_LOCATION) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (time <= 0) {
        return XR_ERROR_TIME_INVALID;
    }

    AcquireSRWLockShared(&gSpaceLock);
    const SpaceRecord* spaceRecord = findSpaceLocked(space);
    const SpaceRecord* baseRecord = findSpaceLocked(baseSpace);
    if (spaceRecord == nullptr || baseRecord == nullptr) {
        ReleaseSRWLockShared(&gSpaceLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    const SpaceRecord target = *spaceRecord;
    const SpaceRecord base = *baseRecord;
    ReleaseSRWLockShared(&gSpaceLock);
    if (target.session != base.session) {
        return XR_ERROR_HANDLE_INVALID;
    }

    uint32_t targetHand = UINT32_MAX;
    uint32_t baseHand = UINT32_MAX;
    bool targetAim = false;
    bool baseAim = false;
    const bool targetActionResolved = target.kind == SpaceKind::kAction &&
        getActionPoseSource(target.session, target.action, target.subactionPath,
                            &targetHand, &targetAim);
    const bool baseActionResolved = base.kind == SpaceKind::kAction &&
        getActionPoseSource(base.session, base.action, base.subactionPath,
                            &baseHand, &baseAim);
    XrSpaceVelocityFlags velocityFlags = 0;
    XrVector3f linearVelocity{};
    XrVector3f angularVelocity{};

    if (target.kind == SpaceKind::kAction && base.kind == SpaceKind::kAction &&
        targetActionResolved && baseActionResolved && targetHand == baseHand &&
        targetAim == baseAim) {
        // The natural controller entity cancels even during a tracking gap.
        location->locationFlags =
            XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
            XR_SPACE_LOCATION_POSITION_VALID_BIT |
            XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
            XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
        location->pose = poseCompose(poseInvert(base.pose), target.pose);
        velocityFlags = XR_SPACE_VELOCITY_LINEAR_VALID_BIT |
                        XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
    } else if (target.kind == SpaceKind::kReference &&
               base.kind == SpaceKind::kReference &&
               target.referenceSpaceType == base.referenceSpaceType) {
        // The natural transform cancels for LOCAL↔LOCAL and VIEW↔VIEW, so
        // creation offsets remain valid even before the first head sample.
        location->locationFlags =
            XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
            XR_SPACE_LOCATION_POSITION_VALID_BIT;
        location->pose = poseCompose(poseInvert(base.pose), target.pose);
        velocityFlags = XR_SPACE_VELOCITY_LINEAR_VALID_BIT |
                        XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
    } else {
        XrPosef headInLocal{};
        const bool headTracked = controlHeadPose(
            target.session, time, nullptr, &headInLocal);
        ControlInputSnapshot input{};
        controlInputSnapshot(target.session, &input, time);

        auto localFromSpace = [&](const SpaceRecord& record, bool actionResolved,
                                  uint32_t hand, XrPosef* pose) -> bool {
            if (record.kind == SpaceKind::kAction) {
                if (!actionResolved || hand >= 2 || !input.controllers[hand].poseActive) {
                    return false;
                }
                *pose = poseCompose(input.controllers[hand].poseInLocal, record.pose);
                return true;
            }
            // Only VIEW follows the head. LOCAL, LOCAL_FLOOR and STAGE are
            // fixed world spaces; composing them with the head pose made a
            // VIEW-vs-floor query cancel the head transform and return a
            // constant pose, so titles rendered a frozen camera.
            if (record.referenceSpaceType != XR_REFERENCE_SPACE_TYPE_VIEW) {
                *pose = record.pose;
                return true;
            }
            if (!headTracked) {
                return false;
            }
            *pose = poseCompose(headInLocal, record.pose);
            return true;
        };

        XrPosef targetInLocal{};
        XrPosef baseInLocal{};
        if (!localFromSpace(target, targetActionResolved, targetHand, &targetInLocal) ||
            !localFromSpace(base, baseActionResolved, baseHand, &baseInLocal)) {
            location->locationFlags = 0;
            location->pose = identityPose();
            setChainedSpaceVelocity(
                location->next, 0, XrVector3f{}, XrVector3f{});
            return XR_SUCCESS;
        }
        location->locationFlags =
            XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
            XR_SPACE_LOCATION_POSITION_VALID_BIT |
            XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
            XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
        location->pose = poseCompose(poseInvert(baseInLocal), targetInLocal);

        // ALVR has already predicted the transmitted controller pose. Expose
        // its raw velocity for the common action-in-LOCAL query without
        // extrapolating the pose a second time. The action-space origin may
        // be offset from the controller origin, adding omega cross radius.
        if (target.kind == SpaceKind::kAction && targetActionResolved &&
            targetHand < 2 && input.controllers[targetHand].poseActive &&
            base.kind == SpaceKind::kReference &&
            base.referenceSpaceType == XR_REFERENCE_SPACE_TYPE_LOCAL) {
            const ControlControllerState& controller =
                input.controllers[targetHand];
            const XrVector3f radiusInLocal{
                targetInLocal.position.x - controller.poseInLocal.position.x,
                targetInLocal.position.y - controller.poseInLocal.position.y,
                targetInLocal.position.z - controller.poseInLocal.position.z,
            };
            const XrVector3f originVelocityInLocal = vectorAdd(
                controller.linearVelocity,
                vectorCross(controller.angularVelocity, radiusInLocal));
            const XrQuaternionf localToBase = poseInvert(baseInLocal).orientation;
            linearVelocity = quaternionRotate(localToBase, originVelocityInLocal);
            angularVelocity = quaternionRotate(
                localToBase, controller.angularVelocity);
            velocityFlags = XR_SPACE_VELOCITY_LINEAR_VALID_BIT |
                            XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
        }
    }
    setChainedSpaceVelocity(
        location->next, velocityFlags, linearVelocity, angularVelocity);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL locateViews(
    XrSession session,
    const XrViewLocateInfo* viewLocateInfo,
    XrViewState* viewState,
    uint32_t viewCapacityInput,
    uint32_t* viewCountOutput,
    XrView* views) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (viewLocateInfo == nullptr ||
        viewLocateInfo->type != XR_TYPE_VIEW_LOCATE_INFO ||
        viewState == nullptr || viewState->type != XR_TYPE_VIEW_STATE ||
        viewCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (viewLocateInfo->viewConfigurationType !=
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    if (viewLocateInfo->displayTime <= 0) {
        return XR_ERROR_TIME_INVALID;
    }

    AcquireSRWLockShared(&gSpaceLock);
    const SpaceRecord* spaceRecord = findSpaceLocked(viewLocateInfo->space);
    if (spaceRecord == nullptr || spaceRecord->session != session) {
        ReleaseSRWLockShared(&gSpaceLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    const SpaceRecord base = *spaceRecord;
    ReleaseSRWLockShared(&gSpaceLock);

    XrPosef headInLocal{};
    uint64_t headQuestTimestamp = 0;
    const bool headTracked = controlHeadPose(
        session, viewLocateInfo->displayTime,
        &headQuestTimestamp, &headInLocal);
    XrPosef baseInLocal{};
    bool baseTracked = false;
    if (base.kind == SpaceKind::kReference) {
        // Same rule as locateSpace: only the VIEW space follows the head.
        if (base.referenceSpaceType == XR_REFERENCE_SPACE_TYPE_VIEW) {
            if (headTracked) {
                baseInLocal = poseCompose(headInLocal, base.pose);
                baseTracked = true;
            }
        } else {
            baseInLocal = base.pose;
            baseTracked = true;
        }
    } else {
        uint32_t hand = UINT32_MAX;
        bool aim = false;
        ControlInputSnapshot input{};
        controlInputSnapshot(session, &input, viewLocateInfo->displayTime);
        if (getActionPoseSource(session, base.action, base.subactionPath, &hand, &aim) &&
            hand < 2 && input.controllers[hand].poseActive) {
            baseInLocal = poseCompose(input.controllers[hand].poseInLocal, base.pose);
            baseTracked = true;
        }
    }
    const bool viewsTracked = headTracked && baseTracked;

    // OpenXR enumeration calls (capacity == 0) must return the same view
    // state as the data-producing call. Set it before the early return.
    viewState->viewStateFlags = viewsTracked
        ? XR_VIEW_STATE_ORIENTATION_VALID_BIT |
              XR_VIEW_STATE_POSITION_VALID_BIT |
              XR_VIEW_STATE_ORIENTATION_TRACKED_BIT |
              XR_VIEW_STATE_POSITION_TRACKED_BIT
        : 0;
    *viewCountOutput = kViewCount;
    if (viewCapacityInput == 0) {
        recordLocatedViewsSample(
            session, viewLocateInfo->displayTime,
            headTracked ? headQuestTimestamp : 0);
        return XR_SUCCESS;
    }
    if (views == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (viewCapacityInput < kViewCount) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (uint32_t index = 0; index < kViewCount; ++index) {
        if (views[index].type != XR_TYPE_VIEW) {
            return XR_ERROR_VALIDATION_FAILURE;
        }
    }

    float ipdMeters = kEyeOffsetMeters * 2.0f;
    XrFovf calibratedFov[kViewCount] = {
        {-kEyeFovHalfAngleRadians, kEyeFovHalfAngleRadians,
         kEyeFovHalfAngleRadians, -kEyeFovHalfAngleRadians},
        {-kEyeFovHalfAngleRadians, kEyeFovHalfAngleRadians,
         kEyeFovHalfAngleRadians, -kEyeFovHalfAngleRadians},
    };
    controlViewConfig(session, &ipdMeters, calibratedFov);
    const float halfIpd = ipdMeters * 0.5f;

    for (uint32_t index = 0; index < kViewCount; ++index) {
        XrPosef eyeOffset = identityPose();
        eyeOffset.position.x = index == 0 ? -halfIpd : halfIpd;
        if (!viewsTracked) {
            views[index].pose = identityPose();
        } else {
            views[index].pose = poseCompose(
                poseCompose(poseInvert(baseInLocal), headInLocal), eyeOffset);
        }
        views[index].fov = calibratedFov[index];
    }
    recordLocatedViewsSample(
        session, viewLocateInfo->displayTime,
        headTracked ? headQuestTimestamp : 0);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getReferenceSpaceBoundsRect(
    XrSession session,
    XrReferenceSpaceType referenceSpaceType,
    XrExtent2Df* bounds) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (bounds == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (referenceSpaceType != XR_REFERENCE_SPACE_TYPE_VIEW &&
        referenceSpaceType != XR_REFERENCE_SPACE_TYPE_LOCAL) {
        return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;
    }

    bounds->width = 0.0f;
    bounds->height = 0.0f;
    return XR_SPACE_BOUNDS_UNAVAILABLE;
}

XrResult XRAPI_CALL destroySpace(XrSpace space) {
    if (space == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gSpaceLock);
    SpaceRecord* record = findSpaceLocked(space);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gSpaceLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    *record = {};
    ReleaseSRWLockExclusive(&gSpaceLock);
    return XR_SUCCESS;
}

void invalidateSpacesForSession(XrSession session) {
    AcquireSRWLockExclusive(&gSpaceLock);
    for (SpaceRecord& record : gSpaces) {
        if (record.session == session) {
            record = {};
        }
    }
    for (LocatedViewsSample& sample : gLocatedViewsSamples) {
        if (sample.session == session) {
            sample = {};
        }
    }
    ReleaseSRWLockExclusive(&gSpaceLock);
}

uint64_t locatedViewsQuestTimestamp(XrSession session, XrTime displayTime) {
    AcquireSRWLockShared(&gSpaceLock);
    uint64_t timestamp = 0;
    for (size_t offset = 0; offset < kLocatedViewsSampleCapacity; ++offset) {
        const size_t index =
            (gNextLocatedViewsSample + kLocatedViewsSampleCapacity - 1 - offset) %
            kLocatedViewsSampleCapacity;
        const LocatedViewsSample& sample = gLocatedViewsSamples[index];
        if (sample.session == session && sample.displayTime == displayTime) {
            timestamp = sample.questTimestamp;
            break;
        }
    }
    ReleaseSRWLockShared(&gSpaceLock);
    return timestamp;
}

bool isSpaceForSession(XrSpace space, XrSession session) {
    if (space == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gSpaceLock);
    const SpaceRecord* record = findSpaceLocked(space);
    const bool matches = record != nullptr && record->session == session;
    ReleaseSRWLockShared(&gSpaceLock);
    return matches;
}

bool isPoseWellFormed(const XrPosef& pose) {
    return poseValid(pose);
}

bool getReferenceSpace(
    XrSpace space,
    XrSession* session,
    XrReferenceSpaceType* referenceSpaceType,
    XrPosef* poseInReferenceSpace) {
    if (space == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gSpaceLock);
    const SpaceRecord* record = findSpaceLocked(space);
    if (record != nullptr && record->kind != SpaceKind::kReference) {
        record = nullptr;
    }
    if (record != nullptr) {
        if (session != nullptr) {
            *session = record->session;
        }
        if (referenceSpaceType != nullptr) {
            *referenceSpaceType = record->referenceSpaceType;
        }
        if (poseInReferenceSpace != nullptr) {
            *poseInReferenceSpace = record->pose;
        }
    }
    ReleaseSRWLockShared(&gSpaceLock);
    return record != nullptr;
}

}  // namespace basalt
