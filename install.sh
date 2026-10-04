#!/usr/bin/env bash
# Restore helper for sway-dotfiles.
#
# Run this from the chezmoi source directory (the cloned repo) on a fresh
# machine to install the packages recorded on the original machine. Missing
# packages are tolerated so this also works on a non-EndeavourOS Arch install.
#
# Usage:
#   chezmoi init --apply git@github.com:<you>/sway-dotfiles.git
#   cd "$(chezmoi source-path)" && ./install.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_list="$here/pkglist-repo.txt"
aur_list="$here/pkglist-aur.txt"

if ! command -v pacman >/dev/null 2>&1; then
    echo "!! This is not an Arch-based system."
    echo "   Install the equivalents of the packages in pkglist-repo.txt manually."
    exit 0
fi

if [ -f "$repo_list" ]; then
    echo ">> Installing repo packages (missing ones are skipped)..."
    grep -v '^[[:space:]]*#' "$repo_list" | grep -v '^[[:space:]]*$' \
        | sudo pacman -S --needed --noconfirm - \
        || echo "!! Some repo packages were unavailable (expected outside EndeavourOS)."
fi

if [ -f "$aur_list" ] && grep -qv '^[[:space:]]*#' "$aur_list"; then
    helper="$(command -v yay || command -v paru || true)"
    if [ -n "$helper" ]; then
        echo ">> Installing AUR packages with $(basename "$helper")..."
        grep -v '^[[:space:]]*#' "$aur_list" | grep -v '^[[:space:]]*$' \
            | "$helper" -S --needed --noconfirm - \
            || echo "!! Some AUR packages failed to install."
    else
        echo "!! Neither yay nor paru found."
        echo "   Install an AUR helper, or install these manually:"
        grep -v '^[[:space:]]*#' "$aur_list"
    fi
fi

echo
echo "Packages done. Now apply the dotfiles (if you have not already):"
echo "    chezmoi init --apply <this-repo-url>"
echo "Then re-login to Sway."
