# shellcheck shell=bash
# Deployment helpers shared by hyprland-install.sh and
# setup_hyprland_isomode.bash. Source lib/system-fixes.sh first (it provides
# say/note/warn/run/backup_file and system_fixes()).

list_file() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1"; }

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

    say "Deploying user configs to /home/$username"
    run "${SUDO[@]}" rsync -a "$repo/.config/" "/home/$username/.config/"
    run "${SUDO[@]}" rsync -a "$repo/home_config/" "/home/$username/"
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] substitute __HOME__ / __OUTPUT__ in settings.toml"
    else
        sed -i "s|__HOME__|/home/$username|g; s|__OUTPUT__|DP-3|g" \
            "/home/$username/.local/state/noctalia/settings.toml"
    fi

    # Lock on suspend: sleep.target exists only in the system manager, so the
    # lock must run as a system template (deployed via etc/), instantiated for
    # this user. Needs a live user manager, hence the DRY_RUN guard.
    if [ "$DRY_RUN" -eq 1 ]; then
        note "[dry-run] systemctl enable noctalia-lock@$username.service"
    else
        run "${SUDO[@]}" systemctl enable "noctalia-lock@$username.service" \
            || warn "could not enable noctalia-lock@$username.service (lock-on-suspend disabled)"
    fi

    run "${SUDO[@]}" chown -R "$username:$username" "/home/$username"

    say "Deploying system configs to /etc"
    run "${SUDO[@]}" rsync -a --chown=root:root "$repo/etc/" /etc/

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
