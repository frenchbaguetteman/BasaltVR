add_library(
    basalt_openxr
    SHARED
    basalt_openxr.def
    compositor.cpp
    control.cpp
    entrypoints.cpp
    frame.cpp
    graphics.cpp
    input.cpp
    path.cpp
    runtime.cpp
    space.cpp
    swapchain.cpp
    system.cpp
    visibility_mask.cpp
)

target_include_directories(basalt_openxr PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(basalt_openxr PRIVATE OpenXR::headers d3d11 dxgi dxguid ws2_32)
target_compile_definitions(
    basalt_openxr
    PRIVATE
        XR_NO_PROTOTYPES
        XR_USE_GRAPHICS_API_D3D11
)
target_compile_options(
    basalt_openxr
    PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -Werror=return-type
)
target_link_options(basalt_openxr PRIVATE -static-libgcc -static-libstdc++)

set_target_properties(
    basalt_openxr
    PROPERTIES
        PREFIX ""
        OUTPUT_NAME "basalt_openxr"
)

configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/../manifests/basalt_openxr.json.in"
    "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/basalt_openxr.json"
    @ONLY
)
