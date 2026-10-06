-- Hyprland configuration (Lua) for the Noctalia setup.
-- Converted from the previous Sway config. "Balanced & cool": animations are
-- enabled but kept lean (no blur, no shadows, modest rounding) so the desktop
-- looks smooth without burning GPU/CPU.
--
-- Docs: https://wiki.hypr.land/configuring/
-- The full API stub ships at /usr/share/hypr/stubs/hl.meta.lua

------------------
---- MONITORS ----
------------------

-- Applies to every output; works regardless of the monitor's name.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "footclient"
local browser     = "firefox"
local fileManager = "thunar"

-- Noctalia surfaces (bar panels / overlays)
local launcher      = "noctalia msg panel-toggle launcher"
local controlCenter = "noctalia msg panel-toggle control-center"
local clipboard     = "noctalia msg panel-toggle clipboard"
local settingsPanel = "noctalia msg settings-toggle"
local windowSwitcher = "noctalia msg window-switcher"

-- Script paths expand $HOME inside the shell that runs them.
local hypr_scripts = "$HOME/.config/hypr/scripts"

-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function()
    -- Import the Wayland/session environment into the systemd user manager and
    -- the D-Bus activation environment (portal + Noctalia services need it).
    hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP")
    hl.exec_cmd("dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP")

    -- Noctalia shell: bar, notifications, launcher, lock/idle, clipboard, wallpaper.
    hl.exec_cmd("noctalia")

    -- Foot terminal server (skip if already running so reloads don't warn).
    hl.exec_cmd("sh -c 'pgrep -x foot >/dev/null 2>&1 || foot --server'")

    -- Network + firewall applets.
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("sh -c 'sleep 2 && firewall-applet'")
end)

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 4,
        border_size = 2,

        -- Catppuccin Mocha accent gradient on the focused window.
        col = {
            active_border   = { colors = { "rgba(cba6f7ee)", "rgba(89b4faee)" }, angle = 45 },
            inactive_border = "rgba(45475aaa)",
        },

        resize_on_border = false,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    decoration = {
        rounding       = 8,
        rounding_power = 2,

        -- Full opacity: transparency costs fill-rate, and the Noctalia bar/panels
        -- draw their own translucency.
        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        -- No blur, no shadows: the expensive effects, deliberately off.
        shadow = { enabled = false },
        blur   = { enabled = false },
    },

    animations = { enabled = true },

    dwindle = { preserve_split = true },

    misc = {
        disable_hyprland_logo   = true,
        force_default_wallpaper = 0,
        disable_splash_rendering = true,
    },
})

-- Lean animation set: popin windows, fading layers, sliding workspaces.
-- Everything here is cheap; no gradients/blur/shadow animation is enabled.
hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1}    } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1}    } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}       } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1}    } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}     } })

hl.animation({ leaf = "global",        enabled = true, speed = 8.0, bezier = "default" })
hl.animation({ leaf = "windows",       enabled = true, speed = 4.5, bezier = "quick" })
hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.5, bezier = "easeOutQuint", style = "popin 90%" })
hl.animation({ leaf = "windowsOut",    enabled = true, speed = 3.0, bezier = "linear",       style = "popin 90%" })
hl.animation({ leaf = "fade",          enabled = true, speed = 3.0, bezier = "quick" })
hl.animation({ leaf = "fadeIn",        enabled = true, speed = 2.5, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true, speed = 2.0, bezier = "almostLinear" })
hl.animation({ leaf = "layers",        enabled = true, speed = 3.8, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 4.0, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5, bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.8, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.4, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true, speed = 4.0, bezier = "easeOutQuint", style = "slide" })
hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 4.0, bezier = "easeOutQuint", style = "slide" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 4.0, bezier = "easeOutQuint", style = "slide" })

-- Keep empty workspaces visible in Noctalia's workspace indicator.
for i = 1, 10 do
    hl.workspace_rule({ workspace = tostring(i), persistent = true })
end

---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout          = "us",
        kb_variant         = "",
        numlock_by_default = true,
        follow_mouse       = 1,
        sensitivity        = 0,

        touchpad = {
            natural_scroll      = true,
            disable_while_typing = true,
            tap_to_click         = true,
        },
    },
})

-- Three-finger horizontal swipe switches workspaces (laptop friendly).
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

-- Basics
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + Q",      hl.dsp.window.close())
hl.bind(mainMod .. " + W",      hl.dsp.window.close())
hl.bind(mainMod .. " + D",      hl.dsp.exec_cmd(launcher))
hl.bind(mainMod .. " + Space",  hl.dsp.exec_cmd(launcher))
hl.bind(mainMod .. " + S",      hl.dsp.exec_cmd(controlCenter))
hl.bind(mainMod .. " + comma",  hl.dsp.exec_cmd(settingsPanel))
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd(launcher))
hl.bind(mainMod .. " + F1",     hl.dsp.exec_cmd("noctalia msg session lock"))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd(hypr_scripts .. "/power_menu.sh"))
hl.bind(mainMod .. " + SHIFT + C", hl.dsp.reload_config())

-- Window switcher (Noctalia overlay); ALT+Tab mirrors the docs' "hold" action.
hl.bind(mainMod .. " + P",  hl.dsp.exec_cmd(windowSwitcher))
hl.bind("ALT + Tab",        hl.dsp.exec_cmd(windowSwitcher .. " hold"))

-- Maximize / fullscreen (Hyprland's built-in maximize, no helper script)
hl.bind(mainMod .. " + F",        hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))

-- Keybind cheatsheet (community plugin kenn/keybind-cheatsheet)
hl.bind(mainMod .. " + SHIFT + slash", hl.dsp.exec_cmd("noctalia msg panel-toggle kenn/keybind-cheatsheet:cheatsheet"))

-- Application shortcuts
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + O", hl.dsp.exec_cmd(browser))

-- Clipboard history (Noctalia)
hl.bind(mainMod .. " + CTRL + V", hl.dsp.exec_cmd(clipboard))

-- Fuzzy shell-history popup (foot + fzf)
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd("footclient --app-id=fzf-history " .. hypr_scripts .. "/fzf-history.sh"))

-- Focus (arrows + vim keys)
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + h",     hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + j",     hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + k",     hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + l",     hl.dsp.focus({ direction = "right" }))

-- Move the focused window (arrows + vim keys)
hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }))
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "up" }))
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "down" }))
hl.bind(mainMod .. " + SHIFT + h",     hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + SHIFT + j",     hl.dsp.window.move({ direction = "down" }))
hl.bind(mainMod .. " + SHIFT + k",     hl.dsp.window.move({ direction = "up" }))
hl.bind(mainMod .. " + SHIFT + l",     hl.dsp.window.move({ direction = "right" }))

-- Workspaces 1-10
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + " .. key,          hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key,  hl.dsp.window.move({ workspace = i }))
end

-- Scratchpad (special workspace)
hl.bind(mainMod .. " + SHIFT + minus", hl.dsp.window.move({ workspace = "special:magic" }))
hl.bind(mainMod .. " + minus",         hl.dsp.workspace.toggle_special("magic"))

-- Layout / windows
hl.bind(mainMod .. " + V",              hl.dsp.layout("togglesplit"))
hl.bind(mainMod .. " + SHIFT + space",  hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + G",              hl.dsp.group.toggle())

-- Resize with mainMod + CTRL + arrows / vim keys
hl.bind(mainMod .. " + CTRL + left",  hl.dsp.window.resize({ x = -20, y = 0, relative = true }))
hl.bind(mainMod .. " + CTRL + right", hl.dsp.window.resize({ x = 20,  y = 0, relative = true }))
hl.bind(mainMod .. " + CTRL + up",    hl.dsp.window.resize({ x = 0, y = -20, relative = true }))
hl.bind(mainMod .. " + CTRL + down",  hl.dsp.window.resize({ x = 0, y = 20,  relative = true }))
hl.bind(mainMod .. " + CTRL + h",     hl.dsp.window.resize({ x = -20, y = 0, relative = true }))
hl.bind(mainMod .. " + CTRL + l",     hl.dsp.window.resize({ x = 20,  y = 0, relative = true }))
hl.bind(mainMod .. " + CTRL + k",     hl.dsp.window.resize({ x = 0, y = -20, relative = true }))
hl.bind(mainMod .. " + CTRL + j",     hl.dsp.window.resize({ x = 0, y = 20,  relative = true }))

-- Move/resize with the mouse
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Scroll through workspaces
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Media keys (Noctalia draws the OSD)
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("noctalia msg volume-up"),      { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("noctalia msg volume-down"),    { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("noctalia msg volume-mute"),    { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("noctalia msg mic-mute"),       { locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("noctalia msg brightness-up"),  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("noctalia msg brightness-down"),{ locked = true, repeating = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

-- Screenshots
hl.bind("Print",        hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | swappy -f -"))
hl.bind("CTRL + Print", hl.dsp.exec_cmd(hypr_scripts .. "/screenshot_window.sh"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd(hypr_scripts .. "/screenshot_display.sh"))

-- Mouse button on the bar toggles Noctalia control center is handled by Noctalia.

--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- Floating dialogs / utilities (ported from Sway's application_defaults)
hl.window_rule({ name = "yad",             match = { class = "^(yad|Yad)$" },                 float = true })
hl.window_rule({ name = "blueman",         match = { class = "blueman-manager" },             float = true, size = { 720, 540 } })
hl.window_rule({ name = "pavucontrol",     match = { class = "pavucontrol" },                 float = true, size = { 720, 540 } })
hl.window_rule({ name = "preferences",     match = { title = "^(Preferences|About)$" },       float = true })
hl.window_rule({ name = "file-progress",   match = { title = "File Operation Progress" },     float = true, pin = true, size = { 400, 300 } })
hl.window_rule({ name = "pip",             match = { title = "Picture in picture" },          float = true, pin = true })
hl.window_rule({ name = "save-file",       match = { title = "Save File" },                   float = true })
hl.window_rule({ name = "fzf-history",     match = { class = "fzf-history" },                 float = true, center = true, size = { 900, 520 } })

-- Keep the machine awake while a video is fullscreen.
hl.window_rule({ name = "inhibit-firefox",  match = { class = "firefox" },  idle_inhibit = "fullscreen" })
hl.window_rule({ name = "inhibit-chromium", match = { class = "chromium" }, idle_inhibit = "fullscreen" })

-- Noctalia settings window: floating, sized.
hl.window_rule({ name = "noctalia-settings", match = { class = "dev.noctalia.Noctalia" }, float = true, size = { 1080, 920 } })

-- Noctalia layer surfaces: skip compositor animations (Noctalia animates itself).
-- No blur here on purpose; this setup has compositor blur disabled.
hl.layer_rule({
    name  = "noctalia",
    match = {
        namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$",
    },
    no_anim      = true,
    ignore_alpha = 0.5,
})
