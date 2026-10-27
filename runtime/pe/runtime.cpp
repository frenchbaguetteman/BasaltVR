#include "runtime.hpp"

#include <windows.h>

#include <openxr/openxr_reflection.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>

namespace {

INIT_ONCE gRuntimeLogInit = INIT_ONCE_STATIC_INIT;
SRWLOCK gRuntimeLogLock = SRWLOCK_INIT;
FILE* gRuntimeLogFile = nullptr;

BOOL CALLBACK openRuntimeLog(PINIT_ONCE, PVOID, PVOID*) {
    char path[MAX_PATH]{};
    const DWORD length = GetEnvironmentVariableA("BASALT_RUNTIME_LOG", path, sizeof(path));
    if (length == 0 || length >= sizeof(path) - 2) {
        return TRUE;
    }
    char windowsPath[MAX_PATH]{};
    if (path[0] == '/') {
        std::snprintf(windowsPath, sizeof(windowsPath), "Z:%s", path);
    } else {
        std::snprintf(windowsPath, sizeof(windowsPath), "%s", path);
    }
    gRuntimeLogFile = std::fopen(windowsPath, "a");
    return TRUE;
}

constexpr uintptr_t kFirstInstanceHandle = static_cast<uintptr_t>(0x10000);
constexpr uintptr_t kInstanceHandleStride = static_cast<uintptr_t>(0x10);

SRWLOCK gInstanceLock = SRWLOCK_INIT;
uintptr_t gNextInstanceHandle = kFirstInstanceHandle;
XrInstance gLiveInstance = XR_NULL_HANDLE;
bool gD3D11ExtensionEnabled = false;
bool gVisibilityMaskExtensionEnabled = false;

struct ExtensionDefinition {
    const char* name;
    uint32_t version;
};

// Every extension needs a session, and sessions need D3D11, so all of them
// are hidden together when the D3D11 capability gate fails.
// XR_KHR_visibility_mask is implemented purely in software.
constexpr ExtensionDefinition kExtensions[] = {
    {XR_KHR_D3D11_ENABLE_EXTENSION_NAME, XR_KHR_D3D11_enable_SPEC_VERSION},
    {XR_KHR_VISIBILITY_MASK_EXTENSION_NAME, XR_KHR_visibility_mask_SPEC_VERSION},
};
constexpr uint32_t kExtensionCount =
    static_cast<uint32_t>(sizeof(kExtensions) / sizeof(kExtensions[0]));

XrResult XRAPI_CALL basaltEnumerateInstanceExtensionProperties(
    const char* layerName,
    uint32_t propertyCapacityInput,
    uint32_t* propertyCountOutput,
    XrExtensionProperties* properties) {
    if (propertyCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (layerName != nullptr) {
        return XR_ERROR_API_LAYER_NOT_PRESENT;
    }

    const uint32_t count = basalt::isD3D11RuntimeAvailable() ? kExtensionCount : 0;
    *propertyCountOutput = count;
    if (propertyCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (properties == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (propertyCapacityInput < count) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (uint32_t index = 0; index < count; ++index) {
        if (properties[index].type != XR_TYPE_EXTENSION_PROPERTIES) {
            return XR_ERROR_VALIDATION_FAILURE;
        }
    }
    for (uint32_t index = 0; index < count; ++index) {
        std::strncpy(
            properties[index].extensionName,
            kExtensions[index].name,
            XR_MAX_EXTENSION_NAME_SIZE - 1);
        properties[index].extensionName[XR_MAX_EXTENSION_NAME_SIZE - 1] = '\0';
        properties[index].extensionVersion = kExtensions[index].version;
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltEnumerateApiLayerProperties(
    uint32_t propertyCapacityInput,
    uint32_t* propertyCountOutput,
    XrApiLayerProperties* properties) {
    if (propertyCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *propertyCountOutput = 0;
    if (propertyCapacityInput > 0 && properties == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltCreateInstance(
    const XrInstanceCreateInfo* createInfo,
    XrInstance* instance) {
    if (instance == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *instance = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_INSTANCE_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (createInfo->createFlags != 0 ||
        (createInfo->enabledApiLayerCount != 0 && createInfo->enabledApiLayerNames == nullptr) ||
        (createInfo->enabledExtensionCount != 0 && createInfo->enabledExtensionNames == nullptr)) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->applicationInfo.applicationName[0] == '\0' ||
        std::memchr(createInfo->applicationInfo.applicationName, '\0', XR_MAX_APPLICATION_NAME_SIZE) == nullptr ||
        std::memchr(createInfo->applicationInfo.engineName, '\0', XR_MAX_ENGINE_NAME_SIZE) == nullptr) {
        std::fprintf(stderr, "Basalt OpenXR: xrCreateInstance rejected an invalid application or engine name\n");
        return XR_ERROR_NAME_INVALID;
    }

    const XrVersion requestedVersion = createInfo->applicationInfo.apiVersion;
    if (requestedVersion < XR_MAKE_VERSION(1, 0, 0) ||
        requestedVersion >= XR_MAKE_VERSION(1, 1, 0)) {
        std::fprintf(
            stderr,
            "Basalt OpenXR: unsupported application API version %u.%u.%u (runtime supports OpenXR 1.0)\n",
            XR_VERSION_MAJOR(requestedVersion),
            XR_VERSION_MINOR(requestedVersion),
            XR_VERSION_PATCH(requestedVersion));
        return XR_ERROR_API_VERSION_UNSUPPORTED;
    }
    bool enableD3D11 = false;
    bool enableVisibilityMask = false;
    for (uint32_t index = 0; index < createInfo->enabledExtensionCount; ++index) {
        const char* extensionName = createInfo->enabledExtensionNames[index];
        if (extensionName == nullptr) {
            std::fprintf(stderr, "Basalt OpenXR: null enabled extension name at index %u\n", index);
            return XR_ERROR_VALIDATION_FAILURE;
        }
        const bool isD3D11 = std::strcmp(extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0;
        const bool isVisibilityMask =
            std::strcmp(extensionName, XR_KHR_VISIBILITY_MASK_EXTENSION_NAME) == 0;
        if (!isD3D11 && !isVisibilityMask) {
            std::fprintf(stderr, "Basalt OpenXR: unsupported enabled extension '%s'\n", extensionName);
            return XR_ERROR_EXTENSION_NOT_PRESENT;
        }
        if (!basalt::isD3D11RuntimeAvailable()) {
            std::fprintf(stderr, "Basalt OpenXR: D3D11 runtime support is unavailable\n");
            return XR_ERROR_EXTENSION_NOT_PRESENT;
        }
        enableD3D11 = enableD3D11 || isD3D11;
        enableVisibilityMask = enableVisibilityMask || isVisibilityMask;
    }

    AcquireSRWLockExclusive(&gInstanceLock);
    if (gLiveInstance != XR_NULL_HANDLE) {
        ReleaseSRWLockExclusive(&gInstanceLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    if (gNextInstanceHandle > UINTPTR_MAX - kInstanceHandleStride) {
        ReleaseSRWLockExclusive(&gInstanceLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    gLiveInstance = reinterpret_cast<XrInstance>(gNextInstanceHandle);
    gD3D11ExtensionEnabled = enableD3D11;
    gVisibilityMaskExtensionEnabled = enableVisibilityMask;
    gNextInstanceHandle += kInstanceHandleStride;
    *instance = gLiveInstance;
    ReleaseSRWLockExclusive(&gInstanceLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltDestroyInstance(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gInstanceLock);
    if (instance != gLiveInstance) {
        ReleaseSRWLockExclusive(&gInstanceLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    gLiveInstance = XR_NULL_HANDLE;
    gD3D11ExtensionEnabled = false;
    gVisibilityMaskExtensionEnabled = false;
    ReleaseSRWLockExclusive(&gInstanceLock);
    basalt::invalidateSessionForInstance(instance);
    basalt::invalidateInputForInstance(instance);
    basalt::invalidatePathsForInstance(instance);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltResultToString(
    XrInstance instance,
    XrResult value,
    char buffer[XR_MAX_RESULT_STRING_SIZE]) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (buffer == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    const char* known = nullptr;
#define BASALT_RESULT_ENTRY(name, unused_value) \
    if (known == nullptr && value == name) {    \
        known = #name;                          \
    }
    XR_LIST_ENUM_XrResult(BASALT_RESULT_ENTRY)
#undef BASALT_RESULT_ENTRY
    if (known != nullptr) {
        std::strncpy(buffer, known, XR_MAX_RESULT_STRING_SIZE - 1);
        buffer[XR_MAX_RESULT_STRING_SIZE - 1] = '\0';
    } else {
        std::snprintf(
            buffer,
            XR_MAX_RESULT_STRING_SIZE,
            XR_FAILED(value) ? "XR_UNKNOWN_FAILURE_VALUE_%d" : "XR_UNKNOWN_SUCCESS_VALUE_%d",
            static_cast<int>(value));
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltStructureTypeToString(
    XrInstance instance,
    XrStructureType value,
    char buffer[XR_MAX_STRUCTURE_NAME_SIZE]) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (buffer == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    const char* known = nullptr;
#define BASALT_STRUCTURE_ENTRY(name, unused_value) \
    if (known == nullptr && value == name) {       \
        known = #name;                             \
    }
    XR_LIST_ENUM_XrStructureType(BASALT_STRUCTURE_ENTRY)
#undef BASALT_STRUCTURE_ENTRY
    if (known != nullptr) {
        std::strncpy(buffer, known, XR_MAX_STRUCTURE_NAME_SIZE - 1);
        buffer[XR_MAX_STRUCTURE_NAME_SIZE - 1] = '\0';
    } else {
        std::snprintf(
            buffer,
            XR_MAX_STRUCTURE_NAME_SIZE,
            "XR_UNKNOWN_STRUCTURE_TYPE_%d",
            static_cast<int>(value));
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltGetInstanceProperties(
    XrInstance instance,
    XrInstanceProperties* instanceProperties) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (instanceProperties == nullptr ||
        instanceProperties->type != XR_TYPE_INSTANCE_PROPERTIES) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    instanceProperties->runtimeVersion = basalt::kRuntimeVersion;
    std::strncpy(
        instanceProperties->runtimeName,
        "BasaltVR M4 prototype",
        XR_MAX_RUNTIME_NAME_SIZE - 1);
    instanceProperties->runtimeName[XR_MAX_RUNTIME_NAME_SIZE - 1] = '\0';
    return XR_SUCCESS;
}

template <typename Function>
PFN_xrVoidFunction asVoidFunction(Function function) {
    return reinterpret_cast<PFN_xrVoidFunction>(function);
}

}  // namespace

namespace basalt {

void runtimeLog(const char* format, ...) {
    InitOnceExecuteOnce(&gRuntimeLogInit, openRuntimeLog, nullptr, nullptr);
    char line[1024];
    const int prefix = std::snprintf(
        line, sizeof(line), "Basalt OpenXR [pid %lu]: ", GetCurrentProcessId());
    va_list arguments;
    va_start(arguments, format);
    std::vsnprintf(line + prefix, sizeof(line) - prefix, format, arguments);
    va_end(arguments);
    AcquireSRWLockExclusive(&gRuntimeLogLock);
    std::fprintf(stderr, "%s\n", line);
    if (gRuntimeLogFile != nullptr) {
        std::fprintf(gRuntimeLogFile, "%s\n", line);
        std::fflush(gRuntimeLogFile);
    }
    ReleaseSRWLockExclusive(&gRuntimeLogLock);
}

bool isValidInstance(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gInstanceLock);
    const bool valid = instance == gLiveInstance;
    ReleaseSRWLockShared(&gInstanceLock);
    return valid;
}

bool isD3D11ExtensionEnabled(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gInstanceLock);
    const bool enabled = instance == gLiveInstance && gD3D11ExtensionEnabled;
    ReleaseSRWLockShared(&gInstanceLock);
    return enabled;
}

bool isVisibilityMaskExtensionEnabled(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gInstanceLock);
    const bool enabled = instance == gLiveInstance && gVisibilityMaskExtensionEnabled;
    ReleaseSRWLockShared(&gInstanceLock);
    return enabled;
}

XrResult XRAPI_CALL getInstanceProcAddr(
    XrInstance instance,
    const char* name,
    PFN_xrVoidFunction* function) {
    if (function == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *function = nullptr;
    if (name == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (std::strcmp(name, "xrGetInstanceProcAddr") == 0) {
        *function = asVoidFunction(getInstanceProcAddr);
    } else if (std::strcmp(name, "xrEnumerateInstanceExtensionProperties") == 0) {
        *function = asVoidFunction(basaltEnumerateInstanceExtensionProperties);
    } else if (std::strcmp(name, "xrEnumerateApiLayerProperties") == 0) {
        *function = asVoidFunction(basaltEnumerateApiLayerProperties);
    } else if (std::strcmp(name, "xrCreateInstance") == 0) {
        *function = asVoidFunction(basaltCreateInstance);
    } else if (std::strcmp(name, "xrDestroyInstance") == 0) {
        *function = asVoidFunction(basaltDestroyInstance);
    } else if (std::strcmp(name, "xrGetInstanceProperties") == 0) {
        *function = asVoidFunction(basaltGetInstanceProperties);
    } else if (std::strcmp(name, "xrResultToString") == 0) {
        *function = asVoidFunction(basaltResultToString);
    } else if (std::strcmp(name, "xrStructureTypeToString") == 0) {
        *function = asVoidFunction(basaltStructureTypeToString);
    } else if (std::strcmp(name, "xrStringToPath") == 0) {
        *function = asVoidFunction(stringToPath);
    } else if (std::strcmp(name, "xrPathToString") == 0) {
        *function = asVoidFunction(pathToString);
    } else if (std::strcmp(name, "xrCreateActionSet") == 0) {
        *function = asVoidFunction(createActionSet);
    } else if (std::strcmp(name, "xrDestroyActionSet") == 0) {
        *function = asVoidFunction(destroyActionSet);
    } else if (std::strcmp(name, "xrCreateAction") == 0) {
        *function = asVoidFunction(createAction);
    } else if (std::strcmp(name, "xrDestroyAction") == 0) {
        *function = asVoidFunction(destroyAction);
    } else if (std::strcmp(name, "xrSuggestInteractionProfileBindings") == 0) {
        *function = asVoidFunction(suggestInteractionProfileBindings);
    } else if (std::strcmp(name, "xrAttachSessionActionSets") == 0) {
        *function = asVoidFunction(attachSessionActionSets);
    } else if (std::strcmp(name, "xrGetCurrentInteractionProfile") == 0) {
        *function = asVoidFunction(getCurrentInteractionProfile);
    } else if (std::strcmp(name, "xrSyncActions") == 0) {
        *function = asVoidFunction(syncActions);
    } else if (std::strcmp(name, "xrGetActionStateBoolean") == 0) {
        *function = asVoidFunction(getActionStateBoolean);
    } else if (std::strcmp(name, "xrGetActionStateFloat") == 0) {
        *function = asVoidFunction(getActionStateFloat);
    } else if (std::strcmp(name, "xrGetActionStateVector2f") == 0) {
        *function = asVoidFunction(getActionStateVector2f);
    } else if (std::strcmp(name, "xrGetActionStatePose") == 0) {
        *function = asVoidFunction(getActionStatePose);
    } else if (std::strcmp(name, "xrEnumerateBoundSourcesForAction") == 0) {
        *function = asVoidFunction(enumerateBoundSourcesForAction);
    } else if (std::strcmp(name, "xrGetInputSourceLocalizedName") == 0) {
        *function = asVoidFunction(getInputSourceLocalizedName);
    } else if (std::strcmp(name, "xrApplyHapticFeedback") == 0) {
        *function = asVoidFunction(applyHapticFeedback);
    } else if (std::strcmp(name, "xrStopHapticFeedback") == 0) {
        *function = asVoidFunction(stopHapticFeedback);
    } else if (std::strcmp(name, "xrCreateActionSpace") == 0) {
        *function = asVoidFunction(createActionSpace);
    } else if (std::strcmp(name, "xrLocateSpace") == 0) {
        *function = asVoidFunction(locateSpace);
    } else if (std::strcmp(name, "xrLocateViews") == 0) {
        *function = asVoidFunction(locateViews);
    } else if (std::strcmp(name, "xrGetReferenceSpaceBoundsRect") == 0) {
        *function = asVoidFunction(getReferenceSpaceBoundsRect);
    } else if (std::strcmp(name, "xrGetSystem") == 0) {
        *function = asVoidFunction(getSystem);
    } else if (std::strcmp(name, "xrGetSystemProperties") == 0) {
        *function = asVoidFunction(getSystemProperties);
    } else if (std::strcmp(name, "xrEnumerateEnvironmentBlendModes") == 0) {
        *function = asVoidFunction(enumerateEnvironmentBlendModes);
    } else if (std::strcmp(name, "xrEnumerateViewConfigurations") == 0) {
        *function = asVoidFunction(enumerateViewConfigurations);
    } else if (std::strcmp(name, "xrGetViewConfigurationProperties") == 0) {
        *function = asVoidFunction(getViewConfigurationProperties);
    } else if (std::strcmp(name, "xrEnumerateViewConfigurationViews") == 0) {
        *function = asVoidFunction(enumerateViewConfigurationViews);
    } else if (std::strcmp(name, "xrGetD3D11GraphicsRequirementsKHR") == 0 &&
               isD3D11ExtensionEnabled(instance)) {
        *function = asVoidFunction(getD3D11GraphicsRequirements);
    } else if (std::strcmp(name, "xrGetVisibilityMaskKHR") == 0 &&
               isVisibilityMaskExtensionEnabled(instance)) {
        *function = asVoidFunction(getVisibilityMask);
    } else if (std::strcmp(name, "xrCreateSession") == 0) {
        *function = asVoidFunction(createSession);
    } else if (std::strcmp(name, "xrDestroySession") == 0) {
        *function = asVoidFunction(destroySession);
    } else if (std::strcmp(name, "xrPollEvent") == 0) {
        *function = asVoidFunction(pollEvent);
    } else if (std::strcmp(name, "xrBeginSession") == 0) {
        *function = asVoidFunction(beginSession);
    } else if (std::strcmp(name, "xrEndSession") == 0) {
        *function = asVoidFunction(endSession);
    } else if (std::strcmp(name, "xrRequestExitSession") == 0) {
        *function = asVoidFunction(requestExitSession);
    } else if (std::strcmp(name, "xrWaitFrame") == 0) {
        *function = asVoidFunction(waitFrame);
    } else if (std::strcmp(name, "xrBeginFrame") == 0) {
        *function = asVoidFunction(beginFrame);
    } else if (std::strcmp(name, "xrEndFrame") == 0) {
        *function = asVoidFunction(endFrame);
    } else if (std::strcmp(name, "xrEnumerateReferenceSpaces") == 0) {
        *function = asVoidFunction(enumerateReferenceSpaces);
    } else if (std::strcmp(name, "xrCreateReferenceSpace") == 0) {
        *function = asVoidFunction(createReferenceSpace);
    } else if (std::strcmp(name, "xrDestroySpace") == 0) {
        *function = asVoidFunction(destroySpace);
    } else if (std::strcmp(name, "xrEnumerateSwapchainFormats") == 0) {
        *function = asVoidFunction(enumerateSwapchainFormats);
    } else if (std::strcmp(name, "xrCreateSwapchain") == 0) {
        *function = asVoidFunction(createSwapchain);
    } else if (std::strcmp(name, "xrDestroySwapchain") == 0) {
        *function = asVoidFunction(destroySwapchain);
    } else if (std::strcmp(name, "xrEnumerateSwapchainImages") == 0) {
        *function = asVoidFunction(enumerateSwapchainImages);
    } else if (std::strcmp(name, "xrAcquireSwapchainImage") == 0) {
        *function = asVoidFunction(acquireSwapchainImage);
    } else if (std::strcmp(name, "xrWaitSwapchainImage") == 0) {
        *function = asVoidFunction(waitSwapchainImage);
    } else if (std::strcmp(name, "xrReleaseSwapchainImage") == 0) {
        *function = asVoidFunction(releaseSwapchainImage);
    }

    const bool globalCommand = std::strcmp(name, "xrEnumerateInstanceExtensionProperties") == 0 ||
                               std::strcmp(name, "xrEnumerateApiLayerProperties") == 0 ||
                               std::strcmp(name, "xrCreateInstance") == 0;
    if (instance == XR_NULL_HANDLE && !globalCommand) {
        *function = nullptr;
        return XR_ERROR_HANDLE_INVALID;
    }
    if (instance != XR_NULL_HANDLE && !isValidInstance(instance)) {
        *function = nullptr;
        return XR_ERROR_HANDLE_INVALID;
    }
    if (*function == nullptr) {
        return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    return XR_SUCCESS;
}

}  // namespace basalt
