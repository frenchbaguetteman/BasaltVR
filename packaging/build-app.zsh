#!/bin/zsh
#
# Build BasaltVR.app for this Mac (`make app`).
#
#   packaging/build-app.zsh                 build build/BasaltVR.app, then copy it to
#                                           ~/Applications/BasaltVR.app
#   packaging/build-app.zsh --no-install    build only
#   packaging/build-app.zsh --output DIR    build DIR/BasaltVR.app instead
#
# The app is linked to this checkout (Info.plist key BasaltRepoRoot). It runs this
# checkout's scripts/play.zsh with streamer/.build/release/basalt-streamer and basaltctl,
# and the bottle gets this checkout's OpenXR runtime and Steam web helper shim: exactly
# what Terminal uses, so there is one copy of everything and nothing to drift or fight.
# Rebuild the checkout (make build) and the app uses the new tools at once.
#
# Only the app's own binary is in the bundle. It is ad-hoc signed with the hardened
# runtime and the audio-input entitlement (packaging/BasaltVR.entitlements), so macOS
# can ask for Microphone access in BasaltVR's name: BlackHole game audio needs it.
# A rebuilt app has a new ad-hoc signature, so macOS may ask once more.
#
# A linked git worktree is never installed to ~/Applications (it would point the app
# at the worktree's tools and shim). Set BASALT_APP_INSTALL_FROM_WORKTREE=1 to override.

set -euo pipefail

readonly repo_dir=${0:A:h:h}
output_dir=$repo_dir/build
install_dir=$HOME/Applications
install=1

while (( $# )); do
    case $1 in
        --output) shift; output_dir=${1:?--output needs a folder} ;;
        --no-install) install=0 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

readonly app=$output_dir/BasaltVR.app
readonly contents=$app/Contents
readonly entitlements=$repo_dir/packaging/BasaltVR.entitlements

for tool in swift codesign iconutil sips plutil ditto; do
    command -v "$tool" >/dev/null 2>&1 || { print -u2 "error: required tool is unavailable: $tool"; exit 1; }
done

print "Building the release tools (streamer, basaltctl, app)..."
swift build -c release --arch arm64 --package-path "$repo_dir/streamer"
readonly bin_dir=$(swift build -c release --arch arm64 --package-path "$repo_dir/streamer" --show-bin-path)
for executable in BasaltVR basalt-streamer basaltctl; do
    if [[ ! -x $bin_dir/$executable ]]; then
        print -u2 "error: release executable is missing: $bin_dir/$executable"
        exit 1
    fi
done
# play.zsh and the app run the tools from streamer/.build/release.
if [[ ! -x $repo_dir/streamer/.build/release/basalt-streamer ]]; then
    print -u2 "error: $repo_dir/streamer/.build/release/basalt-streamer is missing after the build"
    exit 1
fi

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/BasaltVR" "$contents/MacOS/BasaltVR"
chmod 755 "$contents/MacOS/BasaltVR"
cp "$repo_dir/packaging/Info.plist" "$contents/Info.plist"
plutil -insert BasaltRepoRoot -string "$repo_dir" "$contents/Info.plist"

iconset=$(mktemp -d "${TMPDIR:-/tmp}/BasaltVR.XXXXXX")/BasaltVR.iconset
mkdir -p "$iconset"
icon_source=$repo_dir/streamer/Resources/BasaltVRIcon.png
for size in 16 32 128 256 512; do
    sips -z $size $size "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $(( size * 2 )) $(( size * 2 )) "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/BasaltVR.icns"
rm -rf "${iconset:h}"

codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$entitlements" "$app"

# Checks: valid signature, hardened runtime, the entitlement, the usage text.
codesign --verify --strict --verbose=1 "$app"
plutil -lint "$contents/Info.plist" >/dev/null
signed=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
if [[ $signed != *com.apple.security.device.audio-input* ]]; then
    print -u2 "error: the signature lacks com.apple.security.device.audio-input"
    exit 1
fi
# Into a variable first: `grep -q` closing the pipe early would fail under pipefail.
details=$(codesign -dv "$app" 2>&1)
if [[ $details != *flags=*runtime* ]]; then
    print -u2 "error: the signature lacks the hardened runtime"
    exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$contents/Info.plist" >/dev/null; then
    print -u2 "error: Info.plist lacks NSMicrophoneUsageDescription"
    exit 1
fi
print "PASS: $app is signed (ad-hoc, hardened runtime, audio-input) and linked to $repo_dir"

(( install )) || exit 0
if [[ $(git -C "$repo_dir" rev-parse --git-dir 2>/dev/null) != $(git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null) ]] \
    && [[ ${BASALT_APP_INSTALL_FROM_WORKTREE:-0} != 1 ]]; then
    print "Not installed: this is a git worktree. Build the app from the main checkout,"
    print "so the app uses the main checkout's tools and Steam web helper shim."
    exit 0
fi
mkdir -p "$install_dir"
rm -rf "$install_dir/BasaltVR.app"
ditto "$app" "$install_dir/BasaltVR.app"
codesign --verify --strict "$install_dir/BasaltVR.app"
print "Installed $install_dir/BasaltVR.app. Open it from Finder, Launchpad, or Spotlight."
