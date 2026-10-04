#!/usr/bin/env bash
# Regenerate the package manifests from this machine.
# Run after installing/removing packages: ./export-packages.sh && git commit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

{
    echo "# Explicitly-installed repo packages captured from this machine."
    pacman -Qqe
} > "$here/pkglist-repo.txt"

{
    echo "# Foreign/AUR packages captured from this machine."
    pacman -Qqem
} > "$here/pkglist-aur.txt"

echo "Wrote:"
echo "  $here/pkglist-repo.txt ($(grep -vc '^#' "$here/pkglist-repo.txt") packages)"
echo "  $here/pkglist-aur.txt  ($(grep -vc '^#' "$here/pkglist-aur.txt") packages)"
