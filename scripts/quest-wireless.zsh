#!/bin/zsh
#
# Use the Quest without the USB cable (adb over Wi-Fi).
#
#   scripts/quest-wireless.zsh            plugged in: turn on adb over Wi-Fi.
#                                         not plugged in: reconnect to the saved IP.
#   scripts/quest-wireless.zsh status     show what adb sees and the saved IP
#   scripts/quest-wireless.zsh --ip 10.0.0.5   reconnect to this IP (and save it)
#
# One time (and after every Quest reboot): plug the Quest in by USB and run this
# script. It runs `adb tcpip 5555`, reads the Quest Wi-Fi (wlan0) IP, connects, and
# saves the IP in ~/Library/Application Support/BasaltVR/quest-ip.
# Later, without the cable, run it again. It runs `adb connect <saved ip>:5555`.
#
# The Quest drops adb-over-Wi-Fi when it reboots. Then plug in once and run this again.
# If your router gives the Quest a new IP, do the same, or pass --ip.
#
# Environment (optional): BASALT_DATA_DIR, BASALT_QUEST_PORT (default 5555)

set -uo pipefail

readonly script_dir=${0:A:h}
source "$script_dir/quest-adb.zsh"
readonly port=${BASALT_QUEST_PORT:-5555}

action=auto
ip_override=""
while (( $# > 0 )); do
    case $1 in
        status) action=status ;;
        --ip)
            shift
            ip_override=${1:-}
            if [[ $ip_override != <->.<->.<->.<-> ]]; then
                print -u2 "--ip needs an address like 192.168.1.20"
                exit 2
            fi
            ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

quest_find_adb || exit 1

list_devices() { "$QUEST_ADB" devices -l 2>/dev/null | sed '/^$/d'; }

saved_ip=""
[[ -r $QUEST_IP_FILE ]] && saved_ip=$(<"$QUEST_IP_FILE")

save_ip() {
    mkdir -p "${QUEST_IP_FILE:h}" && print -r -- "$1" >"$QUEST_IP_FILE"
}

# Connect to ip:port and check that adb reports state "device" (quest-adb.zsh).
connect_ip() { quest_connect_ip "$1" "$port"; }

print_status() {
    print "adb devices:"
    list_devices | sed 's/^/  /'
    print "Saved Quest IP: ${saved_ip:-none} ($QUEST_IP_FILE)"
    quest_pick_serial
    case $? in
        0) print "Scripts will use: $QUEST_SERIAL ($QUEST_LINK)"; print "Why: $QUEST_REASON" ;;
        2) print "The Quest asks for permission. Put it on and tap Allow for USB debugging." ;;
        *) print "No usable Quest right now." ;;
    esac
}

if [[ $action == status ]]; then
    print_status
    exit 0
fi

# Reconnect without the cable.
reconnect() {
    local ip=${ip_override:-$saved_ip}
    if [[ -z $ip ]]; then
        print -u2 "I do not know the Quest IP yet. Plug the Quest in with the USB cable and run this command again."
        return 1
    fi
    if connect_ip "$ip"; then
        save_ip "$ip"
        print "Connected over Wi-Fi: $ip:$port. You can unplug the cable."
        return 0
    fi
    print -u2 "I could not connect to $ip:$port."
    print -u2 "If the Quest was restarted, or the router gave it a new IP: plug it in with the USB cable and run this command again."
    return 1
}

if [[ -n $ip_override ]]; then
    reconnect
    exit $?
fi

# Is a USB Quest plugged in? Then (re)enable adb over Wi-Fi.
quest_pick_serial_retry
pick=$?
if (( pick == 2 )); then
    print -u2 "The Quest asks for permission. Put it on and tap Allow for USB debugging. Then run this command again."
    exit 1
fi
if (( pick == 0 )) && [[ $QUEST_LINK == usb ]]; then
    usb_serial=$QUEST_SERIAL
    ip=$("$QUEST_ADB" -s "$usb_serial" shell ip -f inet addr show wlan0 2>/dev/null \
        | tr -d '\r' | sed -n 's/^ *inet \([0-9.]*\)\/.*/\1/p' | head -n 1)
    if [[ -z $ip ]]; then
        print -u2 "I cannot read the Quest Wi-Fi address. Turn on Wi-Fi in the Quest, join the same network as this Mac, and run this command again."
        exit 1
    fi
    print "Quest Wi-Fi address: $ip"
    if ! "$QUEST_ADB" -s "$usb_serial" tcpip "$port" >/dev/null 2>&1; then
        print -u2 "adb tcpip $port failed."
        exit 1
    fi
    # adb restarts on the Quest. Give it a moment, then connect.
    ok=0
    for attempt in 1 2 3 4 5 6; do
        sleep 1
        if connect_ip "$ip" 2>/dev/null; then ok=1; break; fi
    done
    if (( ! ok )); then
        print -u2 "Wi-Fi adb did not come up at $ip:$port. Check that the Mac and the Quest are on the same network."
        exit 1
    fi
    save_ip "$ip"
    print "adb over Wi-Fi is on: $ip:$port. Saved in $QUEST_IP_FILE."
    print "You can unplug the cable now. The Quest forgets this when it restarts; then plug in once and run this again."
    exit 0
fi

# No USB Quest: reconnect from the saved IP (or tell the user the Wi-Fi link is already up).
if (( pick == 0 )) && [[ $QUEST_LINK == wifi ]]; then
    print "Already connected over Wi-Fi: $QUEST_SERIAL."
    exit 0
fi
reconnect
