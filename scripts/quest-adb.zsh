#!/bin/zsh
#
# Shared adb helpers for the Quest scripts. Source this file; do not run it.
#
#   source "$script_dir/quest-adb.zsh"
#   quest_find_adb || exit 1        # sets QUEST_ADB and puts its folder on PATH
#   quest_pick_serial_retry         # sets QUEST_SERIAL, QUEST_LINK (usb or wifi), QUEST_REASON
#   qadb shell getprop ro.product.model   # adb -s "$QUEST_SERIAL" ...
#
# One Quest can show up twice in `adb devices` (USB serial and ip:5555) after
# `adb tcpip 5555`. A bare `adb shell` then fails with "more than one device/emulator".
# So every script picks ONE serial and always passes `-s`. Rule: a USB device wins;
# otherwise a Wi-Fi device (ip:port or adb-... wireless debugging). When there are
# several of the same kind, the saved Quest IP wins (Wi-Fi), then the lowest serial.
# The result does not depend on the order adb prints the devices.
#
# Only a Quest can be chosen. Emulators and other Android devices (phones, tablets)
# are ignored, and they never get a command: the Quest check reads the model from
# the `adb devices -l` text. This file never runs `adb kill-server` or `start-server`.
# quest_pick_serial_retry looks again for ~5 s when the listing may be transient.

QUEST_DATA_DIR=${BASALT_DATA_DIR:-$HOME/Library/Application Support/BasaltVR}
QUEST_IP_FILE=$QUEST_DATA_DIR/quest-ip

QUEST_ADB=""
QUEST_SERIAL=""
QUEST_LINK=""
QUEST_MODEL=""
QUEST_REASON=""       # one line: which device was chosen (or not) and why
QUEST_CONCLUSIVE=0    # 1 when the last listing needs no retry

quest_find_adb() {
    QUEST_ADB=$(command -v adb || true)
    if [[ -z $QUEST_ADB ]]; then
        local candidate
        for candidate in "$HOME/Library/Android/sdk/platform-tools/adb" /opt/homebrew/bin/adb /usr/local/bin/adb; do
            [[ -x $candidate ]] && { QUEST_ADB=$candidate; break; }
        done
    fi
    if [[ -z $QUEST_ADB ]]; then
        print -u2 "I cannot find adb. Run: brew install android-platform-tools"
        return 1
    fi
    # The streamer looks for adb on PATH, so make sure its folder is there.
    export PATH=${QUEST_ADB:h}:$PATH
    return 0
}

# Reads `adb devices -l` text on stdin. Prints one line per device:
#   pick <usb|wifi> <serial> <model>   the best Quest (printed last)
#   skip <serial> <reason>             listed, but ignored (emulator, not a Quest)
#   wait <serial> <state>              not ready yet (offline, unauthorized, ...)
# Only state "device" counts. A Quest has model Quest_*/Oculus_* or a Quest product
# name such as eureka. A USB Quest wins over a Wi-Fi Quest.
# Argument 1: the saved Quest IP (may be empty).
_quest_choose() {
    awk -v saved="$1" '
        function field(name,    i, n) {
            n = length(name) + 1
            for (i = 3; i <= NF; i++) if (substr($i, 1, n) == name ":") return substr($i, n + 1)
            return ""
        }
        function is_quest(model, product, dev,    names) {
            names = "^(vegas|monterey|hollywood|seacliff|eureka|panther|corvette)$"
            if (tolower(model) ~ /^(quest|oculus)/) return 1
            if (tolower(product) ~ names || tolower(dev) ~ names) return 1
            return 0
        }
        NR == 1 && /^List of devices/ { next }
        NF < 2 { next }
        $1 ~ /^\*/ { next }
        {
            serial = $1; state = $2
            if (state != "device") {
                if (serial !~ /^emulator-/) print "wait " serial " " state
                next
            }
            if (serial ~ /^emulator-/) { print "skip " serial " emulator"; next }
            model = field("model")
            if (!is_quest(model, field("product"), field("device"))) {
                print "skip " serial " not a Quest (model " (model == "" ? "unknown" : model) ")"
                next
            }
            if ($0 ~ / usb:/) {
                if (usb == "" || serial < usb) { usb = serial; usbmodel = model }
            } else if (serial ~ /^adb-/ || serial ~ /:[0-9]+$/) {
                ip = serial; sub(/:[0-9]+$/, "", ip)
                if (saved != "" && ip == saved) { savedhit = serial; savedmodel = model }
                if (wifi == "" || serial < wifi) { wifi = serial; wifimodel = model }
            } else {
                print "skip " serial " unknown transport"
            }
        }
        END {
            if (usb != "") print "pick usb " usb " " usbmodel
            else if (savedhit != "") print "pick wifi " savedhit " " savedmodel
            else if (wifi != "") print "pick wifi " wifi " " wifimodel
        }'
}

# One look at `adb devices -l`.
# Returns 0 and sets QUEST_SERIAL / QUEST_LINK / QUEST_MODEL / QUEST_REASON when a Quest is usable.
# Returns 2 when a device waits for the "Allow debugging" tap and nothing else works.
# Returns 1 when no usable Quest is listed.
# QUEST_CONCLUSIVE=1 means a retry would not change the answer: a USB Quest, or a
# Wi-Fi Quest with nothing half-ready in the list. Anything else may be a transient
# adb state (server just restarted, Quest just plugged in or re-authorizing).
quest_pick_serial() {
    QUEST_SERIAL=""
    QUEST_LINK=""
    QUEST_MODEL=""
    QUEST_REASON=""
    QUEST_CONCLUSIVE=0
    local devices saved_ip="" choice line w ignored="" adb_rc=0
    local -a skipped waiting
    devices=$("$QUEST_ADB" devices -l 2>/dev/null) || adb_rc=$?
    [[ -r $QUEST_IP_FILE ]] && saved_ip=$(<"$QUEST_IP_FILE")
    choice=$(print -r -- "$devices" | _quest_choose "$saved_ip")
    for line in ${(f)choice}; do
        case $line in
            skip\ *) skipped+=("${line#skip }") ;;
            wait\ *) waiting+=("${line#wait }") ;;
            pick\ *) QUEST_LINK=${${line#pick }%% *}
                     QUEST_SERIAL=${${line#pick * }%% *}
                     QUEST_MODEL=${line#pick * * *} ;;
        esac
    done
    (( ${#skipped} )) && ignored=" Ignored: ${(j:, :)skipped}."
    if [[ -n $QUEST_SERIAL ]]; then
        if [[ $QUEST_LINK == usb ]]; then
            QUEST_REASON="USB Quest $QUEST_SERIAL (${QUEST_MODEL:-model unknown}); a USB Quest always wins.$ignored"
            QUEST_CONCLUSIVE=1
        else
            QUEST_REASON="Wi-Fi Quest $QUEST_SERIAL (${QUEST_MODEL:-model unknown}); no USB Quest is listed.$ignored"
            (( adb_rc == 0 && ${#waiting} == 0 )) && QUEST_CONCLUSIVE=1
        fi
        return 0
    fi
    if (( ${#waiting} )); then
        QUEST_REASON="No usable Quest. Not ready: ${(j:, :)waiting}.$ignored"
        for w in $waiting; do
            [[ $w == *\ unauthorized ]] && return 2
        done
        return 1
    fi
    if (( adb_rc )); then
        QUEST_REASON="No usable Quest. adb devices failed (exit $adb_rc).$ignored"
    else
        QUEST_REASON="No usable Quest is listed.$ignored"
    fi
    return 1
}

# Like quest_pick_serial, but looks again while the answer may be transient.
# It stops at once for a USB Quest. Without one it keeps looking for about 5 s
# (BASALT_PICK_TRIES looks, BASALT_PICK_DELAY seconds apart; default 6 x 1 s)
# before it gives up. So a restarting adb server, or a Quest that is still
# enumerating, does not push the caller to Wi-Fi. It only runs `adb devices`;
# it never restarts or kills adb. The result is the last look.
quest_pick_serial_retry() {
    local tries=${BASALT_PICK_TRIES:-6} delay=${BASALT_PICK_DELAY:-1} n rc=1
    for (( n = 1; n <= tries; n++ )); do
        quest_pick_serial; rc=$?
        (( QUEST_CONCLUSIVE )) && return $rc
        (( n < tries )) && sleep "$delay"
    done
    return $rc
}

# adb for the chosen Quest. Always passes -s.
qadb() { "$QUEST_ADB" -s "$QUEST_SERIAL" "$@"; }

# Prints the Quest IP that scripts/quest-wireless.zsh saved. Returns 1 when there is none.
quest_saved_ip() {
    local ip=""
    [[ -r $QUEST_IP_FILE ]] && ip=$(<"$QUEST_IP_FILE")
    [[ $ip == <->.<->.<->.<-> ]] || return 1
    print -r -- "$ip"
}

# Connect adb over Wi-Fi to IP:PORT (default port BASALT_QUEST_PORT or 5555) and check
# that adb reports state "device". It touches only that address.
quest_connect_ip() {
    local ip=$1 port=${2:-${BASALT_QUEST_PORT:-5555}} out state
    # adb connect waits a long time for a dead address. Check the address first.
    if ! ping -c 1 -t 3 "$ip" >/dev/null 2>&1; then
        print -u2 "The Quest at $ip does not answer. Is it on and on the same Wi-Fi as this Mac?"
        return 1
    fi
    out=$("$QUEST_ADB" connect "$ip:$port" 2>&1)
    state=$("$QUEST_ADB" -s "$ip:$port" get-state 2>/dev/null)
    if [[ $state == device ]]; then
        return 0
    fi
    print -u2 "adb said: ${out:-nothing}"
    return 1
}

# Restart the ALVR app on the chosen Quest: force-stop, wait, launch, wait for it to
# come up. Touches only alvr.client.stable. Waits: BASALT_ALVR_STOP_WAIT (2 s) and
# BASALT_ALVR_START_WAIT (6 s).
quest_restart_alvr() {
    local pkg=alvr.client.stable
    [[ -n $QUEST_SERIAL ]] || return 1
    qadb shell am force-stop $pkg >/dev/null 2>&1
    sleep "${BASALT_ALVR_STOP_WAIT:-2}"
    qadb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep "${BASALT_ALVR_START_WAIT:-6}"
    return 0
}
