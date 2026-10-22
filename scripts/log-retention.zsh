#!/bin/zsh
#
# Delete old BasaltVR logs. Source this file; do not run it.
#
#   source "$script_dir/log-retention.zsh"
#   basalt_prune_logs "$HOME/Library/Logs/BasaltVR"    # keeps the last 7 days
#
# Only regular files directly in that folder, and only with a BasaltVR log name
# (quest-*, streamer-*, runtime-*, game-*, steam-*, app-*, or *.log), are
# deleted when they were last changed more than BASALT_LOG_KEEP_DAYS (default 7)
# days ago. Subfolders and symbolic links are never touched. The app does the
# same for its app-*.log files: BasaltManagerKit/LogRetention.swift.

basalt_prune_logs() {
    local dir=$1 days=${BASALT_LOG_KEEP_DAYS:-7}
    [[ -n $dir && -d $dir && ! -L $dir ]] || return 0
    [[ $days == <1-> ]] || return 0
    /usr/bin/find "$dir" -mindepth 1 -maxdepth 1 -type f \
        \( -name 'quest-*' -o -name 'streamer-*' -o -name 'runtime-*' -o -name 'game-*' \
           -o -name 'steam-*' -o -name 'app-*' -o -name '*.log' \) \
        -mmin +$(( days * 24 * 60 )) -delete 2>/dev/null
    return 0
}
