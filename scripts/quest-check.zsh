#!/bin/zsh
#
# Quest status for the BasaltVR app, one "key=value" line each. Read-only.
#
#   scripts/quest-check.zsh
#
# It takes one look at `adb devices -l` (no retry) and picks the Quest the same way
# scripts/play.zsh does (quest-adb.zsh: USB wins, then the saved Wi-Fi IP). Only for that
# Quest it runs `pm list packages` and `dumpsys package` to read the ALVR version.
# Other adb devices never get a command.
#
# Keys (QuestStatus in BasaltManagerKit/PlayLibrary.swift reads them; keep both in step):
#   saved_ip=IP          the Quest IP quest-wireless.zsh saved (may be empty)
#   adb=PATH             adb, or the line is missing when adb is not installed
#   status=ok|unauthorized|none|no-adb
#   link=usb|wifi        serial=SERIAL   model=MODEL   reason=TEXT
#   alvr=PACKAGE VERSION one line per ALVR package on the chosen Quest

set -uo pipefail

readonly script_dir=${0:A:h}
source "$script_dir/quest-adb.zsh"

kv() { print -r -- "$1=${2//$'\n'/ }"; }

kv saved_ip "$(quest_saved_ip 2>/dev/null)"
if ! quest_find_adb 2>/dev/null; then
    kv status no-adb
    exit 0
fi
kv adb "$QUEST_ADB"

quest_pick_serial
case $? in
    0) kv status ok ;;
    2) kv status unauthorized ;;
    *) kv status none ;;
esac
kv link "$QUEST_LINK"
kv serial "$QUEST_SERIAL"
kv model "$QUEST_MODEL"
kv reason "$QUEST_REASON"

[[ -n $QUEST_SERIAL ]] || exit 0
packages=$(qadb shell pm list packages 2>/dev/null | tr -d '\r' \
    | sed -n 's/^package://p' | grep -E '^alvr\.client(\.stable|\.dev)?$')
for package in ${(f)packages}; do
    version=$(qadb shell dumpsys package "$package" 2>/dev/null | tr -d '\r' \
        | sed -n 's/^ *versionName=//p' | head -n 1)
    kv alvr "$package ${version:-unknown}"
done
exit 0
