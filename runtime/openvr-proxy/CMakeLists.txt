cmake_minimum_required(VERSION 3.25)

# Separate from the OpenXR runtime project: the proxy has no OpenXR dependency and is built and
# tested by runtime/scripts/test-openvr-proxy.zsh.
project(BasaltOpenVRProxy VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "The OpenVR proxy is a Windows PE DLL. Configure with ../cmake/toolchains/mingw-x86_64.cmake.")
endif()

option(BASALT_OPENVR_PROXY_TESTS "Build the fake OpenComposite DLL and the proxy smoke test" ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

# Exports of the pinned OpenComposite build. runtime/scripts/build-opencomposite.zsh fails when
# the built DLL's export table differs from this list.
set(BASALT_OPENCOMPOSITE_EXPORTS_FILE "${CMAKE_CURRENT_SOURCE_DIR}/opencomposite-exports.txt")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${BASALT_OPENCOMPOSITE_EXPORTS_FILE}")
file(STRINGS "${BASALT_OPENCOMPOSITE_EXPORTS_FILE}" basalt_opencomposite_exports
     REGEX "^[A-Za-z_][A-Za-z0-9_]*$")
list(LENGTH basalt_opencomposite_exports basalt_opencomposite_export_count)
if(basalt_opencomposite_export_count EQUAL 0)
    message(FATAL_ERROR "No exports listed in ${BASALT_OPENCOMPOSITE_EXPORTS_FILE}")
endif()

# Exports of Valve's openvr_api.dll that OpenComposite lacks; implemented in openvr_proxy.cpp.
set(basalt_proxy_own_exports
    LiquidVR
    VRControlPanel
    VRHeadsetView
    VRPaths
    VRVirtualDisplay
    VR_GetRuntimePath
)
foreach(name IN LISTS basalt_proxy_own_exports)
    if(name IN_LIST basalt_opencomposite_exports)
        message(FATAL_ERROR "OpenComposite now exports ${name}; drop it from openvr_proxy.cpp")
    endif()
endforeach()

set(proxy_def "LIBRARY openvr_api.dll\nEXPORTS\n")
set(fake_def "LIBRARY openvr_api_opencomposite.dll\nEXPORTS\n")
set(export_list_header "// Generated from opencomposite-exports.txt.\n")
set(fake_special_exports VR_GetGenericInterface)
foreach(name IN LISTS basalt_opencomposite_exports)
    string(APPEND proxy_def "    ${name} = openvr_api_opencomposite.${name}\n")
    string(APPEND export_list_header "BASALT_OPENCOMPOSITE_EXPORT(${name})\n")
    if(name IN_LIST fake_special_exports)
        string(APPEND fake_def "    ${name} = special_${name}\n")
    else()
        string(APPEND fake_def "    ${name} = fake_${name}\n")
    endif()
endforeach()
foreach(name IN LISTS basalt_proxy_own_exports)
    string(APPEND proxy_def "    ${name}\n")
endforeach()

set(generated_dir "${CMAKE_BINARY_DIR}/generated")
file(CONFIGURE OUTPUT "${generated_dir}/openvr_api.def" CONTENT "${proxy_def}" @ONLY)
file(CONFIGURE OUTPUT "${generated_dir}/opencomposite_exports.inc" CONTENT "${export_list_header}" @ONLY)

set(basalt_proxy_warnings -Wall -Wextra -Wpedantic -Werror=return-type)
# Keep every artifact free of MinGW runtime DLL dependencies; a game prefix has none of them.
set(basalt_proxy_link_options -static -static-libgcc -static-libstdc++)

add_library(openvr_api SHARED openvr_proxy.cpp "${generated_dir}/openvr_api.def")
target_compile_options(openvr_api PRIVATE ${basalt_proxy_warnings})
target_link_options(openvr_api PRIVATE ${basalt_proxy_link_options})
set_target_properties(openvr_api PROPERTIES PREFIX "" OUTPUT_NAME "openvr_api")

if(BASALT_OPENVR_PROXY_TESTS)
    string(APPEND fake_def
        "    BasaltFakeCallCount\n"
        "    BasaltFakeCallName\n"
        "    BasaltFakeLastInterfaceVersion\n"
        "    BasaltFakeInterfaceObject\n"
        "    BasaltFakeSetInterfacesAvailable\n")
    file(CONFIGURE OUTPUT "${generated_dir}/fake_opencomposite.def" CONTENT "${fake_def}" @ONLY)

    add_library(fake_opencomposite SHARED
        tests/fake_opencomposite.cpp "${generated_dir}/fake_opencomposite.def")
    target_include_directories(fake_opencomposite PRIVATE "${generated_dir}")
    target_compile_options(fake_opencomposite PRIVATE ${basalt_proxy_warnings})
    target_link_options(fake_opencomposite PRIVATE ${basalt_proxy_link_options})
    set_target_properties(fake_opencomposite PROPERTIES
        PREFIX "" OUTPUT_NAME "openvr_api_opencomposite"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/fake")

    # Links against the proxy's import library so the forwarded and proxy-owned exports are bound
    # through the import table, the way a game binds them.
    add_executable(openvr_proxy_smoke tests/openvr_proxy_smoke.cpp)
    target_include_directories(openvr_proxy_smoke PRIVATE "${generated_dir}")
    target_compile_options(openvr_proxy_smoke PRIVATE ${basalt_proxy_warnings})
    target_link_options(openvr_proxy_smoke PRIVATE ${basalt_proxy_link_options})
    target_link_libraries(openvr_proxy_smoke PRIVATE openvr_api)
endif()
