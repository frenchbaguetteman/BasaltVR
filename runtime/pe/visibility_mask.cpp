#include "runtime.hpp"

namespace {

constexpr uint32_t kViewCount = 2;

}  // namespace

namespace basalt {

// XR_KHR_visibility_mask. ALVR does not report the Quest lens mask, so every
// mask type is "not available": the spec requires zero vertex and index
// counts in that case. Applications then render the full view, which is what
// they do on a runtime without this extension.
XrResult XRAPI_CALL getVisibilityMask(
    XrSession session,
    XrViewConfigurationType viewConfigurationType,
    uint32_t viewIndex,
    XrVisibilityMaskTypeKHR visibilityMaskType,
    XrVisibilityMaskKHR* visibilityMask) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (visibilityMask == nullptr ||
        visibilityMask->type != XR_TYPE_VISIBILITY_MASK_KHR) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (visibilityMaskType != XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR &&
        visibilityMaskType != XR_VISIBILITY_MASK_TYPE_VISIBLE_TRIANGLE_MESH_KHR &&
        visibilityMaskType != XR_VISIBILITY_MASK_TYPE_LINE_LOOP_KHR) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    if (viewIndex >= kViewCount) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    // A zero capacity in either field is a size query for both arrays.
    if (visibilityMask->vertexCapacityInput != 0 &&
        visibilityMask->indexCapacityInput != 0 &&
        (visibilityMask->vertices == nullptr || visibilityMask->indices == nullptr)) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    visibilityMask->vertexCountOutput = 0;
    visibilityMask->indexCountOutput = 0;
    return XR_SUCCESS;
}

}  // namespace basalt
