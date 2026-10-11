# Day/Night Theme Switching — Design

Date: 2026-10-11
Status: approved (design), pending implementation

## Goal

Time-based dark/light theme switching for the Hyprland desktop, with a waybar
module that shows the current state and cycles `auto → dark → light`.

## Current state

Everything is dark-only and statically deployed by Ansible:

- kitty: `kitty.conf` hardcodes `include Dark_Pastel.conf` (which carries the
  color8 `#8f8f8f` fix from 23fe0aa). No light theme exists.
- waybar: single static `style.css`, dark translucent modules. CSS hot-reloads
  (verified in a previous session); `SIGUSR2` also forces a CSS reload.
- No GTK color-scheme management anywhere. `QT_QPA_PLATFORMTHEME=qt5ct` is set
  but no qt5ct config is deployed.
- swaync uses its built-in CSS. hyprsunset (blue light) autostarts and is
  unrelated to app theming.

## Decisions

- **Schedule**: sun-based (NOAA sunrise/sunset math, offline, in-process
  python3 — python3 is guaranteed present because kitty depends on it).
  Fixed-time fallback when location is unknown. Rationale: French sunset
  swings ~16:50–21:45 across the year; any fixed cutoff is wrong most of the
  time.
- **Location source**: no coordinates to configure by default.
  `theme_location: auto` reads the system timezone (`timedatectl show -p
  Timezone --value`) and maps it to representative coordinates via a small
  built-in table (e.g. `Europe/Paris → 48.85, 2.35`). Accuracy anywhere in
  mainland France is within ~±20 min of true sunset — acceptable for theming.
  Explicit `theme_latitude`/`theme_longitude` override for precision.
- **Scope (v1, "core")**: kitty, waybar, GTK color-scheme (which drives
  Firefox/Betterbird when they use the system theme, plus libadwaita apps
  like Vicinae). Hyprland borders, qimgv, and a wallpaper pair are explicit
  non-goals for v1.
- **Scheduling mechanism**: the waybar `custom/theme` module's periodic exec
  runs `apply` (idempotent). No systemd user units — waybar autostarts with
  the session, so the theme applies at login and re-evaluates every interval.
  Trade-off accepted: if waybar is dead, auto-switching pauses until restart.
- **Dark stays byte-identical**: `style.css` and `Dark_Pastel.conf` are not
  modified visually; light mode is purely additive layers. Zero regression
  risk for the current look.

## Architecture

New role `roles/desktop/theming/`, wired with the standard three edits:
role itself, `include_role` block in `roles/profiles/desktop-hyprland/tasks/main.yml`
(gated on `enable_theme_switch`), and the default in
`group_vars/all/deployment_config.yml`.

### Files deployed

By the **theming role**:

- `~/.local/bin/dotarch-theme` (0755) — the switcher CLI.
- `~/.config/kitty/theme-light.conf` — authored light theme (light bg,
  dark fg, same hue family as Dark_Pastel).
- `~/.config/kitty/current-theme.conf` — symlink managed by the script
  (bootstrapped → `Dark_Pastel.conf`).
- `~/.config/waybar/colors-light.css`, `~/.config/waybar/colors-dark.css`,
  and `~/.config/waybar/colors.css` (active copy, initially = dark layer;
  `colors-dark.css` is a near-empty no-op — the dark look comes from
  `style.css` alone, which is why dark stays byte-identical).
- Package additions: `dconf` (gsettings needs the dconf backend to propagate
  to running apps). `gsettings-desktop-schemas` arrives via GTK deps.

By the **terminal role** (it owns `kitty.conf`; no second owner):
`kitty.conf` becomes a Jinja template with
`include {% if enable_theme_switch %}current-theme.conf{% else %}Dark_Pastel.conf{% endif %}`
— unchanged behavior when the feature is off.

By the **waybar role** (it owns `config.j2`; no second owner): when
`enable_theme_switch`, add the `custom/theme` module to `modules-right` and
emit the `css` key as `["style.css", "colors.css"]` (no `css` key otherwise).

### State

`~/.local/state/dotarch-theme/`:

- `state` — `mode=<auto|dark|light>`, `current=<dark|light>`.
- `sun-cache` — date, sunrise, sunset (ISO times). Refreshed when the date
  changes or the file is missing.

### dotarch-theme CLI contract

- `apply` — resolve effective theme (mode=auto → sun times vs now), write
  state, apply components if `current` changed (idempotent; cheap when
  unchanged). Safe to run every waybar interval.
- `set <auto|dark|light>` — set mode, then `apply`.
- `cycle` — `auto → dark → light → auto`, then `apply`.
- `status --json` — emit waybar JSON (text/class/tooltip); also runs
  `apply` first so the module tick doubles as the scheduler.

### Apply pipeline (per component)

1. **kitty**: flip `current-theme.conf` symlink → target theme file; then
   `pkill -USR1 -x kitty` (full config reload including includes). New
   windows read the symlink at startup anyway.
2. **waybar**: atomically copy `colors-<theme>.css` → `colors.css`; CSS
   hot-reload picks it up; also `pkill -USR2 -x waybar` as belt-and-braces.
   The `css` array is `["style.css", "colors.css"]` so the layer overrides
   equal-specificity rules in `style.css` by order.
3. **GTK**: `gsettings set org.gnome.desktop.interface color-scheme
   prefer-dark|prefer-light`. Failure-tolerant: no dbus/no gsettings → log
   and continue.

### Waybar module

`custom/theme` in `modules-right` (near transcript/pulseaudio):

- `exec`: `dotarch-theme status --json`, `return-type: json`, `interval: 30`.
- Icon: sun/moon reflecting the *effective* theme in auto; a distinct
  "pinned" glyph (e.g. 󰁦 / 󰾲 with a small "auto" badge character) when
  forced, so auto vs pinned is readable at a glance.
- Tooltip: mode + today's sunrise/sunset (fixed times when in fallback).
- Left-click: `cycle`. Scroll up/down: force `dark` / `light` directly.
- CSS classes `#custom-theme.dark/.light/.auto` in `colors-light.css` (and
  neutral rules in `style.css` if needed).

### Variables (deployment_config.yml)

- `enable_theme_switch: true`
- `theme_location: auto` (auto | coords)
- `theme_latitude` / `theme_longitude` — used when `theme_location: coords`.
- `theme_day_time: "07:00"` / `theme_night_time: "20:00"` — fallback times.
- `theme_cycle_order: [auto, dark, light]`

### Tags

`[desktop, theme]` + `config` on copy/template tasks, matching conventions.

## Error handling

- `flock` around state read-modify-write (waybar tick vs click race).
- Sun calc failure / unknown timezone / python missing → fixed times.
- Missing Hyprland session or components not running → skip silently
  (exit 0); the script never blocks or fails the waybar module.
- gsettings failure tolerated (logged to stderr → waybar log).
- First run bootstraps state with `mode=auto`, `current=<by time of day>`.

## Testing

- Static: role structure passes `ansible-lint` + `yamllint` (molecule lint).
- Deploy: scoped `/tmp` playbook with `ANSIBLE_ROLES_PATH=../../roles`,
  `-e target=laptop`, `--tags config` (the known meta-role/tag workaround).
- Functional on host: `set/cycle` transitions state + symlink + `colors.css`;
  `status --json` output shape; kitty live reload (pty check); gsettings
  value flips; sun-cache refresh across a date boundary (simulate with a
  stale cache); fallback when timezone table misses.

## Out of scope (v1) / future levers

- Hyprland border colors via `hyprctl keyword` live reload.
- qimgv theme.conf swap (needs app restart).
- Wallpaper pair (fights random-wallpaper.sh).
- swaync CSS theming; systemd user timer for waybar-less switching.

## Caveats documented for the user

- Firefox/Betterbird only follow the system scheme when their theme is set
  to "System theme — auto" (default). A manually selected Light/Dark theme
  in the browser ignores gsettings. `privacy.resistFingerprinting` also
  breaks scheme detection.
- GTK apps flip live via dconf over the session bus (no restart). Firefox
  usually flips live on Wayland; worst case new windows or one restart.
- GTK3-only apps with hardcoded palettes won't react — that's why kitty and
  waybar get explicit layers.
