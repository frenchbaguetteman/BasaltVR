#!/bin/zsh

# Builds OpenComposite (OpenVR -> OpenXR) from source as a 64-bit Windows
# openvr_api.dll for Basalt's D3D11 path. The source is the Charmillionaire
# fork of the upstream `openxr` branch, pinned to an exact commit, plus the
# patches in runtime/openvr-proxy/opencomposite-patches. Everything is cloned
# and built under the ignored runtime/build tree with the Homebrew MinGW-w64
# toolchain. No prebuilt OpenComposite binary is downloaded.
#
# OpenComposite is GPL-3.0. Basalt does not redistribute the result; users build
# it locally and install it with `basaltctl opencomposite install`.
#
# Output: runtime/build/opencomposite/out/openvr_api.dll

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}

# Upstream: https://gitlab.com/znixian/OpenOVR (branch openxr, cff07db). This
# fork adds OpenVR 2.15.6 interfaces (IVRSystem_026, IVRCompositor_029,
# IVRInput_011, IVROverlay_028, IVRApplications_008) and answers the
# IVRIPCResourceManagerClient probe instead of aborting; current Half-Life: Alyx
# builds need these. See docs/OPENCOMPOSITE.md.
readonly oc_repo=https://github.com/Charmillionaire/OpenComposite.git
readonly oc_commit=339509b9caf534fa2ced71dc71331ec3c9c3a1a6
readonly basalt_tag=basalt-patched

patches_dir=${runtime_dir}/openvr-proxy/opencomposite-patches
exports_file=${runtime_dir}/openvr-proxy/opencomposite-exports.txt
toolchain_file=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake
oc_dir=${build_dir}/opencomposite
src_dir=${oc_dir}/src
oc_build_dir=${oc_dir}/build
out_dir=${oc_dir}/out

for tool in git cmake python3 shasum x86_64-w64-mingw32-g++ x86_64-w64-mingw32-objdump; do
    if ! command -v ${tool} >/dev/null; then
        print -u2 "Missing ${tool}. Install the toolchain with: brew install mingw-w64 cmake ninja"
        exit 1
    fi
done
objdump_bin=$(command -v x86_64-w64-mingw32-objdump)

patches=(${patches_dir}/*.patch(N))
patches_sha=$(cat /dev/null ${patches} | shasum -a 256 | awk '{print $1}')

fresh_clone=0
if [[ ! -d ${src_dir}/.git ]]; then
    mkdir -p "${oc_dir}"
    git clone --no-checkout "${oc_repo}" "${src_dir}"
    fresh_clone=1
fi

if [[ $(git -C "${src_dir}" rev-parse -q --verify "${basalt_tag}^{commit}" 2>/dev/null) != '' ]] &&
   [[ $(git -C "${src_dir}" rev-parse HEAD) == $(git -C "${src_dir}" rev-parse "${basalt_tag}^{commit}") ]] &&
   [[ $(git -C "${src_dir}" rev-parse "${basalt_tag}^") == ${oc_commit} ]] &&
   git -C "${src_dir}" diff --quiet HEAD &&
   git -C "${src_dir}" log -1 --format=%B "${basalt_tag}" | grep -q "patches-sha ${patches_sha}"; then
    print "OpenComposite ${oc_commit} with current patches already checked out"
else
    if (( ! fresh_clone )) &&
       { ! git -C "${src_dir}" diff --quiet || ! git -C "${src_dir}" diff --cached --quiet; }; then
        print -u2 "FAIL: ${src_dir} has local changes."
        print -u2 "      Commit or discard them (git -C ${src_dir} checkout -- .) first."
        exit 1
    fi
    if ! git -C "${src_dir}" cat-file -e "${oc_commit}^{commit}" 2>/dev/null; then
        git -C "${src_dir}" fetch origin
    fi
    git -C "${src_dir}" checkout --quiet --detach "${oc_commit}"
    if [[ $(git -C "${src_dir}" rev-parse HEAD) != ${oc_commit} ]]; then
        print -u2 "FAIL: OpenComposite checkout is not ${oc_commit}"
        exit 1
    fi
    # The superproject pins both submodules by commit. libunwind is only used for
    # Linux backtraces and stays uninitialised.
    git -C "${src_dir}" submodule update --init libs/openxr-sdk libs/glm
    for patch in ${patches}; do
        if ! git -C "${src_dir}" apply --check "${patch}"; then
            print -u2 "FAIL: ${patch:t} does not apply to OpenComposite ${oc_commit}"
            exit 1
        fi
        git -C "${src_dir}" apply --index "${patch}"
        print "Applied ${patch:t}"
    done
    git -C "${src_dir}" -c user.name="BasaltVR build" -c user.email="build@basaltvr.invalid" \
        commit --quiet --allow-empty -m "Basalt patches" -m "patches-sha ${patches_sha}"
    git -C "${src_dir}" tag --force "${basalt_tag}" >/dev/null
fi
print "OpenComposite source: ${oc_repo} @ ${oc_commit}"
git -C "${src_dir}" submodule status libs/openxr-sdk libs/glm

generator=()
if command -v ninja >/dev/null; then
    generator=(-G Ninja)
fi
configure_args=(
    -S "${src_dir}"
    -B "${oc_build_dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}"
    -DPython_EXECUTABLE="$(command -v python3)"
    # A game prefix has no MinGW runtime DLLs. -s drops ~20 MB of symbols.
    "-DCMAKE_SHARED_LINKER_FLAGS=-static -static-libgcc -static-libstdc++ -s"
    -DOC_VERSION="basalt-${oc_commit[1,12]}"
)
if [[ ! -f ${oc_build_dir}/CMakeCache.txt ]]; then
    configure_args+=(${generator})
fi
cmake "${configure_args[@]}"
cmake --build "${oc_build_dir}" --target OCOVR --parallel

dll=${oc_build_dir}/bin/vrclient_x64.dll
if [[ $(file -b "${dll}") != *"PE32+ executable"*"DLL"*"x86-64"* ]]; then
    print -u2 "FAIL: ${dll} is not a PE32+ x86-64 DLL: $(file -b "${dll}")"
    exit 1
fi

export_names=$("${objdump_bin}" -p "${dll}" | awk '
    /\[Ordinal\/Name Pointer\] Table/ { in_exports = 1; next }
    in_exports && NF == 0 { in_exports = 0 }
    in_exports && /\+base/ { print $NF }
' | LC_ALL=C sort)
expected_names=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*$' "${exports_file}" | LC_ALL=C sort)
for required in VR_InitInternal2 VR_GetGenericInterface VR_ShutdownInternal VR_IsRuntimeInstalled; do
    if ! print -r -- "${export_names}" | grep -qx "${required}"; then
        print -u2 "FAIL: OpenComposite does not export ${required}"
        exit 1
    fi
done
if [[ ${export_names} != ${expected_names} ]]; then
    print -u2 "FAIL: OpenComposite exports differ from ${exports_file}; update the list (the proxy forwards exactly it):"
    diff <(print -r -- "${expected_names}") <(print -r -- "${export_names}") >&2 || true
    exit 1
fi

# Patch 0004: MSVC-built games call struct-returning methods (GetEyeToHeadTransform,
# GetProjectionMatrix, ...) with 'this' first and the return pointer second; MinGW does the
# reverse. Without the patch the first such call overwrites OpenComposite's vtable (seen in
# The Lab as a crash right after "OpenVR initialized!").
if ! grep -q 'GetEyeToHeadTransform(vr::HmdMatrix34_t \*_ocRet, vr::EVREye eEye) override' \
        "${oc_build_dir}/generated/GVRSystem.gen.h" 2>/dev/null; then
    print -u2 "FAIL: generated OpenComposite stubs do not use the MSVC aggregate-return ABI (patch 0004)"
    exit 1
fi

imports=$("${objdump_bin}" -p "${dll}" | awk '/DLL Name:/ { print tolower($3) }' | LC_ALL=C sort -u)
for runtime_dll in libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll; do
    if print -r -- "${imports}" | grep -qx "${runtime_dll}"; then
        print -u2 "FAIL: OpenComposite imports ${runtime_dll}; it must link the MinGW runtime statically"
        exit 1
    fi
done

mkdir -p "${out_dir}"
cp "${dll}" "${out_dir}/openvr_api.dll"
print "Imports: ${(j:, :)${(f)imports}}"
print "Exports: ${(j:, :)${(f)export_names}}"
print "SHA-256: $(shasum -a 256 "${out_dir}/openvr_api.dll" | awk '{print $1}')"
print "PASS: built ${out_dir}/openvr_api.dll"
