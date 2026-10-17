#pragma once

#include <windows.h>

#include <d3d11.h>

#include <cstdint>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include "basalt_control_protocol.h"

namespace basalt {

constexpr XrVersion kRuntimeApiVersion = XR_MAKE_VERSION(1, 0, 0);
constexpr XrVersion kRuntimeVersion = XR_MAKE_VERSION(0, 1, 0);
constexpr XrSystemId kSystemId = 1;

// Largest per-eye render target the runtime advertises, accepts for a
// swapchain, or takes from the streamer's configured view size.
constexpr uint32_t kMaxViewWidth = BASALT_CONTROL_MAX_VIEW_WIDTH;
constexpr uint32_t kMaxViewHeight = BASALT_CONTROL_MAX_VIEW_HEIGHT;

// A swapchain image is not per-eye sized: UE4 submits both eyes as one texture
// and selects each eye with imageRect, so the accepted image may be twice a
// view. Only the per-eye limits bound a view rect.
constexpr uint32_t kMaxSwapchainWidth = kMaxViewWidth * 2;
constexpr uint32_t kMaxSwapchainHeight = kMaxViewHeight * 2;

// ALVR's hashed path ID for /user/hand/right/input/system/click.
constexpr uint64_t kAlvrRightSystemClickPathId = 0x19729bd97073d474ULL;

bool isValidInstance(XrInstance instance);
bool isD3D11ExtensionEnabled(XrInstance instance);
bool isD3D11RuntimeAvailable();
bool isValidSession(XrSession session);
ID3D11Device* retainSessionDevice(XrSession session);

void invalidatePathsForInstance(XrInstance instance);
bool isKnownPath(XrPath path);
bool pathStringEquals(XrPath path, const char* string);
bool isTopLevelUserPath(XrPath path);
bool isBindingSourcePath(XrPath path);

bool getActionForSpace(
    XrAction action,
    XrActionType* actionType,
    bool* allowsSubactionPath,
    XrPath subactionPath);
bool getActionPoseSource(
    XrSession session,
    XrAction action,
    XrPath subactionPath,
    uint32_t* hand,
    bool* aimPose);
void invalidateInputForSession(XrSession session);
void invalidateInputForInstance(XrInstance instance);

bool isSessionFocused(XrSession session);
void queueInteractionProfileChanged(XrSession session);
void queueReferenceSpaceChange(
    XrSession session,
    XrTime changeTime,
    const XrPosef& poseInPreviousSpace);
bool isSpaceForSession(XrSpace space, XrSession session);
bool isPoseWellFormed(const XrPosef& pose);
bool getSwapchainSubmitState(
    XrSwapchain swapchain,
    XrSession* session,
    uint32_t* width,
    uint32_t* height,
    uint32_t* arraySize,
    bool* hasReleasedImage,
    uint32_t* lastReleasedIndex);

XrResult XRAPI_CALL getInstanceProcAddr(
    XrInstance instance,
    const char* name,
    PFN_xrVoidFunction* function);

XrResult XRAPI_CALL getSystem(
    XrInstance instance,
    const XrSystemGetInfo* getInfo,
    XrSystemId* systemId);
XrResult XRAPI_CALL getSystemProperties(
    XrInstance instance,
    XrSystemId systemId,
    XrSystemProperties* properties);
XrResult XRAPI_CALL enumerateEnvironmentBlendModes(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    uint32_t environmentBlendModeCapacityInput,
    uint32_t* environmentBlendModeCountOutput,
    XrEnvironmentBlendMode* environmentBlendModes);
XrResult XRAPI_CALL enumerateViewConfigurations(
    XrInstance instance,
    XrSystemId systemId,
    uint32_t viewConfigurationTypeCapacityInput,
    uint32_t* viewConfigurationTypeCountOutput,
    XrViewConfigurationType* viewConfigurationTypes);
XrResult XRAPI_CALL getViewConfigurationProperties(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    XrViewConfigurationProperties* configurationProperties);
XrResult XRAPI_CALL enumerateViewConfigurationViews(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    uint32_t viewCapacityInput,
    uint32_t* viewCountOutput,
    XrViewConfigurationView* views);
XrResult XRAPI_CALL getD3D11GraphicsRequirements(
    XrInstance instance,
    XrSystemId systemId,
    XrGraphicsRequirementsD3D11KHR* graphicsRequirements);
XrResult XRAPI_CALL createSession(
    XrInstance instance,
    const XrSessionCreateInfo* createInfo,
    XrSession* session);
XrResult XRAPI_CALL destroySession(XrSession session);
void invalidateSessionForInstance(XrInstance instance);
void initializeSessionLifecycle(XrInstance instance, XrSession session);
void invalidateSessionLifecycle(XrSession session);
XrResult XRAPI_CALL pollEvent(
    XrInstance instance,
    XrEventDataBuffer* eventData);
XrResult XRAPI_CALL beginSession(
    XrSession session,
    const XrSessionBeginInfo* beginInfo);
XrResult XRAPI_CALL endSession(XrSession session);
XrResult XRAPI_CALL requestExitSession(XrSession session);
XrResult XRAPI_CALL waitFrame(
    XrSession session,
    const XrFrameWaitInfo* frameWaitInfo,
    XrFrameState* frameState);
XrResult XRAPI_CALL beginFrame(
    XrSession session,
    const XrFrameBeginInfo* frameBeginInfo);
XrResult XRAPI_CALL endFrame(
    XrSession session,
    const XrFrameEndInfo* frameEndInfo);
XrResult XRAPI_CALL stringToPath(
    XrInstance instance,
    const char* pathString,
    XrPath* path);
XrResult XRAPI_CALL pathToString(
    XrInstance instance,
    XrPath path,
    uint32_t bufferCapacityInput,
    uint32_t* bufferCountOutput,
    char* buffer);
XrResult XRAPI_CALL createActionSet(
    XrInstance instance,
    const XrActionSetCreateInfo* createInfo,
    XrActionSet* actionSet);
XrResult XRAPI_CALL destroyActionSet(XrActionSet actionSet);
XrResult XRAPI_CALL createAction(
    XrActionSet actionSet,
    const XrActionCreateInfo* createInfo,
    XrAction* action);
XrResult XRAPI_CALL destroyAction(XrAction action);
XrResult XRAPI_CALL suggestInteractionProfileBindings(
    XrInstance instance,
    const XrInteractionProfileSuggestedBinding* suggestedBindings);
XrResult XRAPI_CALL attachSessionActionSets(
    XrSession session,
    const XrSessionActionSetsAttachInfo* attachInfo);
XrResult XRAPI_CALL getCurrentInteractionProfile(
    XrSession session,
    XrPath topLevelUserPath,
    XrInteractionProfileState* interactionProfile);
XrResult XRAPI_CALL syncActions(
    XrSession session,
    const XrActionsSyncInfo* syncInfo);
XrResult XRAPI_CALL getActionStateBoolean(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStateBoolean* state);
XrResult XRAPI_CALL getActionStateFloat(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStateFloat* state);
XrResult XRAPI_CALL getActionStateVector2f(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStateVector2f* state);
XrResult XRAPI_CALL getActionStatePose(
    XrSession session,
    const XrActionStateGetInfo* getInfo,
    XrActionStatePose* state);
XrResult XRAPI_CALL enumerateBoundSourcesForAction(
    XrSession session,
    const XrBoundSourcesForActionEnumerateInfo* enumerateInfo,
    uint32_t sourceCapacityInput,
    uint32_t* sourceCountOutput,
    XrPath* sources);
XrResult XRAPI_CALL getInputSourceLocalizedName(
    XrSession session,
    const XrInputSourceLocalizedNameGetInfo* getInfo,
    uint32_t bufferCapacityInput,
    uint32_t* bufferCountOutput,
    char* buffer);
XrResult XRAPI_CALL applyHapticFeedback(
    XrSession session,
    const XrHapticActionInfo* hapticActionInfo,
    const XrHapticBaseHeader* hapticFeedback);
XrResult XRAPI_CALL stopHapticFeedback(
    XrSession session,
    const XrHapticActionInfo* hapticActionInfo);
XrResult XRAPI_CALL createActionSpace(
    XrSession session,
    const XrActionSpaceCreateInfo* createInfo,
    XrSpace* space);
XrResult XRAPI_CALL locateSpace(
    XrSpace space,
    XrSpace baseSpace,
    XrTime time,
    XrSpaceLocation* location);
XrResult XRAPI_CALL locateViews(
    XrSession session,
    const XrViewLocateInfo* viewLocateInfo,
    XrViewState* viewState,
    uint32_t viewCapacityInput,
    uint32_t* viewCountOutput,
    XrView* views);
XrResult XRAPI_CALL getReferenceSpaceBoundsRect(
    XrSession session,
    XrReferenceSpaceType referenceSpaceType,
    XrExtent2Df* bounds);
XrResult XRAPI_CALL enumerateReferenceSpaces(
    XrSession session,
    uint32_t spaceCapacityInput,
    uint32_t* spaceCountOutput,
    XrReferenceSpaceType* spaces);
XrResult XRAPI_CALL createReferenceSpace(
    XrSession session,
    const XrReferenceSpaceCreateInfo* createInfo,
    XrSpace* space);
XrResult XRAPI_CALL destroySpace(XrSpace space);
void invalidateSpacesForSession(XrSession session);
uint64_t locatedViewsQuestTimestamp(XrSession session, XrTime displayTime);
bool getReferenceSpace(
    XrSpace space,
    XrSession* session,
    XrReferenceSpaceType* referenceSpaceType,
    XrPosef* poseInReferenceSpace);
XrResult XRAPI_CALL enumerateSwapchainFormats(
    XrSession session,
    uint32_t formatCapacityInput,
    uint32_t* formatCountOutput,
    int64_t* formats);
XrResult XRAPI_CALL createSwapchain(
    XrSession session,
    const XrSwapchainCreateInfo* createInfo,
    XrSwapchain* swapchain);
XrResult XRAPI_CALL destroySwapchain(XrSwapchain swapchain);
XrResult XRAPI_CALL enumerateSwapchainImages(
    XrSwapchain swapchain,
    uint32_t imageCapacityInput,
    uint32_t* imageCountOutput,
    XrSwapchainImageBaseHeader* images);
XrResult XRAPI_CALL acquireSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageAcquireInfo* acquireInfo,
    uint32_t* index);
XrResult XRAPI_CALL waitSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageWaitInfo* waitInfo);
XrResult XRAPI_CALL releaseSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageReleaseInfo* releaseInfo);
void invalidateSwapchainForSession(XrSession session);

}  // namespace basalt
