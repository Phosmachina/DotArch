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
- **Scheduling mechanism**: a systemd user timer fires exactly at each theme
  boundary; the triggered service applies the theme and plans the next
  boundary ("self-rescheduling timer"). The waybar module is a dumb display
  + click handler, nothing more. Rationale vs alternatives:
  - vs waybar-interval polling: exact fire times, works when waybar is dead
    or not yet started, no 30 s latency.
  - vs a sleep-until-next-boundary daemon: `sleep` counts monotonic time,
    which does not advance during suspend — on a laptop a missed boundary
    would fire hours late after resume. systemd calendar timers use
    realtime alarms and fire missed events on resume.
  - Self-rescheduling mechanics: the service writes the next boundary as an
    `OnCalendar=` drop-in for its own timer, then `systemctl --user
    daemon-reload && systemctl --user restart dotarch-theme.timer`.
    Inspectable at any time via `systemctl --user list-timers`.
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
- `~/.config/kitty/current-theme.conf` — real file managed by the script
  (content copy of the active theme + per-theme `background_opacity`;
  bootstrapped from `Dark_Pastel.conf`).
- `~/.config/waybar/colors-light.css`, `~/.config/waybar/colors-dark.css`,
  and `~/.config/waybar/colors.css` (active copy, initially = dark full
  stylesheet). Each `colors-<theme>.css` is a FULL stylesheet =
  `waybar/style.css` content + theme layer (`#custom-theme` chip + overrides)
  — regenerate them when the base styling changes. Loading chain: waybar
  0.15.0 has NO working `css` config key (string or array — silently
  ignored), so the waybar role templates `style.css` itself: themed mode
  renders it as a one-line `@import url("file://…/colors.css")`, unthemed
  mode renders the original base stylesheet.
- Package additions: `dconf` (gsettings needs the dconf backend to propagate
  to running apps). `gsettings-desktop-schemas` arrives via GTK deps.
- Systemd user units (deployed only by the theming role):
  - `~/.config/systemd/user/dotarch-theme.service` — `Type=oneshot`,
    `ExecStart=dotarch-theme run`, with `DBUS_SESSION_BUS_ADDRESS=
    unix:path=/run/user/%U/bus` in the unit environment so gsettings works
    from the user-manager context.
  - `~/.config/systemd/user/dotarch-theme.timer` — `OnBootSec=10s` (catch-up
    when the user manager starts, i.e. shortly after login) plus the
    script-managed drop-in `~/.config/systemd/user/dotarch-theme.timer.d/
    schedule.conf` carrying the current `OnCalendar=<next boundary>`.
  - Activation task: `systemctl --user enable --now dotarch-theme.timer`
    run as `ansible_user` with `XDG_RUNTIME_DIR=/run/user/<uid>` in the
    task environment (the known SSH-into-user-manager requirement).
    Guarded: if no user manager is reachable (deploy from a pure SSH
    context with no session), the task warns instead of failing and the
    timer activates at next login. `loginctl enable-linger` stays off by
    default (`theme_enable_linger: false`) — single-user desktop, and
    theming before first login has nothing visible to theme.

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

- `run` — what the timer service executes: `apply`, then plan the next
  boundary and rewrite the timer drop-in (`daemon-reload` + restart timer).
  No-op apply still replans, keeping the cadence self-healing.
- `apply` — resolve effective theme (mode=auto → sun times vs now), write
  state, apply components if `current` changed (idempotent). Does not touch
  the timer.
- `plan` — compute next boundary, rewrite drop-in, re-arm timer. No-op with
  a stderr warning when `systemctl --user` is unreachable.
- `set <auto|dark|light>` — set mode, then `run` (apply + replan), so a
  manual override immediately reshapes the schedule.
- `cycle` — `auto → dark → light → auto`, then `run`.
- `status --json` — read-only waybar JSON (text/class/tooltip). Never
  applies anything; the timer owns scheduling.

### Apply pipeline (per component) — as shipped after live fixes

`apply` ALWAYS re-applies components (no "already current" skip): a state /
reality divergence — e.g. an interrupted earlier apply — self-heals on the
next command instead of sticking permanently.

1. **kitty**: copy the theme file's CONTENT into `current-theme.conf` (a
   real file — kitty's reload does not re-follow a swapped symlink include,
   but does re-read include content), appending a per-theme
   `background_opacity` (dark 0.7 / light 0.6 — kitty.conf sets no opacity
   when theming is enabled, since the include parses first and a later
   global value would override the per-theme one); then
   `pkill --signal USR1 -x kitty`.
2. **waybar**: write the full `colors-<theme>.css` into `colors.css` IN
   PLACE (same inode), then `pkill --signal USR2 -x waybar` — on waybar
   0.15.0 the signals are configurable actions (`on-sigusr2` defaults to
   "reload"), and that reload re-reads the whole `style.css` → `@import`
   chain. (`reload_style_on_change` does NOT watch imported files, and
   inode-replacing writes orphan any watcher — hence in-place + signal.)
3. **GTK**: `gsettings set org.gnome.desktop.interface color-scheme
   prefer-dark|prefer-light`. Failure-tolerant: no dbus/no gsettings → log
   and continue.

### Waybar module

`custom/theme` in `modules-right` (near transcript/pulseaudio):

- `exec`: `dotarch-theme status --json`, `return-type: json`, `interval: 5`
  (display freshness only — the module is read-only; 5 s keeps click
  feedback snappy since state changes are event-driven).
- Icon: sun/moon reflecting the *effective* theme in every mode (no
  distinct pinned glyph and no "auto" badge). A forced mode is
  distinguished by the amber `.pinned` CSS class plus a "(pinned)"
  tooltip suffix, so auto vs pinned stays readable at a glance.
- Tooltip: mode + today's sunrise/sunset (fixed times when in fallback).
- Left-click: `cycle`. Scroll up/down: force `dark` / `light` directly.
- CSS classes `#custom-theme.dark/.light` plus `.pinned` in the color
  layers (and neutral rules in `style.css` if needed).

### Variables (deployment_config.yml)

- `enable_theme_switch: true`
- `theme_location: auto` (auto | coords)
- `theme_latitude` / `theme_longitude` — used when `theme_location: coords`.
  Sunrise/sunset are computed for those coordinates but rendered in the
  system timezone (host-frame times — meaningful for nearby coordinates
  only).
- `theme_day_time: "07:00"` / `theme_night_time: "20:00"` — fallback times.

### Tags

`[desktop, theme]` + `config` on copy/template tasks, matching conventions.

## Error handling

- `flock` around state read-modify-write (timer service vs click race).
- Sun calc failure / unknown timezone / python missing → fixed times.
- Missing Hyprland session or components not running → skip silently
  (exit 0); the script never blocks or fails the waybar module.
- `plan` tolerates an unreachable user manager (no `systemctl --user`):
  warn on stderr and continue — manual `set`/`apply` still work, the timer
  re-arms at next `run`.
- gsettings failure tolerated (logged to stderr → journal/waybar log).
- First run bootstraps state with `mode=auto`, `current=<by time of day>`.

## Testing

- Static: role structure passes `ansible-lint` + `yamllint` (molecule lint).
- Deploy: scoped `/tmp` playbook with `ANSIBLE_ROLES_PATH=../../roles`,
  `-e target=laptop`, `--tags config` (the known meta-role/tag workaround).
- Functional on host: `set/cycle` transitions state + symlink + `colors.css`;
  `status --json` output shape; kitty live reload (pty check); gsettings
  value flips; sun-cache refresh across a date boundary (simulate with a
  stale cache); fallback when timezone table misses.
- Timer behavior: `systemctl --user list-timers dotarch-theme.timer` shows
  the computed next boundary after `run`; drop-in rewrite + re-arm works
  (verify `NEXT` advances); firing at a boundary applies the flip (test
  with a schedule planted a minute out); missed-while-suspended behavior
  relies on systemd realtime alarms (spot-check after a short suspend if
  convenient).

## Out of scope (v1) / future levers

- Hyprland border colors via `hyprctl keyword` live reload.
- qimgv theme.conf swap (needs app restart).
- Wallpaper pair (fights random-wallpaper.sh).
- swaync CSS theming.

## Caveats documented for the user

- Firefox/Betterbird only follow the system scheme when their theme is set
  to "System theme — auto" (default). A manually selected Light/Dark theme
  in the browser ignores gsettings. `privacy.resistFingerprinting` also
  breaks scheme detection.
- GTK apps flip live via dconf over the session bus (no restart). Firefox
  usually flips live on Wayland; worst case new windows or one restart.
- GTK3-only apps with hardcoded palettes won't react — that's why kitty and
  waybar get explicit layers.
