add_executable(negotiation_smoke negotiation_smoke.cpp)
target_link_libraries(negotiation_smoke PRIVATE OpenXR::headers)
target_compile_definitions(negotiation_smoke PRIVATE XR_NO_PROTOTYPES)
target_compile_options(negotiation_smoke PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(negotiation_smoke PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(loader_smoke loader_smoke.cpp)
target_link_libraries(loader_smoke PRIVATE OpenXR::openxr_loader)
target_compile_options(loader_smoke PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(loader_smoke PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(dxmt_shared_texture_probe dxmt_shared_texture_probe.cpp)
target_link_libraries(dxmt_shared_texture_probe PRIVATE d3d11 dxgi dxguid)
target_compile_options(dxmt_shared_texture_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(dxmt_shared_texture_probe PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(dxmt_iosurface_probe dxmt_iosurface_probe.cpp)
target_link_libraries(dxmt_iosurface_probe PRIVATE d3d11 dxgi dxguid)
target_compile_options(dxmt_iosurface_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(dxmt_iosurface_probe PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(dxmt_iosurface_pixel_source dxmt_iosurface_pixel_source.cpp)
target_link_libraries(dxmt_iosurface_pixel_source PRIVATE d3d11 dxgi dxguid)
target_compile_options(dxmt_iosurface_pixel_source PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(dxmt_iosurface_pixel_source PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(dxmt_fence_probe dxmt_fence_probe.cpp)
target_link_libraries(dxmt_fence_probe PRIVATE d3d11 dxgi dxguid)
target_compile_options(dxmt_fence_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(dxmt_fence_probe PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(dxmt_msaa_probe dxmt_msaa_probe.cpp)
target_link_libraries(dxmt_msaa_probe PRIVATE d3d11 d3dcompiler dxgi dxguid)
target_compile_options(dxmt_msaa_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(dxmt_msaa_probe PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(dxmt_window_swapchain_probe WIN32 dxmt_window_swapchain_probe.cpp)
target_link_libraries(dxmt_window_swapchain_probe PRIVATE d3d11 dxgi dxguid user32)
target_compile_options(dxmt_window_swapchain_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(dxmt_window_swapchain_probe PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(wine_process_lifetime_probe wine_process_lifetime_probe.cpp)
target_compile_options(wine_process_lifetime_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(wine_process_lifetime_probe PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(steamwebhelper_compat WIN32 steamwebhelper_compat.cpp)
target_link_libraries(steamwebhelper_compat PRIVATE shell32)
target_compile_options(steamwebhelper_compat PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(steamwebhelper_compat PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(d3d11_runtime_smoke d3d11_runtime_smoke.cpp)
target_link_libraries(
    d3d11_runtime_smoke
    PRIVATE
        OpenXR::openxr_loader
        d3d11
        dxgi
        dxguid
        ws2_32
)
target_compile_definitions(d3d11_runtime_smoke PRIVATE XR_USE_GRAPHICS_API_D3D11)
target_compile_options(d3d11_runtime_smoke PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(d3d11_runtime_smoke PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(d3d11_compositor_smoke d3d11_compositor_smoke.cpp)
target_link_libraries(
    d3d11_compositor_smoke
    PRIVATE
        OpenXR::openxr_loader
        d3d11
        dxgi
        dxguid
)
target_compile_definitions(d3d11_compositor_smoke PRIVATE XR_USE_GRAPHICS_API_D3D11)
target_compile_options(d3d11_compositor_smoke PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(d3d11_compositor_smoke PRIVATE -static -static-libgcc -static-libstdc++)

add_executable(frame_timer_probe frame_timer_probe.cpp)
target_compile_options(frame_timer_probe PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(frame_timer_probe PRIVATE -static -static-libgcc -static-libstdc++)

# Optional external-application gate. This is Khronos' real hello_xr program,
# not a Basalt-shaped smoke test. Keep it opt-in because it adds a second
# pinned source download and is primarily run with a connected headset.
option(BASALT_BUILD_KHR_HELLO_XR "Build the pinned Khronos hello_xr D3D11 sample" OFF)
if(BASALT_BUILD_KHR_HELLO_XR)
    FetchContent_Declare(
        openxr_sdk_source
        URL https://github.com/KhronosGroup/OpenXR-SDK-Source/archive/211e2f4f0b79932300a845f3a8ed75026dbfa4a3.tar.gz
        URL_HASH SHA256=44747d4b90e0e4d5793da90ec7af9d38aa856b3c78d7fbdca0faad8029460325
        DOWNLOAD_EXTRACT_TIMESTAMP FALSE
        # Download the source without adding its top-level project. Basalt
        # already owns an identically versioned OpenXR loader target.
        SOURCE_SUBDIR basalt-no-cmake-project
    )
    FetchContent_MakeAvailable(openxr_sdk_source)

    FetchContent_Declare(
        directxmath
        URL https://github.com/microsoft/DirectXMath/archive/93e6399d6d15e1e57f80b5cea04d5a8eb892d693.tar.gz
        URL_HASH SHA256=5df86719dff4f5c10418de4ed3b2e8a77e41ccf8aeab3f74d2810a45e0935df7
        DOWNLOAD_EXTRACT_TIMESTAMP FALSE
        SOURCE_SUBDIR basalt-no-cmake-project
    )
    FetchContent_MakeAvailable(directxmath)

    set(KHR_HELLO_XR_DIR "${openxr_sdk_source_SOURCE_DIR}/src/tests/hello_xr")
    add_executable(
        khr_hello_xr_d3d11
        ${KHR_HELLO_XR_DIR}/d3d_common.cpp
        ${KHR_HELLO_XR_DIR}/graphicsplugin_d3d11.cpp
        ${KHR_HELLO_XR_DIR}/graphicsplugin_factory.cpp
        ${KHR_HELLO_XR_DIR}/logger.cpp
        ${KHR_HELLO_XR_DIR}/main.cpp
        ${KHR_HELLO_XR_DIR}/openxr_program.cpp
        ${KHR_HELLO_XR_DIR}/pch.cpp
        ${KHR_HELLO_XR_DIR}/platformplugin_factory.cpp
        ${KHR_HELLO_XR_DIR}/platformplugin_win32.cpp
        ${KHR_HELLO_XR_DIR}/swapchain_image_data.cpp
    )
    target_include_directories(
        khr_hello_xr_d3d11
        PRIVATE
            ${directxmath_SOURCE_DIR}/Inc
            ${CMAKE_CURRENT_SOURCE_DIR}/hello_xr_compat
            ${KHR_HELLO_XR_DIR}
            ${openxr_sdk_source_SOURCE_DIR}/src
            ${openxr_sdk_source_SOURCE_DIR}/src/common
            ${openxr_sdk_source_SOURCE_DIR}/src/external/span-lite/include
    )
    target_compile_definitions(
        khr_hello_xr_d3d11
        PRIVATE
            XR_USE_PLATFORM_WIN32
            XR_USE_GRAPHICS_API_D3D11
            # The scalar implementation is portable across MinGW targets and
            # plenty fast for hello_xr's handful of cube transforms.
            _XM_NO_INTRINSICS_)
    target_compile_options(khr_hello_xr_d3d11 PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(
        khr_hello_xr_d3d11
        PRIVATE OpenXR::openxr_loader ole32 d3d11 d3dcompiler dxgi dxguid)
    target_link_options(
        khr_hello_xr_d3d11 PRIVATE -static -static-libgcc -static-libstdc++)
endif()

add_executable(opencomposite_frame_timing_smoke opencomposite_frame_timing_smoke.cpp)
target_compile_options(opencomposite_frame_timing_smoke PRIVATE -Wall -Wextra -Wpedantic)
target_link_options(opencomposite_frame_timing_smoke PRIVATE -static -static-libgcc -static-libstdc++)
