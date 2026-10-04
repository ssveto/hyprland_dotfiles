# sway-dotfiles

Personal Sway + [Noctalia](https://github.com/noctalia-dev/noctalia) desktop
configuration, managed with [chezmoi](https://chezmoi.io) so it can be restored
on any Arch machine.

Source of truth: `~/.local/share/chezmoi` (this repository). Do **not** edit
files there by hand unless you mean to change the template itself.

## What is managed

| Target | Notes |
| --- | --- |
| `~/.config/sway/config` | Sway entrypoint (includes `config.d/*`) |
| `~/.config/sway/config.d/` | `default`, `zz-user-binds` (custom binds incl. `Super+f`), `application_defaults`, `input`, `output`, `theme`, `autostart_applications` |
| `~/.config/sway/scripts/` | All helper scripts, including `sway-maximize.sh`, `fzf-history.sh`, `power_menu.sh`, `window_switcher.sh`, `import-gsettings` |
| `~/.config/sway/*.png` | Wallpaper referenced by the fallback Noctalia config |
| `~/.config/sway/keyboard.conf` | Keyboard layout reference list |
| `~/.config/noctalia/config.toml`, `templates.toml` | Noctalia shell config + theme templates |
| `~/.local/state/noctalia/settings.toml` | Noctalia GUI-managed state (bar layout, lock widget, enabled plugins) — **templated** |
| `~/.local/share/noctalia/plugins/sway-keybinds/` | The local `local/sway-keybinds` plugin (not downloadable — must be kept) |
| `~/.config/foot/` | `foot.ini` + generated Noctalia theme |
| `~/.config/fuzzel/fuzzel.ini` | Launcher |
| `~/.config/gtk-3.0/`, `~/.config/gtk-4.0/` | Generated GTK theme + `settings.ini` |
| `~/.zshrc`, `~/.zprofile` | Shell config (completion, history, fzf, zoxide, starship) |
| `~/.gitconfig` | Git identity + lfs filter |

## Restoring on a new machine

1. Install the prerequisites and chezmoi:
   ```sh
   sudo pacman -S base-devel git chezmoi
   ```
2. Clone and apply this repo (replace with your URL):
   ```sh
   chezmoi init --apply git@github.com:<you>/sway-dotfiles.git
   ```
3. Install the recorded packages:
   ```sh
   cd "$(chezmoi source-path)" && ./install.sh
   ```
   Missing packages are skipped, so this also works on a plain Arch install
   (only `welcome`/`eos-welcome` is EndeavourOS-specific).
4. Re-login to Sway. Noctalia re-renders the GTK/foot themes from the active
   palette on startup.

### Machine-specific settings

These are driven by `~/.config/chezmoi/chezmoi.toml` (generated from
`.chezmoi.toml.tmpl`):

- `output` — your primary monitor name, e.g. `DP-3`. Find it with
  `swaymsg -t get_outputs`. It is used by the Noctalia lockscreen widget and
  the per-monitor wallpaper.
- `is_endeavouros` — set `false` on a non-EndeavourOS distro so the
  `eos-welcome` autostart entry is omitted.

After editing, run `chezmoi init && chezmoi apply`.

## Verifying the `Super+f` maximize script

`Super+f` is provided by three files: `config.d/zz-user-binds` (the bind +
the `for_window` staging rule), `config.d/default` (`$term footclient`), and
`scripts/sway-maximize.sh`. Runtime deps: `swaymsg`, `jq`, `footclient`,
`flock` (util-linux).

After restoring, bind `Super+f` and confirm maximize/restore works. The captured
script is:

```sh
sha256sum ~/.config/sway/scripts/sway-maximize.sh
# f0db9aed9295d40d26355b8309b0fcab1e8a92f60920af63570adc1441142a9f
```

## Wallpapers

The wallpaper pack used by this setup
(`~/Pictures/walls-catppuccin-mocha-master`, ~396 MB) is **not** included.
Re-download it, or pick another wallpaper in Noctalia. The paths in
`settings.toml` are written relative to `$HOME`, so they resolve on any user.

## Day-to-day workflow

```sh
chezmoi diff          # see what would change
chezmoi apply         # apply to $HOME
chezmoi edit <file>   # edit a managed file in the source dir
chezmoi re-add <file> # update source from the current $HOME file (non-templated)
cd "$(chezmoi source-path)" && git add -A && git commit -m "..."
```

Publish/push with GitHub Desktop (add the local repository at
`~/.local/share/chezmoi` as an **existing repository**, then *Publish* as
private).

> `settings.toml` and `autostart_applications` are **templates**. If you change
> Noctalia settings in the GUI, `chezmoi re-add` would overwrite the template
> placeholders. Prefer `chezmoi diff` and update the `.tmpl` source instead.

## Not backed up

- Shell history (`~/.zsh_history`, `~/.bash_history`)
- Secrets, tokens, SSH keys, keyrings
- Noctalia runtime state (`notification_history*`, `usage_counts.json`,
  `recently_used.json`, `instance.id`, `state.toml`)
- Downloaded/community Noctalia templates and palettes
- Old backups (`~/.config/sway/backups/`, `~/.config/noctalia/backup-*`)
- The wallpaper pack

## Regenerating package lists

```sh
cd "$(chezmoi source-path)" && ./export-packages.sh
```
