#!/bin/zsh
#
# Helpers for scripts/play.zsh: find out whether a game is still running after the
# executable that Basalt launched has exited. Source this file; do not run it.
#
# Why: some games start a second program and exit. The Lab's hub (TheLab.exe) starts
# Robot Repair (RobotRepair\bin\win64\vr.exe) and ends. The session must last as long
# as that program does.
#
# How: every Windows process in a bottle is a macOS process whose command line holds the
# Windows image path (the same fact scripts/steam.zsh relies on), so
# `ps -axww -o command=` is a cheap, reliable listing. A process belongs to the game
# when its image path is under the game's install folder. The match ignores the drive
# letter, the case, and the slash direction, so C:\...\steamapps\common\The Lab\x.exe,
# Z:\Users\...\drive_c\...\steamapps\common\the lab\x.exe and the host path all match.
#
#   game_find_root EXE [GAME_ROOT]    sets GAME_MARKER, GAME_NAME, GAME_EXE_REL, GAME_STRICT
#   game_processes                    prints the path of each game process, one per line
#   game_wait_for_children [PID]      waits until no game process is left
#
# Environment (all optional, mainly for tests):
#   BASALT_GAME_GRACE       seconds to wait for the child to appear (default 10)
#   BASALT_GAME_POLL        seconds between looks (default 1)
#   BASALT_GAME_GONE_POLLS  looks in a row with no game process before it counts as over (default 3)
#   BASALT_DATA_DIR, BASALT_BOTTLE   which bottle's wineserver to look for

zmodload zsh/mathfunc   # int()

# Lowercase, with / turned into \.
game_norm() {
    local s=${(L)1}
    print -r -- "${s//\//\\}"
}

# If PATH holds a steamapps\common\<Game> folder, sets GAME_MARKER and GAME_NAME from it.
_game_steam_folder() {
    local n o rest orest
    n=$(game_norm "$1"); o=${1//\//\\}
    [[ $n == *'\steamapps\common\'?* ]] || return 1
    rest=${n#*'\steamapps\common\'}
    orest=${o:$(( ${#o} - ${#rest} ))}
    GAME_NAME=${orest%%\\*}
    GAME_MARKER='steamapps\common\'${rest%%\\*}'\'
}

# Sets, from the profile's executable and its optional game root:
#   GAME_MARKER   lowercase path part that every game process contains, ends with \
#   GAME_NAME     folder name of the game, for messages
#   GAME_EXE_REL  lowercase path of EXE below the marker (the launched program), or ""
#   GAME_STRICT   1: the marker is a steamapps\common\<Game> folder (Steam is never under it)
#                 0: the marker is a plain folder, so steam*.exe programs are ignored
# Order: the steamapps\common\<Game> part of GAME_ROOT, GAME_ROOT itself, the
# steamapps\common\<Game> folder of EXE, the parent folder of EXE.
# Returns 1 when there is nothing to wait for (no root, and EXE is steam.exe).
game_find_root() {
    local exe=$1 root=${2:-} n o
    GAME_MARKER=""; GAME_NAME=""; GAME_EXE_REL=""; GAME_STRICT=1
    if [[ -n $root ]]; then
        if ! _game_steam_folder "$root"; then
            n=$(game_norm "$root"); o=${root//\//\\}
            n=${n%\\}; o=${o%\\}
            GAME_MARKER=$n'\'
            GAME_NAME=${o##*\\}
            GAME_STRICT=0
        fi
    elif ! _game_steam_folder "$exe"; then
        n=$(game_norm "$exe"); o=${exe//\//\\}
        [[ ${n##*\\} == steam.exe || $n != *\\* ]] && return 1
        GAME_MARKER=${n%\\*}'\'
        o=${o%\\*}
        GAME_NAME=${o##*\\}
        GAME_STRICT=0
    fi
    n=$(game_norm "$exe")
    if [[ $n == *"$GAME_MARKER"* ]]; then
        GAME_EXE_REL=${n#*"$GAME_MARKER"}
    fi
    return 0
}

# Prints the image path (below the game folder) of every running Windows program that
# lives in the game folder, except the program Basalt launched and, for a plain
# folder, Steam's own programs.
game_processes() {
    local line l ll before after lafter rel
    [[ -n ${GAME_MARKER:-} ]] || return 0
    ps -axww -o command= 2>/dev/null | while IFS= read -r line; do
        l=${line//\//\\}; ll=${(L)l}
        [[ $ll == *"$GAME_MARKER"* ]] || continue
        before=${ll%%"$GAME_MARKER"*}
        after=${l:$(( ${#before} + ${#GAME_MARKER} ))}
        lafter=${(L)after}
        [[ $lafter == *.exe* ]] || continue
        rel=${after:0:$(( ${#${lafter%%.exe*}} + 4 ))}
        [[ ${(L)rel} == $GAME_EXE_REL ]] && continue
        if (( ! GAME_STRICT )) && [[ ${(L)${rel##*\\}} == steam* ]]; then continue; fi
        print -r -- "$rel"
    done
}

# True while this bottle's wineserver is alive (it ends soon after the last Windows
# process in the bottle ends). The path holds the bottle's own engine folder.
game_bottle_alive() {
    local dir=${BASALT_DATA_DIR:-$HOME/Library/Application Support/BasaltVR}/Bottles/${BASALT_BOTTLE:-pcvr}
    pgrep -f "${dir}/engine/.*/wineserver" >/dev/null 2>&1
}

# Call after the launched program ended. Waits up to BASALT_GAME_GRACE seconds for a
# game process to show up; if one does, prints one line and waits until none is left.
# Returns 0 when the game is over (or never started anything else) and 3 when the
# streamer (PID, optional) stopped while waiting. Sets GAME_CHILD_SEEN=1 if a child ran.
game_wait_for_children() {
    local streamer_pid=${1:-} grace=${BASALT_GAME_GRACE:-10} poll=${BASALT_GAME_POLL:-1}
    local gone_needed=${BASALT_GAME_GONE_POLLS:-3} polls found="" i gone=0
    GAME_CHILD_SEEN=0
    (( polls = int(grace / poll) + 1 ))
    for (( i = 0; i < polls; i++ )); do
        game_bottle_alive || return 0
        found=$(game_processes | head -n 1)
        [[ -n $found ]] && break
        sleep $poll
    done
    [[ -n $found ]] || return 0
    GAME_CHILD_SEEN=1
    print -r -- "$GAME_NAME started $found; still running."
    while (( gone < gone_needed )); do
        if [[ -n $streamer_pid ]] && ! kill -0 $streamer_pid 2>/dev/null; then
            return 3
        fi
        if game_bottle_alive && [[ -n $(game_processes | head -n 1) ]]; then
            gone=0
        else
            (( gone++ ))
        fi
        sleep $poll
    done
    return 0
}
