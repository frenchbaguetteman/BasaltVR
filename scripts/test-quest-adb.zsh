#!/bin/zsh
#
# Offline test of the Quest serial choice and scripts/quest-wireless.zsh.
# It puts a fake `adb` first on PATH, so no headset is touched.
#
#   scripts/test-quest-adb.zsh

set -uo pipefail

readonly script_dir=${0:A:h}
work=$(mktemp -d "${TMPDIR:-/tmp}/quest-adb-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/data"

# Fake adb. FAKE_DEVICES holds the text that `adb devices -l` prints.
# Every call is appended to $FAKE_LOG. A call that needs a device but has no -s
# fails like the real adb does when two devices are listed.
cat >"$work/bin/adb" <<'FAKE'
#!/bin/zsh
print -r -- "adb $*" >>"$FAKE_LOG"
if [[ $1 == devices ]]; then
    # FAKE_FIRST_N calls print FAKE_FIRST_DEVICES instead (a flaky adb server);
    # FAKE_FIRST_FAIL=1 makes those calls exit 1 as well.
    n=$(( $(cat "$FAKE_LOG.n" 2>/dev/null || print 0) + 1 ))
    print $n >"$FAKE_LOG.n"
    print "List of devices attached"
    if (( n <= ${FAKE_FIRST_N:-0} )); then
        [[ -n ${FAKE_FIRST_DEVICES:-} ]] && print -r -- "$FAKE_FIRST_DEVICES"
        print
        (( ${FAKE_FIRST_FAIL:-0} )) && exit 1
        exit 0
    fi
    [[ -n ${FAKE_DEVICES:-} ]] && print -r -- "$FAKE_DEVICES"
    print
    exit 0
fi
if [[ $1 == connect ]]; then print "connected to $2"; exit 0; fi
if [[ $1 != -s ]]; then
    if (( $(print -r -- "${FAKE_DEVICES:-}" | grep -c .) > 1 )); then
        print -u2 "adb: more than one device/emulator"
        exit 1
    fi
fi
[[ $1 == -s ]] && shift 2
case $1 in
    get-state) print device ;;
    tcpip) print "restarting in TCP mode port: ${2:-5555}" ;;
    shell)
        shift
        if [[ $1 == ip ]]; then
            print "    inet ${FAKE_QUEST_IP:-127.0.0.1}/24 brd 127.0.0.255 scope global wlan0"
        fi
        if [[ $1 == pm ]]; then print "package:alvr.client.stable"; fi
        if [[ $1 == dumpsys ]]; then print "    versionName=${FAKE_ALVR_VERSION:-20.14.1}"; fi
        ;;
    logcat)
        # A long-running log: remember the pid so the test can check it was stopped.
        print $$ >"$FAKE_LOG.logcat_pid"
        # It runs until killed (like the real one), and has "logcat -v threadtime -T" in its command.
        print "fake logcat line"
        if [[ -n ${FAKE_LOGCAT_BYTES:-} ]]; then
            while :; do head -c 65536 /dev/zero | tr '\0' x || exit 0; sleep 0.01; done
        fi
        trap 'kill $sp 2>/dev/null; exit 0' TERM
        sleep 300 & sp=$!
        wait
        ;;
esac
exit 0
FAKE
chmod +x "$work/bin/adb"

export PATH="$work/bin:$PATH"
export FAKE_LOG="$work/calls.log"
export BASALT_DATA_DIR="$work/data"
export BASALT_PICK_DELAY=0   # no real waiting in the retry loop
: >"$FAKE_LOG"

source "$script_dir/quest-adb.zsh"
quest_find_adb

failures=0
expect() {
    local name=$1 want=$2 got=$3
    if [[ $want == "$got" ]]; then
        print "PASS: $name"
    else
        print -u2 "FAIL: $name: wanted '$want', got '$got'"
        failures=$((failures + 1))
    fi
}

usb_line='QUEST3SERIAL01         device usb:1-1 product:eureka model:Quest_3 device:eureka transport_id:2'
tcp_line='192.168.1.42:5555      device product:eureka model:Quest_3 device:eureka transport_id:3'

pick() {
    FAKE_DEVICES=$1 quest_pick_serial
    print -r -- "rc=$? link=$QUEST_LINK serial=$QUEST_SERIAL"
}

expect "USB and Wi-Fi: USB wins" "rc=0 link=usb serial=QUEST3SERIAL01" "$(pick "$usb_line"$'\n'"$tcp_line")"
expect "Wi-Fi listed first: USB still wins" "rc=0 link=usb serial=QUEST3SERIAL01" "$(pick "$tcp_line"$'\n'"$usb_line")"
expect "only USB" "rc=0 link=usb serial=QUEST3SERIAL01" "$(pick "$usb_line")"
expect "only Wi-Fi" "rc=0 link=wifi serial=192.168.1.42:5555" "$(pick "$tcp_line")"
expect "no devices" "rc=1 link= serial=" "$(pick "")"
expect "unauthorized only" "rc=2 link= serial=" "$(pick 'QUEST3SERIAL01 unauthorized usb:1-1 transport_id:2')"
expect "offline Wi-Fi is not usable" "rc=1 link= serial=" "$(pick '192.168.1.42:5555 offline transport_id:3')"
expect "emulator ignored" "rc=0 link=wifi serial=192.168.1.42:5555" "$(pick 'emulator-5554 device product:sdk transport_id:1'$'\n'"$tcp_line")"
expect "two USB devices: lowest serial, any order" "rc=0 link=usb serial=AAA" \
    "$(pick 'BBB device usb:1-2 product:eureka model:Quest_3 transport_id:2'$'\n''AAA device usb:1-1 product:eureka model:Quest_3 transport_id:3')"
print -r -- "192.168.1.50" >"$QUEST_IP_FILE"
expect "two Wi-Fi devices: saved IP wins" "rc=0 link=wifi serial=192.168.1.50:5555" \
    "$(pick '10.0.0.2:5555 device model:Quest_3 transport_id:2'$'\n''192.168.1.50:5555 device model:Quest_3 transport_id:3')"
rm -f "$QUEST_IP_FILE"
expect "two Wi-Fi devices, no saved IP: lowest serial" "rc=0 link=wifi serial=10.0.0.2:5555" \
    "$(pick '192.168.1.50:5555 device model:Quest_3 transport_id:3'$'\n''10.0.0.2:5555 device model:Quest_3 transport_id:2')"

emu_line='emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1'
phone_line='R5CT1234ABC          device usb:1-3 product:dm1q model:SM_S911B device:dm1q transport_id:4'

# USB Quest selection must ignore unrelated emulators.
expect "USB Quest + emulator: USB Quest wins" "rc=0 link=usb serial=QUEST3SERIAL01" "$(pick "$emu_line"$'\n'"$usb_line")"
expect "emulator listed after USB Quest" "rc=0 link=usb serial=QUEST3SERIAL01" "$(pick "$usb_line"$'\n'"$emu_line")"
expect "USB Quest + other phone: Quest wins" "rc=0 link=usb serial=QUEST3SERIAL01" "$(pick "$phone_line"$'\n'"$usb_line")"
expect "USB Quest + Wi-Fi Quest + emulator + phone" "rc=0 link=usb serial=QUEST3SERIAL01" \
    "$(pick "$emu_line"$'\n'"$tcp_line"$'\n'"$phone_line"$'\n'"$usb_line")"
expect "emulator only: no Quest" "rc=1 link= serial=" "$(pick "$emu_line")"
expect "other phone only: no Quest" "rc=1 link= serial=" "$(pick "$phone_line")"
expect "emulator + phone + Wi-Fi Quest: Wi-Fi Quest" "rc=0 link=wifi serial=192.168.1.42:5555" \
    "$(pick "$emu_line"$'\n'"$phone_line"$'\n'"$tcp_line")"
expect "Quest by product name only (eureka)" "rc=0 link=usb serial=Z1" \
    "$(pick 'Z1 device usb:1-1 product:eureka device:eureka transport_id:2')"
expect "Quest 2 (hollywood) is accepted" "rc=0 link=usb serial=Z2" \
    "$(pick 'Z2 device usb:1-1 product:hollywood model:Quest_2 device:hollywood transport_id:2')"
expect "daemon start noise on stdout is ignored" "rc=0 link=usb serial=QUEST3SERIAL01" \
    "$(pick '* daemon started successfully'$'\n'"$usb_line")"

# The reason line says which device was chosen and what was ignored.
FAKE_DEVICES="$emu_line"$'\n'"$phone_line"$'\n'"$usb_line" quest_pick_serial
expect "reason names the USB Quest" "0" "$([[ $QUEST_REASON == 'USB Quest QUEST3SERIAL01 (Quest_3);'* ]]; print $?)"
expect "reason names the emulator" "0" "$([[ $QUEST_REASON == *'emulator-5554 emulator'* ]]; print $?)"
expect "reason names the phone" "0" "$([[ $QUEST_REASON == *'R5CT1234ABC not a Quest (model SM_S911B)'* ]]; print $?)"

# Retry: a flaky first `adb devices` (server restarting) must not send the caller to Wi-Fi.
retry_pick() {
    : >"$FAKE_LOG"; rm -f "$FAKE_LOG.n"
    quest_pick_serial_retry
    print -r -- "rc=$? link=$QUEST_LINK serial=$QUEST_SERIAL calls=$(grep -c 'adb devices' "$FAKE_LOG")"
}
export FAKE_DEVICES="$emu_line"$'\n'"$usb_line"
FAKE_FIRST_N=1 FAKE_FIRST_DEVICES="$emu_line" expect "flaky first call (only emulator): USB Quest on try 2" \
    "rc=0 link=usb serial=QUEST3SERIAL01 calls=2" "$(FAKE_FIRST_N=1 FAKE_FIRST_DEVICES="$emu_line" retry_pick)"
expect "flaky first call (empty list): USB Quest on try 2" \
    "rc=0 link=usb serial=QUEST3SERIAL01 calls=2" "$(FAKE_FIRST_N=1 FAKE_FIRST_DEVICES="" retry_pick)"
expect "flaky first call (adb exits 1): USB Quest on try 2" \
    "rc=0 link=usb serial=QUEST3SERIAL01 calls=2" "$(FAKE_FIRST_N=1 FAKE_FIRST_FAIL=1 FAKE_FIRST_DEVICES="" retry_pick)"
expect "first call: Quest offline, then ready" \
    "rc=0 link=usb serial=QUEST3SERIAL01 calls=3" "$(FAKE_FIRST_N=2 FAKE_FIRST_DEVICES='QUEST3SERIAL01 offline usb:1-1 transport_id:2' retry_pick)"
expect "first call: Quest unauthorized, then ready" \
    "rc=0 link=usb serial=QUEST3SERIAL01 calls=2" "$(FAKE_FIRST_N=1 FAKE_FIRST_DEVICES='QUEST3SERIAL01 unauthorized usb:1-1 transport_id:2' retry_pick)"
expect "first call: only Wi-Fi Quest while USB is offline: retry finds USB" \
    "rc=0 link=usb serial=QUEST3SERIAL01 calls=2" \
    "$(FAKE_FIRST_N=1 FAKE_FIRST_DEVICES="$tcp_line"$'\n''QUEST3SERIAL01 offline usb:1-1 transport_id:2' retry_pick)"
expect "USB Quest on first call: no retry" "rc=0 link=usb serial=QUEST3SERIAL01 calls=1" "$(retry_pick)"
expect "Wi-Fi Quest only and nothing half-ready: no retry" "rc=0 link=wifi serial=192.168.1.42:5555 calls=1" \
    "$(FAKE_DEVICES="$emu_line"$'\n'"$tcp_line" retry_pick)"
expect "emulator only: retries 6 times, then no Quest" "rc=1 link= serial= calls=6" "$(FAKE_DEVICES="$emu_line" retry_pick)"
expect "nothing listed: retries 6 times, then no Quest" "rc=1 link= serial= calls=6" "$(FAKE_DEVICES="" retry_pick)"
expect "unauthorized for good: rc 2 after 6 looks" "rc=2 link= serial= calls=6" \
    "$(FAKE_DEVICES='QUEST3SERIAL01 unauthorized usb:1-1 transport_id:2' retry_pick)"
expect "emulator only, then Wi-Fi Quest appears" "rc=0 link=wifi serial=192.168.1.42:5555 calls=2" \
    "$(FAKE_FIRST_N=1 FAKE_FIRST_DEVICES="$emu_line" FAKE_DEVICES="$emu_line"$'\n'"$tcp_line" retry_pick)"

# Never touch other devices: pick and retry only run `adb devices`.
FAKE_DEVICES="$emu_line"$'\n'"$phone_line"$'\n'"$usb_line" retry_pick >/dev/null
expect "pick runs only 'adb devices -l'" "0" "$(grep -vqx 'adb devices -l' "$FAKE_LOG"; print $((1 - $?)))"
expect "no kill-server / start-server / -s emulator / -s phone anywhere" "1" \
    "$(grep -qE 'kill-server|start-server|emulator-|R5CT1234ABC' "$FAKE_LOG"; print $?)"
unset FAKE_DEVICES
rm -f "$FAKE_LOG.n"

# qadb always passes -s, so the fake adb never sees an ambiguous call.
: >"$FAKE_LOG"
export FAKE_DEVICES="$usb_line"$'\n'"$tcp_line"
quest_pick_serial
qadb shell pm list packages >/dev/null
expect "qadb passes -s with the USB serial" "adb -s QUEST3SERIAL01 shell pm list packages" "$(tail -n 1 "$FAKE_LOG")"

# quest-wireless.zsh: cable in -> tcpip, connect, save the IP (127.0.0.1 answers ping).
: >"$FAKE_LOG"
export FAKE_DEVICES="$usb_line" FAKE_QUEST_IP=127.0.0.1
"$script_dir/quest-wireless.zsh" >"$work/out.txt" 2>&1
expect "quest-wireless with cable exits 0" "0" "$?"
expect "quest-wireless saves the IP" "127.0.0.1" "$(cat "$QUEST_IP_FILE" 2>/dev/null)"
grep -q 'adb -s QUEST3SERIAL01 tcpip 5555' "$FAKE_LOG"
expect "quest-wireless ran tcpip with -s" "0" "$?"
grep -q 'adb connect 127.0.0.1:5555' "$FAKE_LOG"
expect "quest-wireless connected to the IP" "0" "$?"

# No cable, saved IP -> reconnect only (no tcpip).
: >"$FAKE_LOG"
export FAKE_DEVICES=""
"$script_dir/quest-wireless.zsh" >"$work/out.txt" 2>&1
expect "quest-wireless reconnect exits 0" "0" "$?"
grep -q tcpip "$FAKE_LOG"
expect "quest-wireless reconnect does not run tcpip" "1" "$?"

# No cable, no saved IP -> clear failure.
rm -f "$QUEST_IP_FILE"
"$script_dir/quest-wireless.zsh" >"$work/out.txt" 2>&1
expect "quest-wireless without IP exits 1" "1" "$?"
grep -q 'Plug the Quest in' "$work/out.txt"
expect "quest-wireless without IP says to plug in" "0" "$?"

"$script_dir/quest-wireless.zsh" status >/dev/null 2>&1
expect "quest-wireless status exits 0" "0" "$?"

# ---------------------------------------------------------------------------
# scripts/play.zsh with a fake adb, a fake streamer and a fake game. The scripts are
# copied next to a fake steam.zsh so nothing real is touched (no Steam, no Wine, no
# headset, no real streamer, no real /tmp/basalt-control).
# ---------------------------------------------------------------------------
mkdir -p "$work/scripts" "$work/fakebin"
cp "$script_dir/play.zsh" "$script_dir/quest-adb.zsh" "$script_dir/game-processes.zsh" \
    "$script_dir/log-retention.zsh" "$work/scripts/"
print -r -- $'#!/bin/zsh\nexit 0' >"$work/scripts/steam.zsh"
# Fake pgrep: no other streamer is running. The Steam web helper is "up". The bottle's
# wineserver is up only when FAKE_BOTTLE_UP=1.
cat >"$work/bin/pgrep" <<'FAKE'
#!/bin/zsh
for a in "$@"; do
    [[ $a == *steamwebhelper* ]] && exit 0
    [[ $a == *wineserver* && ${FAKE_BOTTLE_UP:-0} == 1 ]] && exit 0
done
exit 1
FAKE
# Fake ps: prints $FAKE_PS_FILE for the first FAKE_PS_LIVE_CALLS calls, then nothing.
cat >"$work/bin/ps" <<'FAKE'
#!/bin/zsh
n=$(( $(cat "$FAKE_PS_COUNT" 2>/dev/null || print 0) + 1 ))
print $n >"$FAKE_PS_COUNT"
(( n <= ${FAKE_PS_LIVE_CALLS:-1000000} )) && [[ -r $FAKE_PS_FILE ]] && cat "$FAKE_PS_FILE"
exit 0
FAKE
chmod +x "$work/bin/ps"
cat >"$work/fakebin/basalt-streamer" <<'FAKE'
#!/bin/zsh
[[ $1 == --list-audio-devices ]] && exit 0
print -r -- "$*" >>"$FAKE_STREAMER_LOG"
runs=$(wc -l <"$FAKE_STREAMER_LOG")
if (( runs <= ${FAKE_STREAMER_FAIL_N:-0} )); then
    for n in 1 2 3; do print "ALVR USB handshake attempt $n failed; retrying..."; done
    print -u2 "error: Could not start wired ALVR session: ALVR initial client-status stage failed: ALVR client closed the control connection"
    exit 1
fi
args=("$@")
print "9999 token 2304 1216" >"${args[$args[(i)--runtime]+1]}"
print "ALVR control accepted"
trap 'exit 0' TERM
while :; do sleep 0.2; done
FAKE
cat >"$work/fakebin/basaltctl" <<'FAKE'
#!/bin/zsh
case $1 in
    profile)
        if [[ $2 == show && $3 == the-lab ]]; then
            print -r -- '{"bottleName":"fake","source":"steam","executable":"C:\\Program Files (x86)\\Steam\\steamapps\\common\\The Lab\\TheLab\\win64\\TheLab.exe","arguments":["-popupwindow"]}'
        elif [[ $2 == show ]]; then print '{"bottleName":"fake","source":"native","executable":"game.exe","arguments":[]}'; else print fake; fi ;;
    run)
        # The launched program: ps lists it while it runs. After a second it exits. For
        # the-lab it has started Robot Repair by then (FAKE_CHILD_DELAY seconds after
        # it exited, if set).
        if [[ $2 == the-lab ]]; then
            lab='/fake/engine/bin/wine64-preloader C:\Program Files (x86)\Steam\steamapps\common\The Lab\'
            print -r -- "${lab}TheLab\win64\TheLab.exe -popupwindow" >"$FAKE_PS_FILE"
            sleep 1
            if [[ -n ${FAKE_CHILD_DELAY:-} ]]; then
                ( sleep $FAKE_CHILD_DELAY
                  print -r -- "${lab}RobotRepair\bin\win64\vr.exe -noassert -retail -autofidelity +map vr_aperture_main" >>"$FAKE_PS_FILE" ) &
            fi
        else
            sleep 1
        fi ;;
esac
exit 0
FAKE
chmod +x "$work/scripts/steam.zsh" "$work/bin/pgrep" "$work/fakebin/basalt-streamer" "$work/fakebin/basaltctl"

run_play() {
    (( ${KEEP_HOME:-0} )) || rm -rf "$work/home"
    mkdir -p "$work/home"
    : >"$FAKE_LOG"; : >"$work/streamer.log"; rm -f "$FAKE_LOG.logcat_pid"
    HOME=$work/home BASALT_PLAY_CONTROL=$work/control BASALT_BIN_DIR=$work/fakebin \
        BASALT_ALVR_STOP_WAIT=0 BASALT_ALVR_START_WAIT=0 FAKE_STREAMER_LOG=$work/streamer.log \
        "$work/scripts/play.zsh" "$@" >"$work/play.out" 2>&1
}
# 1 when the fake logcat process is gone (or never got to start: it was stopped first).
logcat_stopped() {
    local f=$FAKE_LOG.logcat_pid
    [[ -r $f ]] || { print 1; return; }
    kill -0 "$(<"$f")" 2>/dev/null; print $?
}
count_in() { grep -c -- "$1" "$2"; }   # prints the number of matching lines
export FAKE_DEVICES="$usb_line"$'\n'"$tcp_line"
export FAKE_STREAMER_FAIL_N=0
allowed_calls='^adb (devices -l|-s QUEST3SERIAL01 (shell (pm list packages|am force-stop alvr\.client\.stable|monkey -p alvr\.client\.stable -c android\.intent\.category\.LAUNCHER 1)|logcat -v threadtime -T 1 \*:V VideoRenderQualityTracker:S))$'

# Normal start: one clean ALVR restart, one streamer, Quest log captured and then stopped.
run_play beat-saber-steam
expect "play: normal start exits 0" "0" "$?"
expect "play: one ALVR force-stop at start" "1" "$(count_in 'force-stop' "$FAKE_LOG")"
expect "play: one streamer run" "1" "$(wc -l <"$work/streamer.log" | tr -d ' ')"
expect "play: only alvr.client.stable and the chosen serial are touched" "0" \
    "$(grep -Ev "$allowed_calls" "$FAKE_LOG" | wc -l | tr -d ' ')"
expect "play: quest log file has the logcat output" "fake logcat line" "$(cat "$work"/home/Library/Logs/BasaltVR/quest-*.log 2>/dev/null)"
expect "play: logcat process is stopped on exit" "1" "$(logcat_stopped)"
expect "play: logcat starts now and silences VideoRenderQualityTracker" "1" \
    "$(count_in 'logcat -v threadtime -T 1 \*:V VideoRenderQualityTracker:S$' "$FAKE_LOG")"

# Log retention: play.zsh deletes BasaltVR logs older than 7 days, and nothing else.
logs=$work/home/Library/Logs/BasaltVR
rm -rf "$work/home"; mkdir -p "$logs/sub" "$work/outside"
old_names=(quest-1.log streamer-1.log runtime-1.log game-1.log steam-1.log app-x-1.log build-1.log steam-shutdown.log quest-1.txt)
for f in $old_names; do : >"$logs/$f"; done
: >"$logs/notes.txt"; : >"$logs/sub/game-old.log"; : >"$work/outside/game-old.log"
ln -s "$work/outside/game-old.log" "$logs/game-link.log"
: >"$logs/game-new.log"; : >"$logs/quest-6days.log"
touch -t 202001010000 "$logs"/${^old_names} "$logs/notes.txt" "$logs/sub/game-old.log" \
    "$work/outside/game-old.log"
touch -h -t 202001010000 "$logs/game-link.log"
touch -t "$(date -v-6d +%Y%m%d%H%M)" "$logs/quest-6days.log"
KEEP_HOME=1 run_play beat-saber-steam
expect "logs: old BasaltVR logs are deleted" "" "$(cd "$logs" && print -l ${^old_names}(N))"
expect "logs: new and 6-day-old logs stay" "game-new.log quest-6days.log" \
    "$(cd "$logs" && print game-new.log(N) quest-6days.log(N))"
expect "logs: other names, subfolders, links and their targets stay" "4" \
    "$(print -l "$logs/notes.txt"(N) "$logs/sub/game-old.log"(N) "$logs/game-link.log"(N@) "$work/outside/game-old.log"(N) | grep -c .)"

# Handshake failure once: the ALVR app is restarted and the streamer runs again.
FAKE_STREAMER_FAIL_N=1 run_play beat-saber-steam
expect "play: handshake failure then success exits 0" "0" "$?"
expect "play: two ALVR force-stops (start + retry)" "2" "$(count_in 'force-stop' "$FAKE_LOG")"
expect "play: two ALVR launches" "2" "$(count_in 'monkey' "$FAKE_LOG")"
expect "play: streamer ran twice" "2" "$(wc -l <"$work/streamer.log" | tr -d ' ')"
expect "play: retry prints one plain line" "1" "$(count_in 'handshake failed. Restarting the ALVR app' "$work/play.out")"
expect "play: retry touches only alvr.client.stable" "0" "$(grep -Ev "$allowed_calls" "$FAKE_LOG" | wc -l | tr -d ' ')"
expect "play: logcat stopped after retry" "1" "$(logcat_stopped)"
expect "play: first failure kept in the streamer log" "0" \
    "$(grep -q 'handshake attempt 1' "$work"/home/Library/Logs/BasaltVR/streamer-*.log; print $?)"

# Handshake fails twice: one retry only, then play.zsh stops with an error.
FAKE_STREAMER_FAIL_N=2 run_play beat-saber-steam
expect "play: two failures exit 1" "1" "$?"
expect "play: only one retry (2 streamer runs)" "2" "$(wc -l <"$work/streamer.log" | tr -d ' ')"
expect "play: only two ALVR force-stops" "2" "$(count_in 'force-stop' "$FAKE_LOG")"
expect "play: logcat stopped after failure" "1" "$(logcat_stopped)"

# Every exit path stops logcat. A fake play.zsh session runs in the background, we wait
# until logcat runs, then end the session the way a user or the Terminal window would.
logcat_alive() {   # 0 if a logcat pid was recorded and still runs
    [[ -r $FAKE_LOG.logcat_pid ]] && kill -0 "$(<"$FAKE_LOG.logcat_pid")" 2>/dev/null
}
exit_path() {   # exit_path <name> <how to end the session>
    local name=$1 how=$2 pid i code
    rm -rf "$work/home"; mkdir -p "$work/home"
    : >"$FAKE_LOG"; : >"$work/streamer.log"; rm -f "$FAKE_LOG.logcat_pid" "$work/control"
    HOME=$work/home BASALT_PLAY_CONTROL=$work/control BASALT_BIN_DIR=$work/fakebin \
        BASALT_ALVR_STOP_WAIT=0 BASALT_ALVR_START_WAIT=0 FAKE_STREAMER_LOG=$work/streamer.log \
        BASALT_STEAM_SETTLE=0 "$work/scripts/play.zsh" beat-saber-steam >"$work/play.out" 2>&1 &
    pid=$!
    for i in {1..100}; do logcat_alive && [[ -s $work/control ]] && break; sleep 0.1; done
    expect "exit path $name: logcat runs during the session" "0" "$(logcat_alive; print $?)"
    case $how in
        INT|TERM|HUP) kill -$how $pid ;;
        streamer) pkill -TERM -f "$work/fakebin/basalt-streamer" ;;
    esac
    wait $pid; code=$?
    sleep 0.3
    expect "exit path $name: logcat process is gone" "1" "$(logcat_stopped)"
    expect "exit path $name: no pidfile is left" "0" "$(print -l "$work"/data/run/logcat-*.pid(N) | grep -c .)"
    print -r -- $code
}
unset FAKE_STREAMER_FAIL_N
# Game that ends by itself (normal exit) is the first run_play test above. Signals now:
for sig in INT TERM HUP; do
    code=$(exit_path "SIG$sig" $sig | tail -n 1)
    expect "exit path SIG$sig: exit code 130" "130" "$code"
done
export FAKE_STREAMER_FAIL_N=0

# A stale logcat from an earlier session (owner pid is dead) is stopped at the next start;
# an adb process that is not in our pidfiles is left alone.
mkdir -p "$work/data/run"
: >"$FAKE_LOG"
"$work/bin/adb" -s QUEST3SERIAL01 logcat -v threadtime -T 1 >/dev/null 2>&1 &
stale=$!
"$work/bin/adb" -s OTHER logcat -v threadtime >/dev/null 2>&1 &
other=$!
sleep 0.3
print -r -- "$stale" >"$work/data/run/logcat-999999.pid"
run_play beat-saber-steam
st=$(/bin/ps -o stat= -p $stale 2>/dev/null)   # empty or Z (zombie, not yet reaped by us) = stopped
expect "stale logcat: stopped by the next session" "1" "$([[ -z $st || $st == Z* ]]; print $((! $?)))"
expect "stale logcat: other adb process untouched" "0" "$(kill -0 $other 2>/dev/null; print $?)"
expect "stale logcat: pidfile removed" "0" "$(print -l "$work"/data/run/logcat-*.pid(N) | grep -c .)"
kill -TERM $other 2>/dev/null; wait $other $stale 2>/dev/null

# The log is capped: FAKE_LOGCAT_BYTES makes the fake logcat write without end.
BASALT_QUEST_LOG_POLL=0.1 BASALT_QUEST_LOG_MAX_MB=1 FAKE_LOGCAT_BYTES=1 run_play beat-saber-steam
size=$(wc -c <"$(print -l "$work"/home/Library/Logs/BasaltVR/quest-*.log | head -n 1)" | tr -d ' ')
expect "quest log is capped near 1 MB" "1" "$(( size >= 1048576 && size < 3145728 ))"
sleep 0.3
expect "quest log cap: logcat process is gone" "1" "$(logcat_stopped)"

# --no-log-quest: no logcat at all.
run_play --no-log-quest beat-saber-steam
expect "play: --no-log-quest exits 0" "0" "$?"
expect "play: --no-log-quest runs no logcat" "0" "$(count_in 'logcat' "$FAKE_LOG")"
expect "play: --no-log-quest writes no quest log" "0" "$(print -l "$work"/home/Library/Logs/BasaltVR/quest-*.log(N) | grep -c .)"

# --quality: the streamer gets the right arguments. Explicit --resolution / --mbps win
# over --profile m3pro inside the streamer (StreamerOptions.parse, covered by swift tests).
streamer_line() { sed -n 1p "$work/streamer.log"; }
# Defaults: USB = high + hevc, Wi-Fi = normal + h264 (headset numbers in PERFORMANCE.md).
run_play beat-saber-steam
expect "default USB args: high + hevc" "0" "$(streamer_line | grep -q -- '--codec hevc' && streamer_line | grep -q -- '--wired --profile m3pro --resolution quality --mbps 60'; print $?)"
expect "default USB line" "1" "$(count_in 'Quality high: 1344x1408 per eye, 72 fps, 60 Mbps, hevc.' "$work/play.out")"
expect "default USB: no hevc-max warning" "0" "$(count_in 'HEVC cannot hold' "$work/play.out")"
run_play --wifi beat-saber-steam
expect "default Wi-Fi args: normal + h264" "0" "$(streamer_line | grep -q -- '--codec h264' && streamer_line | grep -q -- '--wireless --mbps 20'; print $?)"
expect "default Wi-Fi line" "1" "$(count_in 'Quality normal: 1344x1408 per eye, 20 Mbps, h264.' "$work/play.out")"
run_play --quality normal --codec h264 beat-saber-steam
expect "quality normal USB args" "0" "$(streamer_line | grep -qE -- '--wired --profile m3pro( |$)' && ! streamer_line | grep -q -- '--resolution'; print $?)"
expect "quality normal USB line" "1" "$(count_in 'Quality normal: 1152x1216 per eye, 72 fps, 30 Mbps, h264.' "$work/play.out")"
run_play --quality high beat-saber-steam
expect "quality high USB args" "0" "$(streamer_line | grep -q -- '--wired --profile m3pro --resolution quality --mbps 60'; print $?)"
run_play --quality=max --codec h264 beat-saber-steam
expect "quality max USB args" "0" "$(streamer_line | grep -q -- '--wired --profile m3pro --resolution 1680x1760 --mbps 80'; print $?)"
expect "quality max warns about 72 fps" "1" "$(count_in 'Warning: max may not hold 72 fps' "$work/play.out")"
BASALT_QUALITY=high BASALT_CODEC=h264 run_play beat-saber-steam
expect "BASALT_QUALITY=high env" "0" "$(streamer_line | grep -q -- '--resolution quality --mbps 60'; print $?)"
BASALT_QUALITY=high run_play --quality normal beat-saber-steam
expect "--quality flag beats BASALT_QUALITY" "0" "$(streamer_line | grep -c -- '--resolution')"
run_play --quality ultra beat-saber-steam
expect "bad quality exits 2" "2" "$?"
run_play --wifi --quality normal beat-saber-steam
expect "quality normal Wi-Fi args" "0" "$(streamer_line | grep -q -- '--wireless --mbps 20'; print $?)"
run_play --wifi --quality high beat-saber-steam
expect "quality high Wi-Fi args" "0" "$(streamer_line | grep -q -- '--wireless --resolution quality --mbps 30'; print $?)"
run_play --wifi --quality max beat-saber-steam
expect "quality max Wi-Fi args" "0" "$(streamer_line | grep -q -- '--wireless --resolution 1680x1760 --mbps 40'; print $?)"
BASALT_WIFI_MBPS=25 run_play --wifi --quality high beat-saber-steam
expect "BASALT_WIFI_MBPS overrides Wi-Fi Mbps" "0" "$(streamer_line | grep -q -- '--resolution quality --mbps 25'; print $?)"

# --codec x --quality x transport: the streamer gets --codec, the summary names it, and
# only hevc + max warns about 72 fps (the line must not block the run).
for t in usb wifi; do
    for c in h264 hevc; do
        for q in normal high max; do
            run_play --$t --codec $c --quality $q beat-saber-steam
            expect "codec $c $q $t exits 0" "0" "$?"
            expect "codec $c $q $t arg" "1" "$(streamer_line | grep -cE -- "--codec $c( |\$)")"
            expect "codec $c $q $t summary" "1" "$(count_in "Quality $q: .*, $c\\." "$work/play.out")"
            want=0; [[ $c == hevc && $q == max ]] && want=1
            expect "codec $c $q $t hevc-max warning" "$want" "$(count_in 'HEVC cannot hold 72 fps' "$work/play.out")"
        done
    done
done
run_play --codec=hevc beat-saber-steam
expect "--codec=hevc form" "1" "$(streamer_line | grep -c -- '--codec hevc')"
BASALT_CODEC=hevc run_play beat-saber-steam
expect "BASALT_CODEC=hevc env" "1" "$(streamer_line | grep -c -- '--codec hevc')"
BASALT_CODEC=hevc run_play --codec h264 beat-saber-steam
expect "--codec flag beats BASALT_CODEC" "1" "$(streamer_line | grep -c -- '--codec h264')"
run_play --codec vp9 beat-saber-steam
expect "bad codec exits 2" "2" "$?"
unset FAKE_STREAMER_FAIL_N

# ---------------------------------------------------------------------------
# A game that starts another program and exits (The Lab starts Robot Repair): the
# session must last while any program from the game's folder runs.
# ---------------------------------------------------------------------------
lab_win='C:\Program Files (x86)\Steam\steamapps\common\The Lab\TheLab\win64\TheLab.exe'
source "$script_dir/game-processes.zsh"

game_find_root "$lab_win"
expect "game root: steamapps folder marker" 'steamapps\common\the lab\' "$GAME_MARKER"
expect "game root: game name keeps its case" "The Lab" "$GAME_NAME"
expect "game root: launched exe is remembered" 'thelab\win64\thelab.exe' "$GAME_EXE_REL"
expect "game root: steamapps folder is strict" "1" "$GAME_STRICT"
game_find_root '/Users/x/Bottles/pcvr/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/The Lab/TheLab/win64/TheLab.exe'
expect "game root: host path gives the same marker" 'steamapps\common\the lab\' "$GAME_MARKER"
game_find_root 'C:\Program Files (x86)\Steam\steam.exe'
expect "game root: steam.exe has nothing to wait for" "1" "$?"
game_find_root game.exe
expect "game root: bare exe name has nothing to wait for" "1" "$?"
game_find_root 'C:\Games\Foo\bin\foo.exe'
expect "game root: plain exe uses its folder" 'c:\games\foo\bin\|bin|0' "$GAME_MARKER|$GAME_NAME|$GAME_STRICT"
game_find_root 'C:\Games\Foo\bin\foo.exe' 'D:\Games\Foo\'
expect "game root: explicit root wins" 'd:\games\foo\|Foo|' "$GAME_MARKER|$GAME_NAME|$GAME_EXE_REL"
game_find_root 'C:\Games\Foo\bin\foo.exe' 'C:\Program Files (x86)\Steam\steamapps\common\Other Game'
expect "game root: explicit steamapps root" 'steamapps\common\other game\|Other Game' "$GAME_MARKER|$GAME_NAME"

# game_processes against a fake ps.
export FAKE_PS_COUNT=$work/ps.count FAKE_PS_FILE=$work/ps.txt
rm -f "$FAKE_PS_COUNT"
unset FAKE_PS_LIVE_CALLS
lab='/e/engine/bin/wine64-preloader C:\Program Files (x86)\Steam\steamapps\common\The Lab\'
game_find_root "$lab_win"
cat >"$FAKE_PS_FILE" <<PS
/sbin/launchd
${lab}TheLab\win64\TheLab.exe -popupwindow
/e/engine/bin/wine64-preloader C:\Program Files (x86)\Steam\steam.exe -noverifyfiles
/e/engine/bin/wine64-preloader C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe -lang=en
tail -f /Users/me/Logs/BasaltVR/the-lab.log
/e/engine/bin/wine64-preloader C:\Program Files (x86)\Steam\steamapps\common\The Lab 2\Other\other.exe
PS
expect "processes: launched exe, Steam and unrelated lines are ignored" "" "$(game_processes)"
print -r -- "${lab}RobotRepair\bin\win64\vr.exe -noassert -retail -autofidelity" >>"$FAKE_PS_FILE"
expect "processes: Robot Repair is found" 'RobotRepair\bin\win64\vr.exe' "$(game_processes)"
print -r -- '/e/engine/bin/wine64-preloader z:/users/me/prefix/drive_c/program files (x86)/steam/STEAMAPPS/COMMON/the lab/SecretShop/win64/SecretShop.exe' >>"$FAKE_PS_FILE"
expect "processes: other case and forward slashes match" "2" "$(game_processes | wc -l | tr -d ' ')"
game_find_root 'C:\Games\Foo\bin\foo.exe'
cat >"$FAKE_PS_FILE" <<'PS'
/e/engine/bin/wine64-preloader C:\Games\Foo\bin\foo.exe
/e/engine/bin/wine64-preloader C:\Games\Foo\bin\Steam.exe
/e/engine/bin/wine64-preloader C:\Games\Foo\bin\helper.exe --x
PS
expect "processes: plain folder ignores the launched exe and steam*.exe" 'helper.exe' "$(game_processes)"

# play.zsh with the fake game. BASALT_GAME_GRACE/POLL make the waits short.
export BASALT_GAME_GRACE=2 BASALT_GAME_POLL=0.2 BASALT_STEAM_SETTLE=0
ps_calls() { cat "$FAKE_PS_COUNT" 2>/dev/null || print 0; }
robot_line_count() { count_in 'The Lab started RobotRepair.bin.win64.vr.exe; still running.' "$work/play.out"; }

# 1. TheLab.exe starts Robot Repair at once and exits; Robot Repair runs for 12 more looks.
rm -f "$FAKE_PS_COUNT"
FAKE_BOTTLE_UP=1 FAKE_CHILD_DELAY=0 FAKE_PS_LIVE_CALLS=12 run_play --no-adb-check the-lab
expect "the-lab with a child: exits 0" "0" "$?"
expect "the-lab with a child: one plain line" "1" "$(robot_line_count)"
expect "the-lab with a child: waited until the child was gone" "1" "$([[ $(ps_calls) -ge 12 ]]; print $((! $?)))"
expect "the-lab with a child: then shut down" "1" "$(count_in 'The game ended.' "$work/play.out")"
expect "the-lab with a child: no error message" "0" "$(count_in 'stopped with an error' "$work/play.out")"

# 2. The child shows up 1 s after TheLab.exe exits (inside the grace period).
rm -f "$FAKE_PS_COUNT"
FAKE_BOTTLE_UP=1 FAKE_CHILD_DELAY=1 FAKE_PS_LIVE_CALLS=20 run_play --no-adb-check the-lab
expect "the-lab, late child: exits 0" "0" "$?"
expect "the-lab, late child: one plain line" "1" "$(robot_line_count)"

# 3. No child ever: only the grace period is added, and no line is printed.
rm -f "$FAKE_PS_COUNT"
FAKE_BOTTLE_UP=1 run_play --no-adb-check the-lab
expect "the-lab, no child: exits 0" "0" "$?"
expect "the-lab, no child: no 'still running' line" "0" "$(count_in 'still running' "$work/play.out")"
expect "the-lab, no child: looked once per poll for the grace period" "1" "$([[ $(ps_calls) -ge 8 ]]; print $((! $?)))"

# 4. A game process is listed but the bottle's wineserver is gone: nothing is running.
rm -f "$FAKE_PS_COUNT"
FAKE_BOTTLE_UP=0 FAKE_CHILD_DELAY=0 run_play --no-adb-check the-lab
expect "the-lab, bottle down: exits 0" "0" "$?"
expect "the-lab, bottle down: no 'still running' line" "0" "$(count_in 'still running' "$work/play.out")"

# 5. A profile with nothing to watch (bare exe name, like steam.exe) never runs ps.
rm -f "$FAKE_PS_COUNT"
FAKE_BOTTLE_UP=1 run_play --no-adb-check beat-saber-steam
expect "no game root: exits 0" "0" "$?"
expect "no game root: ps is never run" "0" "$(ps_calls)"

# 6. Ctrl-C while Robot Repair runs: everything stops, the game is not waited for.
rm -f "$FAKE_PS_COUNT"
rm -rf "$work/home"; mkdir -p "$work/home"; : >"$FAKE_LOG"; : >"$work/streamer.log"
HOME=$work/home BASALT_PLAY_CONTROL=$work/control BASALT_BIN_DIR=$work/fakebin \
    BASALT_ALVR_STOP_WAIT=0 BASALT_ALVR_START_WAIT=0 FAKE_STREAMER_LOG=$work/streamer.log \
    FAKE_BOTTLE_UP=1 FAKE_CHILD_DELAY=0 \
    "$work/scripts/play.zsh" --no-adb-check the-lab >"$work/play.out" 2>&1 &
play_pid=$!
for i in {1..100}; do grep -q 'still running' "$work/play.out" && break; sleep 0.2; done
kill -INT $play_pid
wait $play_pid; code=$?
expect "Ctrl-C while the child runs: exit code 130" "130" "$code"
expect "Ctrl-C while the child runs: shut down" "1" "$(count_in 'Shutting down' "$work/play.out")"

# 7. The BasaltVR app gets one event line when The Lab hands over to Robot Repair.
rm -f "$FAKE_PS_COUNT"
BASALT_PLAY_EVENTS=1 FAKE_BOTTLE_UP=1 FAKE_CHILD_DELAY=0 FAKE_PS_LIVE_CALLS=12 run_play --no-adb-check the-lab
expect "events: the-lab child event" "1" "$(count_in '^@@basalt game-child RobotRepair.bin.win64.vr.exe$' "$work/play.out")"
unset BASALT_GAME_GRACE BASALT_GAME_POLL BASALT_STEAM_SETTLE

# ---------------------------------------------------------------------------
# The BasaltVR app runs play.zsh with BASALT_PLAY_EVENTS=1 and reads "@@basalt" lines.
# ---------------------------------------------------------------------------
export FAKE_STREAMER_FAIL_N=0 BASALT_STEAM_SETTLE=0
events() { sed -n 's/^@@basalt //p' "$work/play.out" | sed 's/ \/.*//' | tr '\n' ',' ; }
export FAKE_DEVICES="$usb_line"$'\n'"$tcp_line"
run_play beat-saber-steam
expect "events: none without BASALT_PLAY_EVENTS" "0" "$(count_in '^@@basalt' "$work/play.out")"
BASALT_PLAY_EVENTS=1 run_play beat-saber-steam
expect "events: USB session in order" \
    "start beat-saber-steam,looking,connection usb,log streamer,log game,log quest,quality high: 1344x1408 per eye, 72 fps, 60 Mbps, hevc,alvr-restart,streamer-start,headset-wait,headset-ready,game-start beat-saber-steam,game-ended 0,stopping,stopped," \
    "$(events)"
BASALT_PLAY_EVENTS=1 run_play --wifi --quality high --codec hevc beat-saber-steam
expect "events: Wi-Fi session names the connection and opens ALVR" "1" \
    "$(events | grep -c 'connection wifi,.*streamer-start,open-alvr,headset-wait,headset-ready')"
BASALT_PLAY_EVENTS=1 FAKE_DEVICES="" run_play --usb beat-saber-steam
expect "events: no USB Quest fails with a code" "fail no-usb-quest" "$(sed -n 's/^@@basalt //p' "$work/play.out" | tail -n 1)"
BASALT_PLAY_EVENTS=1 FAKE_DEVICES='QUEST3SERIAL01 unauthorized usb:1-1 transport_id:2' BASALT_PICK_TRIES=1 \
    run_play --usb beat-saber-steam
expect "events: unauthorized Quest fails with a code" "fail quest-unauthorized" "$(sed -n 's/^@@basalt //p' "$work/play.out" | tail -n 1)"
BASALT_PLAY_EVENTS=1 FAKE_STREAMER_FAIL_N=2 run_play beat-saber-steam
expect "events: streamer that never starts fails with a code" "1" "$(count_in '^@@basalt fail streamer-stopped$' "$work/play.out")"
expect "events: the streamer failure still shuts down" "1" "$(count_in '^@@basalt stopped$' "$work/play.out")"

# Saved Quest IP: with no Quest in adb and Wi-Fi allowed, play.zsh runs `adb connect` to it.
print -r -- "127.0.0.1" >"$QUEST_IP_FILE"
BASALT_PLAY_EVENTS=1 FAKE_DEVICES="" BASALT_PICK_TRIES=1 run_play --wifi beat-saber-steam
expect "saved IP: Wi-Fi without adb Quest connects to the saved IP" "1" "$(count_in 'adb connect 127.0.0.1:5555' "$FAKE_LOG")"
expect "saved IP: event names the address" "1" "$(count_in '^@@basalt wifi-reconnect 127.0.0.1$' "$work/play.out")"
expect "saved IP: the session still runs over Wi-Fi" "1" "$(count_in '^@@basalt connection wifi$' "$work/play.out")"
FAKE_DEVICES="" BASALT_PICK_TRIES=1 run_play beat-saber-steam
expect "saved IP: auto without adb Quest also connects" "1" "$(count_in 'adb connect 127.0.0.1:5555' "$FAKE_LOG")"
run_play beat-saber-steam
expect "saved IP: a USB Quest needs no connect" "0" "$(count_in 'adb connect' "$FAKE_LOG")"
FAKE_DEVICES="" BASALT_PICK_TRIES=1 run_play --usb beat-saber-steam
expect "saved IP: --usb never connects over Wi-Fi" "0" "$(count_in 'adb connect' "$FAKE_LOG")"
rm -f "$QUEST_IP_FILE"
FAKE_DEVICES="" BASALT_PICK_TRIES=1 run_play --wifi beat-saber-steam
expect "saved IP: no saved IP, no connect" "0" "$(count_in 'adb connect' "$FAKE_LOG")"

# The app is gone (quit, crash): play.zsh stops everything like Ctrl-C.
rm -rf "$work/home"; mkdir -p "$work/home"
: >"$FAKE_LOG"; : >"$work/streamer.log"; rm -f "$FAKE_LOG.logcat_pid" "$work/control"
sleep 60 &
fake_app=$!
HOME=$work/home BASALT_PLAY_CONTROL=$work/control BASALT_BIN_DIR=$work/fakebin \
    BASALT_ALVR_STOP_WAIT=0 BASALT_ALVR_START_WAIT=0 FAKE_STREAMER_LOG=$work/streamer.log \
    BASALT_PLAY_PARENT_PID=$fake_app BASALT_PARENT_POLL=0.2 BASALT_PLAY_EVENTS=1 \
    "$work/scripts/play.zsh" beat-saber-steam >"$work/play.out" 2>&1 &
play_pid=$!
for i in {1..100}; do logcat_alive && grep -q 'game-start' "$work/play.out" && break; sleep 0.1; done
kill -TERM $fake_app; wait $fake_app 2>/dev/null
for i in {1..100}; do kill -0 $play_pid 2>/dev/null || break; sleep 0.1; done
wait $play_pid; code=$?
expect "app gone: play.zsh stops (exit 130)" "130" "$code"
expect "app gone: says why" "1" "$(count_in 'The BasaltVR app is gone' "$work/play.out")"
sleep 0.3
expect "app gone: logcat process is gone" "1" "$(logcat_stopped)"
expect "app gone: streamer is gone" "1" "$(/usr/bin/pgrep -f "$work/fakebin/basalt-streamer" >/dev/null; print $?)"
unset FAKE_STREAMER_FAIL_N BASALT_STEAM_SETTLE

# ---------------------------------------------------------------------------
# scripts/quest-check.zsh: the app's read-only Quest status.
# ---------------------------------------------------------------------------
cp "$script_dir/quest-check.zsh" "$work/scripts/"
check_value() { "$work/scripts/quest-check.zsh" | sed -n "s/^$1=//p" | tr '\n' '|'; }
: >"$FAKE_LOG"
export FAKE_DEVICES="$emu_line"$'\n'"$phone_line"$'\n'"$tcp_line"$'\n'"$usb_line"
expect "quest-check: USB Quest" "ok|" "$(check_value status)"
expect "quest-check: link and serial" "usb|QUEST3SERIAL01|" "$(check_value link)$(check_value serial)"
expect "quest-check: ALVR version" "alvr.client.stable 20.14.1|" "$(check_value alvr)"
expect "quest-check: other devices get no command" "1" "$(grep -qE 'emulator-|R5CT1234ABC' "$FAKE_LOG"; print $?)"
expect "quest-check: only reads (devices, pm list, dumpsys)" "0" \
    "$(grep -Ev '^adb (devices -l|-s QUEST3SERIAL01 shell (pm list packages|dumpsys package alvr\.client\.stable))$' "$FAKE_LOG" | wc -l | tr -d ' ')"
expect "quest-check: older ALVR" "alvr.client.stable 20.6.0|" "$(FAKE_ALVR_VERSION=20.6.0 check_value alvr)"
expect "quest-check: unauthorized" "unauthorized|" \
    "$(FAKE_DEVICES='QUEST3SERIAL01 unauthorized usb:1-1 transport_id:2' check_value status)"
expect "quest-check: nothing (and no ALVR line)" "none|" "$(FAKE_DEVICES="" check_value status)$(FAKE_DEVICES="" check_value alvr)"
print -r -- "192.168.1.77" >"$QUEST_IP_FILE"
expect "quest-check: saved IP" "192.168.1.77|" "$(check_value saved_ip)"
rm -f "$QUEST_IP_FILE"
# Only where quest_find_adb's fixed fallbacks hold no adb (it also looks in Homebrew).
if [[ ! -x /opt/homebrew/bin/adb && ! -x /usr/local/bin/adb ]]; then
    expect "quest-check: no adb" "no-adb|" "$(PATH=/usr/bin:/bin HOME=$work/home "$work/scripts/quest-check.zsh" 2>/dev/null | sed -n 's/^status=//p' | tr '\n' '|')"
fi

# scripts/install-quest-client.zsh: a downloaded file must still match the SHA-256.
cat >"$work/bin/curl" <<'FAKE'
#!/bin/zsh
args=("$@")
print -r -- "not the ALVR apk" >"${args[$args[(i)-o]+1]}"
FAKE
chmod +x "$work/bin/curl"
apk_dir=$work/apk
ALVR_APK=$apk_dir/alvr_client_android.apk "$script_dir/install-quest-client.zsh" >"$work/out.txt" 2>&1
expect "install: missing APK without --download exits 1" "1" "$?"
expect "install: names the download page" "1" "$(count_in 'releases/tag/v20.14.1' "$work/out.txt")"
: >"$FAKE_LOG"
ALVR_APK=$apk_dir/alvr_client_android.apk "$script_dir/install-quest-client.zsh" --download --yes >"$work/out.txt" 2>&1
expect "install: a wrong download is refused" "1" "$(count_in 'not the file I expect' "$work/out.txt")"
expect "install: the wrong download is removed" "1" "$([[ -e $apk_dir/alvr_client_android.apk ]]; print $?)"
expect "install: nothing reached the Quest" "0" "$(count_in 'install' "$FAKE_LOG")"
"$script_dir/install-quest-client.zsh" --bogus >/dev/null 2>&1
expect "install: unknown option exits 2" "2" "$?"

if (( failures > 0 )); then
    print -u2 "$failures test(s) failed."
    exit 1
fi
print "PASS: all Quest adb tests"
