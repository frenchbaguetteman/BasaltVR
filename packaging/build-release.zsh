#!/bin/zsh
set -euo pipefail

readonly repo_dir="${0:A:h:h}"
readonly version="${1:-0.1.0}"
readonly build_number="${BASALT_BUILD_NUMBER:-1}"
readonly app_name="BasaltVR.app"
readonly archive_name="BasaltVR-${version}-macos-arm64.zip"
readonly dist_dir="${repo_dir}/dist"
readonly release_dir="${repo_dir}/release"
readonly app_dir="${dist_dir}/${app_name}"
readonly contents_dir="${app_dir}/Contents"
readonly macos_dir="${contents_dir}/MacOS"
readonly resources_dir="${contents_dir}/Resources"
readonly support_dir="${resources_dir}/BasaltVR"
runtime_source_dir="${BASALT_RUNTIME_BUILD_DIR:-${repo_dir}/runtime/build}"
readonly dxmt_source_dir="${BASALT_DXMT_BUILD_DIR:-${repo_dir}/runtime/build/dxmt/fork-install}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    print -u2 "error: version must look like 0.1.0 or 0.1.0-preview.1"
    exit 2
fi

readonly release_notes="${repo_dir}/docs/releases/v${version}.md"
if [[ ! -f "$release_notes" ]]; then
    print -u2 "error: release notes are missing: ${release_notes}"
    exit 1
fi
if ! grep -Fq "## ${version} " "${repo_dir}/CHANGELOG.md"; then
    print -u2 "error: CHANGELOG.md has no release heading for ${version}"
    exit 1
fi

for tool in swift cmake ditto codesign iconutil sips plutil shasum perl unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print -u2 "error: required tool is unavailable: $tool"
        exit 1
    fi
done

if [[ -f "${runtime_source_dir}/CMakeCache.txt" ]]; then
    runtime_build_type=$(sed -n 's/^CMAKE_BUILD_TYPE:STRING=//p' \
        "${runtime_source_dir}/CMakeCache.txt")
    if [[ "$runtime_build_type" != Release ]]; then
        print -u2 "error: ${runtime_source_dir} is a ${runtime_build_type:-unset} build;" \
            "run 'make runtime-build' (Release) or set BASALT_RUNTIME_BUILD_DIR"
        exit 1
    fi
    # Never package a DLL that predates the sources: a stale control-protocol
    # version connects headlessly (black headset) against the fresh streamer.
    # Incremental, so this is a no-op when the tree is current.
    cmake --build "$runtime_source_dir" --parallel
elif [[ ! -f "${runtime_source_dir}/bin/basalt_openxr.dll" ||
        ! -f "${runtime_source_dir}/bin/basalt_openxr.json" ]]; then
    readonly generated_runtime_dir="${repo_dir}/runtime/build-release"
    cmake \
        -S "${repo_dir}/runtime" \
        -B "$generated_runtime_dir" \
        -DCMAKE_TOOLCHAIN_FILE="${repo_dir}/runtime/cmake/toolchains/mingw-x86_64.cmake" \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$generated_runtime_dir" --parallel
    runtime_source_dir="$generated_runtime_dir"
fi

swift build \
    -c release \
    --arch arm64 \
    --package-path "${repo_dir}/streamer"

readonly swift_release_dir="$(
    swift build -c release --arch arm64 --package-path "${repo_dir}/streamer" --show-bin-path
)"

for executable in BasaltVR basalt-streamer basaltctl; do
    if [[ ! -x "${swift_release_dir}/${executable}" ]]; then
        print -u2 "error: release executable is missing: ${swift_release_dir}/${executable}"
        exit 1
    fi
done

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$support_dir" "$release_dir"

cp "${swift_release_dir}/BasaltVR" "${macos_dir}/BasaltVR-bin"
cp "${swift_release_dir}/basalt-streamer" "${macos_dir}/basalt-streamer"
cp "${swift_release_dir}/basaltctl" "${macos_dir}/basaltctl"
cp "${repo_dir}/packaging/BasaltVRLauncher" "${macos_dir}/BasaltVRLauncher"
chmod 755 "${macos_dir}/BasaltVR-bin" "${macos_dir}/basalt-streamer" \
    "${macos_dir}/basaltctl" "${macos_dir}/BasaltVRLauncher"

cp "${repo_dir}/packaging/Info.plist" "${contents_dir}/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${version}" \
    -c "Set :CFBundleVersion ${build_number}" \
    "${contents_dir}/Info.plist"

readonly iconset="${dist_dir}/BasaltVR.iconset"
readonly icon_source="${repo_dir}/streamer/Resources/BasaltVRIcon.png"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" \
        --out "${iconset}/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$icon_source" \
        --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "${resources_dir}/BasaltVR.icns"
rm -rf "$iconset"

mkdir -p "${support_dir}/runtime/build/bin" "${support_dir}/docs"
cp "${runtime_source_dir}/bin/basalt_openxr.dll" \
    "${support_dir}/runtime/build/bin/basalt_openxr.dll"
cp "${runtime_source_dir}/bin/basalt_openxr.json" \
    "${support_dir}/runtime/build/bin/basalt_openxr.json"
for artifact in loader_smoke.exe steamwebhelper_compat.exe; do
    if [[ -f "${runtime_source_dir}/bin/${artifact}" ]]; then
        cp "${runtime_source_dir}/bin/${artifact}" \
            "${support_dir}/runtime/build/bin/${artifact}"
    fi
done

dxmt_included=false
# DXMT is optional, but a partial set (say, winemetal.so without its DLLs)
# would be advertised as included and fail only at game launch.
if [[ -d "${dxmt_source_dir}" ]]; then
    BASALT_DXMT_BUILD_DIR="${dxmt_source_dir}" \
        "${repo_dir}/runtime/scripts/verify-dxmt-artifacts.zsh"
    mkdir -p "${support_dir}/runtime/build/dxmt/fork-install/x86_64-unix" \
        "${support_dir}/runtime/build/dxmt/fork-install/x86_64-windows"
    cp "${dxmt_source_dir}/x86_64-unix/winemetal.so" \
        "${support_dir}/runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so"
    for dll in d3d10core.dll d3d11.dll dxgi.dll winemetal.dll; do
        cp "${dxmt_source_dir}/x86_64-windows/${dll}" \
            "${support_dir}/runtime/build/dxmt/fork-install/x86_64-windows/${dll}"
    done
    dxmt_included=true
fi

ditto "${repo_dir}/docs" "${support_dir}/docs"
cp "${repo_dir}/README.md" "${support_dir}/README.md"
cp "${repo_dir}/CHANGELOG.md" "${support_dir}/CHANGELOG.md"
cp "${repo_dir}/ROADMAP.md" "${support_dir}/ROADMAP.md"
cp "${repo_dir}/SECURITY.md" "${support_dir}/SECURITY.md"
cp "${repo_dir}/SUPPORT.md" "${support_dir}/SUPPORT.md"
cp "${repo_dir}/LICENSE" "${support_dir}/LICENSE"
cp "${repo_dir}/THIRD_PARTY_NOTICES.md" "${support_dir}/THIRD_PARTY_NOTICES.md"
ditto "${repo_dir}/LICENSES" "${support_dir}/LICENSES"

print -r -- \
    "{\"format\":1,\"version\":\"${version}\",\"architecture\":\"arm64\",\"dxmtIncluded\":${dxmt_included},\"wineIncluded\":false}" \
    > "${support_dir}/BasaltVR.support.json"

# Release-mode compilers may retain absolute build paths in diagnostics or embedded shader
# metadata. Replace the checkout prefix in copied artifacts with an equal-length neutral value so
# local usernames never leak into published archives. Equal-length replacement preserves binary
# offsets and happens before signing.
public_build_prefix="/BasaltVR/build"
if (( ${#public_build_prefix} > ${#repo_dir} )); then
    print -u2 "error: checkout path is too short for release path sanitization"
    exit 1
fi
while (( ${#public_build_prefix} < ${#repo_dir} )); do
    public_build_prefix+="_"
done
find "$app_dir" -type f -print0 | while IFS= read -r -d '' artifact; do
    BASALT_PRIVATE_BUILD_PREFIX="$repo_dir" \
    BASALT_PUBLIC_BUILD_PREFIX="$public_build_prefix" \
        perl -0pi -e \
        's/\Q$ENV{BASALT_PRIVATE_BUILD_PREFIX}\E/$ENV{BASALT_PUBLIC_BUILD_PREFIX}/g' \
        "$artifact"
done

codesign --force --sign - --timestamp=none "${macos_dir}/basalt-streamer"
codesign --force --sign - --timestamp=none "${macos_dir}/basaltctl"
codesign --force --sign - --timestamp=none "${macos_dir}/BasaltVR-bin"
codesign --force --deep --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
plutil -lint "${contents_dir}/Info.plist"

# Verify the bundled CLI can discover its packaged support files without relying on
# the source checkout, current working directory, or the GUI launcher's environment.
(
    cd /private/tmp
    env -u BASALT_REPO_ROOT "${macos_dir}/basaltctl" engines >/dev/null
)

rm -f "${release_dir}/${archive_name}" "${release_dir}/${archive_name}.sha256"
ditto -c -k --norsrc --keepParent "$app_dir" \
    "${release_dir}/${archive_name}"
unzip -tq "${release_dir}/${archive_name}"
(
    cd "$release_dir"
    shasum -a 256 "$archive_name" > "${archive_name}.sha256"
)

print "Built ${release_dir}/${archive_name}"
print "Checksum ${release_dir}/${archive_name}.sha256"
print "DXMT artifacts included: ${dxmt_included}"
print "Wine redistributed: false"
