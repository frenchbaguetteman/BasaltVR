#pragma once

#include <openxr/openxr.h>

// Rigid-transform helpers shared by space location and the control-socket
// LOCAL-origin bookkeeping. Quaternions are assumed normalized.
namespace basalt {

inline XrPosef identityPose() {
    return {{0.0f, 0.0f, 0.0f, 1.0f}, {0.0f, 0.0f, 0.0f}};
}

inline XrQuaternionf quaternionMultiply(const XrQuaternionf& a, const XrQuaternionf& b) {
    return {
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

inline XrVector3f quaternionRotate(const XrQuaternionf& q, const XrVector3f& v) {
    const XrVector3f qv{q.x, q.y, q.z};
    const XrVector3f uv{
        qv.y * v.z - qv.z * v.y,
        qv.z * v.x - qv.x * v.z,
        qv.x * v.y - qv.y * v.x,
    };
    const XrVector3f uuv{
        qv.y * uv.z - qv.z * uv.y,
        qv.z * uv.x - qv.x * uv.z,
        qv.x * uv.y - qv.y * uv.x,
    };
    return {
        v.x + 2.0f * (q.w * uv.x + uuv.x),
        v.y + 2.0f * (q.w * uv.y + uuv.y),
        v.z + 2.0f * (q.w * uv.z + uuv.z),
    };
}

inline XrPosef poseCompose(const XrPosef& a, const XrPosef& b) {
    const XrVector3f rotated = quaternionRotate(a.orientation, b.position);
    return {
        quaternionMultiply(a.orientation, b.orientation),
        {a.position.x + rotated.x, a.position.y + rotated.y, a.position.z + rotated.z},
    };
}

inline XrPosef poseInvert(const XrPosef& pose) {
    const XrQuaternionf conjugate{
        -pose.orientation.x,
        -pose.orientation.y,
        -pose.orientation.z,
        pose.orientation.w,
    };
    const XrVector3f rotated = quaternionRotate(conjugate, pose.position);
    return {conjugate, {-rotated.x, -rotated.y, -rotated.z}};
}

}  // namespace basalt
