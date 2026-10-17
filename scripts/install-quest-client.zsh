#!/bin/zsh
#
# Install the official ALVR v20.14.1 client on the connected Quest (USB, or adb over Wi-Fi).
#
#   scripts/install-quest-client.zsh
#
# The APK was downloaded from https://github.com/alvr-org/ALVR/releases/tag/v20.14.1
# (asset alvr_client_android.apk) and its SHA-256 matches the digest GitHub shows for
# that asset. This script checks the SHA-256 again before it installs.
# If a different ALVR version is on the Quest, it asks (y/N) before it removes it.
#
# Environment (optional): ALVR_APK=/path/to/alvr_client_android.apk

set -uo pipefail

readonly apk=${ALVR_APK:-$HOME/Downloads/alvr-v20.14.1/alvr_client_android.apk}
readonly expected_sha=be68feeb02665e3d69f1cdbcabf38ea4d15c42868a7ec6b5e698dbefee4e4e36
readonly expected_package=alvr.client.stable
readonly expected_version=20.14.1

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ ! -f $apk ]]; then
    print -u2 "I cannot find the ALVR APK: $apk"
    print -u2 "Download it from https://github.com/alvr-org/ALVR/releases/tag/v20.14.1 (alvr_client_android.apk)."
    exit 1
fi

# Copy the APK to a private folder and check the copy. We install the checked copy,
# so the file cannot change between the check and the install.
stage=$(mktemp -d "${TMPDIR:-/tmp}/alvr-install.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT
cp "$apk" "$stage/alvr_client_android.apk" || exit 1
actual_sha=$(sha_of "$stage/alvr_client_android.apk")
if [[ $actual_sha != $expected_sha ]]; then
    print -u2 "The APK is not the file I expect. I will not install it."
    print -u2 "  expected: $expected_sha"
    print -u2 "  found:    $actual_sha"
    exit 1
fi
print "APK checked: SHA-256 matches."

script_dir=${0:A:h}
source "$script_dir/quest-adb.zsh"
quest_find_adb || exit 1
adb=$QUEST_ADB

# One serial, always passed with -s. A Quest with adb over Wi-Fi shows up twice;
# the USB one wins, and the Wi-Fi one is fine when there is no cable.
quest_pick_serial
case $? in
    0) ;;
    2)
        print -u2 "The Quest asks for permission. Put it on and tap Allow for USB debugging. Then run this command again."
        exit 1
        ;;
    *)
        print -u2 "I cannot see the Quest. Turn it on and plug it in with the USB cable (or run scripts/quest-wireless.zsh), then run this command again."
        exit 1
        ;;
esac
serial=$QUEST_SERIAL
adbq() { "$adb" -s "$serial" "$@"; }

# Look for ALVR packages already on the Quest.
installed=$(adbq shell pm list packages 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | grep -E '^alvr\.client(\.stable|\.dev)?$' || true)
mismatch=()
for package in ${(f)installed}; do
    version=$(adbq shell dumpsys package "$package" 2>/dev/null | tr -d '\r' | sed -n 's/^ *versionName=//p' | head -n 1)
    if [[ $package == $expected_package && $version == $expected_version ]]; then
        print "ALVR $expected_version is already on the Quest. Nothing to do."
        exit 0
    fi
    mismatch+=("$package ${version:-unknown version}")
done

if (( ${#mismatch} > 0 )); then
    print "Another ALVR is on the Quest:"
    for entry in $mismatch; do print "  $entry"; done
    print -n "Remove it and install ALVR $expected_version? [y/N] "
    answer=""
    read -r answer || answer=""
    if [[ $answer != [yY] && $answer != [yY][eE][sS] ]]; then
        print "No change made."
        exit 1
    fi
    for entry in $mismatch; do
        package=${entry%% *}
        print "Removing $package..."
        if ! adbq uninstall "$package" >/dev/null; then
            print -u2 "I could not remove $package."
            exit 1
        fi
    done
fi

print "Installing ALVR $expected_version..."
if adbq install -r "$stage/alvr_client_android.apk"; then
    print "Done. On the Quest, open ALVR once (Library, Unknown Sources) and accept its permissions."
else
    print -u2 "The install failed. See the message above."
    exit 1
fi
