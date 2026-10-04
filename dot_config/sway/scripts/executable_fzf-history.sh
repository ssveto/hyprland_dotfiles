#!/usr/bin/env bash
# fzf-history.sh — fuzzy shell-history picker in a floating foot window.
#
# Bound to Super+r in sway (~/.config/sway/config.d/zz-user-binds).
# Reads zsh history (plus bash history, for the migration period), lets you
# fuzzy-pick a command, then:
#
#   Enter   run the command in this window; the window stays open
#   Ctrl-y  copy the command to the Wayland clipboard and close
#   Esc     close without doing anything
set -uo pipefail

hist_list() {
    local f
    for f in "$HOME/.zsh_history" "$HOME/.bash_history"; do
        [[ -r $f ]] || continue
        # Strip zsh extended-history timestamps (": 1699999999:0;").
        sed -e 's/^: [0-9]*:[0-9]*;//' "$f"
    done | tac | awk '!seen[$0]++'   # newest first, de-duplicated
}

selected="$(
    hist_list | fzf \
        --height=100% \
        --layout=reverse \
        --border=rounded \
        --pointer='>' \
        --marker='*' \
        --prompt='History> ' \
        --scheme=history \
        --tiebreak=index \
        --header='Enter: run   Ctrl-Y: copy   Esc: cancel' \
        --preview='printf "%s\n" {}' \
        --preview-window='down:3:wrap' \
        --bind='ctrl-y:execute-silent(printf "%s" {} | wl-copy)+abort'
)"

[[ -n ${selected:-} ]] || exit 0

# Run it with the best available interactive shell so aliases/functions work.
run_shell="$(command -v zsh || command -v bash)"

printf '\033]0;fzf-history\007'    # window title (informational)
printf '\n\033[1;36m$\033[0m %s\n\n' "$selected"
"$run_shell" -ic "$selected"
status=$?

printf '\n\033[2m[exit %d] — press Enter to close\033[0m' "$status"
read -r _
