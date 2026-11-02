#include <openxr/openxr.h>

#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

// OpenComposite (gitlab.com/znixian/OpenOVR, openxr branch, cff07db) aborts
// the game if xrSuggestInteractionProfileBindings fails. Every path it can
// suggest must appear in its InteractionProfile::validInputPaths, so these
// lists are copied exactly from OpenOVR/Misc/Input/*InteractionProfile.cpp
// (per-hand suffixes are expanded for both hands below).
struct OpenCompositeProfile {
    const char* profile;
    std::vector<const char*> handPaths;
    std::vector<const char*> fullPaths;
};

const OpenCompositeProfile kOpenCompositeProfiles[] = {
    {"/interaction_profiles/microsoft/motion_controller",
     {"/input/menu/click", "/input/squeeze/click", "/input/trigger/value",
      "/input/thumbstick/x", "/input/thumbstick/y", "/input/thumbstick/click",
      "/input/thumbstick", "/input/trackpad/x", "/input/trackpad/y",
      "/input/trackpad/click", "/input/trackpad/touch", "/input/trackpad",
      "/input/grip/pose", "/input/aim/pose", "/output/haptic"},
     {}},
    {"/interaction_profiles/valve/index_controller",
     {"/input/a/click", "/input/a/touch", "/input/b/click", "/input/b/touch",
      "/input/squeeze/value", "/input/squeeze/force", "/input/trigger/click",
      "/input/trigger/value", "/input/trigger/touch", "/input/thumbstick/x",
      "/input/thumbstick/y", "/input/thumbstick/click", "/input/thumbstick/touch",
      "/input/thumbstick", "/input/trackpad/x", "/input/trackpad/y",
      "/input/trackpad/force", "/input/trackpad/touch", "/input/trackpad",
      "/input/grip/pose", "/input/aim/pose", "/output/haptic"},
     {}},
    {"/interaction_profiles/htc/vive_controller",
     {"/input/squeeze/click", "/input/menu/click", "/input/trigger/click",
      "/input/trigger/value", "/input/trackpad/x", "/input/trackpad/y",
      "/input/trackpad/click", "/input/trackpad/touch", "/input/trackpad",
      "/input/grip/pose", "/input/aim/pose", "/output/haptic"},
     {}},
    {"/interaction_profiles/oculus/touch_controller",
     {"/input/squeeze/value", "/input/trigger/value", "/input/trigger/touch",
      "/input/thumbstick/x", "/input/thumbstick/y", "/input/thumbstick",
      "/input/thumbstick/click", "/input/thumbstick/touch", "/input/thumbrest/touch",
      "/input/grip/pose", "/input/aim/pose", "/output/haptic"},
     {"/user/hand/left/input/x/click", "/user/hand/left/input/x/touch",
      "/user/hand/left/input/y/click", "/user/hand/left/input/y/touch",
      "/user/hand/left/input/menu/click", "/user/hand/right/input/a/click",
      "/user/hand/right/input/a/touch", "/user/hand/right/input/b/click",
      "/user/hand/right/input/b/touch"}},
    {"/interaction_profiles/khr/simple_controller",
     {"/input/select/click", "/input/menu/click", "/input/grip/pose",
      "/input/aim/pose", "/output/haptic"},
     {}},
};

bool endsWith(const std::string& value, const char* suffix) {
    const size_t length = std::strlen(suffix);
    return value.size() >= length &&
           value.compare(value.size() - length, length, suffix) == 0;
}

bool suggestBindings(
    XrInstance instance,
    const char* profile,
    const std::vector<XrActionSuggestedBinding>& bindings,
    XrResult expected) {
    XrInteractionProfileSuggestedBinding suggestedBindings{};
    suggestedBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    XrResult result = xrStringToPath(
        instance, profile, &suggestedBindings.interactionProfile);
    suggestedBindings.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
    suggestedBindings.suggestedBindings = bindings.data();
    if (XR_SUCCEEDED(result)) {
        result = xrSuggestInteractionProfileBindings(instance, &suggestedBindings);
    }
    if (result != expected) {
        std::fprintf(stderr, "FAIL: OpenComposite suggestion for '%s' (%zu bindings) returned %d\n",
                     profile, bindings.size(), result);
        return false;
    }
    return true;
}

// Replays OpenComposite's suggestion pattern: the internal info set suggests
// one /click source per hand cumulatively (so each profile twice), then every
// valid path of every profile is suggested, twice, with type-matched actions.
bool openCompositeBindingsAccepted(XrInstance instance, const XrPath handPaths[2]) {
    XrActionSetCreateInfo setInfo{};
    setInfo.type = XR_TYPE_ACTION_SET_CREATE_INFO;
    std::strncpy(setInfo.actionSetName, "opencomposite-internal-info-set",
                 XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(setInfo.localizedActionSetName, "OpenComposite internal info set",
                 XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    XrActionSet set = XR_NULL_HANDLE;
    XrResult result = xrCreateActionSet(instance, &setInfo, &set);

    struct NamedAction {
        const char* name;
        const char* localizedName;
        XrActionType type;
        XrAction handle;
    };
    NamedAction actions[] = {
        {"opencomposite-internal-info-act", "OpenComposite internal info action",
         XR_ACTION_TYPE_BOOLEAN_INPUT, XR_NULL_HANDLE},
        {"oc-float", "OC float", XR_ACTION_TYPE_FLOAT_INPUT, XR_NULL_HANDLE},
        {"oc-vector", "OC vector", XR_ACTION_TYPE_VECTOR2F_INPUT, XR_NULL_HANDLE},
        {"oc-pose", "OC pose", XR_ACTION_TYPE_POSE_INPUT, XR_NULL_HANDLE},
        {"oc-haptic", "OC haptic", XR_ACTION_TYPE_VIBRATION_OUTPUT, XR_NULL_HANDLE},
    };
    for (NamedAction& action : actions) {
        if (XR_FAILED(result)) {
            break;
        }
        XrActionCreateInfo actionInfo{};
        actionInfo.type = XR_TYPE_ACTION_CREATE_INFO;
        actionInfo.actionType = action.type;
        actionInfo.countSubactionPaths = 2;
        actionInfo.subactionPaths = handPaths;
        std::strncpy(actionInfo.actionName, action.name, XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(actionInfo.localizedActionName, action.localizedName,
                     XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        result = xrCreateAction(set, &actionInfo, &action.handle);
    }
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: OpenComposite action setup returned %d\n", result);
        return false;
    }
    const XrAction booleanAction = actions[0].handle;

    const char* hands[] = {"/user/hand/left", "/user/hand/right"};
    for (const OpenCompositeProfile& profile : kOpenCompositeProfiles) {
        std::vector<std::string> paths;
        for (const char* hand : hands) {
            for (const char* suffix : profile.handPaths) {
                paths.push_back(std::string(hand) + suffix);
            }
        }
        for (const char* path : profile.fullPaths) {
            paths.push_back(path);
        }

        std::vector<XrActionSuggestedBinding> infoBindings;
        for (const char* hand : hands) {
            for (const std::string& path : paths) {
                if (path.find("/click") != std::string::npos &&
                    path.compare(0, std::strlen(hand), hand) == 0) {
                    XrPath binding = XR_NULL_PATH;
                    if (XR_FAILED(xrStringToPath(instance, path.c_str(), &binding))) {
                        return false;
                    }
                    infoBindings.push_back({booleanAction, binding});
                    break;
                }
            }
            if (!suggestBindings(instance, profile.profile, infoBindings, XR_SUCCESS)) {
                return false;
            }
        }

        std::vector<XrActionSuggestedBinding> bindings;
        for (const std::string& path : paths) {
            XrAction action = actions[1].handle;
            if (endsWith(path, "/pose")) {
                action = actions[3].handle;
            } else if (endsWith(path, "/output/haptic")) {
                action = actions[4].handle;
            } else if (endsWith(path, "/thumbstick") || endsWith(path, "/trackpad")) {
                action = actions[2].handle;
            } else if (endsWith(path, "/click") || endsWith(path, "/touch")) {
                action = booleanAction;
            }
            XrPath binding = XR_NULL_PATH;
            if (XR_FAILED(xrStringToPath(instance, path.c_str(), &binding))) {
                return false;
            }
            bindings.push_back({action, binding});
        }
        for (int repeat = 0; repeat < 2; ++repeat) {
            if (!suggestBindings(instance, profile.profile, bindings, XR_SUCCESS)) {
                return false;
            }
        }
    }

    // OpenComposite never suggests its Vive tracker profile
    // (ViveTrackerInteractionProfile::CanHaveBindings() is false). Without
    // XR_HTCX_vive_tracker_interaction the spec result is PATH_UNSUPPORTED.
    XrPath leftGrip = XR_NULL_PATH;
    result = xrStringToPath(instance, "/user/hand/left/input/grip/pose", &leftGrip);
    if (XR_FAILED(result) ||
        !suggestBindings(instance, "/interaction_profiles/htc/vive_tracker_htcx",
                         {{actions[3].handle, leftGrip}}, XR_ERROR_PATH_UNSUPPORTED)) {
        return false;
    }

    result = xrDestroyActionSet(set);
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: OpenComposite action set teardown returned %d\n", result);
        return false;
    }
    return true;
}

}  // namespace

int main() {
    const bool expectD3D11 = [] {
        const char* value = std::getenv("BASALT_EXPECT_D3D11_EXTENSION");
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
    uint32_t extensionCount = UINT32_MAX;
    XrResult result = xrEnumerateInstanceExtensionProperties(nullptr, 0, &extensionCount, nullptr);
    if (result != XR_SUCCESS) {
        std::fprintf(stderr, "FAIL: loader enumeration returned %d with %u extension(s)\n",
                     result, extensionCount);
        return 1;
    }

    // The runtime itself advertises no graphics extension in Whisky/D3DMetal
    // (covered directly by negotiation_smoke), while the official loader may add
    // loader-owned extensions such as XR_EXT_debug_utils.
    std::vector<XrExtensionProperties> extensions(extensionCount);
    for (XrExtensionProperties& extension : extensions) {
        extension.type = XR_TYPE_EXTENSION_PROPERTIES;
    }
    result = xrEnumerateInstanceExtensionProperties(
        nullptr, extensionCount, &extensionCount, extensions.data());
    if (result != XR_SUCCESS) {
        std::fprintf(stderr, "FAIL: loader extension values returned %d\n", result);
        return 1;
    }
    bool foundD3D11 = false;
    for (const XrExtensionProperties& extension : extensions) {
        if (std::strcmp(extension.extensionName, "XR_KHR_D3D11_enable") == 0) {
            foundD3D11 = true;
        }
    }
    if (foundD3D11 != expectD3D11) {
        std::fprintf(
            stderr, "FAIL: XR_KHR_D3D11_enable was %s but the environment expected it %s\n",
            foundD3D11 ? "advertised" : "hidden",
            expectD3D11 ? "advertised" : "hidden");
        return 1;
    }

    XrInstanceCreateInfo createInfo{};
    createInfo.type = XR_TYPE_INSTANCE_CREATE_INFO;
    createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    std::strncpy(createInfo.applicationInfo.applicationName, "Basalt loader smoke",
                 XR_MAX_APPLICATION_NAME_SIZE - 1);

    XrInstance instance = XR_NULL_HANDLE;
    result = xrCreateInstance(&createInfo, &instance);
    if (result != XR_SUCCESS || instance == XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: loader xrCreateInstance returned %d\n", result);
        return 1;
    }

    XrInstanceProperties properties{};
    properties.type = XR_TYPE_INSTANCE_PROPERTIES;
    result = xrGetInstanceProperties(instance, &properties);
    if (result != XR_SUCCESS || std::strncmp(properties.runtimeName, "BasaltVR", 8) != 0) {
        std::fprintf(stderr, "FAIL: loader properties returned %d and runtime '%s'\n",
                     result, properties.runtimeName);
        xrDestroyInstance(instance);
        return 1;
    }

    XrSystemGetInfo systemInfo{};
    systemInfo.type = XR_TYPE_SYSTEM_GET_INFO;
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId systemId = XR_NULL_SYSTEM_ID;
    result = xrGetSystem(instance, &systemInfo, &systemId);
    if (result != XR_SUCCESS || systemId == XR_NULL_SYSTEM_ID) {
        std::fprintf(stderr, "FAIL: loader xrGetSystem returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    XrSystemProperties systemProperties{};
    systemProperties.type = XR_TYPE_SYSTEM_PROPERTIES;
    result = xrGetSystemProperties(instance, systemId, &systemProperties);
    if (result != XR_SUCCESS || std::strncmp(systemProperties.systemName, "BasaltVR", 8) != 0 ||
        systemProperties.trackingProperties.orientationTracking != XR_TRUE ||
        systemProperties.trackingProperties.positionTracking != XR_TRUE) {
        std::fprintf(stderr, "FAIL: loader xrGetSystemProperties returned %d and system '%s'\n",
                     result, systemProperties.systemName);
        xrDestroyInstance(instance);
        return 1;
    }

    uint32_t viewConfigurationCount = 0;
    result = xrEnumerateViewConfigurations(instance, systemId, 0, &viewConfigurationCount, nullptr);
    if (result != XR_SUCCESS || viewConfigurationCount != 1) {
        std::fprintf(stderr, "FAIL: view configuration count returned %d / %u\n",
                     result, viewConfigurationCount);
        xrDestroyInstance(instance);
        return 1;
    }
    XrViewConfigurationType viewConfiguration = XR_VIEW_CONFIGURATION_TYPE_MAX_ENUM;
    result = xrEnumerateViewConfigurations(instance, systemId, 1, &viewConfigurationCount,
                                           &viewConfiguration);
    if (result != XR_SUCCESS || viewConfiguration != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        std::fprintf(stderr, "FAIL: stereo view enumeration returned %d / %d\n",
                     result, viewConfiguration);
        xrDestroyInstance(instance);
        return 1;
    }

    XrViewConfigurationProperties viewProperties{};
    viewProperties.type = XR_TYPE_VIEW_CONFIGURATION_PROPERTIES;
    result = xrGetViewConfigurationProperties(instance, systemId, viewConfiguration, &viewProperties);
    if (result != XR_SUCCESS || viewProperties.fovMutable != XR_FALSE) {
        std::fprintf(stderr, "FAIL: view properties returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    uint32_t viewCount = 0;
    result = xrEnumerateViewConfigurationViews(instance, systemId, viewConfiguration,
                                               0, &viewCount, nullptr);
    if (result != XR_SUCCESS || viewCount != 2) {
        std::fprintf(stderr, "FAIL: stereo view count returned %d / %u\n", result, viewCount);
        xrDestroyInstance(instance);
        return 1;
    }
    XrViewConfigurationView views[2]{};
    views[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    views[1].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    result = xrEnumerateViewConfigurationViews(instance, systemId, viewConfiguration,
                                               2, &viewCount, views);
    if (result != XR_SUCCESS || views[0].recommendedImageRectWidth != 1680 ||
        views[0].recommendedImageRectHeight != 1760 ||
        views[1].recommendedImageRectWidth != 1680 ||
        views[1].recommendedImageRectHeight != 1760) {
        std::fprintf(stderr, "FAIL: stereo view dimensions returned %d / %ux%u\n",
                     result, views[0].recommendedImageRectWidth,
                     views[0].recommendedImageRectHeight);
        xrDestroyInstance(instance);
        return 1;
    }

    uint32_t blendModeCount = 0;
    result = xrEnumerateEnvironmentBlendModes(instance, systemId, viewConfiguration,
                                              0, &blendModeCount, nullptr);
    XrEnvironmentBlendMode blendMode = XR_ENVIRONMENT_BLEND_MODE_MAX_ENUM;
    if (result == XR_SUCCESS && blendModeCount == 1) {
        result = xrEnumerateEnvironmentBlendModes(instance, systemId, viewConfiguration,
                                                  1, &blendModeCount, &blendMode);
    }
    if (result != XR_SUCCESS || blendMode != XR_ENVIRONMENT_BLEND_MODE_OPAQUE) {
        std::fprintf(stderr, "FAIL: opaque blend mode returned %d / %d\n", result, blendMode);
        xrDestroyInstance(instance);
        return 1;
    }

    XrPath leftHandPath = XR_NULL_PATH;
    result = xrStringToPath(instance, "/user/hand/left", &leftHandPath);
    XrPath rightHandPath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/right", &rightHandPath);
    }
    XrPath leftHandAgain = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/left", &leftHandAgain);
    }
    if (XR_FAILED(result) || leftHandPath == XR_NULL_PATH ||
        rightHandPath == XR_NULL_PATH || leftHandPath == rightHandPath ||
        leftHandAgain != leftHandPath) {
        std::fprintf(stderr, "FAIL: xrStringToPath atoms returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    const char* malformedPaths[] = {"user/hand", "/user/hand/", "/User/Hand", "/", "/user//hand"};
    for (const char* malformed : malformedPaths) {
        XrPath rejected = XR_NULL_PATH;
        result = xrStringToPath(instance, malformed, &rejected);
        if (result != XR_ERROR_PATH_FORMAT_INVALID || rejected != XR_NULL_PATH) {
            std::fprintf(stderr, "FAIL: malformed path '%s' returned %d\n", malformed, result);
            xrDestroyInstance(instance);
            return 1;
        }
    }

    uint32_t pathLength = 0;
    result = xrPathToString(instance, leftHandPath, 0, &pathLength, nullptr);
    char pathBuffer[XR_MAX_PATH_LENGTH] = {};
    if (XR_SUCCEEDED(result) && pathLength == sizeof("/user/hand/left")) {
        result = xrPathToString(instance, leftHandPath, pathLength, &pathLength, pathBuffer);
    } else if (XR_SUCCEEDED(result)) {
        result = XR_ERROR_VALIDATION_FAILURE;
    }
    if (XR_FAILED(result) || std::strcmp(pathBuffer, "/user/hand/left") != 0) {
        std::fprintf(stderr, "FAIL: xrPathToString roundtrip returned %d '%s'\n",
                     result, pathBuffer);
        xrDestroyInstance(instance);
        return 1;
    }
    result = xrPathToString(instance, leftHandPath + 0x9999, 0, &pathLength, nullptr);
    if (result != XR_ERROR_PATH_INVALID) {
        std::fprintf(stderr, "FAIL: unknown atom xrPathToString returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    XrActionSetCreateInfo actionSetInfo{};
    actionSetInfo.type = XR_TYPE_ACTION_SET_CREATE_INFO;
    std::strncpy(actionSetInfo.actionSetName, "gameplay", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(actionSetInfo.localizedActionSetName, "Gameplay",
                 XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    XrActionSet actionSet = XR_NULL_HANDLE;
    result = xrCreateActionSet(instance, &actionSetInfo, &actionSet);
    if (XR_FAILED(result) || actionSet == XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: xrCreateActionSet returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    XrActionSet rejectedSet = XR_NULL_HANDLE;
    result = xrCreateActionSet(instance, &actionSetInfo, &rejectedSet);
    if (result != XR_ERROR_NAME_DUPLICATED || rejectedSet != XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: duplicate action set name returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }
    std::strncpy(actionSetInfo.actionSetName, "gameplay2", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    result = xrCreateActionSet(instance, &actionSetInfo, &rejectedSet);
    if (result != XR_ERROR_LOCALIZED_NAME_DUPLICATED || rejectedSet != XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: duplicate localized set name returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }
    std::strncpy(actionSetInfo.actionSetName, "Bad Name", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(actionSetInfo.localizedActionSetName, "Bad",
                 XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    result = xrCreateActionSet(instance, &actionSetInfo, &rejectedSet);
    if (result != XR_ERROR_NAME_INVALID || rejectedSet != XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: invalid action set name returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    const XrPath handPaths[] = {leftHandPath, rightHandPath};
    XrActionCreateInfo actionInfo{};
    actionInfo.type = XR_TYPE_ACTION_CREATE_INFO;
    actionInfo.actionType = XR_ACTION_TYPE_FLOAT_INPUT;
    actionInfo.countSubactionPaths = 2;
    actionInfo.subactionPaths = handPaths;
    std::strncpy(actionInfo.actionName, "grab_object", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Grab Object",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction grabAction = XR_NULL_HANDLE;
    result = xrCreateAction(actionSet, &actionInfo, &grabAction);

    actionInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
    std::strncpy(actionInfo.actionName, "hand_pose", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Hand Pose",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction poseAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(actionSet, &actionInfo, &poseAction);
    }

    actionInfo.actionType = XR_ACTION_TYPE_VIBRATION_OUTPUT;
    std::strncpy(actionInfo.actionName, "vibrate_hand", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Vibrate Hand",
                 XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    XrAction vibrateAction = XR_NULL_HANDLE;
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(actionSet, &actionInfo, &vibrateAction);
    }
    if (XR_FAILED(result) || grabAction == XR_NULL_HANDLE ||
        poseAction == XR_NULL_HANDLE || vibrateAction == XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: xrCreateAction returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    XrAction rejectedAction = XR_NULL_HANDLE;
    result = xrCreateAction(actionSet, &actionInfo, &rejectedAction);
    if (result != XR_ERROR_NAME_DUPLICATED || rejectedAction != XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: duplicate action name returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }
    XrPath footPath = XR_NULL_PATH;
    result = xrStringToPath(instance, "/user/foot/left", &footPath);
    actionInfo.countSubactionPaths = 1;
    actionInfo.subactionPaths = &footPath;
    std::strncpy(actionInfo.actionName, "kick", XR_MAX_ACTION_NAME_SIZE - 1);
    std::strncpy(actionInfo.localizedActionName, "Kick", XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
    if (XR_SUCCEEDED(result)) {
        result = xrCreateAction(actionSet, &actionInfo, &rejectedAction);
    }
    if (result != XR_ERROR_PATH_UNSUPPORTED || rejectedAction != XR_NULL_HANDLE) {
        std::fprintf(stderr, "FAIL: unsupported subaction path returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    // Every OpenXR 1.0 core interaction profile must accept a representative
    // binding. Engines routinely submit their whole binding table even when
    // this runtime has not connected physical input yet.
    struct ProfileBinding {
        const char* profile;
        const char* grabSource;
    };
    const ProfileBinding profileBindings[] = {
        {"/interaction_profiles/khr/simple_controller", "/user/hand/left/input/select/click"},
        {"/interaction_profiles/google/daydream_controller", "/user/hand/left/input/select/click"},
        {"/interaction_profiles/oculus/touch_controller", "/user/hand/left/input/squeeze/value"},
        {"/interaction_profiles/htc/vive_controller", "/user/hand/left/input/trigger/value"},
        {"/interaction_profiles/htc/vive_pro", "/user/head/input/volume_up/click"},
        {"/interaction_profiles/microsoft/motion_controller", "/user/hand/left/input/trigger/value"},
        {"/interaction_profiles/microsoft/xbox_controller", "/user/gamepad/input/trigger_left/value"},
        {"/interaction_profiles/oculus/go_controller", "/user/hand/left/input/trackpad/x"},
        {"/interaction_profiles/valve/index_controller", "/user/hand/left/input/squeeze/force"},
    };
    for (const ProfileBinding& profileBinding : profileBindings) {
        XrPath profilePath = XR_NULL_PATH;
        result = xrStringToPath(instance, profileBinding.profile, &profilePath);
        XrPath grabSourcePath = XR_NULL_PATH;
        if (XR_SUCCEEDED(result)) {
            result = xrStringToPath(instance, profileBinding.grabSource, &grabSourcePath);
        }
        const XrActionSuggestedBinding suggested[] = {
            {grabAction, grabSourcePath},
        };
        XrInteractionProfileSuggestedBinding suggestedBindings{};
        suggestedBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
        suggestedBindings.interactionProfile = profilePath;
        suggestedBindings.countSuggestedBindings = 1;
        suggestedBindings.suggestedBindings = suggested;
        if (XR_SUCCEEDED(result)) {
            result = xrSuggestInteractionProfileBindings(instance, &suggestedBindings);
        }
        if (XR_FAILED(result)) {
            std::fprintf(stderr, "FAIL: suggest bindings for '%s' returned %d\n",
                         profileBinding.profile, result);
            xrDestroyInstance(instance);
            return 1;
        }
    }

    // A syntactically valid input path belonging to another profile is not in
    // the Simple Controller allowlist and must be rejected atomically.
    XrPath simpleProfilePath = XR_NULL_PATH;
    result = xrStringToPath(
        instance, "/interaction_profiles/khr/simple_controller", &simpleProfilePath);
    XrPath triggerValuePath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(
            instance, "/user/hand/left/input/trigger/value", &triggerValuePath);
    }
    const XrActionSuggestedBinding crossProfileSuggested[] = {
        {grabAction, triggerValuePath},
    };
    XrInteractionProfileSuggestedBinding crossProfileBindings{};
    crossProfileBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    crossProfileBindings.interactionProfile = simpleProfilePath;
    crossProfileBindings.countSuggestedBindings = 1;
    crossProfileBindings.suggestedBindings = crossProfileSuggested;
    if (XR_SUCCEEDED(result)) {
        result = xrSuggestInteractionProfileBindings(instance, &crossProfileBindings);
    }
    if (result != XR_ERROR_PATH_UNSUPPORTED) {
        std::fprintf(stderr, "FAIL: cross-profile binding source returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    XrPath viveProProfilePath = XR_NULL_PATH;
    result = xrStringToPath(
        instance, "/interaction_profiles/htc/vive_pro", &viveProProfilePath);
    XrPath handSystemPath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(
            instance, "/user/hand/left/input/system/click", &handSystemPath);
    }
    const XrActionSuggestedBinding wrongUserSuggested[] = {{grabAction, handSystemPath}};
    XrInteractionProfileSuggestedBinding wrongUserBindings{};
    wrongUserBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    wrongUserBindings.interactionProfile = viveProProfilePath;
    wrongUserBindings.countSuggestedBindings = 1;
    wrongUserBindings.suggestedBindings = wrongUserSuggested;
    if (XR_SUCCEEDED(result)) {
        result = xrSuggestInteractionProfileBindings(instance, &wrongUserBindings);
    }
    if (result != XR_ERROR_PATH_UNSUPPORTED) {
        std::fprintf(stderr, "FAIL: wrong profile user path returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    XrPath unknownProfilePath = XR_NULL_PATH;
    result = xrStringToPath(
        instance, "/interaction_profiles/basalt/imaginary_controller", &unknownProfilePath);
    XrPath selectPath = XR_NULL_PATH;
    if (XR_SUCCEEDED(result)) {
        result = xrStringToPath(instance, "/user/hand/left/input/select/click", &selectPath);
    }
    const XrActionSuggestedBinding unknownSuggested[] = {{grabAction, selectPath}};
    XrInteractionProfileSuggestedBinding unknownBindings{};
    unknownBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    unknownBindings.interactionProfile = unknownProfilePath;
    unknownBindings.countSuggestedBindings = 1;
    unknownBindings.suggestedBindings = unknownSuggested;
    if (XR_SUCCEEDED(result)) {
        result = xrSuggestInteractionProfileBindings(instance, &unknownBindings);
    }
    if (result != XR_ERROR_PATH_UNSUPPORTED) {
        std::fprintf(stderr, "FAIL: unknown profile suggestion returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    const XrActionSuggestedBinding topLevelSuggested[] = {{grabAction, leftHandPath}};
    XrInteractionProfileSuggestedBinding knownProfileBindings{};
    knownProfileBindings.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    result = xrStringToPath(
        instance,
        "/interaction_profiles/khr/simple_controller",
        &knownProfileBindings.interactionProfile);
    knownProfileBindings.countSuggestedBindings = 1;
    knownProfileBindings.suggestedBindings = topLevelSuggested;
    if (XR_SUCCEEDED(result)) {
        result = xrSuggestInteractionProfileBindings(instance, &knownProfileBindings);
    }
    if (result != XR_ERROR_PATH_UNSUPPORTED) {
        std::fprintf(stderr, "FAIL: top-level binding source returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    if (!openCompositeBindingsAccepted(instance, handPaths)) {
        xrDestroyInstance(instance);
        return 1;
    }

    char resultString[XR_MAX_RESULT_STRING_SIZE] = {};
    result = xrResultToString(instance, XR_ERROR_HANDLE_INVALID, resultString);
    char structureString[XR_MAX_STRUCTURE_NAME_SIZE] = {};
    if (XR_SUCCEEDED(result)) {
        result = xrStructureTypeToString(instance, XR_TYPE_INSTANCE_CREATE_INFO, structureString);
    }
    if (XR_FAILED(result) ||
        std::strcmp(resultString, "XR_ERROR_HANDLE_INVALID") != 0 ||
        std::strcmp(structureString, "XR_TYPE_INSTANCE_CREATE_INFO") != 0) {
        std::fprintf(stderr, "FAIL: to-string returned %d '%s' '%s'\n",
                     result, resultString, structureString);
        xrDestroyInstance(instance);
        return 1;
    }

    result = xrDestroyAction(grabAction);
    if (XR_SUCCEEDED(result)) {
        result = xrDestroyActionSet(actionSet);
    }
    if (XR_SUCCEEDED(result)) {
        const XrResult cascadeResult = xrDestroyAction(poseAction);
        if (cascadeResult != XR_ERROR_HANDLE_INVALID) {
            std::fprintf(stderr, "FAIL: cascaded xrDestroyAction returned %d\n", cascadeResult);
            xrDestroyInstance(instance);
            return 1;
        }
    }
    if (XR_FAILED(result)) {
        std::fprintf(stderr, "FAIL: action teardown returned %d\n", result);
        xrDestroyInstance(instance);
        return 1;
    }

    result = xrDestroyInstance(instance);
    if (result != XR_SUCCESS) {
        std::fprintf(stderr, "FAIL: loader xrDestroyInstance returned %d\n", result);
        return 1;
    }

    std::printf("PASS: Khronos loader created '%s' %s (%ux%u per eye) runtime version %u.%u.%u\n",
                properties.runtimeName,
                systemProperties.systemName,
                views[0].recommendedImageRectWidth,
                views[0].recommendedImageRectHeight,
                XR_VERSION_MAJOR(properties.runtimeVersion),
                XR_VERSION_MINOR(properties.runtimeVersion),
                XR_VERSION_PATCH(properties.runtimeVersion));
    return 0;
}
