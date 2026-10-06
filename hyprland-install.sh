#!/usr/bin/env bash
# Post-install installer for the Hyprland + Noctalia desktop.
#
#   sudo ./hyprland-install.sh
#   sudo ./hyprland-install.sh --dry-run
#   sudo ./hyprland-install.sh --user someuser
#
# Deploys .config/ + home_config/ into the user's home, etc/ into /etc,
# installs packages, then applies the machine fixes (SATA/ALPM, zram, snapper).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0
username=""

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -u|--user)
            if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                echo "option $1 requires a username argument" >&2; usage; exit 2
            fi
            username="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -ne 1 ]; then
    echo "Run with sudo: sudo ./hyprland-install.sh" >&2
    exit 1
fi

if [ -z "$username" ]; then username="$(logname 2>/dev/null || true)"; fi
if [ -z "$username" ]; then username="${SUDO_USER:-}"; fi
# A root shell (e.g. after `su -`) makes logname report "root"; never deploy a
# desktop into /home/root.
if [ "$username" = "root" ]; then username=""; fi
if [ -z "$username" ]; then
    echo "Could not determine the target user; pass --user NAME." >&2
    exit 1
fi
if ! id "$username" >/dev/null 2>&1; then
    echo "No such user: $username" >&2
    exit 1
fi

SUDO=()
export DRY_RUN

# shellcheck source=lib/system-fixes.sh
. "$here/lib/system-fixes.sh"
# shellcheck source=lib/deploy.sh
. "$here/lib/deploy.sh"

deploy_desktop "$username" "$here"
