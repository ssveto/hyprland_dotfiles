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
# ISOMODE: set to 1 by setup_hyprland_isomode.bash when running inside the
# EndeavourOS/Calamares *chroot* — several calibrations there (findmnt of "/",
# systemctl) see the live ISO instead of the target system.
: "${ISOMODE:=0}"
export ISOMODE DRY_RUN
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
            # Only claim success if the substitution actually happened.
            if grep -qE 'GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\b'"$param"'\b' "$grub_file"; then
                CMDLINE_CHANGED=1
            else
                warn "could not add '$param' to GRUB_CMDLINE_LINUX_DEFAULT; add it manually."
            fi
        fi
    elif [ "$ISOMODE" -eq 1 ]; then
        warn "[chroot] neither /etc/kernel/cmdline nor /etc/default/grub; add '$param' manually post-install."
    else
        warn "No /etc/kernel/cmdline or /etc/default/grub; add '$param' manually."
    fi
}

# ---------------------------------------------------------------------------
plymouth_fix() {
    if ! pacman -Qq plymouth >/dev/null 2>&1; then
        return 0
    fi
    # The theme is set by etc/plymouth/plymouthd.conf (deployed via rsync);
    # the initrd must be rebuilt so plymouth + theme are embedded.
    REGEN=1

    local cmdline_file="/etc/kernel/cmdline"
    local grub_file="/etc/default/grub"
    if [ -f "$cmdline_file" ]; then
        if ! grep -qE '(^| )splash( |$)' "$cmdline_file"; then
            note "adding 'splash' to $cmdline_file"
            backup_file "$cmdline_file"
            if [ "$DRY_RUN" -eq 1 ]; then
                note "[dry-run] append ' splash'"
            else
                printf ' splash' >> "$cmdline_file"
            fi
            CMDLINE_CHANGED=1
        fi
    elif [ -f "$grub_file" ]; then
        if ! grep -qE '(^| )splash( |$)' "$grub_file"; then
            note "adding 'splash' to GRUB_CMDLINE_LINUX_DEFAULT"
            backup_file "$grub_file"
            run "${SUDO[@]}" sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*)"/\1 splash"/' "$grub_file"
            CMDLINE_CHANGED=1
        fi
    fi
    note "Plymouth theme 'bgrt' configured (initrd rebuild scheduled)"
}

# ---------------------------------------------------------------------------
regenerate_boot() {
    if [ "${CMDLINE_CHANGED:-0}" -ne 1 ] && [ "${REGEN:-0}" -ne 1 ]; then
        return 0
    fi
    if command -v reinstall-kernels >/dev/null 2>&1; then
        say "Regenerating boot entries (reinstall-kernels)"
        run "${SUDO[@]}" reinstall-kernels || warn "reinstall-kernels failed"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        say "Regenerating GRUB config"
        run "${SUDO[@]}" grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed"
    else
        warn "Boot entries changed but no regenerator found; reboot manually."
    fi
}

# ---------------------------------------------------------------------------
zram_activate() {
    if [ "$ISOMODE" -eq 1 ]; then
        note "[chroot] zram will come up on first boot (config deployed)"
        return 0
    fi
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
# Identify the root filesystem of the *target* we deploy to.
#
# findmnt / describes the root of the running mount namespace. Inside the
# Calamares chroot (isomode) that root is the live ISO's overlay/tmpfs — not
# the installed system — which would make every btrfs check below silently skip
# the whole snapshot setup. /etc/fstab inside that chroot is the target's
# generated fstab, so when findmnt does not look like a real mount, fall back
# to its "/" entry. Sets:
#   ROOT_FSTYPE  btrfs | ext4 | ... ("" when unknown)
#   ROOT_UUID    filesystem UUID ("" when unknown)
#   ROOT_DEV     device node ("" when unknown)
root_fs_info() {
    ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || true)"
    ROOT_UUID="$(findmnt -no UUID / 2>/dev/null || true)"
    ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
    # findmnt reports the source of a btrfs subvolume mount as
    # "/dev/sda1[/@]"; the "[...]" suffix must go or mount(8) can't use it.
    ROOT_DEV="${ROOT_DEV%%\[*}"

    case "$ROOT_FSTYPE" in
        "" | overlay | tmpfs) ROOT_FSTYPE="" ;;
        *) return 0 ;;
    esac

    local line spec
    line="$(awk '$1 !~ /^#/ && $2 == "/" { print; exit }' /etc/fstab 2>/dev/null || true)"
    [ -n "$line" ] || return 0

    ROOT_FSTYPE="$(printf '%s\n' "$line" | awk '{ print $3 }')"
    spec="$(printf '%s\n' "$line" | awk '{ print $1 }')"
    case "$spec" in
        UUID=*)
            ROOT_UUID="${spec#UUID=}"
            ROOT_DEV="$(readlink -f "/dev/disk/by-uuid/$ROOT_UUID" 2>/dev/null || true)"
            ;;
        PARTUUID=*)
            ROOT_DEV="$(readlink -f "/dev/disk/by-partuuid/${spec#PARTUUID=}" 2>/dev/null || true)"
            ;;
        *) ROOT_DEV="$spec" ;;
    esac
    if [ -z "$ROOT_UUID" ] && [ -n "$ROOT_DEV" ]; then
        ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
    fi
    # Reverse lookup: in the Calamares chroot /dev/disk/by-uuid may be missing,
    # so resolve the device from the UUID via blkid as a fallback.
    if [ -z "$ROOT_DEV" ] && [ -n "$ROOT_UUID" ]; then
        ROOT_DEV="$(blkid -U "$ROOT_UUID" 2>/dev/null || true)"
    fi
}

# ---------------------------------------------------------------------------
# Calamares creates @ / @home / @cache / @log but not @snapshots. Create it (and
# the fstab entry) so snapper-rollback's flat layout works. Returns 0 when the
# flat layout is available, 1 otherwise.
snapshots_is_flat() {
    mountpoint -q /.snapshots 2>/dev/null \
        && findmnt -no OPTIONS /.snapshots 2>/dev/null | grep -q 'subvol=/@snapshots'
}

ensure_snapshots_subvolume() {
    if snapshots_is_flat; then
        note "@snapshots already mounted at /.snapshots"
        return 0
    fi

    # A nested .snapshots (from a previous snapper run) cannot be converted here.
    if [ -d /.snapshots ] && ! mountpoint -q /.snapshots 2>/dev/null; then
        warn "/.snapshots exists but is not the @snapshots subvolume; leaving it as-is"
        return 1
    fi

    local dev uuid
    dev="$ROOT_DEV"
    uuid="$ROOT_UUID"
    if [ -z "$dev" ] || [ -z "$uuid" ]; then
        warn "could not determine the root device/UUID; skipping @snapshots"
        return 1
    fi

    say "Creating @snapshots subvolume (flat layout for snapper-rollback)"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] mount -o subvolid=5 $dev <tmp>"
        note "[dry-run] btrfs subvolume create <tmp>/@snapshots"
        note "[dry-run] /etc/fstab += UUID=$uuid /.snapshots btrfs rw,noatime,compress=zstd:3,subvol=/@snapshots 0 0"
        note "[dry-run] mkdir -p /.snapshots && mount /.snapshots"
        return 0
    fi

    local tmp
    tmp="$(mktemp -d)"
    if ! mount -o subvolid=5 "$dev" "$tmp"; then
        warn "could not mount the btrfs top level; skipping @snapshots"
        rmdir "$tmp" 2>/dev/null || true
        return 1
    fi
    if [ ! -d "$tmp/@snapshots" ]; then
        btrfs subvolume create "$tmp/@snapshots" || warn "could not create @snapshots"
    fi
    umount "$tmp" || true
    rmdir "$tmp" 2>/dev/null || true

    if ! grep -q 'subvol=/@snapshots' /etc/fstab 2>/dev/null; then
        backup_file /etc/fstab
        printf 'UUID=%s /.snapshots btrfs rw,noatime,compress=zstd:3,subvol=/@snapshots 0 0\n' "$uuid" >> /etc/fstab
    fi

    mkdir -p /.snapshots
    if mount /.snapshots; then
        return 0
    fi
    # The subvolume and the fstab entry exist, so it mounts on boot. Still
    # return success so the snapper config gets seeded/registered for first boot
    # (this is the expected path inside the Calamares chroot).
    warn "could not mount /.snapshots now; it will mount on boot"
    return 0
}

# ---------------------------------------------------------------------------
# snapper records its configs in the sysconfig file (/etc/conf.d/snapper,
# SNAPPER_CONFIGS) and the daemon caches that list at startup — it does *not*
# scan /etc/snapper/configs. A hand-seeded config must therefore be registered
# here, and snapperd restarted so the CLI and the timeline timer can see it.
snapper_register() {
    local name="$1" f=/etc/conf.d/snapper cur new
    if [ -f "$f" ] && grep -qE "^SNAPPER_CONFIGS=\"?[^\"]*\b$name\b" "$f"; then
        note "snapper config '$name' already registered"
        return 0
    fi
    cur=""
    if [ -f "$f" ]; then
        cur="$(sed -nE 's/^SNAPPER_CONFIGS="?([^"]*)"?[[:space:]]*$/\1/p' "$f" | head -n1)"
    fi
    new="$(printf '%s %s' "$cur" "$name" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
    backup_file "$f"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] register '$name' in $f (SNAPPER_CONFIGS=\"$new\")"
    elif [ -f "$f" ] && grep -qE '^SNAPPER_CONFIGS=' "$f"; then
        run "${SUDO[@]}" sed -i -E "s#^SNAPPER_CONFIGS=.*#SNAPPER_CONFIGS=\"$new\"#" "$f"
    else
        printf 'SNAPPER_CONFIGS="%s"\n' "$new" >> "$f"
    fi
    # The running daemon cached the old (empty) list; drop it so the next call
    # re-reads the sysconfig file.
    run "${SUDO[@]}" systemctl try-restart snapperd.service || true
}

# snapper's create-config always tries to create the .snapshots subvolume and
# aborts with EEXIST when it already exists — which is exactly the flat layout
# this installer sets up (a pre-created @snapshots mounted at /.snapshots).
# Seed the config from the packaged template instead of calling create-config.
snapper_seed() {
    local name="$1" tmpl
    tmpl="/usr/share/snapper/config-templates/default"
    [ -f "$tmpl" ] || tmpl="/etc/snapper/config-templates/default"
    run "${SUDO[@]}" mkdir -p /etc/snapper/configs
    run "${SUDO[@]}" cp "$tmpl" "/etc/snapper/configs/$name"
    run "${SUDO[@]}" sed -i 's#^SUBVOLUME=.*#SUBVOLUME="/"#' "/etc/snapper/configs/$name"
}

# Set snapper config values by editing the config file directly. This avoids
# `snapper set-config`, which needs a running snapperd (absent inside the
# Calamares chroot) and has its own config-discovery quirks.
snapper_config_set() {
    local name="$1"; shift
    local file="/etc/snapper/configs/$name" kv key val
    if [ ! -f "$file" ]; then
        warn "snapper config $file missing; cannot set values"
        return 0
    fi
    backup_file "$file"
    for kv in "$@"; do
        key="${kv%%=*}"; val="${kv#*=}"
        if grep -qE "^${key}=" "$file"; then
            run "${SUDO[@]}" sed -i -E "s#^${key}=.*#${key}=\"${val}\"#" "$file"
        elif [ "$DRY_RUN" -eq 1 ]; then
            note "[dry-run] add ${key}=\"${val}\" to $file"
        else
            printf '%s="%s"\n' "$key" "$val" >> "$file"
        fi
    done
}

# ---------------------------------------------------------------------------
snapper_configure() {
    root_fs_info
    if [ "$ROOT_FSTYPE" != "btrfs" ]; then
        note "root filesystem is ${ROOT_FSTYPE:-unknown}, not btrfs — skipping snapshots"
        return 0
    fi
    if ! pacman -Qq snapper >/dev/null 2>&1; then
        note "snapper not installed; skipping snapshot setup"
        return 0
    fi

    say "Configuring btrfs snapshots (snapper)"

    if [ -f /etc/snapper/configs/root ]; then
        note "snapper 'root' config already exists — skipping creation"
        ensure_snapshots_subvolume || true
    elif ensure_snapshots_subvolume; then
        snapper_seed root
    else
        warn "flat @snapshots unavailable — skipping snapper config creation (re-run after reboot)"
        return 0
    fi
    snapper_register root

    snapper_config_set root \
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

    # Enable always; start only on a live system (inside the chroot they come up
    # on first boot).
    run "${SUDO[@]}" systemctl enable snapper-timeline.timer snapper-cleanup.timer || true
    if [ "$ISOMODE" -ne 1 ]; then
        run "${SUDO[@]}" systemctl start snapper-timeline.timer snapper-cleanup.timer || true
    fi

    if pacman -Qq btrfsmaintenance >/dev/null 2>&1; then
        if [ -f /etc/default/btrfsmaintenance ] \
           && ! grep -q '^BTRFS_TRIM_PERIOD="none"' /etc/default/btrfsmaintenance; then
            backup_file /etc/default/btrfsmaintenance
            run "${SUDO[@]}" sed -i 's/^BTRFS_TRIM_PERIOD=.*/BTRFS_TRIM_PERIOD="none"/' /etc/default/btrfsmaintenance
        fi
        run "${SUDO[@]}" systemctl enable btrfs-scrub.timer || true
        if [ "$ISOMODE" -ne 1 ]; then
            run "${SUDO[@]}" systemctl start btrfs-scrub.timer || true
        fi
    fi

    if pacman -Qq snapper-rollback >/dev/null 2>&1; then
        if snapshots_is_flat || grep -q 'subvol=/@snapshots' /etc/fstab 2>/dev/null \
           || [ "$DRY_RUN" -eq 1 ]; then
            local dev
            dev="$ROOT_DEV"
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
        else
            note "snapper-rollback config skipped (/.snapshots is not the @snapshots subvolume)"
        fi
    fi

    note "snapshots:"
    snapper -c root list 2>/dev/null | tail -n 5 | sed 's/^/      /' || true
}

# ---------------------------------------------------------------------------
system_fixes() {
    say "System fixes (SATA/ALPM, plymouth, zram, snapshots)"
    cmdline_fix
    plymouth_fix
    say "Applying udev + sysctl"
    # Non-critical live actions: never abort the install over them.
    run "${SUDO[@]}" udevadm control --reload-rules || warn "udevadm control failed (rules apply on next boot)"
    run "${SUDO[@]}" udevadm trigger --subsystem-match=scsi_host --action=add || true
    run "${SUDO[@]}" sysctl --system || warn "sysctl --system reported errors"
    zram_activate
    snapper_configure
    regenerate_boot
}
