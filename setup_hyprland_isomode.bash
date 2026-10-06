#!/usr/bin/env bash
# EndeavourOS installer customization file ("user_commands.bash").
#
# In the live environment: Welcome app -> "Fetch your install customization
# file" -> paste this URL, then run an online install (choose "no desktop"):
#
#   https://raw.githubusercontent.com/ssveto/hyprland_dotfiles/main/setup_hyprland_isomode.bash
#
# Calamares runs this inside the target chroot during install. $1 = username.
set -euo pipefail

username="${1:?username argument required}"
repo_url="${REPO_URL:-https://github.com/ssveto/hyprland_dotfiles.git}"
workdir="/tmp/hyprland_dotfiles"
DRY_RUN="${DRY_RUN:-0}"
ISOMODE=1
SUDO=()
export DRY_RUN ISOMODE

echo "Installing needed packages..."
pacman -S --noconfirm --needed --disable-download-timeout git

echo "Cloning hyprland_dotfiles..."
rm -rf "$workdir"
git clone --depth 1 "$repo_url" "$workdir"
cd "$workdir"

# shellcheck source=lib/system-fixes.sh
. ./lib/system-fixes.sh
# shellcheck source=lib/deploy.sh
. ./lib/deploy.sh

deploy_desktop "$username" "$workdir"

echo "Removing the installer checkout..."
rm -rf "$workdir"
