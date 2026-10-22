#!/bin/zsh

# Builds the Basalt openvr_api.dll proxy (runtime/openvr-proxy) and checks it
# under the pinned Wine 11.10:
#   1. against a fake OpenComposite DLL with the same exports, that forwarded
#      calls reach it and that VRControlPanel returns what its
#      VR_GetGenericInterface("IVRControlPanel_006") returns;
#   2. against the real OpenComposite from build-opencomposite.zsh, that every
#      export resolves through the proxy, VR_IsRuntimeInstalled works, and the
#      Half-Life: Alyx opencomposite.ini is accepted. No headset is needed.
#
# Usage: test-openvr-proxy.zsh [--fake-only]
# Environment: WINE overrides the Wine binary; BUILD_DIR the build tree.

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}
toolchain_file=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake
proxy_build_dir=${build_dir}/openvr-proxy
wine_prefix=${BASALT_OPENVR_PROXY_WINEPREFIX:-${proxy_build_dir}/wineprefix}
opencomposite_dll=${OPENCOMPOSITE_DLL:-${build_dir}/opencomposite/out/openvr_api.dll}
readonly run_timeout=120

fake_only=0
for argument in "$@"; do
    case ${argument} in
        --fake-only) fake_only=1 ;;
        *) print -u2 "usage: ${0:t} [--fake-only]"; exit 2 ;;
    esac
done

# test-dxmt.zsh extracts the pinned Gcenx Wine 11.10 under runtime/build. A
# linked worktree has its own ignored build tree, so also look in the main
# checkout's; it is only executed, never written.
wine_relative=dxmt/toolchain/wine-11.10/Wine\ Devel.app/Contents/Resources/wine/bin/wine
wine_bin=${WINE:-}
if [[ -z ${wine_bin} ]]; then
    wine_bin=${build_dir}/${wine_relative}
    if [[ ! -x ${wine_bin} ]]; then
        common_dir=$(git -C "${runtime_dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
        if [[ -n ${common_dir} && -x ${common_dir:h}/runtime/build/${wine_relative} ]]; then
            wine_bin=${common_dir:h}/runtime/build/${wine_relative}
        fi
    fi
fi
for tool in cmake x86_64-w64-mingw32-g++ x86_64-w64-mingw32-objdump; do
    if ! command -v ${tool} >/dev/null; then
        print -u2 "Missing ${tool}. Install it with: brew install mingw-w64 cmake"
        exit 1
    fi
done
if [[ ! -x ${wine_bin} ]]; then
    print -u2 "Missing the pinned Wine 11.10. Run runtime/scripts/test-dxmt.zsh once or set WINE."
    exit 1
fi
if [[ $("${wine_bin}" --version) != wine-11.10* ]]; then
    print -u2 "FAIL: ${wine_bin} is not Wine 11.10"
    exit 1
fi
wineserver_bin=${wine_bin:h}/wineserver
objdump_bin=$(command -v x86_64-w64-mingw32-objdump)

configure_args=(-S "${runtime_dir}/openvr-proxy" -B "${proxy_build_dir}" -DCMAKE_BUILD_TYPE=Release)
if [[ ! -f ${proxy_build_dir}/CMakeCache.txt ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=${toolchain_file}")
    if command -v ninja >/dev/null; then
        configure_args+=(-G Ninja)
    fi
fi
cmake "${configure_args[@]}"
cmake --build "${proxy_build_dir}" --parallel

bin_dir=${proxy_build_dir}/bin
proxy_dll=${bin_dir}/openvr_api.dll
fake_dll=${bin_dir}/fake/openvr_api_opencomposite.dll
smoke_exe=${bin_dir}/openvr_proxy_smoke.exe

dll_exports() {
    "${objdump_bin}" -p "$1" | awk '
        /\[Ordinal\/Name Pointer\] Table/ { in_exports = 1; next }
        in_exports && NF == 0 { in_exports = 0 }
        in_exports && /\+base/ { print $NF }
    ' | LC_ALL=C sort
}

dll_imports() {
    "${objdump_bin}" -p "$1" | awk '/DLL Name:/ { print tolower($3) }' | LC_ALL=C sort -u
}

for binary in "${proxy_dll}" "${fake_dll}"; do
    if [[ $(file -b "${binary}") != *"PE32+ executable"*"DLL"*"x86-64"* ]]; then
        print -u2 "FAIL: ${binary} is not a PE32+ x86-64 DLL"
        exit 1
    fi
done
for binary in "${proxy_dll}" "${fake_dll}" "${smoke_exe}"; do
    for runtime_dll in libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll; do
        if dll_imports "${binary}" | grep -qx "${runtime_dll}"; then
            print -u2 "FAIL: ${binary:t} imports ${runtime_dll}"
            exit 1
        fi
    done
done

opencomposite_names=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*$' "${runtime_dir}/openvr-proxy/opencomposite-exports.txt" | LC_ALL=C sort)
own_names=$(print -l LiquidVR VRControlPanel VRHeadsetView VRPaths VRVirtualDisplay VR_GetRuntimePath)
expected_proxy_names=$(print -r -- "${opencomposite_names}"$'\n'"${own_names}" | LC_ALL=C sort)
if [[ $(dll_exports "${proxy_dll}") != ${expected_proxy_names} ]]; then
    print -u2 "FAIL: proxy exports differ from the OpenComposite list plus the proxy's own exports"
    diff <(print -r -- "${expected_proxy_names}") <(dll_exports "${proxy_dll}") >&2 || true
    exit 1
fi
forwarders=$("${objdump_bin}" -p "${proxy_dll}" | grep -c 'openvr_api_opencomposite\.' || true)
if (( forwarders != ${#${(f)opencomposite_names}} )); then
    print -u2 "FAIL: expected ${#${(f)opencomposite_names}} forwarders to openvr_api_opencomposite, found ${forwarders}"
    exit 1
fi
print "ok: proxy exports ${#${(f)expected_proxy_names}} names, ${forwarders} forwarded to openvr_api_opencomposite.dll"

mkdir -p "${wine_prefix}"
cleanup() {
    WINEPREFIX=${wine_prefix} "${wineserver_bin}" -k >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Runs the smoke test in `stage` with a deadline: an OpenComposite abort shows a
# message box that would otherwise wait forever.
run_smoke() {
    local stage=$1 mode=$2 exit_code=0 waited=0 pid
    pushd "${stage}" >/dev/null
    WINEPREFIX=${wine_prefix} WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0 \
        "${wine_bin}" ./openvr_proxy_smoke.exe "${mode}" &
    pid=$!
    while kill -0 ${pid} 2>/dev/null; do
        if (( waited >= run_timeout )); then
            print -u2 "FAIL: openvr_proxy_smoke.exe ${mode} did not finish within ${run_timeout}s"
            WINEPREFIX=${wine_prefix} "${wineserver_bin}" -k >/dev/null 2>&1 || true
            popd >/dev/null
            return 1
        fi
        sleep 1
        (( waited += 1 ))
    done
    wait ${pid} || exit_code=$?
    popd >/dev/null
    return ${exit_code}
}

# Half-Life: Alyx keeps hlvr.exe and openvr_api.dll in game/bin/win64, so the
# smoke test runs from the directory that holds the proxy.
fake_stage=${proxy_build_dir}/stage-fake
rm -rf "${fake_stage}"
mkdir -p "${fake_stage}"
cp "${proxy_dll}" "${smoke_exe}" "${fake_stage}/"
cp "${fake_dll}" "${fake_stage}/openvr_api_opencomposite.dll"
run_smoke "${fake_stage}" fake

if (( fake_only )); then
    print "PASS: openvr proxy (fake OpenComposite only)"
    exit 0
fi

if [[ ! -f ${opencomposite_dll} ]]; then
    print -u2 "Missing ${opencomposite_dll}. Run runtime/scripts/build-opencomposite.zsh or pass --fake-only."
    exit 1
fi
real_stage=${proxy_build_dir}/stage-opencomposite
rm -rf "${real_stage}"
mkdir -p "${real_stage}"
cp "${proxy_dll}" "${smoke_exe}" "${real_stage}/"
cp "${opencomposite_dll}" "${real_stage}/openvr_api_opencomposite.dll"
# Matches OpenCompositeConfiguration.alyx in BasaltBottleKit.
cat > "${real_stage}/opencomposite.ini" <<'EOF'
; Managed by BasaltVR. OpenComposite remains a separately built GPLv3 artifact.
initUsingVulkan=false
invertUsingShaders=true
EOF
oc_logs=(${wine_prefix}/drive_c/users/*/AppData/Local/OpenComposite/logs/opencomposite.log(N))
rm -f ${oc_logs}
run_smoke "${real_stage}" opencomposite

oc_logs=(${wine_prefix}/drive_c/users/*/AppData/Local/OpenComposite/logs/opencomposite.log(N))
if (( ${#oc_logs} != 1 )); then
    print -u2 "FAIL: OpenComposite wrote no log in the test prefix"
    exit 1
fi
for expected in \
    'Setting config param initUsingVulkan to false' \
    'Setting config param invertUsingShaders to true'; do
    if ! grep -q "${expected}" "${oc_logs[1]}"; then
        print -u2 "FAIL: OpenComposite log lacks '${expected}':"
        cat "${oc_logs[1]}" >&2
        exit 1
    fi
done
print "ok: OpenComposite accepted the Half-Life: Alyx opencomposite.ini"

print "PASS: openvr proxy with fake and real OpenComposite under Wine 11.10"
