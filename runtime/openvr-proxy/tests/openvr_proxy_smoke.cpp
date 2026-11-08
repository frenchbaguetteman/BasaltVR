// Loads the Basalt openvr_api.dll proxy through the import table, the way a game does, and checks
// that every OpenComposite export resolves to openvr_api_opencomposite.dll next to it.
//
//   openvr_proxy_smoke.exe fake           next to the fake OpenComposite DLL; checks call routing
//   openvr_proxy_smoke.exe opencomposite  next to a real OpenComposite build; checks resolution

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

extern "C" {
__declspec(dllimport) void* VR_GetGenericInterface(const char* version, int* error);
__declspec(dllimport) uint32_t VR_GetInitToken();
__declspec(dllimport) bool VR_IsRuntimeInstalled();
__declspec(dllimport) void* VRControlPanel();
__declspec(dllimport) void* VRHeadsetView();
__declspec(dllimport) void* VRPaths();
__declspec(dllimport) void* LiquidVR();
__declspec(dllimport) void* VRVirtualDisplay();
__declspec(dllimport) bool VR_GetRuntimePath(char* buffer, uint32_t bufferSize,
                                             uint32_t* requiredBufferSize);
}

namespace {

constexpr const char* kOpenCompositeExports[] = {
#define BASALT_OPENCOMPOSITE_EXPORT(name) #name,
#include "opencomposite_exports.inc"
#undef BASALT_OPENCOMPOSITE_EXPORT
};

constexpr uint32_t kFakeReturn = 0x5a5a5a5au;

int gFailures = 0;

void check(bool condition, const char* description) {
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description);
    if (!condition) {
        ++gFailures;
    }
}

template <typename Function>
Function resolve(HMODULE module, const char* name) {
    return reinterpret_cast<Function>(reinterpret_cast<void*>(GetProcAddress(module, name)));
}

bool sameDirectory(HMODULE first, HMODULE second) {
    char firstPath[MAX_PATH * 4];
    char secondPath[MAX_PATH * 4];
    DWORD firstLength = GetModuleFileNameA(first, firstPath, sizeof(firstPath));
    DWORD secondLength = GetModuleFileNameA(second, secondPath, sizeof(secondPath));
    if (firstLength == 0 || secondLength == 0) {
        return false;
    }
    char* firstSlash = std::strrchr(firstPath, '\\');
    char* secondSlash = std::strrchr(secondPath, '\\');
    if (firstSlash == nullptr || secondSlash == nullptr) {
        return false;
    }
    *firstSlash = '\0';
    *secondSlash = '\0';
    return lstrcmpiA(firstPath, secondPath) == 0;
}

void checkForwarding(HMODULE proxy, HMODULE target) {
    int unresolved = 0;
    for (const char* name : kOpenCompositeExports) {
        FARPROC viaProxy = GetProcAddress(proxy, name);
        FARPROC direct = GetProcAddress(target, name);
        if (viaProxy == nullptr || viaProxy != direct) {
            std::printf("  export %s: proxy %p, OpenComposite %p\n", name,
                        reinterpret_cast<void*>(viaProxy), reinterpret_cast<void*>(direct));
            ++unresolved;
        }
    }
    std::printf("  %u OpenComposite exports checked\n",
                static_cast<unsigned>(sizeof(kOpenCompositeExports) / sizeof(*kOpenCompositeExports)));
    check(unresolved == 0, "every OpenComposite export resolves through the proxy to the same address");
}

void checkUnsupportedAccessors(uint32_t (*callCount)()) {
    const uint32_t before = callCount != nullptr ? callCount() : 0;
    check(VRPaths() == nullptr, "VRPaths returns nullptr");
    check(LiquidVR() == nullptr, "LiquidVR returns nullptr");
    check(VRVirtualDisplay() == nullptr, "VRVirtualDisplay returns nullptr");
    if (callCount != nullptr) {
        check(callCount() == before,
              "unsupported accessors never ask OpenComposite (it aborts on unknown versions)");
    }
}

bool calledSince(uint32_t (*callCount)(), const char* (*callName)(uint32_t), uint32_t start,
                 const char* name) {
    for (uint32_t index = start; index < callCount(); ++index) {
        const char* recorded = callName(index);
        if (recorded != nullptr && std::strcmp(recorded, name) == 0) {
            return true;
        }
    }
    return false;
}

int runFake(HMODULE proxy, HMODULE target) {
    auto callCount = resolve<uint32_t (*)()>(target, "BasaltFakeCallCount");
    auto callName = resolve<const char* (*)(uint32_t)>(target, "BasaltFakeCallName");
    auto lastVersion = resolve<const char* (*)()>(target, "BasaltFakeLastInterfaceVersion");
    auto interfaceObject = resolve<void* (*)(const char*)>(target, "BasaltFakeInterfaceObject");
    auto setAvailable = resolve<void (*)(bool)>(target, "BasaltFakeSetInterfacesAvailable");
    if (!callCount || !callName || !lastVersion || !interfaceObject || !setAvailable) {
        check(false, "fake OpenComposite test hooks resolve");
        return 1;
    }

    checkForwarding(proxy, target);

    uint32_t start = callCount();
    check(VR_GetInitToken() == kFakeReturn, "VR_GetInitToken returns the fake DLL's value");
    check(calledSince(callCount, callName, start, "VR_GetInitToken"),
          "VR_GetInitToken reached the fake DLL");

    start = callCount();
    check(VR_IsRuntimeInstalled(), "VR_IsRuntimeInstalled returns true");
    check(calledSince(callCount, callName, start, "VR_IsRuntimeInstalled"),
          "VR_IsRuntimeInstalled reached the fake DLL");

    int error = -1;
    void* direct = VR_GetGenericInterface("IVRControlPanel_006", &error);
    check(direct == interfaceObject("IVRControlPanel_006") && error == 0,
          "forwarded VR_GetGenericInterface reaches the fake DLL");

    start = callCount();
    void* controlPanel = VRControlPanel();
    check(controlPanel != nullptr && controlPanel == interfaceObject("IVRControlPanel_006"),
          "VRControlPanel returns the fake VR_GetGenericInterface(\"IVRControlPanel_006\") object");
    check(calledSince(callCount, callName, start, "VR_GetGenericInterface") &&
              std::strcmp(lastVersion(), "IVRControlPanel_006") == 0,
          "VRControlPanel requested IVRControlPanel_006");

    void* headsetView = VRHeadsetView();
    check(headsetView != nullptr && headsetView == interfaceObject("IVRHeadsetView_001") &&
              std::strcmp(lastVersion(), "IVRHeadsetView_001") == 0,
          "VRHeadsetView returns the fake IVRHeadsetView_001 object");

    setAvailable(false);
    check(VRControlPanel() == nullptr, "VRControlPanel returns nullptr when the interface fails");
    check(VRHeadsetView() == nullptr, "VRHeadsetView returns nullptr when the interface fails");
    setAvailable(true);

    checkUnsupportedAccessors(callCount);

    uint32_t required = 0;
    char tiny[2] = {'x', 'x'};
    check(VR_GetRuntimePath(tiny, sizeof(tiny), &required) && tiny[0] == '\0' && required > 2,
          "VR_GetRuntimePath reports the required size for a short buffer");
    char path[MAX_PATH * 4];
    char expected[MAX_PATH * 4];
    DWORD expectedLength = GetModuleFileNameA(target, expected, sizeof(expected));
    char* slash = expectedLength != 0 ? std::strrchr(expected, '\\') : nullptr;
    if (slash != nullptr) {
        *slash = '\0';
    }
    check(VR_GetRuntimePath(path, sizeof(path), &required) && slash != nullptr &&
              lstrcmpiA(path, expected) == 0 && required == std::strlen(path) + 1,
          "VR_GetRuntimePath reports the OpenComposite directory");
    std::printf("  runtime path: %s\n", path);
    return 0;
}

int runOpenComposite(HMODULE proxy, HMODULE target) {
    checkForwarding(proxy, target);
    check(VR_IsRuntimeInstalled(), "OpenComposite VR_IsRuntimeInstalled returns true");
    check(VR_GetInitToken() != 0, "OpenComposite VR_GetInitToken returns a token");
    // Before VR_Init, OpenComposite reports VRInitError_Init_NotInitialized; the proxy must turn
    // that into nullptr rather than crash or abort.
    check(VRControlPanel() == nullptr, "VRControlPanel before VR_Init returns nullptr");
    checkUnsupportedAccessors(nullptr);
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const bool fake = argc > 1 && std::strcmp(argv[1], "fake") == 0;
    const bool real = argc > 1 && std::strcmp(argv[1], "opencomposite") == 0;
    if (!fake && !real) {
        std::fprintf(stderr, "usage: openvr_proxy_smoke.exe fake|opencomposite\n");
        return 2;
    }

    HMODULE proxy = GetModuleHandleW(L"openvr_api.dll");
    HMODULE target = GetModuleHandleW(L"openvr_api_opencomposite.dll");
    check(proxy != nullptr, "proxy openvr_api.dll is loaded through the import table");
    check(target != nullptr, "forwarders loaded openvr_api_opencomposite.dll");
    if (proxy == nullptr || target == nullptr) {
        std::printf("FAIL: openvr proxy smoke (%s)\n", argv[1]);
        return 1;
    }
    check(proxy != target, "proxy and OpenComposite are distinct modules");
    check(sameDirectory(proxy, target), "OpenComposite was loaded from the proxy's directory");
    check(resolve<void* (*)()>(target, "VRControlPanel") == nullptr,
          "OpenComposite itself does not export VRControlPanel");

    if (fake) {
        runFake(proxy, target);
    } else {
        runOpenComposite(proxy, target);
    }

    if (gFailures != 0) {
        std::printf("FAIL: openvr proxy smoke (%s): %d check(s) failed\n", argv[1], gFailures);
        return 1;
    }
    std::printf("PASS: openvr proxy smoke (%s)\n", argv[1]);
    return 0;
}
