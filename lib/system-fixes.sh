# shellcheck shell=bash
# Shared, idempotent system fixes for this machine, sourced by the install
# scripts *after* packages are installed. Static /etc files are deployed by the
# caller (rsync of etc/); this handles the parts that must run commands:
#   - ahci.mobile_lpm_policy=1 on the kernel cmdline (+ reinstall-kernels)
#   - reload udev rules + sysctl
#   - activate zram
#   - provision snapper btrfs snapshots
#
# Caller may set DRY_RUN=1. Everything touched under /etc is copied to
# /var/tmp/opencode-fixes/backup-<timestamp>/ first.

: "${DRY_RUN:=0}"
if ! declare -p SUDO >/dev/null 2>&1; then
    SUDO=()
fi
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
BK="${BK:-/var/tmp/opencode-fixes/backup-$STAMP}"
BK_READY="${BK_READY:-0}"

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }

ensure_bk() {
    if [ "$BK_READY" -eq 0 ]; then
        if [ "$DRY_RUN" -ne 1 ]; then "${SUDO[@]}" mkdir -p "$BK"; fi
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

# ---------------------------------------------------------------------------
cmdline_fix() {
    local cmdline_file="/etc/kernel/cmdline"
    local grub_file="/etc/default/grub"
    local param="ahci.mobile_lpm_policy=1"
    CMDLINE_CHANGED=0

    # 1 = "maximum performance". 0 would mean "keep firmware settings", and this
    # box's firmware already forces med_power_with_dipm, so 0 would not help.
    if [ -f "$cmdline_file" ]; then
        local cur
        cur="$(cat "$cmdline_file")"
        if printf '%s' "$cur" | grep -qE 'ahci\.mobile_lpm_policy=1( |$)'; then
            note "kernel cmdline already has $param — skipping"
        elif printf '%s' "$cur" | grep -qE 'ahci\.mobile_lpm_policy='; then
            note "replacing existing ahci.mobile_lpm_policy with 1"
            backup_file "$cmdline_file"
            run "${SUDO[@]}" sed -i -E 's/ahci\.mobile_lpm_policy=[0-9]+/ahci.mobile_lpm_policy=1/' "$cmdline_file"
            CMDLINE_CHANGED=1
        else
            note "appending $param to $cmdline_file"
            backup_file "$cmdline_file"
            if [ "$DRY_RUN" -eq 1 ]; then
                note "[dry-run] append '$param'"
            else
                printf ' %s' "$param" >> "$cmdline_file"
            fi
            CMDLINE_CHANGED=1
        fi
    elif [ -f "$grub_file" ]; then
        if grep -qE "$param" "$grub_file"; then
            note "GRUB cmdline already has $param — skipping"
        else
            note "adding $param to GRUB_CMDLINE_LINUX_DEFAULT"
            backup_file "$grub_file"
            run "${SUDO[@]}" sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $param\"/" "$grub_file"
            CMDLINE_CHANGED=1
        fi
    else
        warn "No /etc/kernel/cmdline or /etc/default/grub; add '$param' manually."
    fi

    if [ "$CMDLINE_CHANGED" -eq 1 ]; then
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
}

# ---------------------------------------------------------------------------
zram_activate() {
    if ! pacman -Qq zram-generator >/dev/null 2>&1; then
        note "zram-generator not installed; skipping activation"
        return 0
    fi
    say "Activating zram swap"
    run "${SUDO[@]}" systemctl daemon-reload || true
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] systemctl start systemd-zram-setup@zram0.service"
    else
        systemctl start systemd-zram-setup@zram0.service 2>/dev/null \
            || note "zram will come up on next boot"
    fi
    note "swap devices:"
    swapon --show 2>/dev/null | sed 's/^/      /' || true
}

# ---------------------------------------------------------------------------
snapper_configure() {
    local rootfs
    rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
    if [ "$rootfs" != "btrfs" ]; then
        note "root filesystem is ${rootfs:-unknown}, not btrfs — skipping snapshots"
        return 0
    fi
    if ! pacman -Qq snapper >/dev/null 2>&1; then
        note "snapper not installed; skipping snapshot setup"
        return 0
    fi

    say "Configuring btrfs snapshots (snapper)"

    # Flat layout (@ + @snapshots) is created by the installer.
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

    run "${SUDO[@]}" systemctl enable --now snapper-timeline.timer snapper-cleanup.timer || true

    if pacman -Qq btrfsmaintenance >/dev/null 2>&1; then
        if [ -f /etc/default/btrfsmaintenance ] \
           && ! grep -q '^BTRFS_TRIM_PERIOD="none"' /etc/default/btrfsmaintenance; then
            backup_file /etc/default/btrfsmaintenance
            run "${SUDO[@]}" sed -i 's/^BTRFS_TRIM_PERIOD=.*/BTRFS_TRIM_PERIOD="none"/' /etc/default/btrfsmaintenance
        fi
        run "${SUDO[@]}" systemctl enable --now btrfs-scrub.timer || true
    fi

    if pacman -Qq snapper-rollback >/dev/null 2>&1; then
        local dev
        dev="$(findmnt -no SOURCE / 2>/dev/null || true)"
        if [ "$DRY_RUN" -eq 1 ]; then
            note "[dry-run] write /etc/snapper-rollback.conf (dev=${dev:-?})"
        elif [ -n "$dev" ]; then
            if [ -e /etc/snapper-rollback.conf ]; then backup_file /etc/snapper-rollback.conf; fi
            cat > /etc/snapper-rollback.conf <<EOF
# Roll back with:  sudo snapper-rollback <snapid>
[root]
subvol_main = @
subvol_snapshots = @snapshots
mountpoint = /btrfsroot
dev = $dev
EOF
        fi
    fi

    note "snapshots:"
    snapper -c root list 2>/dev/null | tail -n 5 | sed 's/^/      /' || true
}

# ---------------------------------------------------------------------------
system_fixes() {
    say "System fixes (SATA/ALPM, zram, snapshots)"
    cmdline_fix
    say "Applying udev + sysctl"
    run "${SUDO[@]}" udevadm control --reload-rules
    run "${SUDO[@]}" udevadm trigger --subsystem-match=scsi_host --action=add
    run "${SUDO[@]}" sysctl --system
    zram_activate
    snapper_configure
}
