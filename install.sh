#!/usr/bin/env bash
# install.sh — thin wrapper kept for muscle memory.
#
# This repository's full setup (packages, SATA/ALPM + zram fixes, dotfiles,
# greetd/ReGreet) now lives in bootstrap-arch.sh. All arguments are forwarded,
# so `./install.sh --skip-storage` still works.
#
# Usage:
#   cd "$(chezmoi source-path)" && ./bootstrap-arch.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/bootstrap-arch.sh" "$@"
