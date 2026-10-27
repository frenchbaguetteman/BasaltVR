#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
repo_dir=${runtime_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}
toolchain_file=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake

readonly wine_version=11.10
readonly wine_archive_name=wine-devel-11.10-osx64.tar.xz
readonly wine_url=https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.10/${wine_archive_name}
readonly wine_sha256=6d0637c3526fbe7051a5f8968dbde68fbc3ac417717648b9331c46642b52173b

readonly dxmt_version=v0.80
readonly dxmt_archive_name=dxmt-v0.80-builtin.tar.gz
readonly dxmt_url=https://github.com/3Shain/dxmt/releases/download/v0.80/${dxmt_archive_name}
readonly dxmt_sha256=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d

artifact_dir=${build_dir}/dxmt/artifacts
toolchain_dir=${build_dir}/dxmt/toolchain
probe_dir=${build_dir}/dxmt/probe
wine_extract_dir=${toolchain_dir}/wine-${wine_version}
dxmt_extract_dir=${toolchain_dir}/dxmt-${dxmt_version}
wine_root=${wine_extract_dir}/Wine\ Devel.app/Contents/Resources/wine
dxmt_root=${dxmt_extract_dir}/${dxmt_version}

# Intentionally ignore ambient Wine/OpenXR settings. This prefix is disposable and
# never points at Whisky, CrossOver, or a game bottle unless explicitly overridden.
wine_prefix=${BASALT_DXMT_WINEPREFIX:-${build_dir}/dxmt/prefix-wine-${wine_version}-dxmt-${dxmt_version}}
unset WINEPREFIX WINEDLLPATH WINEDLLOVERRIDES XR_RUNTIME_JSON

cmake_bin=${CMAKE:-$(command -v cmake || true)}
curl_bin=$(command -v curl || true)
shasum_bin=$(command -v shasum || true)
tar_bin=$(command -v tar || true)

if [[ -z ${cmake_bin} || -z ${curl_bin} || -z ${shasum_bin} || -z ${tar_bin} ]]; then
    print -u2 "Missing CMake, curl, shasum, or tar. See runtime/README.md."
    exit 1
fi

if [[ $(uname -m) == arm64 ]] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
    print -u2 "Rosetta 2 is required to run the x86-64 Wine bundle."
    exit 1
fi

sha256_file() {
    "${shasum_bin}" -a 256 "$1" | awk '{print $1}'
}

download_verified() {
    local url=$1
    local destination=$2
    local expected=$3

    if [[ -f ${destination} ]]; then
        local existing
        existing=$(sha256_file "${destination}")
        if [[ ${existing} != ${expected} ]]; then
            print -u2 "FAIL: existing artifact has the wrong SHA-256: ${destination}"
            print -u2 "      expected ${expected}"
            print -u2 "      actual   ${existing}"
            exit 1
        fi
        print "Using verified ${destination:t}"
        return
    fi

    local partial=${destination}.partial.$$
    "${curl_bin}" --fail --location --progress-bar --output "${partial}" "${url}"

    local actual
    actual=$(sha256_file "${partial}")
    if [[ ${actual} != ${expected} ]]; then
        print -u2 "FAIL: downloaded artifact has the wrong SHA-256: ${destination:t}"
        print -u2 "      expected ${expected}"
        print -u2 "      actual   ${actual}"
        exit 1
    fi
    mv "${partial}" "${destination}"
}

mkdir -p "${artifact_dir}" "${toolchain_dir}" "${probe_dir}" "${wine_prefix}"

wine_archive=${artifact_dir}/${wine_archive_name}
dxmt_archive=${artifact_dir}/${dxmt_archive_name}
download_verified "${wine_url}" "${wine_archive}" "${wine_sha256}"
download_verified "${dxmt_url}" "${dxmt_archive}" "${dxmt_sha256}"

if [[ ! -x ${wine_root}/bin/wine ]]; then
    mkdir -p "${wine_extract_dir}"
    "${tar_bin}" -xJf "${wine_archive}" -C "${wine_extract_dir}"
fi
if [[ ! -f ${dxmt_root}/x86_64-windows/d3d11.dll ]]; then
    mkdir -p "${dxmt_extract_dir}"
    "${tar_bin}" -xzf "${dxmt_archive}" -C "${dxmt_extract_dir}"
fi

if [[ $(${wine_root}/bin/wine --version) != wine-${wine_version} ]]; then
    print -u2 "FAIL: extracted Wine does not report wine-${wine_version}"
    exit 1
fi

# v0.80 is the official DXMT built-in layout. Overlay only this generated Wine
# extraction; no installed app or user bottle is changed.
for dll in d3d10core.dll d3d11.dll dxgi.dll winemetal.dll; do
    cp "${dxmt_root}/x86_64-windows/${dll}" \
        "${wine_root}/lib/wine/x86_64-windows/${dll}"
done
cp "${dxmt_root}/x86_64-unix/winemetal.so" \
    "${wine_root}/lib/wine/x86_64-unix/winemetal.so"

configure_args=(
    -S "${runtime_dir}"
    -B "${build_dir}"
    -DCMAKE_BUILD_TYPE=Release
)
if [[ ! -f ${build_dir}/CMakeCache.txt ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=${toolchain_file}")
fi
"${cmake_bin}" "${configure_args[@]}"
"${cmake_bin}" --build "${build_dir}" --parallel --target \
    basalt_openxr \
    d3d11_runtime_smoke \
    d3d11_compositor_smoke \
    dxmt_shared_texture_probe \
    dxmt_fence_probe \
    dxmt_window_swapchain_probe \
    dxmt_iosurface_probe \
    dxmt_iosurface_pixel_source \
    frame_timer_probe \
    dxmt_msaa_probe \
    opencomposite_frame_timing_smoke \
    steamwebhelper_compat

# Keep the executable in a clean directory so an unrelated d3d11.dll beside the
# main build output cannot shadow the pinned DXMT installation.
cp "${build_dir}/bin/dxmt_shared_texture_probe.exe" "${probe_dir}/dxmt_shared_texture_probe.exe"
cp "${build_dir}/bin/dxmt_fence_probe.exe" "${probe_dir}/dxmt_fence_probe.exe"
cp "${build_dir}/bin/dxmt_window_swapchain_probe.exe" "${probe_dir}/dxmt_window_swapchain_probe.exe"
cp "${build_dir}/bin/dxmt_iosurface_probe.exe" "${probe_dir}/dxmt_iosurface_probe.exe"
cp "${build_dir}/bin/dxmt_iosurface_pixel_source.exe" "${probe_dir}/dxmt_iosurface_pixel_source.exe"
cp "${build_dir}/bin/d3d11_runtime_smoke.exe" "${probe_dir}/d3d11_runtime_smoke.exe"
cp "${build_dir}/bin/d3d11_compositor_smoke.exe" "${probe_dir}/d3d11_compositor_smoke.exe"
cp "${build_dir}/bin/frame_timer_probe.exe" "${probe_dir}/frame_timer_probe.exe"
cp "${build_dir}/bin/dxmt_msaa_probe.exe" "${probe_dir}/dxmt_msaa_probe.exe"

# An already-created disposable prefix may contain older generated built-ins.
# Keep its Windows view in sync with the overlay before running the probe.
system32=${wine_prefix}/drive_c/windows/system32
if [[ -d ${system32} ]]; then
    for dll in d3d10core.dll d3d11.dll dxgi.dll winemetal.dll; do
        cp "${dxmt_root}/x86_64-windows/${dll}" "${system32}/${dll}"
    done
fi

fork_overlay_active=false
cleanup() {
    if [[ -n ${control_peer_pid:-} ]]; then
        kill ${control_peer_pid} 2>/dev/null || true
    fi
    WINEPREFIX=${wine_prefix} "${wine_root}/bin/wineserver" -k >/dev/null 2>&1 || true
    # A failing fork-phase step exits under `set -e`; never leave the shared
    # Wine tree and prefix on the fork overlay.
    if [[ ${fork_overlay_active} == true ]]; then
        overlay_dxmt "${dxmt_root}/x86_64-windows" "${dxmt_root}/x86_64-unix"
        fork_overlay_active=false
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# One control-socket gate: start a native peer that publishes a control file,
# run the OpenXR smoke against it, and fail with the peer's log if either side
# fails. Usage:
#   run_control_gate <label> [--smoke <exe>] [SMOKE_ENV=value...] -- <peer command>
# The smoke defaults to d3d11_runtime_smoke.exe. The peer receives
# --control-file <path> after its own arguments.
run_control_gate() {
    local label=$1
    shift
    local smoke_exe=./d3d11_runtime_smoke.exe
    if [[ $1 == --smoke ]]; then
        smoke_exe=$2
        shift 2
    fi
    local -a smoke_env
    while [[ $1 != -- ]]; do
        smoke_env+=("$1")
        shift
    done
    shift
    local control_file=${probe_dir}/control-file.$$
    local peer_out=${probe_dir}/control-peer-out.$$
    rm -f "${control_file}" "${peer_out}"
    "$@" --control-file "${control_file}" > "${peer_out}" 2>&1 &
    control_peer_pid=$!
    for _ in {1..100}; do
        if [[ -s ${control_file} ]]; then
            break
        fi
        sleep 0.1
    done
    local smoke_status=0 peer_status=0
    env WINEPREFIX=${wine_prefix} WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
        DXMT_BASALT_IOSURFACE=1 BASALT_EXPECT_IOSURFACE=1 "${smoke_env[@]}" \
        BASALT_CONTROL="Z:${control_file//\//\\}" \
        "${wine_root}/bin/wine" "${smoke_exe}" || smoke_status=$?
    # Report the peer's side too: a smoke failure alone hides whether the
    # peer saw the handshake, frames, or teardown.
    wait ${control_peer_pid} || peer_status=$?
    control_peer_pid=
    if (( smoke_status != 0 || peer_status != 0 )); then
        print -u2 "FAIL: ${label} gate (smoke ${smoke_status}, peer ${peer_status})"
        cat "${peer_out}" >&2 || true
        exit 1
    fi
    grep '^PASS' "${peer_out}"
    rm -f "${control_file}" "${peer_out}"
}

pushd "${probe_dir}" >/dev/null
WINEPREFIX=${wine_prefix} \
WINEARCH=win64 \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
    "${wine_root}/bin/wine" ./dxmt_shared_texture_probe.exe

WINEPREFIX=${wine_prefix} \
WINEARCH=win64 \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
    "${wine_root}/bin/wine" ./dxmt_fence_probe.exe

WINEPREFIX=${wine_prefix} \
WINEARCH=win64 \
WINEDEBUG=-all \
    "${wine_root}/bin/wine" ./frame_timer_probe.exe

# Stock v0.80 rejects 8x MSAA textures on GPUs that stop at 4x (all Apple
# GPUs); the fork phase below must pass the same probe.
if WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    "${wine_root}/bin/wine" ./dxmt_msaa_probe.exe >/dev/null 2>&1; then
    print "NOTE: stock DXMT passes the 8x MSAA probe (this GPU supports 8x MSAA)"
else
    print "PASS: stock DXMT ${dxmt_version} fails the 8x MSAA probe on this GPU (expected; the fork fixes it)"
fi

# Stock DXMT must not expose the Basalt IOSurface private data.
WINEPREFIX=${wine_prefix} \
WINEARCH=win64 \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
    "${wine_root}/bin/wine" ./dxmt_iosurface_probe.exe

manifest=${build_dir}/bin/basalt_openxr.json
manifest_windows="Z:${manifest//\//\\}"
WINEPREFIX=${wine_prefix} WINEDEBUG=-all \
    "${wine_root}/bin/wine" reg.exe add \
    'HKLM\Software\Khronos\OpenXR\1' \
    /v ActiveRuntime /t REG_SZ /d "${manifest_windows}" /f
WINEPREFIX=${wine_prefix} \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
    "${wine_root}/bin/wine" ./d3d11_runtime_smoke.exe

# Headless compositor API surface: formats, limits, layer validation, FIFO
# swapchain order, repeated wait+begin, and session replacement events.
WINEPREFIX=${wine_prefix} \
WINEDEBUG=-all \
MVK_CONFIG_LOG_LEVEL=0 \
    "${wine_root}/bin/wine" ./d3d11_compositor_smoke.exe

# OpenComposite on the headless runtime: GetFrameTiming must report one present per
# frame for old SteamVR Unity plugins too (IVRCompositor_013, 168-byte struct). A zero
# there sends The Lab's Secret Shop to about 1 fps (opencomposite-patches/0005).
opencomposite_dll=${OPENCOMPOSITE_DLL:-${build_dir}/opencomposite/out/openvr_api.dll}
if [[ -f ${opencomposite_dll} ]]; then
    oc_probe_dir=${build_dir}/dxmt/opencomposite-probe
    rm -rf "${oc_probe_dir}"
    mkdir -p "${oc_probe_dir}"
    cp "${build_dir}/bin/opencomposite_frame_timing_smoke.exe" "${oc_probe_dir}/"
    cp "${opencomposite_dll}" "${oc_probe_dir}/openvr_api.dll"
    print 'initUsingVulkan=false' > "${oc_probe_dir}/opencomposite.ini"
    pushd "${oc_probe_dir}" >/dev/null
    WINEPREFIX=${wine_prefix} \
    WINEDEBUG=-all \
    MVK_CONFIG_LOG_LEVEL=0 \
        "${wine_root}/bin/wine" ./opencomposite_frame_timing_smoke.exe
    popd >/dev/null
else
    print "SKIP: OpenComposite frame-timing smoke (run runtime/scripts/build-opencomposite.zsh first)"
fi

# --- Basalt DXMT fork phase (runs when build-dxmt-fork.zsh has produced it) --
fork_install=${build_dir}/dxmt/fork-install
if [[ -f ${fork_install}/x86_64-windows/d3d11.dll && -f ${fork_install}/x86_64-unix/winemetal.so ]]; then
    overlay_dxmt() {
        local source_windows=$1
        local source_unix=$2
        for dll in d3d10core.dll d3d11.dll dxgi.dll winemetal.dll; do
            cp "${source_windows}/${dll}" "${wine_root}/lib/wine/x86_64-windows/${dll}"
            cp "${source_windows}/${dll}" "${system32:-${wine_prefix}/drive_c/windows/system32}/${dll}"
        done
        cp "${source_unix}/winemetal.so" "${wine_root}/lib/wine/x86_64-unix/winemetal.so"
    }
    # Build the production streamer before touching the Wine tree so a Swift
    # failure cannot strand the fork overlay.
    swift build --package-path "${repo_dir}/streamer" --product basalt-streamer
    streamer_bin=$(swift build --package-path "${repo_dir}/streamer" --show-bin-path)/basalt-streamer

    system32=${wine_prefix}/drive_c/windows/system32
    fork_overlay_active=true
    overlay_dxmt "${fork_install}/x86_64-windows" "${fork_install}/x86_64-unix"

    # 8x MSAA (Source 2 Auto-Fidelity): the fork falls back to the largest
    # sample count Metal supports (patch 0006); stock v0.80 fails to create
    # the targets on Apple GPUs, which left Robot Repair's eye texture empty.
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
        "${wine_root}/bin/wine" ./dxmt_msaa_probe.exe

    # Fork with the gate off must be indistinguishable from stock.
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
        "${wine_root}/bin/wine" ./dxmt_iosurface_probe.exe
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
        "${wine_root}/bin/wine" ./dxmt_shared_texture_probe.exe

    # Gate on: IOSurface-backed sharing, fences, and swapchain ID republish.
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    DXMT_BASALT_IOSURFACE=1 BASALT_EXPECT_IOSURFACE=1 \
        "${wine_root}/bin/wine" ./dxmt_iosurface_probe.exe
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    DXMT_BASALT_IOSURFACE=1 \
        "${wine_root}/bin/wine" ./dxmt_shared_texture_probe.exe
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    DXMT_BASALT_IOSURFACE=1 \
        "${wine_root}/bin/wine" ./dxmt_fence_probe.exe
    # A visible HWND swapchain exercises the Wine mac-driver bridge that the
    # headless texture/runtime probes cannot reach.
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    DXMT_BASALT_IOSURFACE=1 \
        "${wine_root}/bin/wine" ./dxmt_window_swapchain_probe.exe
    WINEPREFIX=${wine_prefix} WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    DXMT_BASALT_IOSURFACE=1 BASALT_EXPECT_IOSURFACE=1 \
        "${wine_root}/bin/wine" ./d3d11_runtime_smoke.exe

    # Cross-process zero-copy pixel proof (docs/DXMT-INTEROP.md acceptance
    # test 2): a Wine process renders a known pattern into a gated texture
    # and holds it; the native tool maps the same IOSurface and verifies it.
    cc -O2 -Wall -Wextra -framework IOSurface -framework CoreFoundation \
        -o "${probe_dir}/iosurface_readback" \
        "${runtime_dir}/tests/native/iosurface_readback.c"
    pixel_done=${probe_dir}/pixel-done.$$
    pixel_out=${probe_dir}/pixel-source-out.$$
    rm -f "${pixel_done}" "${pixel_out}"
    WINEPREFIX=${wine_prefix} WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
    DXMT_BASALT_IOSURFACE=1 BASALT_DONE_FILE="Z:${pixel_done//\//\\}" \
        "${wine_root}/bin/wine" ./dxmt_iosurface_pixel_source.exe > "${pixel_out}" &
    pixel_source_pid=$!
    for _ in {1..600}; do
        if grep -q '^BASALT_IOSURFACE_ID=' "${pixel_out}" 2>/dev/null; then
            break
        fi
        if ! kill -0 ${pixel_source_pid} 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    pixel_iosurface_id=$(grep -m1 '^BASALT_IOSURFACE_ID=' "${pixel_out}" | cut -d= -f2 | tr -d '\r' || true)
    if [[ -z ${pixel_iosurface_id} ]]; then
        print -u2 "FAIL: the Wine pixel source never published an IOSurfaceID"
        cat "${pixel_out}" >&2 || true
        exit 1
    fi
    "${probe_dir}/iosurface_readback" "${pixel_iosurface_id}"
    touch "${pixel_done}"
    if ! wait ${pixel_source_pid}; then
        print -u2 "FAIL: the Wine pixel source exited with an error"
        cat "${pixel_out}" >&2 || true
        exit 1
    fi
    rm -f "${pixel_done}" "${pixel_out}"

    # Control-socket FrameReady gate (docs/DXMT-INTEROP.md §3-4): the OpenXR
    # smoke connects to a native daemon which validates the hello/token
    # handshake, looks up every registered swapchain IOSurface, and requires
    # a fence-confirmed FrameReady plus clean teardown.
    cc -O2 -Wall -Wextra -framework IOSurface -framework CoreFoundation \
        -o "${probe_dir}/basalt_control_test_daemon" \
        "${runtime_dir}/tests/native/basalt_control_test_daemon.c"
    # The daemon negotiates 90 Hz here, so xrWaitFrame must report the
    # HELLO_ACK display period instead of the 72 Hz headless default.
    # --hand-tracking lists the hand_tracking feature in the control file, so
    # the smoke enables XR_EXT_hand_tracking and checks injected skeletons;
    # every other gate must not see the extension.
    run_control_gate "control-socket" \
        BASALT_EXPECT_HEAD_POSE=1 BASALT_EXPECT_HAND_TRACKING=1 \
        BASALT_EXPECT_VIEW_WIDTH=1152 BASALT_EXPECT_VIEW_HEIGHT=1216 \
        BASALT_EXPECT_DISPLAY_PERIOD_NS=11111111 -- \
        "${probe_dir}/basalt_control_test_daemon" \
        --expect-frames 21 --verify-clears --frame-delay-ms 25 \
        --view-width 1152 --view-height 1216 --display-period-ns 11111111 \
        --hand-tracking

    # Runtime compositor gate: OpenComposite-shaped swapchains and layers
    # (sRGB RGBA, mipmapped, oversized, flipped, blended quads, quad-only)
    # arrive as the compositor's BGRA output with the expected pixels, the
    # direct BGRA path still exports the application's own surfaces (also
    # for UE4's side-by-side typeless image with one rect per eye), and
    # wait/release follow acquisition order.
    runtime_log=${probe_dir}/runtime-log.$$
    rm -f "${runtime_log}"
    run_control_gate "runtime compositor" \
        --smoke ./d3d11_compositor_smoke.exe \
        BASALT_RUNTIME_LOG="${runtime_log}" BASALT_COMPOSITOR_LOG=1 -- \
        "${probe_dir}/basalt_control_test_daemon" \
        --expect-frames 12 --compositor-scenarios \
        --view-width 512 --view-height 512
    # BASALT_RUNTIME_LOG (a host path) receives the compositor diagnostics;
    # the periodic layer lines need BASALT_COMPOSITOR_LOG=1.
    if ! grep -q 'compositor active' "${runtime_log}" ||
        ! grep -q 'compositor frame 1: 1 layer(s), left eye draws projection\[fmt 29 view 29 96x80' \
            "${runtime_log}"; then
        print -u2 "FAIL: BASALT_RUNTIME_LOG lacks the compositor diagnostics"
        cat "${runtime_log}" >&2 2>/dev/null || true
        exit 1
    fi
    # The periodic head-pinning line; the daemon's head sample never changes
    # within a frame here, so no frame may report a newer later sample.
    if ! grep -q 'head pose pinning: 0 of [1-9][0-9]* frames since the last report' \
            "${runtime_log}"; then
        print -u2 "FAIL: BASALT_RUNTIME_LOG lacks the head pose pinning diagnostic"
        cat "${runtime_log}" >&2 2>/dev/null || true
        exit 1
    fi
    print "PASS: BASALT_RUNTIME_LOG records compositor activation, layer, and head pinning diagnostics"
    rm -f "${runtime_log}"

    # The production streamer's RuntimeLink, not just the C test daemon, must
    # complete the same handshake, swapchain registration, ordered
    # FrameConsumed acknowledgements, and H.264 encode against this runtime.
    run_control_gate "streamer RuntimeLink" -- \
        "${streamer_bin}" runtime-link-selftest --frames 21 --timeout 90

    # Leave the generated Wine tree and prefix on the pinned stock overlay.
    overlay_dxmt "${dxmt_root}/x86_64-windows" "${dxmt_root}/x86_64-unix"
    fork_overlay_active=false
    print "PASS: Basalt DXMT fork gate (IOSurface IDs, native readback, control-socket FrameReady, runtime compositor, streamer RuntimeLink)"
else
    print "NOTE: fork phase skipped; run runtime/scripts/build-dxmt-fork.zsh to enable it"
fi
popd >/dev/null

print "PASS: Wine ${wine_version} + DXMT ${dxmt_version} sharing, fence frame completion, and OpenXR D3D11 swapchains"
