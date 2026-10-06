#!/usr/bin/env bash
# bootstrap-arch.sh — set up this Hyprland + Noctalia desktop on a fresh Arch
# install, and apply the SATA/ALPM + zram fixes this machine needs.
#
# Safe and idempotent: re-running only changes what has drifted, and every file
# it modifies is first copied to
#     /var/tmp/opencode-fixes/backup-<timestamp>/
#
# Run it as your normal user (it calls sudo where needed):
#
#   git clone https://github.com/ssveto/hyprland_dotfiles.git ~/.local/share/chezmoi
#   cd ~/.local/share/chezmoi && ./bootstrap-arch.sh
#
#   # ...or clone anywhere and point the script at the repo:
#   ./bootstrap-arch.sh --repo https://github.com/ssveto/hyprland_dotfiles.git
#
# Options:
#   -r, --repo URL      chezmoi repo to clone + apply (default: run from source)
#       --dry-run       show what would change; write nothing
#       --skip-storage  skip the kernel cmdline / udev / swappiness fixes
#       --storage-only  only run the storage fixes, then exit
#       --skip-packages skip package installation
#       --skip-aur      skip AUR helper + AUR packages
#       --no-upgrade    do not run a full `pacman -Syu` first
#   -y, --yes           non-interactive pacman (--noconfirm)
#   -h, --help          show this help
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

REPO_URL=""
DRY_RUN=0
SKIP_STORAGE=0
STORAGE_ONLY=0
SKIP_PACKAGES=0
SKIP_AUR=0
DO_UPGRADE=1
ASSUME_YES=0

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--repo)      REPO_URL="${2:-}"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --skip-storage) SKIP_STORAGE=1; shift ;;
        --storage-only) STORAGE_ONLY=1; shift ;;
        --skip-packages) SKIP_PACKAGES=1; shift ;;
        --skip-aur)     SKIP_AUR=1; shift ;;
        --no-upgrade)   DO_UPGRADE=0; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) warn "unknown option: $1"; usage; exit 2 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    warn "Run this as your normal user (it uses sudo when needed), not as root."
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo is required."
    exit 1
fi
SUDO=(sudo)

CONFIRM=()
if [ "$ASSUME_YES" -eq 1 ]; then CONFIRM=(--noconfirm); fi

if [ ! -f /etc/arch-release ]; then
    warn "This does not look like an Arch-based system (/etc/arch-release missing)."
    warn "Continuing anyway — package steps may fail."
fi

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="/var/tmp/opencode-fixes/backup-$STAMP"
BK_READY=0

ensure_bk() {
    if [ "$BK_READY" -eq 0 ]; then
        [ "$DRY_RUN" -eq 1 ] || "${SUDO[@]}" mkdir -p "$BK"
        BK_READY=1
        note "backups -> $BK"
    fi
}

backup_file() {
    local p="$1"
    [ -e "$p" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    ensure_bk
    local name
    name="$(printf '%s' "$p" | sed 's#^/##; s#/#_#g')"
    "${SUDO[@]}" cp -a "$p" "$BK/$name" 2>/dev/null || true
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Write $1 from stdin, backing it up first.
write_root_file() {
    local path="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] write $path"
        cat >/dev/null
        return 0
    fi
    backup_file "$path"
    "${SUDO[@]}" tee "$path" >/dev/null
}

# ---------------------------------------------------------------------------
# Storage / SATA ALPM + zram fixes
# ---------------------------------------------------------------------------
STORAGE_FIX() {
    say "Storage / SATA ALPM fixes"

    local cmdline_file="/etc/kernel/cmdline"
    local grub_file="/etc/default/grub"
    local udev_rule="/etc/udev/rules.d/69-sata-alpm.rules"
    local sysctl_file="/etc/sysctl.d/99-swappiness.conf"
    local param="ahci.mobile_lpm_policy=1"
    local cmdline_changed=0

    # 1) Kernel command line ------------------------------------------------
    # 1 = "maximum performance". 0 would mean "keep firmware settings", and this
    # box's firmware already forces med_power_with_dipm, so 0 would not help.
    if [ -f "$cmdline_file" ]; then
        local cur
        cur="$("${SUDO[@]}" cat "$cmdline_file")"
        if printf '%s' "$cur" | grep -qE 'ahci\.mobile_lpm_policy=1( |$)'; then
            note "kernel cmdline already has $param — skipping"
        elif printf '%s' "$cur" | grep -qE 'ahci\.mobile_lpm_policy='; then
            note "replacing existing ahci.mobile_lpm_policy with 1"
            backup_file "$cmdline_file"
            run "${SUDO[@]}" sed -i -E 's/ahci\.mobile_lpm_policy=[0-9]+/ahci.mobile_lpm_policy=1/' "$cmdline_file"
            cmdline_changed=1
        else
            note "appending $param to $cmdline_file"
            backup_file "$cmdline_file"
            # The file is a single line with no trailing newline.
            printf ' %s' "$param" | { if [ "$DRY_RUN" -eq 1 ]; then cat >/dev/null; else "${SUDO[@]}" tee -a "$cmdline_file" >/dev/null; fi; }
            cmdline_changed=1
        fi
    elif [ -f "$grub_file" ]; then
        if "${SUDO[@]}" grep -qE "$param" "$grub_file"; then
            note "GRUB cmdline already has $param — skipping"
        else
            note "adding $param to GRUB_CMDLINE_LINUX_DEFAULT"
            backup_file "$grub_file"
            run "${SUDO[@]}" sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $param\"/" "$grub_file"
            cmdline_changed=1
        fi
    else
        warn "No /etc/kernel/cmdline or /etc/default/grub found."
        warn "Add '$param' to your bootloader command line manually."
    fi

    # 2) udev rule: force max_performance on hotplug / resume -----------------
    if [ -f "$udev_rule" ] && "${SUDO[@]}" grep -q 'link_power_management_policy.*max_performance' "$udev_rule"; then
        note "udev rule already present — skipping"
    else
        note "writing $udev_rule"
        write_root_file "$udev_rule" <<'EOF'
# Force SATA LPM to max_performance to prevent ALPM link dropouts/freezes.
# Skips USB hosts (DEVPATH /usb) and AHCI dummy ports (supported==0) to avoid noise.
ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ENV{DEVPATH}!="*usb*", ATTR{link_power_management_supported}=="1", ATTR{link_power_management_policy}="max_performance"
EOF
    fi

    # 3) swappiness: swap here is zram-only, so a high value is appropriate ----
    if [ -f "$sysctl_file" ] && "${SUDO[@]}" grep -qE '^vm\.swappiness=100[[:space:]]*$' "$sysctl_file"; then
        note "vm.swappiness already 100 — skipping"
    else
        note "setting vm.swappiness=100 (zram-backed swap)"
        write_root_file "$sysctl_file" <<'EOF'
# Swap is zram-only on this machine, so prefer fast compressed RAM swap.
vm.swappiness=100
EOF
    fi

    # 4) zram swap: the machine's only swap is zram, so swappiness=100 above
    #    is meaningful only once this config exists.
    local zram_conf="/etc/systemd/zram-generator.conf"
    if [ -f "$zram_conf" ] && "${SUDO[@]}" grep -qE '^\[zram0\]' "$zram_conf"; then
        note "zram-generator already configured — skipping"
    else
        note "writing $zram_conf"
        write_root_file "$zram_conf" <<'EOF'
# Compressed RAM swap. zram-size = min(ram/2, 4096) -> 4 GiB on an 8 GiB box.
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF
    fi

    # 5) Apply what can be applied at runtime --------------------------------
    say "Applying udev + sysctl at runtime"
    run "${SUDO[@]}" udevadm control --reload-rules
    run "${SUDO[@]}" udevadm trigger --subsystem-match=scsi_host --action=add
    run "${SUDO[@]}" sysctl --system

    # 6) Regenerate boot entries if the cmdline changed ----------------------
    if [ "$cmdline_changed" -eq 1 ]; then
        if command -v reinstall-kernels >/dev/null 2>&1; then
            say "Regenerating boot entries (reinstall-kernels)"
            run "${SUDO[@]}" reinstall-kernels || warn "reinstall-kernels failed"
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            say "Regenerating GRUB config"
            run "${SUDO[@]}" grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed"
        else
            warn "Cmdline changed but no boot-entry regenerator found; reboot manually."
        fi
    fi

    say "Verification (runtime)"
    note "cmdline file : $([ -f "$cmdline_file" ] && "${SUDO[@]}" cat "$cmdline_file" || echo n/a)"
    note "swappiness   : $(cat /proc/sys/vm/swappiness)"
    local h
    for h in /sys/class/scsi_host/host*/link_power_management_policy; do
        if [ -r "$h" ]; then note "$(basename "$(dirname "$h")") = $(cat "$h")"; fi
    done
    note "The cmdline param takes effect after a reboot."
}

# ---------------------------------------------------------------------------
# zram activation (run after zram-generator is installed)
# ---------------------------------------------------------------------------
activate_zram() {
    if ! pacman -Qq zram-generator >/dev/null 2>&1; then
        note "zram-generator not installed yet; it will activate after packages are installed"
        return 0
    fi
    say "Activating zram swap"
    run "${SUDO[@]}" systemctl daemon-reload
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] systemctl start systemd-zram-setup@zram0.service"
    else
        "${SUDO[@]}" systemctl start systemd-zram-setup@zram0.service 2>/dev/null \
            || note "zram unit did not start now; it will come up on next boot"
    fi
    note "swap devices:"
    swapon --show 2>/dev/null | sed 's/^/      /' || true
}

# ---------------------------------------------------------------------------
# btrfs snapshots (only when / is btrfs)
# ---------------------------------------------------------------------------
configure_btrfs_snapshots() {
    local rootfs
    rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
    if [ "$rootfs" != "btrfs" ]; then
        note "root filesystem is ${rootfs:-unknown}, not btrfs — skipping snapshot setup"
        return 0
    fi
    if ! pacman -Qq snapper >/dev/null 2>&1; then
        note "snapper not installed; skipping snapshot setup"
        return 0
    fi

    say "Configuring btrfs snapshots (snapper)"

    # 1) config + /.snapshots. The install-time flat layout (@ + @snapshots)
    #    means /.snapshots already exists as its own subvolume.
    if [ -f /etc/snapper/configs/root ]; then
        note "snapper 'root' config already exists — skipping creation"
    else
        if ! run "${SUDO[@]}" snapper -c root create-config /; then
            warn "snapper create-config failed; falling back to the default template"
            run "${SUDO[@]}" mkdir -p /etc/snapper/configs
            run "${SUDO[@]}" cp /etc/snapper/config-templates/default /etc/snapper/configs/root
            run "${SUDO[@]}" sed -i 's#^SUBVOLUME=.*#SUBVOLUME="/"#' /etc/snapper/configs/root
        fi
    fi

    # 2) retention so snapshots can never fill the SSD
    backup_file /etc/snapper/configs/root
    local kv
    for kv in \
        TIMELINE_CREATE=yes \
        TIMELINE_LIMIT_HOURLY=5 \
        TIMELINE_LIMIT_DAILY=7 \
        TIMELINE_LIMIT_WEEKLY=4 \
        TIMELINE_LIMIT_MONTHLY=2 \
        TIMELINE_LIMIT_YEARLY=0 \
        NUMBER_CLEANUP=yes \
        NUMBER_LIMIT=20 \
        NUMBER_LIMIT_IMPORTANT=10 \
        SPACE_LIMIT=0.3 \
        FREE_LIMIT=0.2
    do
        run "${SUDO[@]}" snapper -c root set-config "$kv"
    done

    # 3) timeline + cleanup timers (snap-pac's pacman hooks need no timer)
    run "${SUDO[@]}" systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

    # 4) btrfs scrub; trim is left to fstrim.timer
    if pacman -Qq btrfsmaintenance >/dev/null 2>&1; then
        if [ -f /etc/default/btrfsmaintenance ] \
           && ! "${SUDO[@]}" grep -q '^BTRFS_TRIM_PERIOD="none"' /etc/default/btrfsmaintenance; then
            backup_file /etc/default/btrfsmaintenance
            run "${SUDO[@]}" sed -i 's/^BTRFS_TRIM_PERIOD=.*/BTRFS_TRIM_PERIOD="none"/' /etc/default/btrfsmaintenance
        fi
        run "${SUDO[@]}" systemctl enable --now btrfs-scrub.timer
    fi

    # 5) snapper-rollback needs the flat layout (@ + @snapshots)
    if pacman -Qq snapper-rollback >/dev/null 2>&1; then
        local dev
        dev="$(findmnt -no SOURCE / 2>/dev/null || true)"
        if [ -n "$dev" ]; then
            write_root_file /etc/snapper-rollback.conf <<EOF
# Roll back with:  sudo snapper-rollback <snapid>
[root]
subvol_main = @
subvol_snapshots = @snapshots
mountpoint = /btrfsroot
dev = $dev
EOF
        else
            write_root_file /etc/snapper-rollback.conf <<'EOF'
[root]
subvol_main = @
subvol_snapshots = @snapshots
mountpoint = /btrfsroot
EOF
        fi
    fi

    note "snapshots:"
    snapper -c root list 2>/dev/null | tail -n 5 | sed 's/^/      /' || true
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
install_packages() {
    say "Refreshing package databases"
    run "${SUDO[@]}" pacman -Sy "${CONFIRM[@]}"

    if [ "$DO_UPGRADE" -eq 1 ]; then
        say "Upgrading the system (skip with --no-upgrade)"
        run "${SUDO[@]}" pacman -Su "${CONFIRM[@]}" || warn "system upgrade reported errors"
    fi

    say "Installing repo packages"
    declare -A HAVE=()
    while read -r a; do if [ -n "$a" ]; then HAVE["$a"]=1; fi; done < <(pacman -Slq 2>/dev/null)
    # Groups (base, base-devel) are installable but are not listed by -Slq.
    local g
    for g in base base-devel; do
        if pacman -Sgq "$g" >/dev/null 2>&1; then HAVE["$g"]=1; fi
    done

    local install_list=() skip_list=()
    local p
    while read -r p; do
        case "$p" in ''|\#*) continue ;; esac
        if [ -n "${HAVE[$p]:-}" ]; then install_list+=("$p"); else skip_list+=("$p"); fi
    done < "$here/pkglist-repo.txt"

    if [ "${#skip_list[@]}" -gt 0 ]; then
        note "not in the official repos (skipped): ${skip_list[*]}"
    fi
    if [ "${#install_list[@]}" -gt 0 ]; then
        run "${SUDO[@]}" pacman -S --needed "${CONFIRM[@]}" "${install_list[@]}"
    else
        note "nothing to install"
    fi

    # AUR ---------------------------------------------------------------------
    if [ "$SKIP_AUR" -eq 1 ]; then
        note "AUR step skipped (--skip-aur)"
        return 0
    fi
    local aur_file="$here/pkglist-aur.txt"
    [ -f "$aur_file" ] || return 0
    local aur_pkgs=()
    while read -r p; do
        case "$p" in ''|\#*) continue ;; esac
        aur_pkgs+=("$p")
    done < "$aur_file"
    [ "${#aur_pkgs[@]}" -gt 0 ] || return 0

    local helper
    helper="$(command -v yay || command -v paru || true)"
    if [ -z "$helper" ]; then
        say "Bootstrapping yay (AUR helper)"
        run "${SUDO[@]}" pacman -S --needed "${CONFIRM[@]}" base-devel git
        local tmp; tmp="$(mktemp -d)"
        run git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp/yay"
        if [ "$DRY_RUN" -eq 1 ]; then
            note "[dry-run] build + install yay, then: yay -S --needed ${aur_pkgs[*]}"
            return 0
        fi
        ( cd "$tmp/yay" && makepkg -si --noconfirm )
        helper="$(command -v yay || true)"
        rm -rf "$tmp"
    fi

    if [ -n "$helper" ]; then
        say "Installing AUR packages with $(basename "$helper")"
        run "$helper" -S --needed "${CONFIRM[@]}" "${aur_pkgs[@]}" || warn "some AUR packages failed"
    else
        warn "No AUR helper available; install manually: ${aur_pkgs[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Dotfiles (chezmoi)
# ---------------------------------------------------------------------------
apply_dotfiles() {
    say "Installing dotfiles with chezmoi"
    if ! command -v chezmoi >/dev/null 2>&1; then
        run "${SUDO[@]}" pacman -S --needed "${CONFIRM[@]}" chezmoi
    fi

    local default_source="${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi"

    if [ -n "$REPO_URL" ]; then
        run chezmoi init --apply "$REPO_URL"
        return 0
    fi

    if [ ! -d "$here/dot_config" ]; then
        warn "Not a chezmoi source tree. Pass --repo URL or run from the cloned repo."
        return 1
    fi

    local src_args=()
    [ "$here" = "$default_source" ] || src_args=(--source "$here")

    if [ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
        run chezmoi "${src_args[@]}" init
    fi
    run chezmoi "${src_args[@]}" apply --force
}

# ---------------------------------------------------------------------------
# Login manager (greetd + ReGreet)
# ---------------------------------------------------------------------------
configure_greetd() {
    if ! pacman -Qq greetd >/dev/null 2>&1; then
        warn "greetd is not installed; skipping login-manager setup."
        return 0
    fi
    say "Configuring greetd + ReGreet"

    write_root_file /etc/greetd/config.toml <<'EOF'
[terminal]
# The VT to run the greeter on.
vt = 1

[default_session]
# ReGreet reads its own settings from /etc/greetd/regreet.toml
command = "regreet"
user = "greeter"
EOF

    if pacman -Qq greetd-regreet >/dev/null 2>&1; then
        write_root_file /etc/greetd/regreet.toml <<'EOF'
# ReGreet configuration (see https://github.com/rharish101/ReGreet)

[env]
XDG_SESSION_TYPE = "wayland"
XDG_CURRENT_DESKTOP = "Hyprland"
XDG_SESSION_DESKTOP = "Hyprland"
MOZ_ENABLE_WAYLAND = "1"
OZONE_PLATFORM = "wayland"
GDK_BACKEND = "wayland"
QT_QPA_PLATFORM = "wayland"

[GTK]
application_prefer_dark_theme = true
cursor_theme_name = "Qogir-dark"
font_name = "Inter 11"
icon_theme_name = "Papirus-Dark"
theme_name = "adw-gtk3-dark"

[commands]
reboot = [ "systemctl", "reboot" ]
poweroff = [ "systemctl", "poweroff" ]

[appearance]
greeting_msg = "Welcome Back!"
EOF
    fi

    # greetd drops privileges to `greeter`; make sure the account exists.
    if ! id greeter >/dev/null 2>&1; then
        note "creating the 'greeter' system user"
        run "${SUDO[@]}" useradd -r -M -d /var/lib/greeter -s /usr/bin/nologin -c "Greeter user" greeter
    fi

    run "${SUDO[@]}" systemctl enable greetd.service
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$SKIP_STORAGE" -eq 0 ]; then STORAGE_FIX; fi
if [ "$STORAGE_ONLY" -eq 1 ]; then activate_zram; exit 0; fi

if [ "$SKIP_PACKAGES" -eq 0 ]; then
    install_packages
else
    note "package installation skipped (--skip-packages)"
fi

activate_zram
configure_btrfs_snapshots

apply_dotfiles || warn "dotfiles step failed"

configure_greetd

say "Enabling the user before-sleep lock unit"
if [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] systemctl --user enable noctalia-lock-on-suspend.service"
else
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable noctalia-lock-on-suspend.service 2>/dev/null \
        || note "could not enable the user unit now; run: systemctl --user enable noctalia-lock-on-suspend.service"
fi

say "Done"
cat <<'EOF'
    Next steps:
      1. Reboot (the kernel cmdline change needs it).
      2. At the ReGreet login screen, pick "Hyprland".
      3. Verify storage after reboot:
           grep -o 'ahci.mobile_lpm_policy=[0-9]*' /proc/cmdline
           cat /sys/class/scsi_host/host*/link_power_management_policy

    If anything is wrong, the originals are under:
EOF
printf '      %s\n' "$BK"
