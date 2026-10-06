#!/bin/bash
# Screenshot the focused monitor (Hyprland). Bound to Shift+Print.
set -euo pipefail

output="$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .name' | head -n1)"
[ -n "$output" ] || exit 0

grim -o "$output" - | swappy -f -
