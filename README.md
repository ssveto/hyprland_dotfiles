# hyprland_dotfiles

Personal **Hyprland + [Noctalia](https://github.com/noctalia-dev/noctalia)**
desktop for an Intel i5-6th-gen / HD 520 / 8 GB machine, packaged in the
[EndeavourOS Community Edition](https://github.com/EndeavourOS-Community-Editions)
style (plain `.config/` + `etc/` + `home_config/` trees, rsync-deployed).

> This is a **personal** setup: the storage/zram fixes below are tailored to
> this specific machine and run unconditionally. The primary monitor is assumed
> to be `DP-3` and the username is taken from the installer.

## Install

### With the EndeavourOS installer

1. Boot the live ISO, open the Welcome app → **Fetch your install customization file**.
2. Paste:
   ```
   https://raw.githubusercontent.com/ssveto/hyprland_dotfiles/main/setup_hyprland_isomode.bash
   ```
3. Start the installer and do an **online** install, choosing **"no desktop"**.
   Calamares runs the script in the target and deploys everything.

### Manually (post-install)

```sh
git clone https://github.com/ssveto/hyprland_dotfiles.git
cd hyprland_dotfiles
sudo ./hyprland-install.sh
# preview first with: ./hyprland-install.sh --dry-run
```

Reboot and pick **Hyprland** at the ReGreet login screen.

## Repository layout

| Path | Deployed to | Notes |
| --- | --- | --- |
| `.config/` | `~/.config/` | Hyprland, Noctalia, foot, fuzzel, GTK, portals, user units |
| `home_config/` | `~/` | `.zshrc`, `.zprofile`, `.gitconfig`, wallpapers, Noctalia settings |
| `etc/` | `/etc/` | greetd, zram, swappiness, udev rule |
| `packages-repository.txt` | — | repo packages |
| `packages-aur.txt` | — | AUR packages (installed via yay as the user) |
| `lib/system-fixes.sh` | — | SATA/ALPM + zram + snapper logic (shared, idempotent) |
| `lib/deploy.sh` | — | deployment logic (shared) |
| `hyprland-install.sh` | — | post-install entry point |
| `setup_hyprland_isomode.bash` | — | EOS installer customization file |

`home_config/.local/state/noctalia/settings.toml` uses `__HOME__` / `__OUTPUT__`
placeholders that the installer substitutes (`/home/<user>` and `DP-3`).

## Fresh install: filesystem & snapshots

### With Calamares (usual path)

In the EndeavourOS installer:

- **Erase disk → btrfs** for a single-disk layout, or
- **Manual partitioning** if you want `/home` on the HDD: SSD partition → `/`
  (**btrfs**), HDD partition → `/home` (**ext4**).

Calamares creates the flat subvolumes `@`, `@cache`, `@log` (and `@home` only if
`/home` is on the same disk). It does **not** create `@snapshots`, so
`lib/system-fixes.sh` adds it during install:

1. mount the btrfs top level (`subvolid=5`) and `btrfs subvolume create @snapshots`,
2. append `UUID=<ssd> /.snapshots btrfs … subvol=/@snapshots 0 0` to `/etc/fstab`,
3. mount `/.snapshots`, then run `snapper create-config /`.

Do **not** pre-create `/.snapshots` yourself. Resulting fstab (example, with
`/home` on the HDD):

```
UUID=<ssd>  /            btrfs  rw,noatime,compress=zstd:3,subvol=/@           0 0
UUID=<ssd>  /var/cache   btrfs  rw,noatime,compress=zstd:3,subvol=/@cache      0 0
UUID=<ssd>  /var/log     btrfs  rw,noatime,compress=zstd:3,subvol=/@log        0 0
UUID=<ssd>  /.snapshots  btrfs  rw,noatime,compress=zstd:3,subvol=/@snapshots  0 0
UUID=<hdd>  /home        ext4   rw,noatime                                     0 0
```

### Manual btrfs (alternative)

If you partition outside Calamares, create `@` and `@snapshots` up front:

```sh
# from the live ISO; SSD = /dev/sda2
mkfs.btrfs -L arch /dev/sda2
mount /dev/sda2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
mount -o subvol=@,compress=zstd:3,noatime /dev/sda2 /mnt
mkdir /mnt/.snapshots
mount -o subvol=@snapshots,compress=zstd:3,noatime /dev/sda2 /mnt/.snapshots
```

### Snapshots

If `/` is btrfs, `lib/system-fixes.sh` creates the snapper `root` config (+
`snap-pac` hooks), sets retention (5 hourly / 7 daily / 4 weekly / 2 monthly),
enables `snapper-timeline.timer`, `snapper-cleanup.timer`, `btrfs-scrub.timer`
(trim left to `fstrim.timer`), and writes `/etc/snapper-rollback.conf` **only if**
`/.snapshots` is the real `@snapshots` subvolume (otherwise it falls back to
live-USB `snapper rollback`).

**Snapshots cover `/` only** — `/home` is on the HDD (ext4). Snapshots also live
on the same disk they protect, so they are **not backups**.

- List: `sudo snapper -c root list`
- Roll back: `sudo snapper-rollback <snapid>` (reboot after), or from a live ISO:
  `sudo snapper rollback <snapid>`
- **Back `/home` up off-machine.**

## SATA/ALPM + zram fixes (`lib/system-fixes.sh`)

This machine's HDD drops its SATA link under aggressive link power management,
which can freeze the system. The installer:

1. ensures **`ahci.mobile_lpm_policy=1`** on the kernel cmdline (GRUB fallback),
   then `reinstall-kernels` if it changed. `1` = max performance; `0` means
   "keep firmware settings", and this firmware already forces
   `med_power_with_dipm`,
2. ships a **udev rule** (`etc/udev/rules.d/69-sata-alpm.rules`) forcing
   `max_performance`, and reloads/triggers it,
3. provisions **zram** (`etc/systemd/zram-generator.conf`) and sets
   **`vm.swappiness=100`** (`etc/sysctl.d/99-swappiness.conf`) — swap is
   zram-only, so a high value is correct,
4. provisions **snapper** snapshots (above).

Every file it touches under `/etc` is backed up to
`/var/tmp/opencode-fixes/backup-<timestamp>/`.

Verify after reboot:

```sh
grep -o 'ahci.mobile_lpm_policy=[0-9]*' /proc/cmdline
cat /sys/class/scsi_host/host*/link_power_management_policy   # -> max_performance
```

## Desktop design

- **Noctalia** owns the bar, launcher, control center, notifications, lock/idle,
  clipboard, wallpaper and theming; the `kenn/keybind-cheatsheet` community
  plugin replaces the old Sway keybinds widget.
- **Animations on, kept lean**: popin windows, fading layers, sliding
  workspaces. Compositor **blur and shadows are off**, rounding is modest.
- **Super+F** = Hyprland native *maximize* (`fullscreen mode = maximized`);
  Alt+Tab / Super+P use Noctalia's window switcher.
- Qt/Electron run natively on Wayland (`qt5-wayland`/`qt6-wayland`,
  `ELECTRON_OZONE_PLATFORM_HINT=auto`).
- Idle/lock is Noctalia's; the user unit `noctalia-lock-on-suspend.service`
  locks on `sleep.target`.

### Keybindings (Super = main mod)

| Key | Action |
| --- | --- |
| Super+Return | foot terminal |
| Super+Q / Super+W | close window |
| Super+D / Super+Space | Noctalia launcher |
| Super+S | control center |
| Super+, | Noctalia settings |
| Super+P / Alt+Tab | window switcher |
| Super+F | maximize (toggle) |
| Super+Shift+F | fullscreen (toggle) |
| Super+Shift+/ | keybind cheatsheet |
| Super+R | fuzzy shell-history popup |
| Super+N / Super+O | Thunar / Firefox |
| Super+Ctrl+V | clipboard history |
| Super+Shift+E | power menu |
| Super+F1 | lock screen |
| Super+[1-9,0] / +Shift | switch / move to workspace |
| Super+arrows or hjkl | focus |
| Super+Shift+arrows or hjkl | move window |
| Super+Ctrl+arrows or hjkl | resize window |
| Print / Ctrl+Print / Shift+Print | region / window / monitor screenshot |

Layout is dwindle; `Super+V` toggles split, `Super+G` toggles a group (tabbed),
`Super+minus` opens the scratchpad (`special:magic`).

## Updating

There is no chezmoi here; updates are pull-and-redeploy:

```sh
cd hyprland_dotfiles && git pull && sudo ./hyprland-install.sh
```

The installer is idempotent, so re-running is safe.

## Not backed up

- Shell history, secrets, SSH/GPG keys, keyrings, browser profiles
- Noctalia runtime state (clipboard, notification history, usage counts)
- The optional wallpaper pack (`~/Pictures/walls-catppuccin-mocha-master`, ~396 MB)
