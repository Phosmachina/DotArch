# Window-first semantics for grouped windows — design

Date: 2026-10-30
Status: approved (design), pending implementation
Scope: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` only

## Problem

On Hyprland 0.57.0 (Lua config), several commands implicitly target the
**group container** when the focused window is in a tab group:

- `SUPER + mouse:272` drag grabs the whole group (the drag starts on the
  window's *layout target*, which is the shared group target).
- `SUPER + SHIFT + F` floats the whole group (`changeFloatingMode` runs on
  the layout target).
- `SUPER + SHIFT + arrows` moves the whole group tile.
- `SUPER + SHIFT + 1..9` / `SUPER + SHIFT + grave` move the whole group to
  the workspace (`moveWindowToWorkspace` ends with
  `group()->updateWorkspace()`).

The user wants every command to act on the focused **window**: if it is in
a group, extract it first, then run the command on it alone.

Already built-in on 0.57 (kept, not reimplemented): dragging a tab by its
groupbar **header** extracts exactly that tab and drags it alone
(`CHyprGroupBarDecoration::onBeginWindowDragOnDeco`).

## Principle

Every window command targets the focused window, never the group
container. Group-native binds are untouched.

## Implementation

One helper in `keybindings.lua`:

```lua
-- Extract the active window from its group so commands target the
-- window, never the group container.
local function ungroupActive()
    local w = hl.get_active_window()
    if w and w.group then
        hl.dispatch(hl.dsp.window.move({ out_of_group = true }))
    end
end
```

Binds become Lua functions that call `ungroupActive()` before their
dispatcher (same multi-dispatch pattern as the existing power submap):

| Bind | Becomes |
|---|---|
| `SUPER + mouse:272` | if press is **not** on the tab strip: extract, then `window.drag()` |
| `SUPER + SHIFT + F` | extract, then `window.float({ action = "toggle" })` |
| `SUPER + SHIFT + ←/→/↑/↓` | extract, then `window.move({ direction = … })` |
| `SUPER + SHIFT + 1..9` | extract, then `window.move({ workspace = … })` |
| `SUPER + SHIFT + grave` | extract, then `window.move({ workspace = "special:magic" })` |

The `.group` check also means `out_of_group` never runs on an ungrouped
window (which would log a WARNING).

### Tab-strip guard (drag bind only)

Pressing on the groupbar must **not** pre-extract: the built-in per-tab
drag already handles header grabs, and pre-extracting would pop the
*active* tab (which may differ from the grabbed tab), making the built-in
handler extract a second, wrong tab. Guard: skip extraction when the
cursor is within ~20 px of the top edge of the active window's box
(groupbar height is 14 px in `hyprland.lua.j2`). Exact threshold and the
coordinate space of `w.at` are verified live.

## Unchanged

- `SUPER + K` toggle group; bracket keys (tab nav / reorder);
  `SUPER + G` / `SUPER + SHIFT + G` (join / leave group) — group-native.
- `SUPER + Z` close — already single-window.
- `SUPER + CTRL + arrows` resize — **exception**: tabs share geometry, so
  "resize this tab" does not exist while grouped; extracting just to
  resize would be destructive. Resize keeps operating on the visible tile.

## Consequences

- No mouse gesture moves a whole group anymore. Group relocation is
  tab-by-tab, or float-first. Escape hatch if ever needed: add
  `group_aware = true` move variants on another combo later.
- Alternative rejected: `group_aware = true` on direction moves — it
  auto-merges the window into any neighboring group in the direction;
  `SUPER + G` already covers deliberate merging.
- Alternative rejected (user decision): second combo (e.g.
  `SUPER + ALT + mouse:272`) for extract-drag, keeping group-drag on the
  plain combo.

## Verification checklist (live session)

1. `Hyprland --verify-config` clean (grep output; exit code lies).
2. Body-drag of a grouped window: exactly one window extracted and
   dragged; the rest of the group stays.
3. Header-drag of a non-active tab: only that tab extracts (built-in path
   not disturbed by the guard).
4. `group:focus_removed_window` default warps the cursor onto the
   extracted window so the chained drag grabs it — confirm.
5. Float on tiled group member: single window floats; rest of group intact.
6. Extract from an already-floating group (drag + float) — if placement is
   weird, fallback: skip extraction when `w.floating` is true.
7. `SUPER + SHIFT + 1..9` on group member: only that window changes ws.
8. Ungrouped windows: all five binds behave exactly as before.

## Deploy / revert

- Deploy: re-run the hyprland role config tasks (or copy the file) +
  `hyprctl reload`; hands-on test.
- Revert: restore previous `keybindings.lua` (git).
