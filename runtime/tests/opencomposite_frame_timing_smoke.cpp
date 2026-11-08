// Loads OpenComposite's openvr_api.dll (from the current directory), starts it on the
// registered Basalt OpenXR runtime, and checks IVRCompositor::GetFrameTiming for the old
// IVRCompositor_013 struct (168 bytes) and the IVRCompositor_018+ struct (200 bytes).
//
// Old SteamVR Unity plugins (The Lab's Secret Shop: Unity 5.4, IVRCompositor_013) set
//   Time.fixedDeltaTime = timeScale * m_nNumFramePresents / hmd_DisplayFrequency
// after every frame. Stock OpenComposite zeroes any struct smaller than the 018 one, so
// m_nNumFramePresents was 0 and Unity ran physics thousands of times per frame (about
// 1 fps). Basalt patch 0005 fills the old layout. Needs opencomposite.ini with
// initUsingVulkan=false next to the DLL.

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

// OpenVR ABI (openvr.h, BSD-3-Clause): TrackedDevicePose_t is 80 bytes.
struct TrackedDevicePose {
    float deviceToAbsoluteTracking[3][4];
    float velocity[3];
    float angularVelocity[3];
    int32_t trackingResult;
    bool poseIsValid;
    bool deviceIsConnected;
};
static_assert(sizeof(TrackedDevicePose) == 80, "TrackedDevicePose_t layout");

// IVRCompositor_012 to _014 (OpenVR 0.9.x to 1.0.0).
struct FrameTiming013 {
    uint32_t size;
    uint32_t frameIndex;
    uint32_t numFramePresents;
    uint32_t numDroppedFrames;
    double systemTimeInSeconds;
    float milliseconds[15];
    TrackedDevicePose hmdPose;
    int32_t fidelityLevel;
};
static_assert(sizeof(FrameTiming013) == 168, "IVRCompositor_013 Compositor_FrameTiming size");
static_assert(offsetof(FrameTiming013, numFramePresents) == 8, "m_nNumFramePresents offset");

// IVRCompositor_018 and later.
struct FrameTiming018 {
    uint32_t size;
    uint32_t frameIndex;
    uint32_t numFramePresents;
    uint32_t numMisPresented;
    uint32_t numDroppedFrames;
    uint32_t reprojectionFlags;
    double systemTimeInSeconds;
    float milliseconds[16];
    TrackedDevicePose hmdPose;
    uint32_t vsyncs[5];
};
static_assert(sizeof(FrameTiming018) == 200, "IVRCompositor_018 Compositor_FrameTiming size");

using InitInternal2Fn = uint32_t (*)(int* error, int applicationType, const char* startupInfo);
using ShutdownInternalFn = void (*)();
using GetGenericInterfaceFn = void* (*)(const char* version, int* error);
// FnTable:IVRCompositor_013 slot 8 (after SetTrackingSpace, GetTrackingSpace, WaitGetPoses,
// GetLastPoses, GetLastPoseForTrackedDeviceIndex, Submit, ClearLastSubmittedFrame,
// PostPresentHandoff).
using GetFrameTimingFn = bool (*)(void* timing, uint32_t framesAgo);
constexpr size_t kGetFrameTimingSlot013 = 8;

int gFailures = 0;

void check(bool condition, const char* description) {
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description);
    if (!condition) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    HMODULE openvr = LoadLibraryA("openvr_api.dll");
    if (openvr == nullptr) {
        std::printf("FAIL: cannot load openvr_api.dll (error %lu)\n", GetLastError());
        return 1;
    }
    auto initInternal2 = reinterpret_cast<InitInternal2Fn>(
        reinterpret_cast<void*>(GetProcAddress(openvr, "VR_InitInternal2")));
    auto shutdownInternal = reinterpret_cast<ShutdownInternalFn>(
        reinterpret_cast<void*>(GetProcAddress(openvr, "VR_ShutdownInternal")));
    auto getGenericInterface = reinterpret_cast<GetGenericInterfaceFn>(
        reinterpret_cast<void*>(GetProcAddress(openvr, "VR_GetGenericInterface")));
    if (initInternal2 == nullptr || shutdownInternal == nullptr || getGenericInterface == nullptr) {
        std::printf("FAIL: openvr_api.dll lacks VR_InitInternal2/VR_ShutdownInternal/VR_GetGenericInterface\n");
        return 1;
    }

    int error = -1;
    initInternal2(&error, 1 /* VRApplication_Scene */, nullptr);
    if (error != 0) {
        std::printf("FAIL: VR_InitInternal2 error %d\n", error);
        return 1;
    }
    std::printf("ok: OpenComposite started on the Basalt runtime\n");

    error = -1;
    auto** table = static_cast<void**>(getGenericInterface("FnTable:IVRCompositor_013", &error));
    check(table != nullptr && error == 0, "VR_GetGenericInterface(FnTable:IVRCompositor_013)");
    if (table != nullptr && error == 0) {
        auto getFrameTiming = reinterpret_cast<GetFrameTimingFn>(table[kGetFrameTimingSlot013]);

        FrameTiming013 legacy;
        std::memset(&legacy, 0xcd, sizeof(legacy));
        legacy.size = sizeof(legacy);
        const bool legacyResult = getFrameTiming(&legacy, 0);
        std::printf("    013 struct: returned %d, m_nNumFramePresents %u, m_flTotalRenderGpuMs %.1f\n",
                    legacyResult ? 1 : 0, legacy.numFramePresents, legacy.milliseconds[1]);
        check(legacyResult, "GetFrameTiming accepts the 168-byte IVRCompositor_013 struct");
        check(legacy.numFramePresents == 1,
              "m_nNumFramePresents is 1 for IVRCompositor_013 (0 makes Unity 5 SteamVR physics run every 0.0001 s)");
        check(legacy.size == sizeof(legacy), "m_nSize is kept");

        FrameTiming018 current;
        std::memset(&current, 0xcd, sizeof(current));
        current.size = sizeof(current);
        const bool currentResult = getFrameTiming(&current, 0);
        check(currentResult && current.numFramePresents == 1,
              "m_nNumFramePresents is 1 for the 200-byte IVRCompositor_018 struct");
    }

    shutdownInternal();
    if (gFailures != 0) {
        std::printf("FAIL: %d OpenComposite frame-timing check(s)\n", gFailures);
        return 1;
    }
    std::printf("PASS: OpenComposite frame timing for old and new SteamVR plugins\n");
    return 0;
}
