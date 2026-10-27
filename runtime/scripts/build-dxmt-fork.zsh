#!/bin/zsh

# Builds the Basalt DXMT fork: upstream DXMT pinned at the MIT-licensed v0.80
# tag plus the patches in runtime/dxmt-fork/patches (IOSurface-backed shared
# textures, docs/DXMT-INTEROP.md). Produces a matched winemetal.dll/.so set in
# runtime/build/dxmt/fork-install. Everything is downloaded, verified, and
# built under the ignored runtime/build tree; no installed Wine, Whisky,
# CrossOver, or game bottle is modified.
#
# The first run builds LLVM 15.0.7 x86_64 static libraries from source
# (tens of minutes); later runs reuse them.

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
repo_dir=${runtime_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}

readonly dxmt_repo=https://github.com/3Shain/dxmt.git
readonly dxmt_tag=v0.80
readonly dxmt_commit=589adb780354b461645b29999cefaf533594ee99
readonly basalt_tag=v0.80-basalt.2

readonly llvm_repo=https://github.com/llvm/llvm-project.git
readonly llvm_tag=llvmorg-15.0.7
readonly llvm_commit=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a
readonly macos_deployment_target=14.0
readonly macos_deployment_flag="-mmacosx-version-min=${macos_deployment_target}"

# DXMT's own CI builds the official v0.80 release against this Wine build
# tree; the produced artifacts demonstrably run under the Gcenx Wine 11.10
# that test-dxmt.zsh pins.
readonly wine_tools_name=wine-v8.16-3shain.tar.gz
readonly wine_tools_url=https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
readonly wine_tools_sha256=289c7f19e270a3d3d0a6fdb07691b176c70a0795f6811e5255cba82425de4f10

patches_dir=${runtime_dir}/dxmt-fork/patches
artifact_dir=${build_dir}/dxmt/artifacts
toolchain_dir=${build_dir}/dxmt/toolchain
src_dir=${build_dir}/dxmt/src
install_dir=${build_dir}/dxmt/fork-install
wine_tools_dir=${toolchain_dir}/wine-v8.16-3shain
llvm_project_dir=${toolchain_dir}/llvm-project
llvm_build_dir=${toolchain_dir}/llvm-build
llvm_install_dir=${toolchain_dir}/llvm-darwin
llvm_deployment_stamp=${llvm_install_dir}/.basalt-macos-deployment-target

for tool in git meson ninja cmake curl shasum tar x86_64-w64-mingw32-g++; do
    if ! command -v ${tool} >/dev/null; then
        print -u2 "Missing ${tool}. See runtime/dxmt-fork/README.md."
        exit 1
    fi
done
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    print -u2 "Missing the Xcode Metal toolchain (xcrun -sdk macosx metal)."
    exit 1
fi

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
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
            exit 1
        fi
        print "Using verified ${destination:t}"
        return
    fi

    local partial=${destination}.partial.$$
    curl --fail --location --progress-bar --output "${partial}" "${url}"
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

mkdir -p "${artifact_dir}" "${toolchain_dir}"

# --- DXMT source at the pinned MIT tag, with Basalt patches committed ------

if [[ ! -d ${src_dir}/.git ]]; then
    git clone "${dxmt_repo}" "${src_dir}"
fi

# The checkout is only reusable if it was built from the exact patch files
# on disk on top of the pinned upstream commit: the hash in the tagged
# commit's message detects edited patches, and the tag's parent detects a
# patch commit left over from an older dxmt_commit pin.
patches_sha=$(cat "${patches_dir}"/*.patch | shasum -a 256 | awk '{print $1}')

if [[ $(git -C "${src_dir}" rev-parse "${basalt_tag}^{commit}" 2>/dev/null) != '' ]] &&
   git -C "${src_dir}" diff --quiet "${basalt_tag}" 2>/dev/null &&
   [[ $(git -C "${src_dir}" rev-parse HEAD) == $(git -C "${src_dir}" rev-parse "${basalt_tag}^{commit}") ]] &&
   [[ $(git -C "${src_dir}" rev-parse "${basalt_tag}^{commit}^" 2>/dev/null) == ${dxmt_commit} ]] &&
   git -C "${src_dir}" log -1 --format=%B "${basalt_tag}" | grep -q "patches-sha ${patches_sha}"; then
    print "Using existing ${basalt_tag} checkout (patches ${patches_sha[1,12]})"
else
    if ! git -C "${src_dir}" diff --quiet || ! git -C "${src_dir}" diff --cached --quiet; then
        print -u2 "FAIL: ${src_dir} has uncommitted changes; refusing to reset."
        print -u2 "      Commit or discard them (git -C ${src_dir} checkout -- .) first."
        exit 1
    fi
    git -C "${src_dir}" fetch --tags origin
    git -C "${src_dir}" checkout --quiet "${dxmt_commit}"
    if [[ $(git -C "${src_dir}" rev-parse HEAD) != ${dxmt_commit} ]]; then
        print -u2 "FAIL: DXMT checkout is not the pinned ${dxmt_tag} commit ${dxmt_commit}"
        exit 1
    fi
    git -C "${src_dir}" submodule update --init include/native/directx
    # Check every patch before applying any, so a bad set cannot leave the
    # tree half-patched and wedge later runs on the dirty-tree refusal.
    for patch in "${patches_dir}"/*.patch; do
        if ! git -C "${src_dir}" apply --check "${patch}"; then
            print -u2 "FAIL: ${patch:t} does not apply to ${dxmt_tag}; tree left untouched."
            exit 1
        fi
    done
    for patch in "${patches_dir}"/*.patch; do
        # --index stages exactly the patch's changes (including added files)
        # without sweeping up unrelated untracked build output.
        git -C "${src_dir}" apply --index "${patch}"
        print "Applied ${patch:t}"
    done
    git -C "${src_dir}" -c user.name="BasaltVR build" -c user.email="build@basaltvr.invalid" \
        commit --quiet --message "Basalt IOSurface export (${basalt_tag}) patches-sha ${patches_sha}"
    git -C "${src_dir}" tag --force "${basalt_tag}"
fi

# --- Wine build tools (winebuild, headers, import libraries) ---------------

download_verified "${wine_tools_url}" "${artifact_dir}/${wine_tools_name}" "${wine_tools_sha256}"
if [[ ! -x ${wine_tools_dir}/bin/winebuild ]]; then
    mkdir -p "${wine_tools_dir}"
    tar -xzf "${artifact_dir}/${wine_tools_name}" -C "${wine_tools_dir}"
fi

# --- LLVM 15 x86_64 static libraries (DXMT DEVELOPMENT.md recipe) -----------

if [[ ! -f ${llvm_install_dir}/lib/libLLVMCore.a ||
      ! -f ${llvm_deployment_stamp} ||
      "$(<${llvm_deployment_stamp})" != ${macos_deployment_target} ]]; then
    if [[ ! -d ${llvm_project_dir}/.git ]]; then
        git clone --depth 1 --branch "${llvm_tag}" "${llvm_repo}" "${llvm_project_dir}"
    fi
    if [[ $(git -C "${llvm_project_dir}" rev-parse HEAD) != ${llvm_commit} ]]; then
        print -u2 "FAIL: LLVM checkout is not the pinned ${llvm_tag} commit ${llvm_commit}"
        exit 1
    fi
    print "Building LLVM ${llvm_tag} x86_64 static libraries (first run only)..."
    cmake -B "${llvm_build_dir}" -S "${llvm_project_dir}/llvm" \
        -DCMAKE_INSTALL_PREFIX="${llvm_install_dir}" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${macos_deployment_target}" \
        -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
        -DLLVM_ENABLE_ASSERTIONS=On \
        -DLLVM_ENABLE_ZSTD=Off \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_BUILD_TOOLS=Off \
        -DLLVM_INCLUDE_TESTS=Off \
        -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" \
        -DPACKAGE_VENDOR="DXMT" \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
        -G Ninja
    ninja -C "${llvm_build_dir}"
    ninja -C "${llvm_build_dir}" install
    print -r -- "${macos_deployment_target}" > "${llvm_deployment_stamp}"
fi

# --- DXMT cross build (mirrors DXMT CI's gcc release job) -------------------

reconfigure=()
if [[ -d ${src_dir}/build ]]; then
    reconfigure=(--reconfigure)
fi
MACOSX_DEPLOYMENT_TARGET="${macos_deployment_target}" \
meson setup --cross-file "${src_dir}/build-win64.txt" \
    -Dbuild.c_args="${macos_deployment_flag}" \
    -Dbuild.cpp_args="${macos_deployment_flag}" \
    -Dbuild.c_link_args="${macos_deployment_flag}" \
    -Dbuild.cpp_link_args="${macos_deployment_flag}" \
    -Dnative_llvm_path="${llvm_install_dir}" \
    -Dwine_install_path="${wine_tools_dir}" \
    "${src_dir}/build" "${src_dir}" \
    --buildtype release --prefix "${install_dir}" --strip \
    "${reconfigure[@]}"
meson compile -C "${src_dir}/build"
rm -rf "${install_dir}"
meson install -C "${src_dir}/build"

print ""
print "Basalt DXMT fork ${basalt_tag} installed:"
for artifact in "${install_dir}"/x86_64-windows/*.dll "${install_dir}"/x86_64-unix/*.so; do
    print "  $(sha256_file "${artifact}")  ${artifact#${install_dir}/}"
done
print "PASS: built ${basalt_tag} from ${dxmt_tag} (${dxmt_commit[1,12]}) + $(ls "${patches_dir}" | wc -l | tr -d ' ') patches"
