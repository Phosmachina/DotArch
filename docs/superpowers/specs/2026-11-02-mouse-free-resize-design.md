# Mouse-free window resize — design

- **Date:** 2026-11-02
- **Status:** approved in conversation; implementation plan pending
- **Scope:** `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` only

## Context and evidence

All facts below verified live on the laptop session (Hyprland 0.57.0, Lua config) on 2026-11-02, unless marked as source-derived.

### The chords are broken — root cause

`SUPER+CTRL+arrows` resize binds (keybindings.lua:121-124) are registered (confirmed via
`hyprctl binds`: modmask 68, dispatcher `HL.Dispatcher(exec_cmd)`) but each spawns
`hyprctl dispatch resizeactive "0 -5%"`. Since 0.57 (~2026-10-28), `hyprctl dispatch`
evaluates its argument as a Lua expression and the legacy `resizeactive` **global no longer
exists** — every press produces `attempt to call a nil value (global 'resizeactive')`
(exit 7) in the spawned process, invisible to the user. The bind recipe was a 0.56-era
workaround (percent strings rejected by `hl.dsp.window.resize`); on 0.57 it is dead.

### Tiled resize moves the split, not "the window"

Measured with decoy windows in a forced horizontal split (1069px each):

- `window.resize({x=+100, relative=true})` on the **left** window → left 1069→1169,
  right 1069→969: the shared split moved right.
- The same `+100` on the **right** window → the split *also* moved right
  (right window shrank 969→869). The delta direction is applied to the boundary
  regardless of which side window is targeted.
- On a vertical split, an x-delta is a no-op (no boundary in that axis).

Source (v0.57.0 `ConfigActions.cpp`): resize computes a delta and calls
`g_layoutManager->resizeTarget(delta, window->layoutTarget())`; it never sets geometry
directly and rejects fullscreen windows.

Consequence: the current chord mapping is sign-inverted — `←` is bound to `+x`
(moves the split right) and `→` to `−x`. This is the "resize is not aware of the
window position" feeling: the arrow direction and the boundary movement disagree.

### Floating resize is center-anchored

Measured: on a floated window, `+100` width grew **50px on each side** symmetrically.
A floating window near a screen edge grows half off-screen. Position-unaware.

### Interactive (drag) resize is already position-aware

The no-arg form of `hl.dsp.window.resize()` starts mouse-mode resize, which operates
on the corner nearest the cursor. This is the mechanism behind the existing
`Super + mouse:273` (right-drag) bind.

## Design

### 1. Super + three-finger tap → interactive resize

```lua
hl.bind(mainMod .. " + mouse:274", hl.dsp.window.resize())
```

- libinput maps a three-finger tap to middle button (`mouse:274`; `tap_to_click` is
  enabled). The bind requires SUPER, so bare three-finger taps keep middle-click paste.
- Finger motion resizes from the corner nearest the cursor; any tap/click ends it —
  same end-behavior as the existing drag-resize.
- `mouse:274` is unused; no conflicts.

**Probe-first unknowns** (live, before shipping):
1. The ELAN i2c pad emits three-finger taps as `mouse:274`.
2. A bind on a mouse button **without** `{mouse=true}` fires on the tap's press
   (the `{mouse=true}` flag gives bindm hold-to-drag semantics — wrong for a tap).
3. An interactive resize started by the dispatcher survives the tap's synthetic
   button-release (bind fires on press; release follows milliseconds later).

**Fallback chain** if any probe fails, in order:
1. `{mouse=true}` bindm form + libinput tap-drag gesture (tap 3 fingers, re-touch
   immediately, drag — libinput holds the button for you; drag ends on release).
2. Keyboard resize submap (`Super+R`-style, arrows/hjkl, repeating) — rejected as
   primary this round.

### 2. Fixed chords — same keys, honest mapping

Replace the four `exec_cmd` binds with the native dispatcher. Step size: **5% of the
resized axis of the window's current size** (computed in Lua via
`hl.get_active_window().size`, floored, minimum 10px) — percent strings are rejected
by the dispatcher, so the old "5%" behavior is recomputed per press.

Arrow mapping (edge-push semantics — the dispatcher already moves boundaries, so this
is a pure sign flip):

| Key | Old (broken) | New |
|-----|--------------|-----|
| `→` | `−5% 0` (split left) | `+x` — push boundary right |
| `←` | `+5% 0` (split right) | `−x` — push boundary left |
| `↓` | `0 −5%` | `+y` — push boundary down |
| `↑` | `0 +5%` | `−y` — push boundary up |

- Grouped windows: resize stays group-scoped (tabs share geometry) — deliberate,
  unchanged from the window-first-binds decision.
- Fullscreen windows: dispatcher rejects — accepted silent no-op.

### 3. Position-aware floating resize

For floating windows the dispatcher's center-symmetric growth is replaced by a Lua
handler that moves a **single boundary per axis**, chosen by position:

- Horizontal: window center left of its workspace center → the **right** edge is the
  boundary (`→` grows, `←` shrinks). Right of center → the **left** edge is the
  boundary (`←` grows, `→` shrinks).
- Vertical: window center above workspace center → bottom edge is the boundary
  (`↓` grows, `↑` shrinks); below → top edge.

Mechanism: relative resize of `d` (symmetric ±d/2) compensated by a position shift of
∓d/2, netting single-edge movement. The exact move call (window move with relative
pixel offsets vs `set_prop`) is confirmed at implementation time from the v0.57.0
dispatcher bindings.

Tiled windows take the plain sign-flipped path — no position math, because the
dispatcher *is* boundary movement for splits.

## Verification plan

- **Chords + floating semantics:** decoy-window harness (`kitty --class probe-rsz`),
  with the 2026-11-02 lesson applied: **extract from any group before moving** the
  decoy (`group:auto_group` adds spawns to the focused group; moving a grouped member
  hauls the whole group). Special workspace must be visible during measurement (hidden
  workspaces don't run layout). Count-check decoys before and after every state change
  (one historical double-execution incident).
- **Touchpad tap:** user-assisted, ~10 seconds — Super + three-finger tap, move finger,
  tap to end.
- **Regression:** `hyprctl binds` shows the new entries; `Super + mouse:272/273`
  drag binds unchanged; focus/move binds untouched.

## Out of scope

- Keyboard resize submap and `Super+R` alias (rejected in favor of direct binds).
- `keybindings.conf` parity edits — the file is dead on 0.57 (hyprlang never loads
  again); flipping `hyprland_remove_legacy_conf: true` in `deployment_config.yml` is a
  separate pending decision recommended soon.
- `swap-workspaces.sh` legacy `--batch` syntax, `resize_on_border`, percent-step
  configurability via variables.
