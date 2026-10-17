#!/bin/zsh
#
# One command to play a Basalt profile on the Quest.
#
#   scripts/play.zsh beat-saber-steam          USB if the Quest is plugged in, else Wi-Fi
#   scripts/play.zsh --wifi beat-saber-steam   force Wi-Fi (no cable)
#   scripts/play.zsh --usb beat-saber-steam    force USB (fail if no cable)
#
# What it does: checks the Quest, closes any old Steam in the profile's bottle,
# starts the streamer (with BlackHole game audio when BlackHole is installed),
# starts the game, and on Ctrl-C or game exit closes the game, Steam and the
# streamer cleanly. Logs go to ~/Library/Logs/BasaltVR/.
#
# Some games start a second program and exit (The Lab starts Robot Repair). The session
# ends only when no program from the game's install folder is left in the bottle: see
# scripts/game-processes.zsh. Set "gameRoot" in the profile (basaltctl profile add
# --game-root) if the game does not live in steamapps/common/<Game>.
#
# Wi-Fi needs no pairing and no Trust tap: the streamer connects to the ALVR app
# by itself. See "Quest over Wi-Fi" in docs/STREAMER.md. Defaults: --quality high
# --codec hevc on USB, --quality normal --codec h264 on Wi-Fi (see --quality).
# To use adb without the cable: scripts/quest-wireless.zsh.
#
# The ALVR app on the Quest (alvr.client.stable only) is restarted once at the start,
# because a Basalt session that ended badly can leave it in a state where the USB
# handshake fails. If the handshake still fails, it is restarted once more and the
# streamer is tried once more.
#
#   --quality normal|high|max   picture size and bitrate (default: high on USB, normal on
#                    Wi-Fi; or set BASALT_QUALITY). The flag wins over the variable.
#                      normal  USB: 1152x1216 per eye, 30 Mbps.  Wi-Fi: 1344x1408, 20 Mbps
#                      high    USB: 1344x1408 per eye, 60 Mbps.  Wi-Fi: 1344x1408, 30 Mbps
#                      max     USB: 1680x1760 per eye, 80 Mbps.  Wi-Fi: 1680x1760, 40 Mbps
#                    max may not hold 72 fps with H.264. On Wi-Fi, BASALT_WIFI_MBPS
#                    overrides the Mbps of every level.
#   --codec h264|hevc   video codec (default: hevc on USB, h264 on Wi-Fi; or set BASALT_CODEC). The flag wins
#                    over the variable. hevc cannot hold 72 fps at --quality max.
#   --log-quest      (default) save `adb logcat -v threadtime` from the Quest to
#                    ~/Library/Logs/BasaltVR/quest-<time>.log while you play
#   --no-log-quest   do not save the Quest log
#
# Hidden test flag: --no-adb-check skips the Quest check and runs the streamer
# without --wired/--wireless and without audio (no headset), so everything else
# can be tested.

set -uo pipefail

readonly script_dir=${0:A:h}
readonly repo=${script_dir:h}
readonly log_dir=$HOME/Library/Logs/BasaltVR
readonly control=${BASALT_PLAY_CONTROL:-/tmp/basalt-control}
readonly stamp=$(date +%Y%m%d-%H%M%S)
readonly streamer_log=$log_dir/streamer-$stamp.log
readonly game_log=$log_dir/game-$stamp.log
readonly build_log=$log_dir/build-$stamp.log
readonly quest_log=$log_dir/quest-$stamp.log
# The OpenXR runtime appends its diagnostics here as well as to stderr: a game
# started by another game (The Lab -> Robot Repair) has no stderr in game_log.
export BASALT_RUNTIME_LOG=${BASALT_RUNTIME_LOG:-$log_dir/runtime-$stamp.log}

profile=""
no_adb_check=0
log_quest=1
transport=${BASALT_TRANSPORT:-auto}   # auto, usb, or wifi
quality=${BASALT_QUALITY:-}     # normal, high, or max; empty = the default for the transport (set after mode)
codec=${BASALT_CODEC:-}         # h264 or hevc; empty = the default for the transport
while (( $# )); do
    arg=$1; shift
    case $arg in
        --quality)
            if (( ! $# )); then print -u2 "--quality needs a value: normal, high, or max."; exit 2; fi
            quality=$1; shift ;;
        --quality=*) quality=${arg#--quality=} ;;
        --codec)
            if (( ! $# )); then print -u2 "--codec needs a value: h264 or hevc."; exit 2; fi
            codec=$1; shift ;;
        --codec=*) codec=${arg#--codec=} ;;
        --wifi) transport=wifi ;;
        --usb) transport=usb ;;
        --log-quest) log_quest=1 ;;
        --no-log-quest) log_quest=0 ;;
        --no-adb-check) no_adb_check=1 ;;
        -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) print -u2 "Unknown option: $arg"; exit 2 ;;
        *)
            if [[ -n $profile ]]; then print -u2 "usage: scripts/play.zsh [--wifi|--usb] [--quality normal|high|max] [--codec h264|hevc] [--no-log-quest] <profile>"; exit 2; fi
            profile=$arg
            ;;
    esac
done
if [[ $transport != (auto|usb|wifi) ]]; then
    print -u2 "BASALT_TRANSPORT must be auto, usb, or wifi."
    exit 2
fi
if [[ -n $quality && $quality != (normal|high|max) ]]; then
    print -u2 "Quality must be normal, high, or max (got '$quality')."
    exit 2
fi
if [[ -n $codec && $codec != (h264|hevc) ]]; then
    print -u2 "Codec must be h264 or hevc (got '$codec')."
    exit 2
fi
if [[ -z $profile ]]; then
    print -u2 "usage: scripts/play.zsh [--wifi|--usb] [--quality normal|high|max] [--codec h264|hevc] [--no-log-quest] <profile>   (see your profiles: swift run --package-path streamer basaltctl profile list)"
    exit 2
fi

mkdir -p "$log_dir"
cd "$repo" || exit 1
export BASALT_REPO_ROOT=$repo

# 1. Binaries: build once, then run them directly.
readonly bin_dir=${BASALT_BIN_DIR:-$repo/streamer/.build/release}
readonly streamer=$bin_dir/basalt-streamer
readonly ctl=$bin_dir/basaltctl
if [[ ! -x $streamer || ! -x $ctl ]]; then
    print "Building the streamer. This happens one time and takes a few minutes."
    if ! swift build -c release --package-path streamer >"$build_log" 2>&1 \
        || [[ ! -x $streamer || ! -x $ctl ]]; then
        print -u2 "The build failed. See: $build_log"
        exit 1
    fi
fi

# 2. Profile.
source "$script_dir/game-processes.zsh"
profile_json=$("$ctl" profile show "$profile" 2>&1) || {
    print -u2 "I do not know the profile '$profile'. Your profiles:"
    "$ctl" profile list 2>&1 | cut -f1 | sed 's/^/  /' >&2
    exit 1
}
bottle_name=$(print -r -- "$profile_json" | jq -r '.bottleName')
# basaltctl turns "steam.exe -applaunch 620980" (Beat Saber) into a direct launch of
# Beat Saber.exe. Other Steam profiles (for example the-lab) name the game exe directly.
# Those games need Steam to be running first, so we start Steam here.
needs_steam_first=$(print -r -- "$profile_json" | jq -r '
    (.arguments // []) as $a | ($a | index("-applaunch")) as $i
    | (.executable | ascii_downcase | split("\\") | last) as $exe
    | (.source == "steam"
       and (($i != null and $a[$i + 1] == "620980") or $exe != "steam.exe"))')
export BASALT_BOTTLE=$bottle_name
# Which folder holds the game? The session lasts while a program from it runs.
game_wait=0
if game_find_root "$(print -r -- "$profile_json" | jq -r '.executable')" \
        "$(print -r -- "$profile_json" | jq -r '.gameRoot // empty')"; then
    game_wait=1
fi

# 3. Quest check. Every adb call below uses -s with one serial (a Quest with adb over
#    Wi-Fi shows up twice in `adb devices`; USB wins when both are there).
source "$script_dir/quest-adb.zsh"
mode=""            # usb or wifi
alvr_package=""
if (( ! no_adb_check )); then
    have_adb=0
    quest_find_adb 2>/dev/null && have_adb=1
    pick=1
    if (( have_adb )); then
        # --wifi does not need adb, so look once. Otherwise look again for ~5 s while
        # the listing may be transient (adb server restarting, Quest just plugged in).
        if [[ $transport == wifi ]]; then quest_pick_serial; pick=$?
        else
            print "Looking for the Quest on the USB cable..."
            quest_pick_serial_retry; pick=$?
        fi
    fi

    # auto: USB if a USB Quest is attached, else Wi-Fi.
    case $transport in
        usb) mode=usb ;;
        wifi) mode=wifi ;;
        auto) if (( pick == 0 )) && [[ $QUEST_LINK == usb ]]; then mode=usb; else mode=wifi; fi ;;
    esac

    if [[ $mode == usb ]]; then
        if (( ! have_adb )); then
            print -u2 "I cannot find adb. Run: brew install android-platform-tools"
            exit 1
        fi
        if (( pick == 2 )); then
            print -u2 "The Quest asks for permission. Put it on and tap Allow for USB debugging. Then run this command again."
            exit 1
        fi
        if (( pick != 0 )) || [[ $QUEST_LINK != usb ]]; then
            print -u2 "I cannot see the Quest on the USB cable. Plug it in and run this command again. Or play without the cable: scripts/play.zsh --wifi $profile"
            exit 1
        fi
    fi
    # Wi-Fi streaming itself does not need adb. If adb can see the Quest (cable or
    # adb over Wi-Fi), use it to check ALVR and open it for you.
    if (( have_adb && pick == 0 )); then
        alvr_package=$(qadb shell pm list packages 2>/dev/null | tr -d '\r' \
            | sed -n 's/^package://p' | grep -E '^alvr\.client(\.stable|\.dev)?$' | head -n 1)
        if [[ -z $alvr_package ]]; then
            print -u2 "ALVR is not on the Quest. Run: scripts/install-quest-client.zsh"
            exit 1
        fi
    fi
    print "Connection: $mode${QUEST_SERIAL:+ (adb $QUEST_SERIAL)}"
    if (( have_adb )); then
        print "Quest choice: $QUEST_REASON"
        if [[ $transport == auto && $mode == wifi ]]; then
            if (( pick == 2 )); then
                print "Wi-Fi was chosen because the Quest on the cable waits for you to tap Allow for USB debugging."
            else
                print "Wi-Fi was chosen because no USB Quest was found after 6 looks."
            fi
        fi
    fi
else
    print "TEST MODE: no headset. The streamer runs without --wired and without audio."
fi

if pgrep -x basalt-streamer >/dev/null 2>&1; then
    print -u2 "Another streamer is already running. Stop it first: pkill -INT basalt-streamer"
    exit 1
fi

# 4. Audio: only when BlackHole is installed.
audio_args=()
if (( ! no_adb_check )); then
    if "$streamer" --list-audio-devices 2>/dev/null | grep -q '^BlackHole 2ch'; then
        audio_args=(--audio-device 'BlackHole 2ch' --route-audio)
    else
        print "Warning: no game audio until BlackHole is installed (brew install --cask blackhole-2ch)."
    fi
fi

# Shutdown: game, then Steam, then streamer. The streamer needs SIGTERM (not SIGKILL)
# so it can put the Mac audio output back.
streamer_pid=""
game_pid=""
logcat_pid=""        # pid of the watcher subshell
logcat_adb_pid=""    # pid of the real adb logcat process
logcat_pidfile=""
cleanup_done=0

# Quest log. A small watcher subshell runs adb logcat (a plain background command, so its
# pid is known and one kill stops it) and stops it when the log reaches the size cap.
# The pids go in a pidfile so a later play.zsh can stop a logcat that a crash left behind.
readonly run_dir=$QUEST_DATA_DIR/run
readonly quest_log_max_mb=${BASALT_QUEST_LOG_MAX_MB:-200}

zmodload zsh/system   # $sysparams[pid]: the pid of a subshell
proc_command() { /bin/ps -o command= -p "$1" 2>/dev/null; }

# Stop logcat processes that an earlier play.zsh started and that are still running after
# that play.zsh ended. Only pids from our own pidfiles, only if the pid still looks like
# our command (a reused pid is left alone). Other adb processes are never touched.
kill_stale_logcats() {
    local f owner pids p cmd
    for f in "$run_dir"/logcat-*.pid(N); do
        owner=${${f:t}#logcat-}; owner=${owner%.pid}
        if [[ $owner == <-> ]] && [[ $owner != $$ ]] && kill -0 $owner 2>/dev/null \
            && [[ $(proc_command $owner) == *play.zsh* ]]; then
            continue   # that session is still running
        fi
        pids=($(<"$f"))
        for p in $pids; do
            [[ $p == <-> ]] || continue
            cmd=$(proc_command $p)
            if [[ $cmd == *adb*" logcat -v threadtime"* ]]; then
                kill -TERM $p 2>/dev/null
                print "Stopped an old Quest log process ($p) left by an earlier session."
            fi
        done
        rm -f "$f"
    done
}

start_logcat() {
    mkdir -p "$run_dir"
    logcat_pidfile=$run_dir/logcat-$$.pid
    local max_bytes=$(( quest_log_max_mb * 1024 * 1024 ))
    (
        trap - EXIT
        "$QUEST_ADB" -s "$QUEST_SERIAL" logcat -v threadtime >"$quest_log" 2>&1 </dev/null &
        adb_pid=$!
        trap 'kill -TERM $adb_pid 2>/dev/null; exit 0' TERM INT HUP
        print -r -- $adb_pid >"$logcat_pidfile.adb"
        while kill -0 $adb_pid 2>/dev/null; do
            sleep ${BASALT_QUEST_LOG_POLL:-2} &
            wait $!
            if (( $(/usr/bin/stat -f %z "$quest_log" 2>/dev/null || print 0) >= max_bytes )); then
                kill -TERM $adb_pid 2>/dev/null
                print -u2 "The Quest log reached $quest_log_max_mb MB. Saving stopped."
                break
            fi
        done
        wait $adb_pid 2>/dev/null
        exit 0
    ) &
    logcat_pid=$!
    local i
    for i in {1..40}; do [[ -s $logcat_pidfile.adb ]] && break; sleep 0.05; done
    logcat_adb_pid=$(<"$logcat_pidfile.adb" 2>/dev/null)
    print -r -- "$logcat_adb_pid $logcat_pid" >"$logcat_pidfile"
    rm -f "$logcat_pidfile.adb"
}

stop_logcat() {
    [[ -n $logcat_pid || -n $logcat_adb_pid ]] || return 0
    [[ -n $logcat_pid ]] && kill -TERM $logcat_pid 2>/dev/null
    [[ -n $logcat_adb_pid ]] && kill -TERM $logcat_adb_pid 2>/dev/null
    [[ -n $logcat_pid ]] && wait $logcat_pid 2>/dev/null
    [[ -n $logcat_adb_pid ]] && kill -KILL $logcat_adb_pid 2>/dev/null
    [[ -n $logcat_pidfile ]] && rm -f "$logcat_pidfile" "$logcat_pidfile.adb"
    logcat_pid=""; logcat_adb_pid=""
}

stop_streamer() {
    [[ -n $streamer_pid ]] || return 0
    local i
    if kill -0 $streamer_pid 2>/dev/null; then
        kill -TERM $streamer_pid 2>/dev/null
        for i in {1..40}; do
            kill -0 $streamer_pid 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 $streamer_pid 2>/dev/null; then
            print -u2 "The streamer did not stop. Forcing it. Check your Mac sound output."
            kill -KILL $streamer_pid 2>/dev/null
        fi
    fi
    wait $streamer_pid 2>/dev/null
    streamer_pid=""
}

cleanup() {
    (( cleanup_done )) && return 0
    cleanup_done=1
    trap '' INT TERM HUP
    print "Shutting down..."
    if [[ -n $game_pid ]] && kill -0 $game_pid 2>/dev/null; then
        kill -TERM $game_pid 2>/dev/null
    fi
    "$script_dir/steam.zsh" stop
    stop_streamer
    stop_logcat
    [[ -n $game_pid ]] && wait $game_pid 2>/dev/null
    if grep -q 'Restored the previous Mac audio output' "$streamer_log" 2>/dev/null; then
        print "Mac sound output is back to normal."
    fi
    rm -f "$control"
    print "Done. Logs: $log_dir"
}

on_signal() {
    cleanup
    exit 130
}
trap on_signal INT TERM HUP
trap cleanup EXIT
kill_stale_logcats

# Quest log: the Quest keeps only ~30 s of log, so save it for the whole session.
if (( log_quest )) && [[ -n $QUEST_SERIAL && -n $alvr_package ]]; then
    start_logcat
    print "Saving the Quest log to $quest_log (stops at $quest_log_max_mb MB)."
fi

# 5. Close any Steam that is already running in this bottle. A game started from a running
#    Steam inherits that Steam's old environment, which lacks the Basalt settings.
"$script_dir/steam.zsh" stop

# 6. Streamer.
rm -f "$control"
# Defaults: USB = high + hevc (The Lab, high: 62 ms latency, Quest decode 10 ms, versus
# 83 ms and 26 ms with H.264, same picture; docs/PERFORMANCE.md). Wi-Fi and
# test mode = normal + h264 (HEVC drops more frames at low bitrate). Flags and env win.
if [[ $mode == usb ]]; then
    : ${quality:=high} ${codec:=hevc}
else
    : ${quality:=normal} ${codec:=h264}
fi
streamer_args=(--runtime "$control" --codec "$codec")
# The streamer applies --profile m3pro only for values that are not set explicitly, so an
# explicit --resolution / --mbps wins over the preset (StreamerOptions.parse). USB always
# keeps the preset's 72 fps and low latency.
quality_text=""
if [[ $mode == usb ]]; then
    # m3pro: balanced resolution, 72 fps, 30 Mbps, low latency (docs/PERFORMANCE.md).
    streamer_args+=(--wired --profile m3pro)
    case $quality in
        normal) quality_text="1152x1216 per eye, 72 fps, 30 Mbps" ;;
        high) streamer_args+=(--resolution quality --mbps 60); quality_text="1344x1408 per eye, 72 fps, 60 Mbps" ;;
        max) streamer_args+=(--resolution 1680x1760 --mbps 80); quality_text="1680x1760 per eye, 72 fps, 80 Mbps" ;;
    esac
elif [[ $mode == wifi ]]; then
    streamer_args+=(--wireless)
    case $quality in
        normal) streamer_args+=(--mbps ${BASALT_WIFI_MBPS:-20}); quality_text="1344x1408 per eye, ${BASALT_WIFI_MBPS:-20} Mbps" ;;
        high) streamer_args+=(--resolution quality --mbps ${BASALT_WIFI_MBPS:-30}); quality_text="1344x1408 per eye, ${BASALT_WIFI_MBPS:-30} Mbps" ;;
        max) streamer_args+=(--resolution 1680x1760 --mbps ${BASALT_WIFI_MBPS:-40}); quality_text="1680x1760 per eye, ${BASALT_WIFI_MBPS:-40} Mbps" ;;
    esac
fi
if [[ -n $quality_text ]]; then
    print "Quality $quality: $quality_text, $codec."
    if [[ $quality == max && $codec == hevc ]]; then
        print "Warning: HEVC cannot hold 72 fps at --quality max (1680x1760, 23.5 ms encode). Use --quality high or --codec h264."
    elif [[ $quality == max ]]; then
        print "Warning: max may not hold 72 fps with H.264. If it stutters, use --quality high."
    fi
fi
streamer_args+=("${audio_args[@]}")
# Clean ALVR start. Only alvr.client.stable, only on the chosen Quest serial.
alvr_retried=0
if [[ $alvr_package == alvr.client.stable ]]; then
    print "Restarting the ALVR app on the Quest for a clean start."
    quest_restart_alvr
fi

start_streamer() {
    rm -f "$control"
    "$streamer" "${streamer_args[@]}" >>"$streamer_log" 2>&1 </dev/null &
    streamer_pid=$!
}

# Called when the streamer stopped while it was starting. If the ALVR handshake failed,
# restart the ALVR app and start the streamer again, one time only. Returns 0 if it did.
retry_after_handshake_failure() {
    wait $streamer_pid 2>/dev/null
    streamer_pid=""
    (( alvr_retried )) && return 1
    [[ $alvr_package == alvr.client.stable ]] || return 1
    grep -qE 'ALVR USB handshake attempt|ALVR initial client-status stage failed' "$streamer_log" 2>/dev/null || return 1
    alvr_retried=1
    print "The ALVR handshake failed. Restarting the ALVR app and trying once more."
    print "--- ALVR handshake failed; restarted the ALVR app; second try ---" >>"$streamer_log"
    quest_restart_alvr
    start_streamer
    return 0
}

print "Starting the streamer. Put the headset on."
start_streamer

if [[ $mode == wifi ]]; then
    # The ALVR app must be open on the Quest. If adb sees the Quest, open it for you.
    if [[ -n $alvr_package ]]; then
        qadb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        qadb shell monkey -p "$alvr_package" 1 >/dev/null 2>&1
    fi
    print "Wi-Fi: ALVR connects by itself, so tap nothing in ALVR. Open ALVR on the Quest if it is not open. If your Mac asks to allow incoming connections or Local Network access, click Allow."
fi

# Beat Saber needs Steam running before it starts. Start Steam while the streamer connects.
if [[ $needs_steam_first == true ]]; then
    print "Starting Steam."
    "$script_dir/steam.zsh" start >/dev/null
    if [[ ! -f $HOME/Library/Application\ Support/BasaltVR/Bottles/$bottle_name/prefix/drive_c/Program\ Files\ \(x86\)/Steam/config/loginusers.vdf ]]; then
        print "Warning: Steam does not look signed in. If the game fails, run scripts/steam.zsh, sign in, then scripts/steam.zsh stop."
    fi
fi

# Wait for the control file. With a headset this includes the USB handshake.
i=0
while (( i < 360 )); do
    [[ -s $control ]] && break
    if ! kill -0 $streamer_pid 2>/dev/null; then
        if retry_after_handshake_failure; then i=0; continue; fi
        print -u2 "The streamer stopped. Last lines of $streamer_log:"
        tail -n 6 "$streamer_log" >&2
        exit 1
    fi
    sleep 0.5
    (( i++ ))
done
if [[ ! -s $control ]]; then
    print -u2 "The streamer did not get ready in 3 minutes. Last lines of $streamer_log:"
    tail -n 6 "$streamer_log" >&2
    exit 1
fi

# Wi-Fi: the control file appears at once, before any headset is connected. Start the
# game only after the headset is connected, as with USB.
if [[ $mode == wifi ]]; then
    i=0
    while (( i < 360 )); do
        grep -q 'ALVR control accepted' "$streamer_log" 2>/dev/null && break
        if ! kill -0 $streamer_pid 2>/dev/null; then
            if retry_after_handshake_failure; then i=0; continue; fi
            print -u2 "The streamer stopped. Last lines of $streamer_log:"
            tail -n 6 "$streamer_log" >&2
            exit 1
        fi
        sleep 0.5
        (( i++ ))
    done
    if ! grep -q 'ALVR control accepted' "$streamer_log" 2>/dev/null; then
        print -u2 "The Quest did not connect in 3 minutes. Open ALVR on the Quest, check that the Mac and the Quest use the same Wi-Fi, then run this command again. Last lines of $streamer_log:"
        tail -n 6 "$streamer_log" >&2
        exit 1
    fi
fi

# Wait until Steam has its window up (webhelper renderer), then a short pause.
if [[ $needs_steam_first == true ]]; then
    for i in {1..240}; do
        pgrep -f 'steamwebhelper.*--type=renderer' >/dev/null 2>&1 && break
        sleep 0.5
    done
    sleep ${BASALT_STEAM_SETTLE:-5}
fi

# 7. Game.
print "Starting $profile."
"$ctl" run "$profile" --control-file "$control" >"$game_log" 2>&1 </dev/null &
game_pid=$!

game_status=0
while kill -0 $game_pid 2>/dev/null; do
    if ! kill -0 $streamer_pid 2>/dev/null; then
        print -u2 "The streamer stopped. Last lines of $streamer_log:"
        tail -n 6 "$streamer_log" >&2
        game_status=1
        break
    fi
    sleep 1
done
if kill -0 $game_pid 2>/dev/null; then
    kill -TERM $game_pid 2>/dev/null
fi
wait $game_pid 2>/dev/null
wait_status=$?
if (( game_status == 0 )); then
    game_status=$wait_status
    # The launched program ended. Some games start another program and exit (The Lab
    # starts Robot Repair). Keep the session while any program of the game still runs.
    if (( game_wait )); then
        game_wait_for_children $streamer_pid
        if (( $? == 3 )); then
            print -u2 "The streamer stopped. Last lines of $streamer_log:"
            tail -n 6 "$streamer_log" >&2
            game_status=1
        elif (( GAME_CHILD_SEEN )); then
            game_status=0   # handing over to another program is not an error
        fi
    fi
fi
if (( game_status != 0 )); then
    print -u2 "The game stopped with an error. Last lines of $game_log:"
    tail -n 6 "$game_log" >&2
else
    print "The game ended."
fi
exit $game_status
