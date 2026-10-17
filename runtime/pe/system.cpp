#include "runtime.hpp"

#include <cstring>

#include "control.hpp"

namespace {

constexpr uint32_t kViewCount = 2;

XrResult validateSystemQuery(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (systemId != basalt::kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    if (viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    return XR_SUCCESS;
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL getSystem(
    XrInstance instance,
    const XrSystemGetInfo* getInfo,
    XrSystemId* systemId) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (systemId == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *systemId = XR_NULL_SYSTEM_ID;
    if (getInfo == nullptr || getInfo->type != XR_TYPE_SYSTEM_GET_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (getInfo->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) {
        return XR_ERROR_FORM_FACTOR_UNSUPPORTED;
    }

    *systemId = kSystemId;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getSystemProperties(
    XrInstance instance,
    XrSystemId systemId,
    XrSystemProperties* properties) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (systemId != kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    if (properties == nullptr || properties->type != XR_TYPE_SYSTEM_PROPERTIES) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    properties->systemId = kSystemId;
    properties->vendorId = 0;
    std::strncpy(properties->systemName, "BasaltVR ALVR HMD prototype", XR_MAX_SYSTEM_NAME_SIZE - 1);
    properties->systemName[XR_MAX_SYSTEM_NAME_SIZE - 1] = '\0';
    properties->graphicsProperties.maxSwapchainImageWidth = kMaxSwapchainWidth;
    properties->graphicsProperties.maxSwapchainImageHeight = kMaxSwapchainHeight;
    properties->graphicsProperties.maxLayerCount = XR_MIN_COMPOSITION_LAYERS_SUPPORTED;
    properties->trackingProperties.orientationTracking = XR_TRUE;
    properties->trackingProperties.positionTracking = XR_TRUE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL enumerateEnvironmentBlendModes(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    uint32_t environmentBlendModeCapacityInput,
    uint32_t* environmentBlendModeCountOutput,
    XrEnvironmentBlendMode* environmentBlendModes) {
    XrResult result = validateSystemQuery(instance, systemId, viewConfigurationType);
    if (XR_FAILED(result)) {
        return result;
    }
    if (environmentBlendModeCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *environmentBlendModeCountOutput = 1;
    if (environmentBlendModeCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (environmentBlendModes == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (environmentBlendModeCapacityInput < 1) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    environmentBlendModes[0] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL enumerateViewConfigurations(
    XrInstance instance,
    XrSystemId systemId,
    uint32_t viewConfigurationTypeCapacityInput,
    uint32_t* viewConfigurationTypeCountOutput,
    XrViewConfigurationType* viewConfigurationTypes) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (systemId != kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    if (viewConfigurationTypeCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *viewConfigurationTypeCountOutput = 1;
    if (viewConfigurationTypeCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (viewConfigurationTypes == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (viewConfigurationTypeCapacityInput < 1) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    viewConfigurationTypes[0] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getViewConfigurationProperties(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    XrViewConfigurationProperties* configurationProperties) {
    XrResult result = validateSystemQuery(instance, systemId, viewConfigurationType);
    if (XR_FAILED(result)) {
        return result;
    }
    if (configurationProperties == nullptr ||
        configurationProperties->type != XR_TYPE_VIEW_CONFIGURATION_PROPERTIES) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    configurationProperties->viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    configurationProperties->fovMutable = XR_FALSE;
    return XR_SUCCESS;
}

XrResult XRAPI_CALL enumerateViewConfigurationViews(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    uint32_t viewCapacityInput,
    uint32_t* viewCountOutput,
    XrViewConfigurationView* views) {
    XrResult result = validateSystemQuery(instance, systemId, viewConfigurationType);
    if (XR_FAILED(result)) {
        return result;
    }
    if (viewCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *viewCountOutput = kViewCount;
    if (viewCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (views == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (viewCapacityInput < kViewCount) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    for (uint32_t index = 0; index < kViewCount; ++index) {
        if (views[index].type != XR_TYPE_VIEW_CONFIGURATION_VIEW) {
            return XR_ERROR_VALIDATION_FAILURE;
        }
    }
    // The streamer's configured per-eye size, else the full headset size.
    uint32_t recommendedWidth = kMaxViewWidth;
    uint32_t recommendedHeight = kMaxViewHeight;
    controlConfiguredViewSize(&recommendedWidth, &recommendedHeight);
    for (uint32_t index = 0; index < kViewCount; ++index) {
        views[index].recommendedImageRectWidth = recommendedWidth;
        views[index].maxImageRectWidth = kMaxViewWidth;
        views[index].recommendedImageRectHeight = recommendedHeight;
        views[index].maxImageRectHeight = kMaxViewHeight;
        views[index].recommendedSwapchainSampleCount = 1;
        views[index].maxSwapchainSampleCount = 1;
    }
    return XR_SUCCESS;
}

}  // namespace basalt
