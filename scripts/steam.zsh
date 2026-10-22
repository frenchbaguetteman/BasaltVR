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

# Prints the PID of every Wine process of this bottle, also of those that outlived their
# wineserver (it can crash while it stops Steam, and then `wineserver --kill` finds
# nothing). The same rule as WineProcessOwnership in the app: the process holds a file in
# the prefix's server folder /tmp/.wine-UID/server-DEV-INODE (device and inode of the
# prefix, in hex), or it holds a file in the prefix and maps this bottle's engine.
# Spotlight, editors and shells in the prefix never match.
bottle_pids() {
    [[ -d $prefix ]] || return 0
    local -a id
    id=(${(z)"$(stat -f '%d %i' "$prefix")"})
    local server_dir
    server_dir=$(printf '/private/tmp/.wine-%d/server-%x-%x/' $UID ${id[1]} ${id[2]})
    lsof -n -P -w -F pn -u $UID 2>/dev/null | awk -v sd="$server_dir" -v pf="$prefix/" \
        -v en="$bottle_dir/engine/" -v self=$$ '
        /^p/ { pid = substr($0, 2); if (!(pid in seen)) { seen[pid] = 1; order[++n] = pid }; next }
        /^n/ {
            name = substr($0, 2) "/"
            if (index(name, sd) == 1) server[pid] = 1
            if (index(name, pf) == 1) inprefix[pid] = 1
            if (index(name, en) == 1) engine[pid] = 1
        }
        END {
            for (i = 1; i <= n; i++) {
                p = order[i]
                if (p <= 1 || p == self) continue
                if ((p in server) || ((p in inprefix) && (p in engine))) print p
            }
        }'
}

# Ends the Wine processes of this bottle that are still there: TERM, then KILL after 2 s.
kill_leftovers() {
    local -a pids
    pids=(${(f)"$(bottle_pids)"})
    (( ${#pids} )) || return 0
    print "Ending ${#pids} Wine processes left in bottle '$bottle_name'."
    kill -TERM $pids 2>/dev/null
    local i p
    for i in {1..20}; do
        for p in $pids; do kill -0 $p 2>/dev/null && break; p=""; done
        [[ -z $p ]] && return 0
        sleep 0.1
    done
    kill -KILL $pids 2>/dev/null
    return 0
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
# BASALT_BIN_DIR (set by play.zsh and the BasaltVR app) names the folder that holds
# basaltctl. A packaged app has no sources, so nothing is built there.
ensure_ctl() {
    local ctl=${BASALT_BIN_DIR:-$repo/streamer/.build/release}/basaltctl
    local can_build=0
    [[ -f $repo/streamer/Package.swift && -f $repo/runtime/CMakeLists.txt ]] && can_build=1
    if [[ ! -x $ctl ]]; then
        if (( ! can_build )); then
            print -u2 "basaltctl is missing: $ctl"
            return 1
        fi
        print -u2 "Building basaltctl. This happens one time."
        swift build -c release --package-path "$repo/streamer" --product basaltctl >&2 || return 1
        ctl=$repo/streamer/.build/release/basaltctl
    fi
    if [[ ! -f $repo/runtime/build/bin/steamwebhelper_compat.exe ]]; then
        if (( ! can_build )); then
            print -u2 "The Steam web helper shim is missing: $repo/runtime/build/bin/steamwebhelper_compat.exe"
            return 1
        fi
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
        if [[ -n $(bottle_pids) ]]; then
            kill_leftovers
            print "Steam is closed."
        else
            print "Steam is not running."
        fi
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
        [[ -n $(bottle_pids) ]] || break
        sleep 0.5
    done
    kill_leftovers
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
