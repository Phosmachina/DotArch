# Waybar clock: native calendar tooltip + reliability fix

Date: 2026-08-21
Status: Approved

## Problem

Two symptoms reported on the waybar clock:

1. Hovering the clock does not show a calendar tooltip. (The user saw a
   storage-on-`/` tooltip instead — that text matches the neighboring `disk`
   module's default tooltip, most likely hovered while the clock was hidden.)
2. The clock module sometimes disappears completely from the bar, possibly
   correlated with suspend.

## Root cause

The clock is a custom module (`custom/clock`) running
`~/.config/waybar/scripts/waybar-clock.sh` (repo:
`roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-clock.sh`),
which emits JSON built by hand:

- `cal --color=always` closes today's highlight with `ESC[0m`, but the
  script's sed only rewrites `ESC[7m` / `ESC[27m`. A raw ESC byte stays inside
  the JSON string (invalid per RFC 8259; `jq` rejects it: "control characters
  from U+0000 through U+001F must be escaped") and the closing `</span></b>`
  tags are never inserted, so even a lenient parse yields unbalanced Pango
  markup. The tooltip is broken garbage.
- waybar 0.15.0 `src/modules/custom.cpp`: when the exec script's output stream
  ends, the worker logs "clock stopped unexpectedly, is it endless?" and stops
  permanently unless `restart-interval` is set; empty/failed output calls
  `event_box_.hide()`. Any transient script death (e.g. around suspend) leaves
  the module hidden until waybar restarts.

## Solution

Replace the custom module with waybar's built-in `clock` module. No script, no
JSON — both symptoms disappear by construction.

### Config (`roles/desktop/waybar/templates/home/.config/waybar/config.j2`)

- `modules-center`: `["clock"]` (was `["custom/clock"]`).
- Remove the `custom/clock` block; add:

```json
"clock": {
    "format": "{:%a, %b %d %H:%M}",
    "format-alt": "{:%a, %b %d %H:%M:%S}",
    "format-alt-click": 1,
    "interval": 1,
    "tooltip-format": "<tt>{calendar}</tt>",
    "calendar": {
        "mode": "month",
        "format": {
            "months": "<b>{}</b>",
            "weekdays": "<b>{}</b>",
            "today": "<b><span color='red'>{}</span></b>"
        }
    },
    "actions": {
        "on-scroll-up": "shift_up",
        "on-scroll-down": "shift_down"
    }
}
```

Behavior:

- Hover: native month calendar; today in bold red (matches the old script's
  intent); `<tt>` keeps columns aligned.
- Left-click: toggles HH:MM ↔ HH:MM:SS via `format-alt` + `format-alt-click: 1`
  (native in waybar 0.15 — verified in `src/ALabel.cpp`). The old script's
  click feature is preserved.
- `interval: 1` keeps the seconds format ticking; cost is one wake/sec, the
  same as the existing `cpu` module.
- Scroll up/down on the clock browses previous/next months in the tooltip.

### Role cleanup (`roles/desktop/waybar/tasks/main.yml`)

- Delete `files/home/.config/waybar/scripts/waybar-clock.sh`.
- Remove the "Copy Waybar clock script" task.
- Add a `state: absent` task for the deployed
  `~/.config/waybar/scripts/waybar-clock.sh` so it does not linger on hosts.

### CSS

No change: `style.css` already styles `#clock` (the old `custom-clock` id was
never styled).

### Applying

The role writes config only. Waybar picks it up on next relogin or immediately
via `pkill waybar; waybar & disown` (Hyprland `exec-once` does not respawn it).

## Testing

- `yamllint` + `ansible-lint` (molecule lint) for role/task changes.
- Render check: the templated config keeps the file's existing style (`//`
  comments, trailing commas) — already proven loadable by the deployed config;
  confirm the rendered JSON with a comment-stripped `jq empty` pass.
- Manual verification after deploy: hover shows calendar with today
  highlighted; click toggles seconds; scroll navigates months; suspend/resume
  leaves the clock visible.

## Out of scope

- The `disk` module's tooltip (storage info on `/`) is unchanged; it is a
  separate widget on the right side of the bar.
