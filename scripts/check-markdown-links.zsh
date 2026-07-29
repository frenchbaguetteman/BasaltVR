#!/bin/zsh

set -euo pipefail

readonly script_dir=${0:A:h}
readonly repo_dir=${script_dir:h}
cd "$repo_dir"

documents=("${(@f)$(git ls-files --cached --others --exclude-standard -- '*.md')}")
failures=()

while IFS=$'\t' read -r document link; do
    link=${link#<}
    link=${link%>}

    case "$link" in
        ""|\#*|http://*|https://*|mailto:*|../../releases|../../releases/*)
            continue
            ;;
    esac

    link=${link%%\#*}
    link=${link%%\?*}
    [[ -n "$link" ]] || continue

    local_target="${document:h}/${link}"
    if [[ ! -e "$local_target" ]]; then
        failures+=("$document -> $link")
    fi
done < <(
    perl -ne '
        while (/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g) {
            print "$ARGV\t$1\n";
        }
    ' "${documents[@]}"
)

if (( ${#failures} > 0 )); then
    print -u2 "Broken local Markdown links:"
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi

print "PASS: ${#documents} Markdown files have valid local links"
