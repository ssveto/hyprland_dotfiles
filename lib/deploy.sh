# shellcheck shell=bash
# Deployment helpers shared by hyprland-install.sh and
# setup_hyprland_isomode.bash. Source lib/system-fixes.sh first (it provides
# say/note/warn/run/backup_file and system_fixes()).

list_file() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1"; }

# Apply a dconf key to the target user's *live* session. On Wayland, GTK apps
# (and Noctalia) resolve icons/theme through the XSettings portal backed by the
# user's dconf, so ~/.config/gtk-3.0/settings.ini alone is not always honoured.
# Best-effort: skip quietly when the user's session bus is not reachable (e.g.
# installing from a TTY before first login).
set_user_dconf() {
    local username="$1" schema="$2" key="$3" value="$4"
    local uid rt home
    uid="$(id -u "$username" 2>/dev/null)" || return 0
    rt="/run/user/$uid"
    home="$(getent passwd "$username" | cut -d: -f6)"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] gsettings set $schema $key '$value' (as $username)"
        return 0
    fi
    if [ ! -S "$rt/bus" ]; then
        note "user session bus not running; $schema $key will apply on next login"
        return 0
    fi
    runuser -u "$username" -- env HOME="$home" XDG_RUNTIME_DIR="$rt" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
        gsettings set "$schema" "$key" "$value" || warn "could not set $schema $key"
}

install_aur_pkgs() {
    local username="$1" list="$2"
    [ -s "$list" ] || return 0
    local -a aur=(); mapfile -t aur < <(list_file "$list")
    [ "${#aur[@]}" -gt 0 ] || return 0
    say "Installing AUR packages: ${aur[*]}"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] yay -S --needed --noconfirm ${aur[*]}"
        return 0
    fi

    # yay is in the EndeavourOS repo but absent from vanilla Arch; installing it
    # is therefore best-effort. When it is unavailable the makepkg fallback
    # below still installs the AUR packages, so never let this abort the run.
    if ! command -v yay >/dev/null 2>&1; then
        "${SUDO[@]}" pacman -S --noconfirm --needed --disable-download-timeout yay >/dev/null 2>&1 \
            || note "yay not available from the repos; building AUR packages directly"
    fi

    # Prefer yay as the target user (yay refuses to run as root).
    if command -v yay >/dev/null 2>&1 \
       && runuser -u "$username" -- yay -S --needed --noconfirm "${aur[@]}"; then
        return 0
    fi

    # Fallback: build with makepkg as the user, install as root.
    warn "yay unavailable/failed; building AUR packages directly"
    local tmp; tmp="$(mktemp -d)"; chown "$username:$username" "$tmp"
    local -a built=()
    local p f
    for p in "${aur[@]}"; do
        if runuser -u "$username" -- git clone --depth 1 "https://aur.archlinux.org/$p.git" "$tmp/$p" \
           && runuser -u "$username" -- bash -c "cd '$tmp/$p' && makepkg -d --noconfirm"; then
            while IFS= read -r f; do built+=("$f"); done \
                < <(find "$tmp/$p" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*-debug-*')
        else
            warn "failed to build $p"
        fi
    done
    if [ "${#built[@]}" -gt 0 ]; then
        "${SUDO[@]}" pacman -U --noconfirm "${built[@]}" || warn "pacman -U failed for AUR packages"
    fi
    rm -rf "$tmp"
}

deploy_desktop() {
    local username="$1" repo="$2"
    local -a pkgs=(); mapfile -t pkgs < <(list_file "$repo/packages-repository.txt")

    say "Installing repo packages (${#pkgs[@]})"
    run "${SUDO[@]}" pacman -S --noconfirm --needed --disable-download-timeout "${pkgs[@]}"

    install_aur_pkgs "$username" "$repo/packages-aur.txt"

    # Default login shell -> zsh. The shipped .zshrc/.zprofile are only read
    # once zsh is the login shell, so this is what actually makes zsh "active".
    if [ "$(getent passwd "$username" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
        say "Setting zsh as the login shell for $username"
        run "${SUDO[@]}" chsh -s /usr/bin/zsh "$username" \
            || warn "could not set zsh as the login shell (run: chsh -s /usr/bin/zsh)"
    else
        note "login shell is already zsh"
    fi

    say "Deploying user configs to /home/$username"
    run "${SUDO[@]}" rsync -a "$repo/.config/" "/home/$username/.config/"
    run "${SUDO[@]}" rsync -a "$repo/home_config/" "/home/$username/"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] substitute __HOME__ / __OUTPUT__ in settings.toml"
    else
        sed -i "s|__HOME__|/home/$username|g; s|__OUTPUT__|DP-3|g" \
            "/home/$username/.local/state/noctalia/settings.toml"
    fi

    # Numix Circle icons for the live session (dconf + XSettings portal).
    set_user_dconf "$username" org.gnome.desktop.interface icon-theme "Numix-Circle"

    say "Deploying system configs to /etc"
    run "${SUDO[@]}" rsync -a --chown=root:root "$repo/etc/" /etc/

    # Lock on suspend: sleep.target exists only in the system manager, so the
    # lock must run as a system template, instantiated for this user. The unit
    # file is deployed by the etc/ rsync just above — enabling before that
    # fails with "Unit file ... does not exist". Needs a live user manager,
    # hence the DRY_RUN guard.
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] systemctl enable noctalia-lock@$username.service"
    else
        run "${SUDO[@]}" systemctl enable "noctalia-lock@$username.service" \
            || warn "could not enable noctalia-lock@$username.service (lock-on-suspend disabled)"
    fi

    run "${SUDO[@]}" chown -R "$username:$username" "/home/$username"

    system_fixes

    if [ "$(systemd-detect-virt 2>/dev/null || echo none)" != "none" ]; then
        # In VMs (no GPU accel) cage would refuse to start without software
        # rendering, taking the greeter down with it. Allow llvmpipe for it.
        if grep -q 'WLR_RENDERER_ALLOW_SOFTWARE' /etc/greetd/config.toml; then
            note "greeter already allows software rendering"
        else
            note "VM detected — allowing software rendering for the greeter"
            run "${SUDO[@]}" sed -i 's/^command = "/command = "env WLR_RENDERER_ALLOW_SOFTWARE=1 /' \
                /etc/greetd/config.toml
        fi
    fi

    say "Enabling greetd"
    run "${SUDO[@]}" systemctl -f enable greetd.service

    say "Installation complete — reboot and pick Hyprland at ReGreet."
}
