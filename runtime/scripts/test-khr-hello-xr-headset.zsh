#!/bin/zsh

# Runs Khronos' unmodified hello_xr application against Basalt's runtime.
# This is an opt-in, interactive M4 compatibility gate: it uses the same
# disposable pinned Wine/DXMT stack as the lower-level integration tests and
# never opens or modifies a CrossOver/Steam bottle.
#
# Quest link: BASALT_HEADSET_TRANSPORT=usb|wifi|auto (default auto). Wi-Fi needs no
# Trust tap: open ALVR on the Quest and the streamer connects by itself. Use
# BASALT_HEADSET_MBPS to change the bitrate (default 12).

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
repo_dir=${runtime_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}
toolchain_file=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake

fps=${BASALT_HEADSET_FPS:-72}
megabits=${BASALT_HEADSET_MBPS:-12}
resolution=${BASALT_HEADSET_RESOLUTION:-balanced}
# usb, wifi, or auto (USB when a USB Quest is attached, else Wi-Fi). If adb is not
# installed, auto keeps the old behaviour: --wired.
transport=${BASALT_HEADSET_TRANSPORT:-auto}
if [[ ${transport} != (auto|usb|wifi) ]]; then
    print -u2 "BASALT_HEADSET_TRANSPORT must be auto, usb, or wifi"
    exit 2
fi
# Extra basalt-streamer flags for A/B runs, split on spaces, for example
# BASALT_HEADSET_STREAMER_ARGS='--idr-interval 10 --entropy cavlc'.
extra_streamer_args=(${=BASALT_HEADSET_STREAMER_ARGS:-})

if [[ ${fps} != <-> ]] || (( fps < 1 || fps > 240 )); then
    print -u2 "BASALT_HEADSET_FPS must be an integer from 1 to 240"
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
control_dir=${build_dir}/hello-xr-integration
control_file=${control_dir}/control

for tool in cmake swift; do
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

print "Building the release streamer and pinned Khronos hello_xr D3D11 sample..."
swift build -c release --package-path "${repo_dir}/streamer"

configure_args=(
    -S "${runtime_dir}"
    -B "${build_dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DBASALT_BUILD_KHR_HELLO_XR=ON
)
if [[ ! -f ${build_dir}/CMakeCache.txt ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=${toolchain_file}")
fi
cmake "${configure_args[@]}"
cmake --build "${build_dir}" --parallel --target basalt_openxr khr_hello_xr_d3d11

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
cp "${build_dir}/bin/khr_hello_xr_d3d11.exe" "${probe_dir}/khr_hello_xr_d3d11.exe"

streamer_bin=${repo_dir}/streamer/.build/release/basalt-streamer

# Pick the Quest link. quest-adb.zsh chooses one adb serial (USB wins over adb-over-Wi-Fi).
source "${repo_dir}/scripts/quest-adb.zsh"
link_args=(--wired)
wifi_log=
if [[ ${transport} == wifi ]]; then
    link_args=(--wireless)
elif [[ ${transport} == auto ]]; then
    if quest_find_adb 2>/dev/null; then
        if quest_pick_serial && [[ ${QUEST_LINK} == usb ]]; then
            link_args=(--wired)
        else
            link_args=(--wireless)
        fi
    fi
fi
if [[ ${link_args[1]} == --wireless ]]; then
    wifi_log=${control_dir}/streamer.log
    : >"${wifi_log}"
    print "Quest link: Wi-Fi. Open ALVR on the Quest and tap nothing else: there is no Trust step."
    print "If your Mac asks to allow incoming connections or Local Network access, click Allow."
else
    print "Quest link: USB."
fi

print ""
print "Starting ALVR and waiting for the Quest..."
if [[ -n ${wifi_log} ]]; then
    "${streamer_bin}" \
        "${link_args[@]}" \
        --runtime "${control_file}" \
        --fps "${fps}" \
        --mbps "${megabits}" \
        --resolution "${resolution}" \
        "${extra_streamer_args[@]}" > >(tee "${wifi_log}") 2>&1 &
else
    "${streamer_bin}" \
        "${link_args[@]}" \
        --runtime "${control_file}" \
        --fps "${fps}" \
        --mbps "${megabits}" \
        --resolution "${resolution}" \
        "${extra_streamer_args[@]}" &
fi
streamer_pid=$!

# USB writes the control file after the headset handshake. Wi-Fi writes it at once,
# so for Wi-Fi also wait (up to 3 minutes) until the Quest has connected.
wait_ticks=300
[[ -n ${wifi_log} ]] && wait_ticks=1800
for _ in {1..${wait_ticks}}; do
    if [[ -s ${control_file} ]] &&
       { [[ -z ${wifi_log} ]] || grep -q 'ALVR control accepted' "${wifi_log}" 2>/dev/null; }; then
        break
    fi
    if ! kill -0 ${streamer_pid} 2>/dev/null; then
        wait ${streamer_pid}
        print -u2 "FAIL: the streamer exited before its runtime control socket was ready."
        exit 1
    fi
    sleep 0.1
done
if [[ ! -s ${control_file} ]] ||
   { [[ -n ${wifi_log} ]] && ! grep -q 'ALVR control accepted' "${wifi_log}" 2>/dev/null; }; then
    print -u2 "FAIL: timed out waiting for ALVR StreamReady/runtime control file."
    exit 1
fi

control_windows="Z:${control_file//\//\\}"
print ""
print "Launching Khronos hello_xr, built from the pinned official 1.1.61 source."
print "Expected: world-fixed colored cubes plus a small cube for each tracked hand."
print "Move your head and both controllers through depth, then squeeze past 90% for haptics."
print "Press the left controller menu button to request a clean OpenXR exit."
print "Ctrl-C aborts the interactive gate without printing PASS."
print ""

pushd "${probe_dir}" >/dev/null
WINEPREFIX=${wine_prefix} \
WINEARCH=win64 \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
DXMT_BASALT_IOSURFACE=1 \
BASALT_CONTROL="${control_windows}" \
    "${wine_root}/bin/wine" ./khr_hello_xr_d3d11.exe \
        --graphics D3D11 --space Local --verbose
popd >/dev/null

print ""
print "PASS: Khronos hello_xr completed a clean external-application OpenXR session."
print "VISUAL GATE: confirm fused stereo, world-fixed cubes, 6DoF hands, squeeze scaling, and haptics."
