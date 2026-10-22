// winsock2.h must precede windows.h (pulled in by control.hpp), or the
// legacy winsock.h definitions win.
#include <winsock2.h>
#include <ws2tcpip.h>

#include "control.hpp"
#include "runtime.hpp"

#include <d3d11_4.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "basalt_control_protocol.h"
#include "pose_math.hpp"

namespace {

using basalt::poseCompose;
using basalt::poseInvert;
using basalt::quaternionRotate;

// Must match BASALT_GUID_IOSURFACE_ID in the Basalt DXMT fork
// (runtime/dxmt-fork). {DD807311-529E-4856-A5C0-48BED2048129}
constexpr GUID kBasaltIOSurfaceIdGuid = {
    0xdd807311, 0x529e, 0x4856, {0xa5, 0xc0, 0x48, 0xbe, 0xd2, 0x04, 0x81, 0x29}};

constexpr DWORD kSocketTimeoutMilliseconds = 5000;
constexpr DWORD kFenceWaitMilliseconds = 10000;
// A frame is consumed only after its GPU fence (up to kFenceWaitMilliseconds),
// the FrameReady send, and the daemon's Metal reads. Waiting for consumption
// must outlast the fence wait, or a long GPU hitch would disconnect from the
// frame budget before the waiter's own fence deadline.
constexpr DWORD kFrameConsumeMilliseconds =
    kFenceWaitMilliseconds + kSocketTimeoutMilliseconds;
constexpr DWORD kWaiterJoinMilliseconds = 15000;
// Two frames allow game rendering to overlap the native Metal compose and
// VideoToolbox stages. The daemon still acks only after Metal has finished
// reading a source surface, so this is a strict latency/memory bound.
constexpr uint64_t kFrameWindow = 2;
// xrWaitFrame checks the window against frames already queued, so an app that
// calls xrWaitFrame(N+1) before xrEndFrame(N) can have one more frame in
// flight. Sizing the ring for that keeps the overflow guard unreachable.
constexpr size_t kPendingFrameCapacity = kFrameWindow + 1;
constexpr uint32_t kMaxFrameViews = 2;
constexpr size_t kMaxRendererLength = 256;
constexpr size_t kHeadPosePayloadLength = 8 + 7 * sizeof(float);
constexpr size_t kControllerMotionPayloadLength = 8 + 4 + 4 + 13 * sizeof(float);
constexpr size_t kButtonStatePayloadLength = 8 + 4 + sizeof(float);
constexpr size_t kInteractionProfilePayloadLength = 4 + 8;
constexpr XrDuration kHeadPoseFreshness = 500'000'000;
constexpr XrDuration kControllerPoseFreshness = 500'000'000;
constexpr XrDuration kSystemButtonRecenterHold = 600'000'000;

// Serialized FrameReady payload: header (8 + 8 + 8 + 4) plus per view
// (8 + 4 + 4 + 16 + 28 + 16).
constexpr size_t kFrameMessageCapacity = 28 + kMaxFrameViews * 76;

struct PendingFrame {
    uint64_t frameNumber = 0;
    uint32_t payloadLength = 0;
    uint8_t payload[kFrameMessageCapacity]{};
};

struct ControllerInputRecord {
    bool poseValid = false;
    bool profileActive = false;
    bool presenceActive = false;
    uint64_t questTimestamp = 0;
    uint64_t presenceTimestamp = 0;
    uint64_t profileId = 0;
    XrTime poseArrival = 0;
    XrPosef rawPose{};
    XrVector3f rawLinearVelocity{};
    XrVector3f rawAngularVelocity{};
};

struct RecenterNotification {
    bool ready = false;
    XrSession session = XR_NULL_HANDLE;
    XrTime changeTime = 0;
    XrPosef poseInPreviousSpace{};
};

struct ButtonInputRecord {
    bool valid = false;
    uint64_t pathId = 0;
    uint32_t valueType = 0;
    float value = 0.0f;
    XrTime lastChangeTime = 0;
};

// gControlLock guards every field below. gSendLock keeps complete framed
// messages atomic across the frame waiter, teardown path, and request path.
// gRequestLock permits only one ACK-requiring request at a time while the
// receiver thread remains the sole owner of socket reads.
SRWLOCK gControlLock = SRWLOCK_INIT;
SRWLOCK gSendLock = SRWLOCK_INIT;
SRWLOCK gRequestLock = SRWLOCK_INIT;
CONDITION_VARIABLE gAckCondition = CONDITION_VARIABLE_INIT;
CONDITION_VARIABLE gFrameDeliveryCondition = CONDITION_VARIABLE_INIT;
bool gWsaStarted = false;
SOCKET gSocket = INVALID_SOCKET;
XrSession gControlSession = XR_NULL_HANDLE;
ID3D11DeviceContext4* gContext4 = nullptr;
ID3D11Fence* gFence = nullptr;
HANDLE gFenceEvent = nullptr;
HANDLE gWaiterThread = nullptr;
HANDLE gWaiterWake = nullptr;
HANDLE gReceiverThread = nullptr;
bool gWaiterStop = false;
bool gReceiverFailed = false;
uint16_t gExpectedAckType = 0;
bool gAckReady = false;
bool gAckFailed = false;
uint8_t gAckPayload[32]{};
size_t gAckPayloadLength = 0;
bool gHeadPoseValid = false;
uint64_t gHeadPoseQuestTimestamp = 0;
XrTime gHeadPoseArrival = 0;
XrPosef gRawHeadPose{};
bool gLocalOriginValid = false;
XrPosef gLocalFromQuest{};
XrPosef gPreviousLocalFromQuest{};
XrTime gLocalSpaceChangeTime = 0;
// Latest xrWaitFrame predictedDisplayTime handed to the control session. A
// recenter must not take effect at or before it: the application may already
// have located part of that frame against the previous LOCAL definition.
XrTime gLatestPredictedDisplayTime = 0;
// Nonzero while the right system button is held; the recenter gesture fires
// once per hold.
XrTime gSystemButtonPressTime = 0;
bool gSystemButtonRecentered = false;
ControllerInputRecord gControllerInputs[2]{};
ButtonInputRecord gButtonInputs[basalt::kControlButtonCapacity]{};
bool gViewConfigValid = false;
float gViewConfigIpdMeters = 0.0f;
XrFovf gViewConfigFov[2]{};
uint64_t gNextFrameNumber = 1;
uint64_t gLastConsumedFrameNumber = 0;
PendingFrame gPendingFrames[kPendingFrameCapacity]{};
size_t gPendingHead = 0;
size_t gPendingCount = 0;

void resetSystemButtonLocked() {
    gSystemButtonPressTime = 0;
    gSystemButtonRecentered = false;
}

void resetInputsLocked() {
    for (ControllerInputRecord& record : gControllerInputs) {
        record = {};
    }
    for (ButtonInputRecord& record : gButtonInputs) {
        record = {};
    }
    resetSystemButtonLocked();
}

// Everything the daemon streams per connection. A new or closing connection
// must never inherit the previous one's poses, LOCAL origin, or held buttons.
void resetTrackingStateLocked() {
    gHeadPoseValid = false;
    gHeadPoseQuestTimestamp = 0;
    gHeadPoseArrival = 0;
    gRawHeadPose = {};
    gLocalOriginValid = false;
    gLocalFromQuest = basalt::identityPose();
    gPreviousLocalFromQuest = gLocalFromQuest;
    gLocalSpaceChangeTime = 0;
    gLatestPredictedDisplayTime = 0;
    resetInputsLocked();
    gViewConfigValid = false;
    gViewConfigIpdMeters = 0.0f;
    gViewConfigFov[0] = {};
    gViewConfigFov[1] = {};
}

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

bool basaltGateEnabled() {
    char value[8]{};
    const DWORD length = GetEnvironmentVariableA("DXMT_BASALT_IOSURFACE", value, sizeof(value));
    return length == 1 && value[0] == '1';
}

XrTime monotonicTime() {
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

// Returns the gravity-aligned horizontal origin at the head's current X/Z
// and yaw. Keeping Y at zero preserves the Quest floor height in LOCAL.
XrPosef leveledHeadOrigin(const XrPosef& head) {
    const XrVector3f forward =
        quaternionRotate(head.orientation, {0.0f, 0.0f, -1.0f});
    const float horizontalLength = std::hypot(forward.x, forward.z);
    float yaw = 0.0f;
    if (std::isfinite(horizontalLength) && horizontalLength >= 0.001f) {
        yaw = std::atan2(-forward.x, -forward.z);
    }
    const float halfYaw = yaw * 0.5f;
    return {
        {0.0f, std::sin(halfYaw), 0.0f, std::cos(halfYaw)},
        {head.position.x, 0.0f, head.position.z},
    };
}

void establishInitialLocalOriginLocked() {
    gLocalFromQuest = poseInvert(leveledHeadOrigin(gRawHeadPose));
    gPreviousLocalFromQuest = gLocalFromQuest;
    gLocalSpaceChangeTime = 0;
    gLocalOriginValid = true;
}

const XrPosef& localTransformForTimeLocked(XrTime locateTime) {
    return locateTime > 0 && gLocalSpaceChangeTime > 0 &&
                   locateTime < gLocalSpaceChangeTime
        ? gPreviousLocalFromQuest
        : gLocalFromQuest;
}

void recenterLocalOriginLocked(
    XrTime changeTime, RecenterNotification* notification) {
    if (!gLocalOriginValid || !gHeadPoseValid || notification == nullptr) {
        return;
    }
    const XrPosef originInPreviousLocal =
        leveledHeadOrigin(poseCompose(gLocalFromQuest, gRawHeadPose));
    gPreviousLocalFromQuest = gLocalFromQuest;
    gLocalSpaceChangeTime = changeTime;
    gLocalFromQuest = poseCompose(
        poseInvert(originInPreviousLocal), gLocalFromQuest);
    notification->ready = true;
    notification->session = gControlSession;
    notification->changeTime = changeTime;
    notification->poseInPreviousSpace = originInPreviousLocal;
}

// --- little-endian message building ----------------------------------------

class MessageWriter {
public:
    MessageWriter(uint8_t* buffer, size_t capacity) : buffer_(buffer), capacity_(capacity) {}

    void bytes(const void* data, size_t size) {
        if (overflow_ || size > capacity_ - length_) {
            overflow_ = true;
            return;
        }
        std::memcpy(buffer_ + length_, data, size);
        length_ += size;
    }
    void u16(uint16_t value) { bytes(&value, sizeof(value)); }
    void u32(uint32_t value) { bytes(&value, sizeof(value)); }
    void u64(uint64_t value) { bytes(&value, sizeof(value)); }
    void s32(int32_t value) { bytes(&value, sizeof(value)); }
    void s64(int64_t value) { bytes(&value, sizeof(value)); }
    void f32(float value) { bytes(&value, sizeof(value)); }

    size_t length() const { return length_; }
    bool ok() const { return !overflow_; }

private:
    uint8_t* buffer_;
    size_t capacity_;
    size_t length_ = 0;
    bool overflow_ = false;
};

bool sendAll(SOCKET socket, const void* data, size_t size) {
    const char* cursor = static_cast<const char*>(data);
    size_t remaining = size;
    while (remaining > 0) {
        const int sent = send(socket, cursor, static_cast<int>(remaining), 0);
        if (sent <= 0) {
            return false;
        }
        cursor += sent;
        remaining -= static_cast<size_t>(sent);
    }
    return true;
}

bool sendMessage(
    SOCKET socket,
    uint16_t type,
    const uint8_t* payload,
    size_t payloadLength) {
    if (socket == INVALID_SOCKET) {
        return false;
    }
    uint8_t header[6];
    const uint32_t length = static_cast<uint32_t>(sizeof(uint16_t) + payloadLength);
    std::memcpy(header, &length, sizeof(length));
    std::memcpy(header + 4, &type, sizeof(type));
    AcquireSRWLockExclusive(&gSendLock);
    const bool sent = sendAll(socket, header, sizeof(header)) &&
                      sendAll(socket, payload, payloadLength);
    ReleaseSRWLockExclusive(&gSendLock);
    return sent;
}

bool recvAll(SOCKET socket, void* data, size_t size) {
    char* cursor = static_cast<char*>(data);
    size_t remaining = size;
    while (remaining > 0) {
        const int received = recv(socket, cursor, static_cast<int>(remaining), 0);
        if (received <= 0) {
            return false;
        }
        cursor += received;
        remaining -= static_cast<size_t>(received);
    }
    return true;
}

bool recvMessage(
    SOCKET socket,
    uint16_t* type,
    uint8_t* payload,
    size_t payloadCapacity,
    size_t* payloadLength) {
    uint32_t length = 0;
    if (!recvAll(socket, &length, sizeof(length)) ||
        length < sizeof(*type) ||
        length > BASALT_CONTROL_MAX_MESSAGE_LENGTH ||
        !recvAll(socket, type, sizeof(*type))) {
        return false;
    }
    const size_t bodyLength = length - sizeof(*type);
    if (bodyLength > payloadCapacity) {
        return false;
    }
    if (bodyLength > 0 && !recvAll(socket, payload, bodyLength)) {
        return false;
    }
    *payloadLength = bodyLength;
    return true;
}

bool recvExpectedMessage(
    SOCKET socket,
    uint16_t expectedType,
    uint8_t* payload,
    size_t payloadCapacity,
    size_t* payloadLength) {
    uint16_t type = 0;
    return recvMessage(socket, &type, payload, payloadCapacity, payloadLength) &&
           type == expectedType;
}

bool parseHeadPose(
    const uint8_t* payload,
    size_t payloadLength,
    RecenterNotification* recenter) {
    if (payloadLength != kHeadPosePayloadLength) {
        return false;
    }
    uint64_t timestamp = 0;
    float values[7]{};
    std::memcpy(&timestamp, payload, sizeof(timestamp));
    std::memcpy(values, payload + sizeof(timestamp), sizeof(values));
    for (float value : values) {
        if (!std::isfinite(value)) {
            return false;
        }
    }
    const double norm = std::sqrt(
        static_cast<double>(values[0]) * values[0] +
        static_cast<double>(values[1]) * values[1] +
        static_cast<double>(values[2]) * values[2] +
        static_cast<double>(values[3]) * values[3]);
    if (norm < 0.5 || norm > 1.5 || timestamp < gHeadPoseQuestTimestamp) {
        return norm >= 0.5 && norm <= 1.5;
    }

    const float inverseNorm = static_cast<float>(1.0 / norm);
    gRawHeadPose.orientation = {
        values[0] * inverseNorm,
        values[1] * inverseNorm,
        values[2] * inverseNorm,
        values[3] * inverseNorm,
    };
    gRawHeadPose.position = {values[4], values[5], values[6]};
    gHeadPoseQuestTimestamp = timestamp;
    const XrTime now = monotonicTime();
    gHeadPoseArrival = now;
    gHeadPoseValid = true;
    if (!gLocalOriginValid) {
        establishInitialLocalOriginLocked();
    }
    if (!gSystemButtonRecentered &&
        gSystemButtonPressTime > 0 && now >= gSystemButtonPressTime &&
        now - gSystemButtonPressTime >= kSystemButtonRecenterHold) {
        const XrTime changeTime = gLatestPredictedDisplayTime >= now
            ? gLatestPredictedDisplayTime + 1 : now;
        recenterLocalOriginLocked(changeTime, recenter);
        gSystemButtonRecentered = true;
        std::fprintf(stderr, "Basalt OpenXR: recentered LOCAL from the right system button\n");
    }
    return true;
}

bool parseControllerMotion(const uint8_t* payload, size_t payloadLength) {
    if (payloadLength != kControllerMotionPayloadLength) {
        return false;
    }
    uint64_t timestamp = 0;
    uint32_t hand = 0;
    uint32_t reserved = 0;
    float values[13]{};
    std::memcpy(&timestamp, payload, sizeof(timestamp));
    std::memcpy(&hand, payload + 8, sizeof(hand));
    std::memcpy(&reserved, payload + 12, sizeof(reserved));
    std::memcpy(values, payload + 16, sizeof(values));
    if (hand > 1 || reserved != 0) {
        return false;
    }
    for (float value : values) {
        if (!std::isfinite(value)) {
            return false;
        }
    }
    const double norm = std::sqrt(
        static_cast<double>(values[0]) * values[0] +
        static_cast<double>(values[1]) * values[1] +
        static_cast<double>(values[2]) * values[2] +
        static_cast<double>(values[3]) * values[3]);
    if (norm < 0.5 || norm > 1.5) {
        return false;
    }
    ControllerInputRecord& record = gControllerInputs[hand];
    if (timestamp < record.questTimestamp ||
        timestamp < record.presenceTimestamp ||
        (timestamp == record.presenceTimestamp && !record.presenceActive)) {
        return true;
    }
    if (!gLocalOriginValid) {
        return true;
    }
    const float inverseNorm = static_cast<float>(1.0 / norm);
    record.rawPose.orientation = {
        values[0] * inverseNorm, values[1] * inverseNorm,
        values[2] * inverseNorm, values[3] * inverseNorm,
    };
    record.rawPose.position = {values[4], values[5], values[6]};
    record.rawLinearVelocity = {values[7], values[8], values[9]};
    record.rawAngularVelocity = {values[10], values[11], values[12]};
    record.questTimestamp = timestamp;
    record.poseArrival = monotonicTime();
    record.poseValid = true;
    return true;
}

bool parseButtonState(const uint8_t* payload, size_t payloadLength) {
    if (payloadLength != kButtonStatePayloadLength) {
        return false;
    }
    uint64_t pathId = 0;
    uint32_t valueType = 0;
    float value = 0.0f;
    std::memcpy(&pathId, payload, sizeof(pathId));
    std::memcpy(&valueType, payload + 8, sizeof(valueType));
    std::memcpy(&value, payload + 12, sizeof(value));
    if (pathId == 0 || valueType > 1 || !std::isfinite(value) ||
        (valueType == 0 && value != 0.0f && value != 1.0f)) {
        return false;
    }
    ButtonInputRecord* available = nullptr;
    for (ButtonInputRecord& record : gButtonInputs) {
        if (record.valid && record.pathId == pathId) {
            available = &record;
            break;
        }
        if (!record.valid && available == nullptr) {
            available = &record;
        }
    }
    if (pathId == basalt::kAlvrRightSystemClickPathId) {
        if (!basalt::controlButtonPressed(valueType, value)) {
            resetSystemButtonLocked();
        } else if (gSystemButtonPressTime == 0) {
            // Quest normally reserves the Meta button, so confirm on hardware
            // that ALVR forwards it before relying on the recenter gesture.
            std::fprintf(stderr, "Basalt OpenXR: right system button pressed\n");
            gSystemButtonPressTime = monotonicTime();
        }
    }
    if (available == nullptr) {
        // Input is extensible and the daemon may know more ALVR paths than
        // this fixed-size runtime slice. Ignore overflow instead of treating
        // an otherwise valid control connection as corrupt.
        return true;
    }
    if (!available->valid || available->valueType != valueType ||
        available->value != value) {
        available->lastChangeTime = monotonicTime();
    }
    available->valid = true;
    available->pathId = pathId;
    available->valueType = valueType;
    available->value = value;
    return true;
}

bool parseInteractionProfile(const uint8_t* payload, size_t payloadLength) {
    if (payloadLength != kInteractionProfilePayloadLength) {
        return false;
    }
    uint32_t hand = 0;
    uint64_t profileId = 0;
    std::memcpy(&hand, payload, sizeof(hand));
    std::memcpy(&profileId, payload + 4, sizeof(profileId));
    if (hand > 1 || profileId == 0) {
        return false;
    }
    gControllerInputs[hand].profileActive = true;
    gControllerInputs[hand].profileId = profileId;
    return true;
}

bool parseInputReset(size_t payloadLength) {
    if (payloadLength != 0) {
        return false;
    }
    resetInputsLocked();
    return true;
}

bool parseViewConfig(const uint8_t* payload, size_t payloadLength) {
    constexpr size_t kPayloadLength = 9 * sizeof(float);
    if (payloadLength != kPayloadLength) {
        return false;
    }
    float values[9]{};
    std::memcpy(values, payload, sizeof(values));
    for (float value : values) {
        if (!std::isfinite(value)) {
            return false;
        }
    }
    if (values[0] < 0.04f || values[0] > 0.09f) {
        return false;
    }
    XrFovf fov[2]{};
    for (uint32_t eye = 0; eye < 2; ++eye) {
        const size_t base = 1 + eye * 4;
        fov[eye] = {values[base], values[base + 1],
                    values[base + 2], values[base + 3]};
        if (fov[eye].angleLeft >= fov[eye].angleRight ||
            fov[eye].angleDown >= fov[eye].angleUp ||
            fov[eye].angleLeft < -1.57079633f ||
            fov[eye].angleRight > 1.57079633f ||
            fov[eye].angleDown < -1.57079633f ||
            fov[eye].angleUp > 1.57079633f) {
            return false;
        }
    }
    gViewConfigIpdMeters = values[0];
    gViewConfigFov[0] = fov[0];
    gViewConfigFov[1] = fov[1];
    gViewConfigValid = true;
    return true;
}

bool parseControllerMask(const uint8_t* payload, size_t payloadLength) {
    constexpr size_t kPayloadLength = 16;
    if (payloadLength != kPayloadLength) {
        return false;
    }
    uint64_t timestamp = 0;
    uint32_t activeMask = 0;
    uint32_t reserved = 0;
    std::memcpy(&timestamp, payload, sizeof(timestamp));
    std::memcpy(&activeMask, payload + 8, sizeof(activeMask));
    std::memcpy(&reserved, payload + 12, sizeof(reserved));
    if ((activeMask & ~3u) != 0 || reserved != 0) {
        return false;
    }
    for (uint32_t hand = 0; hand < 2; ++hand) {
        ControllerInputRecord& record = gControllerInputs[hand];
        if (timestamp < record.presenceTimestamp) {
            continue;
        }
        record.presenceTimestamp = timestamp;
        record.presenceActive = (activeMask & (1u << hand)) != 0;
        if (record.presenceActive) {
            // A presence bit cannot manufacture a pose. The corresponding
            // ControllerMotion activates it when that sample arrives.
            continue;
        }
        if (timestamp < record.questTimestamp) {
            continue;
        }
        record.poseValid = false;
        record.poseArrival = 0;
        record.questTimestamp = timestamp;
        record.rawLinearVelocity = {};
        record.rawAngularVelocity = {};
    }
    return true;
}

void markReceiverFailedLocked() {
    gReceiverFailed = true;
    gHeadPoseValid = false;
    gAckFailed = true;
    gWaiterStop = true;
    if (gWaiterWake != nullptr) {
        SetEvent(gWaiterWake);
    }
    WakeAllConditionVariable(&gAckCondition);
    WakeAllConditionVariable(&gFrameDeliveryCondition);
}

DWORD WINAPI receiverThreadProc(LPVOID) {
    AcquireSRWLockShared(&gControlLock);
    const SOCKET socket = gSocket;
    ReleaseSRWLockShared(&gControlLock);

    for (;;) {
        uint16_t type = 0;
        uint8_t payload[BASALT_CONTROL_MAX_MESSAGE_LENGTH]{};
        size_t payloadLength = 0;
        RecenterNotification recenter{};
        if (!recvMessage(socket, &type, payload, sizeof(payload), &payloadLength)) {
            AcquireSRWLockExclusive(&gControlLock);
            if (gSocket == socket && !gReceiverFailed) {
                markReceiverFailedLocked();
            }
            ReleaseSRWLockExclusive(&gControlLock);
            return 0;
        }

        AcquireSRWLockExclusive(&gControlLock);
        bool accepted = false;
        if (gSocket != socket || gReceiverFailed) {
            ReleaseSRWLockExclusive(&gControlLock);
            return 0;
        }
        if (type == BASALT_MSG_HEAD_POSE) {
            accepted = parseHeadPose(payload, payloadLength, &recenter);
        } else if (type == BASALT_MSG_CONTROLLER_MOTION) {
            accepted = parseControllerMotion(payload, payloadLength);
        } else if (type == BASALT_MSG_BUTTON_STATE) {
            accepted = parseButtonState(payload, payloadLength);
        } else if (type == BASALT_MSG_INTERACTION_PROFILE) {
            accepted = parseInteractionProfile(payload, payloadLength);
        } else if (type == BASALT_MSG_INPUT_RESET) {
            accepted = parseInputReset(payloadLength);
        } else if (type == BASALT_MSG_VIEW_CONFIG) {
            accepted = parseViewConfig(payload, payloadLength);
        } else if (type == BASALT_MSG_CONTROLLER_MASK) {
            accepted = parseControllerMask(payload, payloadLength);
        } else if (type == BASALT_MSG_FRAME_CONSUMED && payloadLength == 8) {
            uint64_t frameNumber = 0;
            std::memcpy(&frameNumber, payload, sizeof(frameNumber));
            if (frameNumber > gLastConsumedFrameNumber &&
                frameNumber < gNextFrameNumber) {
                gLastConsumedFrameNumber = frameNumber;
                WakeAllConditionVariable(&gFrameDeliveryCondition);
                accepted = true;
            }
        } else if (type == gExpectedAckType && !gAckReady && !gAckFailed &&
                   payloadLength <= sizeof(gAckPayload)) {
            std::memcpy(gAckPayload, payload, payloadLength);
            gAckPayloadLength = payloadLength;
            gAckReady = true;
            WakeAllConditionVariable(&gAckCondition);
            accepted = true;
        }
        if (!accepted) {
            markReceiverFailedLocked();
            ReleaseSRWLockExclusive(&gControlLock);
            shutdown(socket, SD_BOTH);
            return 0;
        }
        ReleaseSRWLockExclusive(&gControlLock);
        if (recenter.ready) {
            basalt::queueReferenceSpaceChange(
                recenter.session, recenter.changeTime,
                recenter.poseInPreviousSpace);
        }
    }
}

bool requestMessage(
    uint16_t requestType,
    const uint8_t* requestPayload,
    size_t requestPayloadLength,
    uint16_t expectedType,
    uint8_t* responsePayload,
    size_t responseCapacity,
    size_t* responseLength) {
    AcquireSRWLockExclusive(&gRequestLock);
    AcquireSRWLockExclusive(&gControlLock);
    if (gSocket == INVALID_SOCKET || gReceiverFailed || gExpectedAckType != 0) {
        ReleaseSRWLockExclusive(&gControlLock);
        ReleaseSRWLockExclusive(&gRequestLock);
        return false;
    }
    const SOCKET socket = gSocket;
    gExpectedAckType = expectedType;
    gAckReady = false;
    gAckFailed = false;
    gAckPayloadLength = 0;
    ReleaseSRWLockExclusive(&gControlLock);

    bool ok = sendMessage(socket, requestType, requestPayload, requestPayloadLength);
    AcquireSRWLockExclusive(&gControlLock);
    if (ok) {
        while (!gAckReady && !gAckFailed && gSocket == socket) {
            if (!SleepConditionVariableSRW(
                    &gAckCondition, &gControlLock,
                    kSocketTimeoutMilliseconds, 0)) {
                ok = false;
                break;
            }
        }
    }
    ok = ok && gAckReady && !gAckFailed && gSocket == socket &&
         gAckPayloadLength <= responseCapacity;
    if (ok && gAckPayloadLength > 0) {
        std::memcpy(responsePayload, gAckPayload, gAckPayloadLength);
    }
    *responseLength = ok ? gAckPayloadLength : 0;
    gExpectedAckType = 0;
    gAckReady = false;
    gAckPayloadLength = 0;
    ReleaseSRWLockExclusive(&gControlLock);
    ReleaseSRWLockExclusive(&gRequestLock);
    return ok;
}

// --- connection lifecycle ---------------------------------------------------

// Joining must happen without the lock held (the waiter takes it to send),
// so disconnect splits into a locked teardown that hands out the thread
// handle and an unlocked join.
struct DisconnectState {
    HANDLE waiterThread = nullptr;
    HANDLE receiverThread = nullptr;
    HANDLE waiterWake = nullptr;
    HANDLE fenceEvent = nullptr;
    ID3D11Fence* fence = nullptr;
    ID3D11DeviceContext4* context4 = nullptr;
    SOCKET socket = INVALID_SOCKET;
};

DisconnectState beginDisconnectLocked() {
    DisconnectState state;
    gWaiterStop = true;
    if (gWaiterWake != nullptr) {
        SetEvent(gWaiterWake);
    }
    state.waiterThread = gWaiterThread;
    state.receiverThread = gReceiverThread;
    state.waiterWake = gWaiterWake;
    state.fenceEvent = gFenceEvent;
    state.fence = gFence;
    state.context4 = gContext4;
    state.socket = gSocket;
    gWaiterThread = nullptr;
    gReceiverThread = nullptr;
    gWaiterWake = nullptr;
    gFenceEvent = nullptr;
    gFence = nullptr;
    gContext4 = nullptr;
    gSocket = INVALID_SOCKET;
    gControlSession = XR_NULL_HANDLE;
    gReceiverFailed = false;
    gExpectedAckType = 0;
    gAckReady = false;
    gAckFailed = true;
    gAckPayloadLength = 0;
    resetTrackingStateLocked();
    gPendingHead = 0;
    gPendingCount = 0;
    WakeAllConditionVariable(&gAckCondition);
    WakeAllConditionVariable(&gFrameDeliveryCondition);
    return state;
}

void finishDisconnect(DisconnectState& state, bool sendTeardown) {
    if (state.socket != INVALID_SOCKET) {
        if (sendTeardown) {
            uint8_t payload[4];
            const uint32_t reason = BASALT_TEARDOWN_SESSION_ENDED;
            std::memcpy(payload, &reason, sizeof(reason));
            uint8_t header[6];
            const uint32_t length = sizeof(uint16_t) + sizeof(payload);
            const uint16_t type = BASALT_MSG_TEARDOWN;
            std::memcpy(header, &length, sizeof(length));
            std::memcpy(header + 4, &type, sizeof(type));
            AcquireSRWLockExclusive(&gSendLock);
            sendAll(state.socket, header, sizeof(header));
            sendAll(state.socket, payload, sizeof(payload));
            ReleaseSRWLockExclusive(&gSendLock);
        }
        shutdown(state.socket, SD_BOTH);
    }
    if (state.waiterThread != nullptr) {
        WaitForSingleObject(state.waiterThread, kWaiterJoinMilliseconds);
        CloseHandle(state.waiterThread);
    }
    if (state.receiverThread != nullptr) {
        WaitForSingleObject(state.receiverThread, kWaiterJoinMilliseconds);
        CloseHandle(state.receiverThread);
    }
    if (state.socket != INVALID_SOCKET) {
        closesocket(state.socket);
    }
    if (state.waiterWake != nullptr) {
        CloseHandle(state.waiterWake);
    }
    if (state.fenceEvent != nullptr) {
        CloseHandle(state.fenceEvent);
    }
    release(state.fence);
    release(state.context4);
}

// The waiter thread: pops queued frames in order, waits the fence value on
// the CPU, and only then sends FrameReady — the Phase-1 frame-done contract.
// The receiver advances gLastConsumedFrameNumber only after the daemon has
// completed Metal reads of the submitted swapchain surfaces.
DWORD WINAPI waiterThreadProc(LPVOID) {
    for (;;) {
        AcquireSRWLockExclusive(&gControlLock);
        if (gWaiterStop) {
            ReleaseSRWLockExclusive(&gControlLock);
            return 0;
        }
        PendingFrame frame;
        bool haveFrame = false;
        ID3D11Fence* fence = gFence;
        HANDLE fenceEvent = gFenceEvent;
        HANDLE wake = gWaiterWake;
        if (gPendingCount > 0) {
            frame = gPendingFrames[gPendingHead];
            gPendingHead = (gPendingHead + 1) % kPendingFrameCapacity;
            --gPendingCount;
            haveFrame = true;
        }
        ReleaseSRWLockExclusive(&gControlLock);

        if (!haveFrame) {
            if (wake == nullptr ||
                WaitForSingleObject(wake, kFenceWaitMilliseconds) == WAIT_FAILED) {
                return 0;
            }
            continue;
        }

        if (fence == nullptr || fenceEvent == nullptr ||
            FAILED(fence->SetEventOnCompletion(frame.frameNumber, fenceEvent)) ||
            WaitForSingleObject(fenceEvent, kFenceWaitMilliseconds) != WAIT_OBJECT_0) {
            // The frame-done contract broke; stop sending rather than lie.
            AcquireSRWLockExclusive(&gControlLock);
            const bool stopping = gWaiterStop;
            DisconnectState state;
            if (!stopping) {
                state = beginDisconnectLocked();
                // A thread cannot join itself; the handle alone is safe to
                // close while running.
                if (state.waiterThread != nullptr) {
                    CloseHandle(state.waiterThread);
                    state.waiterThread = nullptr;
                }
            }
            ReleaseSRWLockExclusive(&gControlLock);
            if (!stopping) {
                finishDisconnect(state, false);
            }
            return 0;
        }

        AcquireSRWLockExclusive(&gControlLock);
        bool sent = false;
        if (!gWaiterStop && gSocket != INVALID_SOCKET) {
            sent = sendMessage(
                gSocket, BASALT_MSG_FRAME_READY, frame.payload, frame.payloadLength);
        } else {
            sent = true;  // shutting down; nothing to report
        }
        ReleaseSRWLockExclusive(&gControlLock);
        if (!sent) {
            AcquireSRWLockExclusive(&gControlLock);
            const bool stopping = gWaiterStop;
            DisconnectState state;
            if (!stopping) {
                state = beginDisconnectLocked();
                if (state.waiterThread != nullptr) {
                    CloseHandle(state.waiterThread);
                    state.waiterThread = nullptr;
                }
            }
            ReleaseSRWLockExclusive(&gControlLock);
            if (!stopping) {
                finishDisconnect(state, false);
            }
            return 0;
        }
    }
}

// Reads "<port> <token> [<per-eye width> <per-eye height>]" from the
// BASALT_CONTROL file.
bool readControlFile(
    uint16_t* port,
    char token[BASALT_CONTROL_TOKEN_LENGTH + 1],
    uint32_t* viewWidth,
    uint32_t* viewHeight) {
    char path[MAX_PATH]{};
    const DWORD pathLength =
        GetEnvironmentVariableA("BASALT_CONTROL", path, sizeof(path));
    if (pathLength == 0 || pathLength >= sizeof(path)) {
        return false;
    }

    const HANDLE file = CreateFileA(
        path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    char contents[128]{};
    DWORD bytesRead = 0;
    const BOOL readOk = ReadFile(file, contents, sizeof(contents) - 1, &bytesRead, nullptr);
    CloseHandle(file);
    if (!readOk || bytesRead == 0) {
        return false;
    }
    contents[bytesRead] = '\0';

    char tokenBuffer[64]{};
    unsigned int parsedPort = 0;
    unsigned int parsedWidth = 0;
    unsigned int parsedHeight = 0;
    char extra = '\0';
    const int parsed = std::sscanf(
        contents, "%u %63s %u %u %c", &parsedPort, tokenBuffer,
        &parsedWidth, &parsedHeight, &extra);
    if ((parsed != 2 && parsed != 4) ||
        parsedPort == 0 || parsedPort > 65535 ||
        std::strlen(tokenBuffer) != BASALT_CONTROL_TOKEN_LENGTH) {
        return false;
    }
    *port = static_cast<uint16_t>(parsedPort);
    std::memcpy(token, tokenBuffer, BASALT_CONTROL_TOKEN_LENGTH + 1);
    if (viewWidth != nullptr) {
        *viewWidth = parsed == 4 ? parsedWidth : 0;
    }
    if (viewHeight != nullptr) {
        *viewHeight = parsed == 4 ? parsedHeight : 0;
    }
    return true;
}

// Third capability probe: one gated texture on the session device must
// republish a nonzero IOSurfaceID, proving the Basalt DXMT fork is active.
bool probeSessionIOSurface(ID3D11Device* device) {
    D3D11_TEXTURE2D_DESC description{};
    description.Width = 2;
    description.Height = 2;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;

    ID3D11Texture2D* texture = nullptr;
    if (FAILED(device->CreateTexture2D(&description, nullptr, &texture))) {
        return false;
    }
    const uint32_t id = basalt::queryTextureIOSurfaceId(texture);
    texture->Release();
    return id != 0;
}

bool connectSocketLocked(uint16_t port) {
    if (!gWsaStarted) {
        WSADATA wsaData{};
        if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
            return false;
        }
        gWsaStarted = true;
    }

    const SOCKET connection = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (connection == INVALID_SOCKET) {
        return false;
    }

    const DWORD timeout = kSocketTimeoutMilliseconds;
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO,
               reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    const BOOL noDelay = TRUE;
    setsockopt(connection, IPPROTO_TCP, TCP_NODELAY,
               reinterpret_cast<const char*>(&noDelay), sizeof(noDelay));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(connection, reinterpret_cast<const sockaddr*>(&address),
                sizeof(address)) != 0) {
        closesocket(connection);
        return false;
    }
    gSocket = connection;
    return true;
}

// Adapter description string for Hello; identifies the DXMT build (the fork
// surfaces its tag there).
void adapterDescription(ID3D11Device* device, char* buffer, size_t capacity) {
    buffer[0] = '\0';
    IDXGIDevice* dxgiDevice = nullptr;
    if (FAILED(device->QueryInterface(__uuidof(IDXGIDevice),
                                      reinterpret_cast<void**>(&dxgiDevice)))) {
        return;
    }
    IDXGIAdapter* adapter = nullptr;
    const HRESULT result = dxgiDevice->GetAdapter(&adapter);
    dxgiDevice->Release();
    if (FAILED(result)) {
        return;
    }
    DXGI_ADAPTER_DESC adapterDesc{};
    if (SUCCEEDED(adapter->GetDesc(&adapterDesc))) {
        const int written = WideCharToMultiByte(
            CP_UTF8, 0, adapterDesc.Description, -1, buffer,
            static_cast<int>(capacity), nullptr, nullptr);
        if (written <= 0) {
            buffer[0] = '\0';
        }
    }
    adapter->Release();
}

}  // namespace

namespace basalt {

bool controlConfiguredViewSize(uint32_t* width, uint32_t* height) {
    if (width == nullptr || height == nullptr) {
        return false;
    }
    uint16_t port = 0;
    char token[BASALT_CONTROL_TOKEN_LENGTH + 1]{};
    uint32_t configuredWidth = 0;
    uint32_t configuredHeight = 0;
    if (!readControlFile(
            &port, token, &configuredWidth, &configuredHeight) ||
        configuredWidth < BASALT_CONTROL_MIN_VIEW_DIMENSION ||
        configuredHeight < BASALT_CONTROL_MIN_VIEW_DIMENSION ||
        configuredWidth > kMaxViewWidth ||
        configuredHeight > kMaxViewHeight ||
        configuredWidth % 2 != 0 || configuredHeight % 2 != 0) {
        return false;
    }
    *width = configuredWidth;
    *height = configuredHeight;
    return true;
}

uint32_t queryTextureIOSurfaceId(ID3D11Texture2D* texture) {
    uint32_t id = 0;
    UINT size = sizeof(id);
    if (FAILED(texture->GetPrivateData(kBasaltIOSurfaceIdGuid, &size, &id)) ||
        size != sizeof(id)) {
        return 0;
    }
    return id;
}

void controlSessionCreated(XrSession session, ID3D11Device* device) {
    if (!basaltGateEnabled() || !probeSessionIOSurface(device)) {
        return;
    }

    uint16_t port = 0;
    char token[BASALT_CONTROL_TOKEN_LENGTH + 1]{};
    if (!readControlFile(&port, token, nullptr, nullptr)) {
        return;
    }

    ID3D11Device5* device5 = nullptr;
    if (FAILED(device->QueryInterface(IID_ID3D11Device5,
                                      reinterpret_cast<void**>(&device5)))) {
        return;
    }
    ID3D11DeviceContext* context = nullptr;
    device->GetImmediateContext(&context);
    ID3D11DeviceContext4* context4 = nullptr;
    const HRESULT contextResult = context->QueryInterface(
        IID_ID3D11DeviceContext4, reinterpret_cast<void**>(&context4));
    context->Release();
    if (FAILED(contextResult)) {
        device5->Release();
        return;
    }
    ID3D11Fence* fence = nullptr;
    const HRESULT fenceResult = device5->CreateFence(
        0, D3D11_FENCE_FLAG_NONE, IID_ID3D11Fence, reinterpret_cast<void**>(&fence));
    device5->Release();
    if (FAILED(fenceResult)) {
        context4->Release();
        return;
    }

    char renderer[kMaxRendererLength]{};
    adapterDescription(device, renderer, sizeof(renderer));
    const size_t rendererLength = std::strlen(renderer);

    AcquireSRWLockExclusive(&gControlLock);
    if (gControlSession != XR_NULL_HANDLE) {
        // Never tear down an existing connection from a stray create.
        ReleaseSRWLockExclusive(&gControlLock);
        release(fence);
        release(context4);
        return;
    }
    bool connected = false;
    do {
        if (!connectSocketLocked(port)) {
            break;
        }

        uint8_t payload[2 + BASALT_CONTROL_TOKEN_LENGTH + 8 + 2 + kMaxRendererLength];
        MessageWriter writer(payload, sizeof(payload));
        writer.u16(BASALT_CONTROL_PROTOCOL_VERSION);
        writer.bytes(token, BASALT_CONTROL_TOKEN_LENGTH);
        writer.u64(reinterpret_cast<uintptr_t>(session));
        writer.u16(static_cast<uint16_t>(rendererLength));
        writer.bytes(renderer, rendererLength);
        if (!writer.ok() ||
            !sendMessage(gSocket, BASALT_MSG_HELLO, payload, writer.length())) {
            closesocket(gSocket);
            gSocket = INVALID_SOCKET;
            break;
        }

        uint8_t ack[8]{};
        size_t ackLength = 0;
        uint16_t acceptedVersion = 0;
        if (!recvExpectedMessage(
                gSocket, BASALT_MSG_HELLO_ACK, ack, sizeof(ack), &ackLength) ||
            ackLength != sizeof(acceptedVersion)) {
            closesocket(gSocket);
            gSocket = INVALID_SOCKET;
            break;
        }
        std::memcpy(&acceptedVersion, ack, sizeof(acceptedVersion));
        if (acceptedVersion != BASALT_CONTROL_PROTOCOL_VERSION) {
            closesocket(gSocket);
            gSocket = INVALID_SOCKET;
            break;
        }

        gWaiterWake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        gFenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (gWaiterWake == nullptr || gFenceEvent == nullptr) {
            break;
        }
        gWaiterStop = false;
        gReceiverFailed = false;
        gExpectedAckType = 0;
        gAckReady = false;
        gAckFailed = false;
        resetTrackingStateLocked();
        gControlSession = session;
        gContext4 = context4;
        gFence = fence;
        context4 = nullptr;
        fence = nullptr;
        gNextFrameNumber = 1;
        gLastConsumedFrameNumber = 0;
        gPendingHead = 0;
        gPendingCount = 0;
        gReceiverThread = CreateThread(
            nullptr, 0, receiverThreadProc, nullptr, 0, nullptr);
        if (gReceiverThread == nullptr) {
            break;
        }
        gWaiterThread = CreateThread(nullptr, 0, waiterThreadProc, nullptr, 0, nullptr);
        if (gWaiterThread == nullptr) {
            break;
        }
        connected = true;
    } while (false);

    if (!connected) {
        DisconnectState state = beginDisconnectLocked();
        ReleaseSRWLockExclusive(&gControlLock);
        finishDisconnect(state, false);
        release(fence);
        release(context4);
        return;
    }
    ReleaseSRWLockExclusive(&gControlLock);
}

void controlSessionDestroyed(XrSession session) {
    AcquireSRWLockExclusive(&gControlLock);
    if (gControlSession != session) {
        ReleaseSRWLockExclusive(&gControlLock);
        return;
    }
    DisconnectState state = beginDisconnectLocked();
    ReleaseSRWLockExclusive(&gControlLock);
    finishDisconnect(state, true);
}

bool controlActive(XrSession session) {
    AcquireSRWLockShared(&gControlLock);
    const bool active = session != XR_NULL_HANDLE && gControlSession == session &&
                        gSocket != INVALID_SOCKET && !gReceiverFailed;
    ReleaseSRWLockShared(&gControlLock);
    return active;
}

void controlNotePredictedDisplayTime(XrSession session, XrTime predictedDisplayTime) {
    AcquireSRWLockExclusive(&gControlLock);
    if (session != XR_NULL_HANDLE && gControlSession == session &&
        predictedDisplayTime > gLatestPredictedDisplayTime) {
        gLatestPredictedDisplayTime = predictedDisplayTime;
    }
    ReleaseSRWLockExclusive(&gControlLock);
}

bool controlWaitForFrameBudget(XrSession session) {
    AcquireSRWLockExclusive(&gControlLock);
    const uint64_t lastQueuedFrame =
        gNextFrameNumber == 0 ? 0 : gNextFrameNumber - 1;
    bool timedOut = false;
    while (gControlSession == session && gSocket != INVALID_SOCKET &&
           !gReceiverFailed &&
           gLastConsumedFrameNumber + kFrameWindow <= lastQueuedFrame) {
        if (!SleepConditionVariableSRW(
                &gFrameDeliveryCondition, &gControlLock,
                kFrameConsumeMilliseconds, 0)) {
            timedOut = true;
            break;
        }
    }
    const bool active = gControlSession == session &&
                        gSocket != INVALID_SOCKET && !gReceiverFailed &&
                        !timedOut;
    DisconnectState state;
    if (timedOut && gControlSession == session) {
        state = beginDisconnectLocked();
    }
    ReleaseSRWLockExclusive(&gControlLock);
    if (state.socket != INVALID_SOCKET) {
        finishDisconnect(state, false);
    }
    return active;
}

bool controlHeadPose(
    XrSession session,
    XrTime locateTime,
    uint64_t* questTimestampNanoseconds,
    XrPosef* poseInLocal) {
    const XrTime now = monotonicTime();
    AcquireSRWLockShared(&gControlLock);
    const bool fresh = session != XR_NULL_HANDLE && gControlSession == session &&
                       gSocket != INVALID_SOCKET && !gReceiverFailed &&
                       gHeadPoseValid && gHeadPoseArrival > 0 &&
                       now >= gHeadPoseArrival &&
                       now - gHeadPoseArrival <= kHeadPoseFreshness;
    if (fresh) {
        if (questTimestampNanoseconds != nullptr) {
            *questTimestampNanoseconds = gHeadPoseQuestTimestamp;
        }
        if (poseInLocal != nullptr) {
            *poseInLocal = poseCompose(
                localTransformForTimeLocked(locateTime), gRawHeadPose);
        }
    }
    ReleaseSRWLockShared(&gControlLock);
    return fresh;
}

bool controlInputSnapshot(
    XrSession session,
    ControlInputSnapshot* snapshot,
    XrTime locateTime) {
    if (snapshot == nullptr) {
        return false;
    }
    *snapshot = {};
    const XrTime now = monotonicTime();
    AcquireSRWLockShared(&gControlLock);
    const bool connected = session != XR_NULL_HANDLE && gControlSession == session &&
                           gSocket != INVALID_SOCKET && !gReceiverFailed;
    if (connected) {
        const XrPosef& localFromQuest = localTransformForTimeLocked(locateTime);
        for (uint32_t hand = 0; hand < 2; ++hand) {
            const ControllerInputRecord& source = gControllerInputs[hand];
            ControlControllerState& destination = snapshot->controllers[hand];
            destination.profileActive = source.profileActive;
            destination.profileId = source.profileId;
            destination.poseActive = source.poseValid && source.poseArrival > 0 &&
                                     now >= source.poseArrival &&
                                     now - source.poseArrival <= kControllerPoseFreshness;
            destination.questTimestampNanoseconds = source.questTimestamp;
            destination.poseInLocal = poseCompose(localFromQuest, source.rawPose);
            destination.linearVelocity = quaternionRotate(
                localFromQuest.orientation, source.rawLinearVelocity);
            destination.angularVelocity = quaternionRotate(
                localFromQuest.orientation, source.rawAngularVelocity);
        }
        for (const ButtonInputRecord& source : gButtonInputs) {
            if (!source.valid || snapshot->buttonCount >= kControlButtonCapacity) {
                continue;
            }
            ControlButtonState& destination =
                snapshot->buttons[snapshot->buttonCount++];
            destination.pathId = source.pathId;
            destination.valueType = source.valueType;
            destination.value = source.value;
            destination.lastChangeTime = source.lastChangeTime;
        }
    }
    ReleaseSRWLockShared(&gControlLock);
    return connected;
}

bool controlViewConfig(
    XrSession session,
    float* ipdMeters,
    XrFovf fov[2]) {
    if (ipdMeters == nullptr || fov == nullptr) {
        return false;
    }
    AcquireSRWLockShared(&gControlLock);
    const bool available = session != XR_NULL_HANDLE && gControlSession == session &&
                           gSocket != INVALID_SOCKET && !gReceiverFailed &&
                           gViewConfigValid;
    if (available) {
        *ipdMeters = gViewConfigIpdMeters;
        fov[0] = gViewConfigFov[0];
        fov[1] = gViewConfigFov[1];
    }
    ReleaseSRWLockShared(&gControlLock);
    return available;
}

bool controlSendHaptic(
    XrSession session,
    ControlHand hand,
    uint64_t durationNanoseconds,
    float frequency,
    float amplitude) {
    const uint32_t handValue = static_cast<uint32_t>(hand);
    if (handValue > 1 || !std::isfinite(frequency) || frequency < 0.0f ||
        !std::isfinite(amplitude) || amplitude < 0.0f || amplitude > 1.0f) {
        return false;
    }
    AcquireSRWLockShared(&gControlLock);
    const SOCKET socket = session != XR_NULL_HANDLE && gControlSession == session &&
                                  gSocket != INVALID_SOCKET && !gReceiverFailed
                              ? gSocket
                              : INVALID_SOCKET;
    ReleaseSRWLockShared(&gControlLock);
    if (socket == INVALID_SOCKET) {
        return false;
    }
    uint8_t payload[20]{};
    MessageWriter writer(payload, sizeof(payload));
    writer.u32(handValue);
    writer.u64(durationNanoseconds);
    writer.f32(frequency);
    writer.f32(amplitude);
    return writer.ok() &&
           sendMessage(socket, BASALT_MSG_HAPTIC, payload, writer.length());
}

void controlRegisterSwapchain(
    XrSwapchain swapchain,
    uint32_t width,
    uint32_t height,
    int64_t dxgiFormat,
    const uint32_t* iosurfaceIds,
    uint32_t imageCount) {
    AcquireSRWLockShared(&gControlLock);
    const bool headless = gSocket == INVALID_SOCKET;
    ReleaseSRWLockShared(&gControlLock);
    if (headless) {
        return;
    }

    uint8_t payload[8 + 4 + 4 + 4 + 4 + 16 * sizeof(uint32_t)];
    MessageWriter writer(payload, sizeof(payload));
    writer.u64(reinterpret_cast<uintptr_t>(swapchain));
    writer.u32(width);
    writer.u32(height);
    writer.u32(static_cast<uint32_t>(dxgiFormat));
    writer.u32(imageCount);
    for (uint32_t index = 0; index < imageCount; ++index) {
        writer.u32(iosurfaceIds[index]);
    }
    uint8_t ack[16]{};
    size_t ackLength = 0;
    const bool requested = writer.ok() && requestMessage(
        BASALT_MSG_CREATE_SWAPCHAIN, payload, writer.length(),
        BASALT_MSG_SWAPCHAIN_ACK, ack, sizeof(ack), &ackLength);
    uint64_t ackId = 0;
    if (ackLength >= sizeof(ackId)) {
        std::memcpy(&ackId, ack, sizeof(ackId));
    }
    const bool ok = requested && ackLength == 12 &&
                    ackId == reinterpret_cast<uintptr_t>(swapchain);

    if (!ok) {
        AcquireSRWLockExclusive(&gControlLock);
        DisconnectState state = beginDisconnectLocked();
        ReleaseSRWLockExclusive(&gControlLock);
        finishDisconnect(state, false);
    }
}

void controlUnregisterSwapchain(XrSwapchain swapchain) {
    // FrameReady is sent asynchronously after its D3D fence completes.
    // Preserve wire ordering: the daemon must see every already-submitted
    // frame before DestroySwapchain releases the IOSurfaces it references.
    AcquireSRWLockExclusive(&gControlLock);
    const uint64_t lastQueuedFrame =
        gNextFrameNumber == 0 ? 0 : gNextFrameNumber - 1;
    bool headless = gSocket == INVALID_SOCKET;
    bool drained = headless;
    while (!headless && !gReceiverFailed &&
           gLastConsumedFrameNumber < lastQueuedFrame) {
        if (!SleepConditionVariableSRW(
                &gFrameDeliveryCondition, &gControlLock,
                kFrameConsumeMilliseconds, 0)) {
            break;
        }
        headless = gSocket == INVALID_SOCKET;
    }
    drained = headless || (!gReceiverFailed &&
        gLastConsumedFrameNumber >= lastQueuedFrame);
    ReleaseSRWLockExclusive(&gControlLock);
    if (headless) {
        return;
    }
    if (!drained) {
        AcquireSRWLockExclusive(&gControlLock);
        DisconnectState state = beginDisconnectLocked();
        ReleaseSRWLockExclusive(&gControlLock);
        finishDisconnect(state, false);
        return;
    }

    uint8_t payload[8];
    const uint64_t swapchainId = reinterpret_cast<uintptr_t>(swapchain);
    std::memcpy(payload, &swapchainId, sizeof(swapchainId));
    uint8_t ack[8]{};
    size_t ackLength = 0;
    const bool requested = requestMessage(
        BASALT_MSG_DESTROY_SWAPCHAIN, payload, sizeof(payload),
        BASALT_MSG_DESTROY_SWAPCHAIN_ACK, ack, sizeof(ack), &ackLength);
    uint64_t ackId = 0;
    if (ackLength == sizeof(ackId)) {
        std::memcpy(&ackId, ack, sizeof(ackId));
    }
    const bool ok = requested && ackLength == sizeof(uint64_t) && ackId == swapchainId;

    if (!ok) {
        // Socket teardown drops the daemon's surface retains, so the caller
        // may still release the textures safely.
        AcquireSRWLockExclusive(&gControlLock);
        DisconnectState state = beginDisconnectLocked();
        ReleaseSRWLockExclusive(&gControlLock);
        finishDisconnect(state, false);
    }
}

uint64_t controlFrameReady(
    int64_t displayTime,
    uint64_t questTrackingTimestampNanoseconds,
    const ControlFrameView* views,
    uint32_t viewCount,
    bool exportViews) {
    if (viewCount == 0 || viewCount > kMaxFrameViews) {
        return 0;
    }

    AcquireSRWLockExclusive(&gControlLock);
    if (gSocket == INVALID_SOCKET || gReceiverFailed ||
        gFence == nullptr || gContext4 == nullptr) {
        ReleaseSRWLockExclusive(&gControlLock);
        return 0;
    }

    ControlFrameView preparedViews[kMaxFrameViews]{};
    for (uint32_t index = 0; index < viewCount; ++index) {
        preparedViews[index] = views[index];
        if (exportViews && !prepareSwapchainViewForExport(
                gContext4, &preparedViews[index])) {
            DisconnectState state = beginDisconnectLocked();
            ReleaseSRWLockExclusive(&gControlLock);
            finishDisconnect(state, false);
            return 0;
        }
    }

    const uint64_t frameNumber = gNextFrameNumber++;
    PendingFrame* slot = nullptr;
    if (gPendingCount == kPendingFrameCapacity) {
        // xrWaitFrame's budget bounds unconsumed frames to the ring capacity,
        // so reaching this guard means that contract broke; disconnect rather
        // than drop ordered frame metadata.
        DisconnectState state = beginDisconnectLocked();
        ReleaseSRWLockExclusive(&gControlLock);
        finishDisconnect(state, false);
        return 0;
    }
    slot = &gPendingFrames[(gPendingHead + gPendingCount) % kPendingFrameCapacity];
    ++gPendingCount;

    MessageWriter writer(slot->payload, sizeof(slot->payload));
    writer.u64(frameNumber);
    writer.s64(displayTime);
    writer.u64(questTrackingTimestampNanoseconds);
    writer.u32(viewCount);
    for (uint32_t index = 0; index < viewCount; ++index) {
        const ControlFrameView& view = preparedViews[index];
        writer.u64(view.swapchainId);
        writer.u32(view.imageIndex);
        writer.u32(view.imageArrayIndex);
        writer.s32(view.rect.offset.x);
        writer.s32(view.rect.offset.y);
        writer.s32(view.rect.extent.width);
        writer.s32(view.rect.extent.height);
        writer.f32(view.pose.orientation.x);
        writer.f32(view.pose.orientation.y);
        writer.f32(view.pose.orientation.z);
        writer.f32(view.pose.orientation.w);
        writer.f32(view.pose.position.x);
        writer.f32(view.pose.position.y);
        writer.f32(view.pose.position.z);
        writer.f32(view.fov.angleLeft);
        writer.f32(view.fov.angleRight);
        writer.f32(view.fov.angleUp);
        writer.f32(view.fov.angleDown);
    }
    slot->frameNumber = frameNumber;
    slot->payloadLength = static_cast<uint32_t>(writer.length());

    // Caller is the xrEndFrame thread, which owns the immediate context per
    // the D3D11 binding contract, so Signal/Flush here is safe.
    ID3D11Fence* fence = gFence;
    ID3D11DeviceContext4* context4 = gContext4;
    HANDLE wake = gWaiterWake;
    const HRESULT signalResult = context4->Signal(fence, frameNumber);
    context4->Flush();
    if (FAILED(signalResult)) {
        DisconnectState state = beginDisconnectLocked();
        ReleaseSRWLockExclusive(&gControlLock);
        finishDisconnect(state, false);
        return 0;
    }
    if (wake != nullptr) {
        SetEvent(wake);
    }
    ReleaseSRWLockExclusive(&gControlLock);
    return frameNumber;
}

bool controlWaitForFrameConsumed(XrSession session, uint64_t frameNumber) {
    if (frameNumber == 0) {
        return true;
    }
    AcquireSRWLockExclusive(&gControlLock);
    bool timedOut = false;
    while (gControlSession == session && gSocket != INVALID_SOCKET &&
           !gReceiverFailed && gLastConsumedFrameNumber < frameNumber) {
        if (!SleepConditionVariableSRW(
                &gFrameDeliveryCondition, &gControlLock,
                kFrameConsumeMilliseconds, 0)) {
            timedOut = true;
            break;
        }
    }
    const bool consumed = gControlSession == session &&
                          gSocket != INVALID_SOCKET && !gReceiverFailed &&
                          gLastConsumedFrameNumber >= frameNumber;
    DisconnectState state;
    if (timedOut && gControlSession == session) {
        // Same policy as the frame budget: a daemon that stops consuming is
        // dropped instead of letting the compositor overwrite a read image.
        state = beginDisconnectLocked();
    }
    ReleaseSRWLockExclusive(&gControlLock);
    if (state.socket != INVALID_SOCKET) {
        finishDisconnect(state, false);
    }
    return consumed;
}

}  // namespace basalt
