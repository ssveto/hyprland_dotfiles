#!/bin/bash
# Screenshot the focused window (Hyprland). Bound to Ctrl+Print.
set -euo pipefail

geom="$(hyprctl -j activewindow \
    | jq -r 'select(.at != null) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')"

[ -n "$geom" ] || exit 0

grim -g "$geom" - | swappy -f -
