# hyprland-dotfiles

Personal **Hyprland + [Noctalia](https://github.com/noctalia-dev/noctalia)**
desktop configuration, managed with [chezmoi](https://chezmoi.io) so it can be
restored on any Arch machine.

Source of truth: `~/.local/share/chezmoi` (this repository). Do **not** edit
files there by hand unless you mean to change the template itself.

> This repo was converted from a Sway setup. The compositor is now
> **Hyprland 0.56+**, which uses the new **Lua configuration**
> (`~/.config/hypr/hyprland.lua`).

## Quick start (fresh Arch)

```sh
git clone https://github.com/ssveto/sway_dotfiles.git ~/.local/share/chezmoi
cd ~/.local/share/chezmoi
./bootstrap-arch.sh
```

`bootstrap-arch.sh` is safe and idempotent; it backs up every file it touches
to `/var/tmp/opencode-fixes/backup-<timestamp>/` and:

1. applies the **SATA/ALPM + zram fixes** (see below),
2. installs the recorded repo packages (unavailable/EOL packages are skipped),
3. installs + applies these dotfiles through chezmoi,
4. configures **greetd + ReGreet**.

Useful flags: `--dry-run`, `--skip-storage`, `--storage-only`,
`--skip-packages`, `--skip-aur`, `--no-upgrade`, `-y`.

## What is managed

| Target | Notes |
| --- | --- |
| `~/.config/hypr/hyprland.lua` | Hyprland entrypoint (single Lua file, sectioned) |
| `~/.config/hypr/scripts/` | `power_menu.sh`, `fzf-history.sh`, screenshot helpers |
| `~/.config/noctalia/config.toml`, `templates.toml` | Noctalia shell config + theme templates |
| `~/.local/state/noctalia/settings.toml` | Noctalia GUI-managed state (bar layout, lock widget, enabled plugins) — **templated** |
| `~/.config/systemd/user/noctalia-lock-on-suspend.service` | Locks the session before sleep |
| `~/.config/xdg-desktop-portal/portals.conf` | Hyprland portal backends |
| `~/.local/share/wallpapers/` | Wallpaper used by the fallback Noctalia config |
| `~/.config/foot/` | `foot.ini` + generated Noctalia theme |
| `~/.config/fuzzel/fuzzel.ini` | dmenu/launcher (power menu, etc.) |
| `~/.config/gtk-3.0/`, `~/.config/gtk-4.0/` | Generated GTK theme + `settings.ini` |
| `~/.zshrc`, `~/.zprofile` | Shell config (completion, history, fzf, zoxide, starship) |
| `~/.gitconfig` | Git identity + lfs filter |

## Desktop design

- **Noctalia** owns the bar, launcher, control center, notifications, lock/idle,
  clipboard, wallpaper and theming. A community plugin,
  `kenn/keybind-cheatsheet`, replaces the old local Sway keybinds widget.
- **Animations on, kept lean**: popin windows, fading layers, sliding
  workspaces. Compositor **blur and shadows are disabled**, opacities are 1.0
  and rounding is modest, so it looks smooth without a heavy GPU cost.
- **Super+F** uses Hyprland's native *maximize* (`fullscreen mode = maximized`);
  the old sway-only maximize script is gone.
- **Alt+Tab / Super+P** use Noctalia's built-in window switcher.
- Idle/lock is Noctalia's; a systemd `sleep.target` hook locks on suspend.

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

Layout is dwindle; `Super+V` toggles the split, `Super+G` toggles a group
(tabbed), `Super+minus` opens the scratchpad (`special:magic`).

## SATA/ALPM fix (in `bootstrap-arch.sh`)

This machine's HDD (`sdb`) drops its SATA link under aggressive link power
management, which can freeze the system. The script:

1. ensures **`ahci.mobile_lpm_policy=1`** ("maximum performance") in
   `/etc/kernel/cmdline` (GRUB fallback handled; `1`, not `0` — `0` means "keep
   firmware settings", and this box's firmware already forces
   `med_power_with_dipm`),
2. installs a **udev rule** forcing `link_power_management_policy=max_performance`
   (catches hotplug/resume) and triggers it at runtime,
3. provisions **zram swap** (`/etc/systemd/zram-generator.conf`:
   `min(ram/2, 4096)`, `zstd`, priority 100) and then sets
   **`vm.swappiness=100`**. Swap here is **zram-only**, so a high value (prefer
   fast compressed RAM swap) is correct; this is *not* the usual "10 for an HDD
   swap" advice,
4. runs **`reinstall-kernels`** (only if the cmdline changed) to regenerate the
   systemd-boot entries.

Verify after reboot:

```sh
grep -o 'ahci.mobile_lpm_policy=[0-9]*' /proc/cmdline
cat /sys/class/scsi_host/host*/link_power_management_policy   # -> max_performance
```

## Machine-specific settings

`~/.config/chezmoi/chezmoi.toml` (rendered from `.chezmoi.toml.tmpl`) holds:

- `output` — your primary monitor name, e.g. `DP-3`. Find it with
  `hyprctl monitors`. It is used by the Noctalia lockscreen widget and the
  per-monitor wallpaper. Hyprland's own monitor rule is output-agnostic, so the
  wrong value only affects the lock widget.

After editing, run `chezmoi init && chezmoi apply`.

## Day-to-day workflow

```sh
chezmoi diff          # see what would change
chezmoi apply         # apply to $HOME
chezmoi edit <file>   # edit a managed file in the source dir
chezmoi re-add <file> # update source from the current $HOME file (non-templated)
cd "$(chezmoi source-path)" && git add -A && git commit -m "..."
```

> `settings.toml` is a **template**. If you change Noctalia settings in the GUI,
> `chezmoi re-add` would overwrite the template placeholders. Prefer
> `chezmoi diff` and update the `.tmpl` source instead.

## Not backed up

- Shell history (`~/.zsh_history`, `~/.bash_history`)
- Secrets, tokens, SSH keys, keyrings
- Noctalia runtime state (`notification_history*`, `usage_counts.json`,
  `recently_used.json`, `instance.id`, `state.toml`)
- Downloaded/community Noctalia templates and palettes
- Old backups (`~/.config/noctalia/backup-*`)
- The wallpaper pack (`~/Pictures/walls-catppuccin-mocha-master`, ~396 MB) —
  optional; a default wallpaper ships in `~/.local/share/wallpapers/`

## Regenerating package lists

```sh
cd "$(chezmoi source-path)" && ./export-packages.sh
```
