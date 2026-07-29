#!/bin/zsh

set -euo pipefail

readonly script_dir=${0:A:h}
readonly runtime_dir=${script_dir:h}
readonly install_dir=${BASALT_DXMT_BUILD_DIR:-${runtime_dir}/build/dxmt/fork-install}
readonly deployment_target=14.0

for tool in file otool shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print -u2 "FAIL: required artifact-inspection tool is unavailable: $tool"
        exit 1
    fi
done

windows_artifacts=(
    d3d10core.dll
    d3d11.dll
    dxgi.dll
    winemetal.dll
)

for name in "${windows_artifacts[@]}"; do
    artifact="${install_dir}/x86_64-windows/${name}"
    if [[ ! -s "$artifact" ]]; then
        print -u2 "FAIL: required DXMT artifact is missing or empty: $artifact"
        exit 1
    fi
    description=$(file "$artifact")
    if [[ "$description" != *"PE32+ executable (DLL)"*"x86-64"* ]]; then
        print -u2 "FAIL: ${name} is not a PE32+ x86-64 DLL"
        print -u2 "      $description"
        exit 1
    fi
done

unix_artifact="${install_dir}/x86_64-unix/winemetal.so"
if [[ ! -s "$unix_artifact" ]]; then
    print -u2 "FAIL: required DXMT artifact is missing or empty: $unix_artifact"
    exit 1
fi
unix_description=$(file "$unix_artifact")
if [[ "$unix_description" != *"Mach-O 64-bit"*"x86_64"* ]]; then
    print -u2 "FAIL: winemetal.so is not a Mach-O x86-64 library"
    print -u2 "      $unix_description"
    exit 1
fi

minimum_macos=$(otool -l "$unix_artifact" | awk '
    /LC_BUILD_VERSION/ { command = "build"; next }
    /LC_VERSION_MIN_MACOSX/ { command = "legacy"; next }
    command == "build" && $1 == "minos" { print $2; exit }
    command == "legacy" && $1 == "version" { print $2; exit }
')
if [[ "$minimum_macos" != "$deployment_target" ]]; then
    print -u2 "FAIL: winemetal.so targets macOS ${minimum_macos:-unknown}; expected ${deployment_target}"
    exit 1
fi

print "Verified Basalt DXMT artifacts:"
for artifact in \
    "${install_dir}"/x86_64-windows/*.dll \
    "$unix_artifact"; do
    shasum -a 256 "$artifact"
done
print "PASS: PE/Mach-O architectures and macOS ${deployment_target} deployment target"
