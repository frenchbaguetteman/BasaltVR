// Stand-in for OpenComposite with the same export names. Every export records its name so the
// smoke test can prove that a call through the proxy reached this DLL.

#include <windows.h>

#include <cstdint>
#include <cstring>

namespace {

constexpr uint32_t kMaxCalls = 256;
constexpr uintptr_t kFakeReturn = 0x5a5a5a5au;
constexpr int kInitErrorNone = 0;
constexpr int kInitErrorInterfaceNotFound = 105;

const char* gCalls[kMaxCalls];
uint32_t gCallCount = 0;
char gLastInterfaceVersion[128];
bool gInterfacesAvailable = true;

struct FakeInterface {
    const char* version;
};
FakeInterface gControlPanel{"IVRControlPanel_006"};
FakeInterface gHeadsetView{"IVRHeadsetView_001"};

void record(const char* name) {
    if (gCallCount < kMaxCalls) {
        gCalls[gCallCount] = name;
    }
    ++gCallCount;
}

FakeInterface* interfaceFor(const char* version) {
    if (version == nullptr) {
        return nullptr;
    }
    if (std::strcmp(version, gControlPanel.version) == 0) {
        return &gControlPanel;
    }
    if (std::strcmp(version, gHeadsetView.version) == 0) {
        return &gHeadsetView;
    }
    return nullptr;
}

} // namespace

extern "C" {

// Generic recorder for every OpenComposite export without bespoke behaviour. Arguments are
// accepted in registers and ignored; the return value proves which DLL answered.
#define BASALT_OPENCOMPOSITE_EXPORT(name)                                   \
    uintptr_t fake_##name(uintptr_t, uintptr_t, uintptr_t, uintptr_t) {     \
        record(#name);                                                      \
        return kFakeReturn;                                                 \
    }
#include "opencomposite_exports.inc"
#undef BASALT_OPENCOMPOSITE_EXPORT

void* special_VR_GetGenericInterface(const char* version, int* error) {
    record("VR_GetGenericInterface");
    if (version != nullptr) {
        std::strncpy(gLastInterfaceVersion, version, sizeof(gLastInterfaceVersion) - 1);
        gLastInterfaceVersion[sizeof(gLastInterfaceVersion) - 1] = '\0';
    }
    FakeInterface* object = gInterfacesAvailable ? interfaceFor(version) : nullptr;
    if (error != nullptr) {
        *error = object != nullptr ? kInitErrorNone : kInitErrorInterfaceNotFound;
    }
    return object;
}

uint32_t BasaltFakeCallCount() {
    return gCallCount;
}

const char* BasaltFakeCallName(uint32_t index) {
    return index < gCallCount && index < kMaxCalls ? gCalls[index] : nullptr;
}

const char* BasaltFakeLastInterfaceVersion() {
    return gLastInterfaceVersion;
}

void* BasaltFakeInterfaceObject(const char* version) {
    return interfaceFor(version);
}

void BasaltFakeSetInterfacesAvailable(bool available) {
    gInterfacesAvailable = available;
}

} // extern "C"

BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) {
    return TRUE;
}
