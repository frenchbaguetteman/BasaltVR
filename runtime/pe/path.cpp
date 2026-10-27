#include "runtime.hpp"

#include <windows.h>

#include <array>
#include <cstring>

namespace {

constexpr XrPath kFirstPathAtom = 0x1000;
// Engines commonly intern hundreds of paths while registering complete
// controller-binding tables. Keep a deterministic static allocation, but do
// not reject otherwise valid applications at a small prototype-era ceiling.
constexpr size_t kMaxPaths = 1024;

struct PathRecord {
    XrPath atom = XR_NULL_PATH;
    char string[XR_MAX_PATH_LENGTH] = {};
};

SRWLOCK gPathLock = SRWLOCK_INIT;
XrPath gNextPathAtom = kFirstPathAtom;
std::array<PathRecord, kMaxPaths> gPaths{};

bool isPathCharacter(char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= '0' && character <= '9') ||
           character == '-' || character == '_' || character == '.' ||
           character == '/';
}

// Spec path format: '/'-separated non-empty lowercase segments, no trailing
// slash, bounded by XR_MAX_PATH_LENGTH including the terminator.
bool isWellFormedPathString(const char* string, size_t* lengthOut) {
    if (std::memchr(string, '\0', XR_MAX_PATH_LENGTH) == nullptr) {
        return false;
    }
    const size_t length = std::strlen(string);
    if (length < 2 || string[0] != '/' || string[length - 1] == '/') {
        return false;
    }
    for (size_t index = 0; index < length; ++index) {
        if (!isPathCharacter(string[index])) {
            return false;
        }
        if (string[index] == '/' && index + 1 < length && string[index + 1] == '/') {
            return false;
        }
    }
    *lengthOut = length;
    return true;
}

const PathRecord* findAtomLocked(XrPath atom) {
    if (atom == XR_NULL_PATH) {
        return nullptr;
    }
    for (const PathRecord& record : gPaths) {
        if (record.atom == atom) {
            return &record;
        }
    }
    return nullptr;
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL stringToPath(
    XrInstance instance,
    const char* pathString,
    XrPath* path) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (path == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *path = XR_NULL_PATH;
    if (pathString == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    size_t length = 0;
    if (!isWellFormedPathString(pathString, &length)) {
        return XR_ERROR_PATH_FORMAT_INVALID;
    }

    AcquireSRWLockExclusive(&gPathLock);
    PathRecord* available = nullptr;
    for (PathRecord& record : gPaths) {
        if (record.atom != XR_NULL_PATH) {
            if (std::strcmp(record.string, pathString) == 0) {
                *path = record.atom;
                ReleaseSRWLockExclusive(&gPathLock);
                return XR_SUCCESS;
            }
        } else if (available == nullptr) {
            available = &record;
        }
    }
    if (available == nullptr || gNextPathAtom == UINT64_MAX) {
        ReleaseSRWLockExclusive(&gPathLock);
        return XR_ERROR_PATH_COUNT_EXCEEDED;
    }

    available->atom = gNextPathAtom++;
    std::memcpy(available->string, pathString, length + 1);
    *path = available->atom;
    ReleaseSRWLockExclusive(&gPathLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL pathToString(
    XrInstance instance,
    XrPath path,
    uint32_t bufferCapacityInput,
    uint32_t* bufferCountOutput,
    char* buffer) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (bufferCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gPathLock);
    const PathRecord* record = findAtomLocked(path);
    if (record == nullptr) {
        ReleaseSRWLockShared(&gPathLock);
        return XR_ERROR_PATH_INVALID;
    }
    const size_t required = std::strlen(record->string) + 1;
    *bufferCountOutput = static_cast<uint32_t>(required);
    if (bufferCapacityInput == 0) {
        ReleaseSRWLockShared(&gPathLock);
        return XR_SUCCESS;
    }
    if (buffer == nullptr) {
        ReleaseSRWLockShared(&gPathLock);
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (bufferCapacityInput < required) {
        ReleaseSRWLockShared(&gPathLock);
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    std::memcpy(buffer, record->string, required);
    ReleaseSRWLockShared(&gPathLock);
    return XR_SUCCESS;
}

void invalidatePathsForInstance(XrInstance instance) {
    (void)instance;  // single live instance: destroying it clears the table
    AcquireSRWLockExclusive(&gPathLock);
    for (PathRecord& record : gPaths) {
        record = {};
    }
    ReleaseSRWLockExclusive(&gPathLock);
}

bool isKnownPath(XrPath path) {
    AcquireSRWLockShared(&gPathLock);
    const bool known = findAtomLocked(path) != nullptr;
    ReleaseSRWLockShared(&gPathLock);
    return known;
}

bool pathStringEquals(XrPath path, const char* string) {
    AcquireSRWLockShared(&gPathLock);
    const PathRecord* record = findAtomLocked(path);
    const bool equal = record != nullptr && std::strcmp(record->string, string) == 0;
    ReleaseSRWLockShared(&gPathLock);
    return equal;
}

bool isTopLevelUserPath(XrPath path) {
    static constexpr const char* kTopLevelUserPaths[] = {
        "/user/head",
        "/user/hand/left",
        "/user/hand/right",
        "/user/gamepad",
    };
    for (const char* topLevel : kTopLevelUserPaths) {
        if (pathStringEquals(path, topLevel)) {
            return true;
        }
    }
    return false;
}

}  // namespace basalt
