#!/bin/zsh

# Runs the first visible M3 integration test:
# D3D11/OpenXR under pinned Wine + Basalt DXMT -> IOSurface/RuntimeLink ->
# VideoToolbox -> ALVR wired transport -> headset.
#
# Usage: runtime/scripts/test-headset.zsh [seconds]
# The generated Wine tree and prefix live under runtime/build. The script
# temporarily overlays only that disposable Wine tree with the Basalt DXMT
# fork and restores the pinned stock DXMT files during cleanup.

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
repo_dir=${runtime_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}
toolchain_file=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake

duration_seconds=${1:-${BASALT_HEADSET_SECONDS:-60}}
fps=${BASALT_HEADSET_FPS:-72}
megabits=${BASALT_HEADSET_MBPS:-12}
resolution=${BASALT_HEADSET_RESOLUTION:-balanced}

if [[ ${duration_seconds} != <-> ]] || (( duration_seconds < 5 || duration_seconds > 600 )); then
    print -u2 "usage: ${0:t} [seconds]  # seconds must be 5-600"
    exit 2
fi
if [[ ${fps} != <-> ]] || (( fps < 1 || fps > 240 )); then
    print -u2 "BASALT_HEADSET_FPS must be an integer from 1 to 240"
    exit 2
fi
frame_count=$(( duration_seconds * fps ))
if (( frame_count > 1000000 )); then
    print -u2 "Requested integration run is too long (${frame_count} frames)."
    exit 2
fi

readonly wine_version=11.10
readonly dxmt_version=v0.80
wine_extract_dir=${build_dir}/dxmt/toolchain/wine-${wine_version}
wine_root=${wine_extract_dir}/Wine\ Devel.app/Contents/Resources/wine
stock_dxmt=${build_dir}/dxmt/toolchain/dxmt-${dxmt_version}/${dxmt_version}
fork_dxmt=${build_dir}/dxmt/fork-install
wine_prefix=${BASALT_DXMT_WINEPREFIX:-${build_dir}/dxmt/prefix-wine-${wine_version}-dxmt-${dxmt_version}}
probe_dir=${build_dir}/dxmt/probe
control_dir=${build_dir}/headset-integration
control_file=${control_dir}/control

for tool in cmake swift x86_64-w64-mingw32-objdump; do
    if ! command -v ${tool} >/dev/null; then
        print -u2 "Missing ${tool}. See runtime/README.md."
        exit 1
    fi
done
if [[ ! -x ${wine_root}/bin/wine ||
      ! -f ${stock_dxmt}/x86_64-windows/d3d11.dll ||
      ! -f ${fork_dxmt}/x86_64-windows/d3d11.dll ||
      ! -f ${fork_dxmt}/x86_64-unix/winemetal.so ]]; then
    print -u2 "The pinned Wine/DXMT test stack is incomplete."
    print -u2 "Run runtime/scripts/test-dxmt.zsh and, if requested,"
    print -u2 "runtime/scripts/build-dxmt-fork.zsh first."
    exit 1
fi
if command -v lsof >/dev/null &&
   [[ -n $(lsof -nP -tiTCP:9999 -sTCP:LISTEN 2>/dev/null || true) ]]; then
    print -u2 "TCP port 9999 is already in use. Stop the existing streamer with Ctrl-C, then retry."
    exit 1
fi

streamer_pid=
fork_overlaid=false

overlay_dxmt() {
    local source_windows=$1
    local source_unix=$2
    for dll in d3d10core.dll d3d11.dll dxgi.dll winemetal.dll; do
        cp "${source_windows}/${dll}" "${wine_root}/lib/wine/x86_64-windows/${dll}"
        if [[ -d ${wine_prefix}/drive_c/windows/system32 ]]; then
            cp "${source_windows}/${dll}" "${wine_prefix}/drive_c/windows/system32/${dll}"
        fi
    done
    cp "${source_unix}/winemetal.so" "${wine_root}/lib/wine/x86_64-unix/winemetal.so"
}

cleanup() {
    local saved_status=$?
    trap - EXIT INT TERM
    if [[ -n ${streamer_pid} ]] && kill -0 ${streamer_pid} 2>/dev/null; then
        kill -INT ${streamer_pid} 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 ${streamer_pid} 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 ${streamer_pid} 2>/dev/null; then
            kill -TERM ${streamer_pid} 2>/dev/null || true
        fi
        wait ${streamer_pid} 2>/dev/null || true
    fi
    WINEPREFIX=${wine_prefix} "${wine_root}/bin/wineserver" -k >/dev/null 2>&1 || true
    if [[ ${fork_overlaid} == true ]]; then
        overlay_dxmt "${stock_dxmt}/x86_64-windows" "${stock_dxmt}/x86_64-unix"
    fi
    rm -f "${control_file}"
    exit ${saved_status}
}
trap cleanup EXIT
trap 'exit 130' INT TERM

print "Building the release streamer and OpenXR visual producer..."
swift build -c release --package-path "${repo_dir}/streamer"

configure_args=(
    -S "${runtime_dir}"
    -B "${build_dir}"
    -DCMAKE_BUILD_TYPE=Release
)
if [[ ! -f ${build_dir}/CMakeCache.txt ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=${toolchain_file}")
fi
cmake "${configure_args[@]}"
cmake --build "${build_dir}" --parallel --target basalt_openxr d3d11_runtime_smoke

mkdir -p "${wine_prefix}" "${probe_dir}" "${control_dir}"
rm -f "${control_file}"
WINEPREFIX=${wine_prefix} "${wine_root}/bin/wineserver" -k >/dev/null 2>&1 || true

# Establish a known stock prefix first, then apply the matched Basalt fork.
overlay_dxmt "${stock_dxmt}/x86_64-windows" "${stock_dxmt}/x86_64-unix"
WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all \
    "${wine_root}/bin/wineboot" -u >/dev/null 2>&1
overlay_dxmt "${fork_dxmt}/x86_64-windows" "${fork_dxmt}/x86_64-unix"
fork_overlaid=true

manifest=${build_dir}/bin/basalt_openxr.json
manifest_windows="Z:${manifest//\//\\}"
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_root}/bin/wine" reg.exe add \
    'HKLM\Software\Khronos\OpenXR\1' \
    /v ActiveRuntime /t REG_SZ /d "${manifest_windows}" /f >/dev/null
cp "${build_dir}/bin/d3d11_runtime_smoke.exe" "${probe_dir}/d3d11_runtime_smoke.exe"

streamer_bin=${repo_dir}/streamer/.build/release/basalt-streamer
print ""
print "Starting ALVR and waiting for the Quest..."
"${streamer_bin}" \
    --wired \
    --runtime "${control_file}" \
    --fps "${fps}" \
    --mbps "${megabits}" \
    --resolution "${resolution}" &
streamer_pid=$!

for _ in {1..300}; do
    if [[ -s ${control_file} ]]; then
        break
    fi
    if ! kill -0 ${streamer_pid} 2>/dev/null; then
        wait ${streamer_pid}
        print -u2 "FAIL: the streamer exited before its runtime control socket was ready."
        exit 1
    fi
    sleep 0.1
done
if [[ ! -s ${control_file} ]]; then
    print -u2 "FAIL: timed out waiting for ALVR StreamReady/runtime control file."
    exit 1
fi
# The streamer advertises its selected per-eye size ("<port> <token> <w> <h>"),
# and the runtime recommends exactly that size to the smoke.
read -r _ _ view_width view_height < "${control_file}"
if [[ ${view_width} != <-> || ${view_height} != <-> ]]; then
    print -u2 "FAIL: the runtime control file does not carry a per-eye size."
    exit 1
fi

control_windows="Z:${control_file//\//\\}"
print ""
print "Rendering ${frame_count} OpenXR frames (${duration_seconds}s at ${fps} Hz)."
print "Expected: a green controller marker plus a pale world-anchored depth grid."
print "Move your head: the grid should remain fixed in space with correct stereo depth."
print "Move the left controller in 3D: the marker follows and scales with distance."
print "Squeeze the left grip: the marker grows/turns yellow and the controller receives a pulse."
print "This validates D3D11 -> DXMT -> IOSurface -> Swift -> H.264 -> ALVR -> Quest."
print ""

pushd "${probe_dir}" >/dev/null
WINEPREFIX=${wine_prefix} \
WINEARCH=win64 \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
DXMT_BASALT_IOSURFACE=1 \
BASALT_EXPECT_IOSURFACE=1 \
BASALT_REQUIRE_HEAD_POSE=1 BASALT_REQUIRE_CONTROLLER_INPUT=1 \
BASALT_EXPECT_VIEW_WIDTH=${view_width} BASALT_EXPECT_VIEW_HEIGHT=${view_height} \
BASALT_CONTROL="${control_windows}" \
    "${wine_root}/bin/wine" ./d3d11_runtime_smoke.exe \
        --render-frames "${frame_count}" --visual
popd >/dev/null

print ""
print "PASS: the OpenXR producer completed the live head/controller/action/haptic path."
print "VISUAL GATE: confirm fused stereo, a world-fixed grid, and 3D controller response."
