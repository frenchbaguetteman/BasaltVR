#!/bin/zsh
#
# Start or stop Steam inside the Basalt "pcvr" bottle, without the streamer.
# Use it to sign in to Steam and to download games.
#
#   scripts/steam.zsh          start Steam in the background
#   scripts/steam.zsh stop     close Steam cleanly (kills the bottle's Wine only if needed)
#   scripts/steam.zsh status   say whether Steam is running
#
# Environment (optional):
#   BASALT_BOTTLE    bottle name (default: pcvr)
#   BASALT_STEAM_PROFILE  Steam profile in that bottle (default: steam)
#   BASALT_DATA_DIR  Basalt data folder (default: ~/Library/Application Support/BasaltVR)

set -uo pipefail

readonly bottle_name=${BASALT_BOTTLE:-pcvr}
readonly data_root=${BASALT_DATA_DIR:-$HOME/Library/Application Support/BasaltVR}
readonly bottle_dir=$data_root/Bottles/$bottle_name
readonly prefix=$bottle_dir/prefix
readonly wine=$bottle_dir/engine/bin/wine
readonly wineserver=$bottle_dir/engine/bin/wineserver
readonly steam_dir=$prefix/drive_c/Program\ Files\ \(x86\)/Steam
readonly log_dir=$HOME/Library/Logs/BasaltVR
readonly script_dir=${0:A:h}
readonly repo=${script_dir:h}
readonly profile_name=${BASALT_STEAM_PROFILE:-steam}

# Same variables as BottleManager.applicationLaunchCommand.
export WINEPREFIX=$prefix WINEARCH=win64 WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0

# True while this bottle's wineserver is alive (it exits shortly after the last
# Windows process in the bottle ends). The pattern holds the bottle's own engine
# path, so other bottles are not matched.
bottle_running() {
    pgrep -f "${bottle_dir}/engine/.*/wineserver" >/dev/null 2>&1
}

steam_running() {
    bottle_running && pgrep -f 'Steam\\steam\.exe' >/dev/null 2>&1
}

require_bottle() {
    if [[ ! -x $wine ]]; then
        print -u2 "Bottle '$bottle_name' is not ready. Missing: $wine"
        print -u2 "Set it up first (see docs/BOTTLES.md, \"Steam\")."
        exit 1
    fi
    if [[ ! -f $steam_dir/steam.exe ]]; then
        print -u2 "Steam is not installed in bottle '$bottle_name'. Missing: $steam_dir/steam.exe"
        exit 1
    fi
}

# Prints the path of basaltctl, building it once if needed. Also makes sure the
# Steam web helper shim exists (runtime/build/bin/steamwebhelper_compat.exe).
ensure_ctl() {
    local ctl=$repo/streamer/.build/release/basaltctl
    if [[ ! -x $ctl ]]; then
        print -u2 "Building basaltctl. This happens one time."
        swift build -c release --package-path "$repo/streamer" --product basaltctl >&2 || return 1
    fi
    if [[ ! -f $repo/runtime/build/bin/steamwebhelper_compat.exe ]]; then
        print -u2 "Building the Steam web helper shim."
        (cd "$repo" && make runtime-build) >&2 || return 1
    fi
    print -r -- $ctl
}

start_steam() {
    require_bottle
    if steam_running; then
        print "Steam is already running. To close it: scripts/steam.zsh stop"
        return 0
    fi
    mkdir -p "$log_dir"
    local log=$log_dir/steam-$(date +%Y%m%d-%H%M%S).log
    # basaltctl installs the Steam web helper shim (fixes the black Steam window) and
    # starts steam.exe with -inhibitbootstrap -noverifyfiles -no-cef-sandbox. Steam keeps
    # running after this script and this terminal tab end.
    local ctl
    ctl=$(ensure_ctl) || return 1
    BASALT_REPO_ROOT=$repo "$ctl" steam start "$profile_name" --log "$log" || return 1
    # Wait (up to 10 s) until Wine is up, so a second call right now sees Steam running.
    local i
    for i in {1..20}; do bottle_running && break; sleep 0.5; done
    print "Steam is starting. Sign in in the Steam window (the first start takes a minute). When you are done: scripts/steam.zsh stop   (log: $log)"
}

stop_steam() {
    if ! bottle_running; then
        print "Steam is not running."
        return 0
    fi
    mkdir -p "$log_dir"
    local log=$log_dir/steam-shutdown.log
    local i patience=5
    if steam_running; then
        print "Closing Steam..."
        patience=30
        # Ask Steam to exit. Cap this call at 20 s so a stuck Steam cannot hang us.
        (cd "$steam_dir" && "$wine" 'C:\Program Files (x86)\Steam\steam.exe' -shutdown \
            >"$log" 2>&1 </dev/null) &
        local asker=$!
        local waited=0
        while kill -0 $asker 2>/dev/null && (( waited < 20 )); do
            sleep 1; (( waited++ ))
        done
        kill $asker 2>/dev/null
    else
        print "Closing Wine in bottle '$bottle_name'..."
    fi
    for i in {1..$patience}; do
        bottle_running || break
        sleep 1
    done
    if bottle_running; then
        print "It did not close by itself. Stopping this bottle's Wine."
        "$wineserver" --kill >>"$log" 2>&1
        for i in {1..10}; do
            bottle_running || break
            sleep 1
        done
    fi
    if bottle_running; then
        print -u2 "Could not stop Wine for bottle '$bottle_name'. Run: WINEPREFIX='$prefix' '$wineserver' --kill"
        return 1
    fi
    # The wineserver can end a moment before its last child processes do.
    for i in {1..10}; do
        pgrep -f 'Steam\\steam\.exe|steamwebhelper|winedevice\.exe' >/dev/null 2>&1 || break
        sleep 0.5
    done
    print "Steam is closed."
}

case ${1:-start} in
    start)  start_steam ;;
    stop)   stop_steam ;;
    status) if steam_running; then print "Steam is running."; else print "Steam is not running."; fi ;;
    -h|--help|help)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        print -u2 "usage: ${0:t} [start|stop|status]"
        exit 2
        ;;
esac
