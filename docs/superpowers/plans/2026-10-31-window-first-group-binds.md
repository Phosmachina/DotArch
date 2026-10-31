# Window-First Group Binds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every window command (drag, float, direction-move, workspace-move) target the focused window — extracting it from its tab group first — instead of the group container.

**Architecture:** One Lua helper (`ungroupActive()`) plus function-valued binds in the single Hyprland keybind module. Verification is live-session red/green: the same dispatcher logic the binds use is executed over the `hyprctl dispatch` socket (which accepts Lua functions) against decoy kitty groups, before and after the change.

**Tech Stack:** Hyprland 0.57.0 Lua config (`hl.bind`, `hl.dsp.*`, `hl.get_active_window`, `hl.get_cursor_pos`), hyprctl socket, DotArch Ansible role layout.

**Spec:** `docs/superpowers/specs/2026-10-30-window-first-group-binds-design.md`

## Global Constraints

- Hyprland 0.57.0 on the live session; `hyprctl` needs the session env (derivation command below).
- Only repo file modified: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` (currently clean in git — verify). Commit only that file; the user has unrelated dirty files.
- Scratch files must live in repo `.zcode/` (sandboxed `/tmp` is invisible to the session), never `/tmp`.
- `Hyprland --verify-config` exits 0 even when errors are listed — always grep its output.
- No unit-test framework exists for Hyprland configs; red/green = live-session probes.
- Every `hyprctl` shell step begins by exporting the session env:

```bash
export WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$(tr '\0' '\n' < /proc/$(pgrep -x waybar | head -1)/environ | sed -n 's/^HYPRLAND_INSTANCE_SIGNATURE=//p') XDG_RUNTIME_DIR=/run/user/1000
```

---

### Task 0: Pre-flight — session env, drift check, decoy harness

**Files:** none modified. Produces: verified probe commands for Tasks 1–2.

- [ ] **Step 1: Derive session env and confirm version**

```bash
export WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$(tr '\0' '\n' < /proc/$(pgrep -x waybar | head -1)/environ | sed -n 's/^HYPRLAND_INSTANCE_SIGNATURE=//p') XDG_RUNTIME_DIR=/run/user/1000
hyprctl version | head -1
```

Expected: `Hyprland 0.57.0 ...` (if the signature changed or waybar is gone, re-derive from any live client: `kitty`, `vicinae`).

- [ ] **Step 2: Check deployed-file drift**

```bash
diff roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua && echo IN-SYNC
git status --porcelain roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua
```

Expected: `IN-SYNC` and empty git status for the file. If drift: stop and surface the diff to the user before proceeding.

- [ ] **Step 3: Build a 3-window decoy group and confirm group semantics**

Open decoys one at a time (each new window takes focus, so `group.toggle()` after each open builds one group — same mechanics as the user's `SUPER + K`):

```bash
setsid -f kitty --title g1 sh -c 'sleep 600' ; sleep 0.8
hyprctl dispatch 'hl.dsp.group.toggle()'
setsid -f kitty --title g2 sh -c 'sleep 600' ; sleep 0.8
hyprctl dispatch 'hl.dsp.group.toggle()'
setsid -f kitty --title g3 sh -c 'sleep 600' ; sleep 0.8
hyprctl dispatch 'hl.dsp.group.toggle()'
hyprctl -j activewindow
```

Then probe the JSON shape once (field names needed by later asserts):

```bash
hyprctl -j clients > .zcode/clients-probe.json
grep -o '"grouped":\[[^]]*\]' .zcode/clients-probe.json | sort | uniq -c
grep -o '"floating":[a-z]*' .zcode/clients-probe.json | sort | uniq -c
```

Expected: one `grouped` list containing 3 addresses (the g1/g2/g3 windows); all `"floating":false`. If the `grouped` field is absent in 0.57 JSON, fall back to counting via `hyprctl -j activewindow` while cycling `hl.dsp.group.next()` — record whichever observable works; use it in all later asserts.

- [ ] **Step 4: RED — capture today's group-container behavior**

With the active window being a decoy group member:

```bash
hyprctl dispatch 'hl.dsp.window.float({ action = "toggle" })'
sleep 0.5
hyprctl -j clients | grep -o '"floating":[a-z]*' | sort | uniq -c
```

Expected (red): **all three** decoys report `"floating":true` — the toggle floated the whole group. Restore state and record it:

```bash
hyprctl dispatch 'hl.dsp.window.float({ action = "toggle" })'
```

Also record the ws-move red on a scratch workspace if desired (optional; float red is the reference evidence).

- [ ] **Step 5: Clean up decoys (keep the command for reuse)**

```bash
pkill -f 'kitty --title g[123]'
```

Expected: three windows close; `hyprctl -j clients | grep -c '"title":"g[123]"'` → 0.

---

### Task 1: `ungroupActive()` helper + window-first keyboard binds

**Files:**
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: `local function ungroupActive()` (exact name — Task 2's drag bind calls it).

- [ ] **Step 1: Add the helper after the `local` declarations (line 5)**

Insert after `local mainMod = "SUPER"`:

```lua
-- Extract the active window from its group so commands below target the
-- window, never the group container. Group-native binds (SUPER+K, G,
-- brackets) are untouched, and built-in groupbar tab-header drags still
-- work (see the mouse drag bind).
local function ungroupActive()
    local w = hl.get_active_window()
    if w and w.group then
        hl.dispatch(hl.dsp.window.move({ out_of_group = true }))
    end
end
```

- [ ] **Step 2: Rewrite the float bind (currently line ~22)**

Replace:

```lua
hl.bind("SUPER + SHIFT + F", hl.dsp.window.float({ action = "toggle" }))
```

with:

```lua
hl.bind("SUPER + SHIFT + F", function()
    ungroupActive()
    hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
end)
```

- [ ] **Step 3: Rewrite the four direction moves (currently lines ~96–99)**

Replace each of the four `hl.bind("SUPER + SHIFT + <dir>", hl.dsp.window.move({ direction = "…" }))` lines with the function form, e.g. for left:

```lua
hl.bind("SUPER + SHIFT + left", function()
    ungroupActive()
    hl.dispatch(hl.dsp.window.move({ direction = "l" }))
end)
```

Repeat verbatim pattern for `down`/`"d"`, `up`/`"u"`, `right`/`"r"`.

- [ ] **Step 4: Rewrite the workspace-move binds (currently lines ~104–108)**

Replace the loop with:

```lua
for i = 1, 9 do
    local workspace = string.format("%02d", i)
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = workspace }))
    hl.bind("SUPER + SHIFT + " .. i, function()
        ungroupActive()
        hl.dispatch(hl.dsp.window.move({ workspace = workspace }))
    end)
end
```

(`local workspace` inside the loop body gives each closure its own upvalue — capture is correct.)

- [ ] **Step 5: Rewrite the scratchpad move bind (currently line ~125)**

Replace:

```lua
hl.bind("SUPER + SHIFT + grave", hl.dsp.window.move({ workspace = "special:magic" }))
```

with:

```lua
hl.bind("SUPER + SHIFT + grave", function()
    ungroupActive()
    hl.dispatch(hl.dsp.window.move({ workspace = "special:magic" }))
end)
```

- [ ] **Step 6: Validate config**

```bash
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i 'error' ; echo "exit=$?"
```

Expected: no error lines (run against the still-deployed OLD keybindings — this just proves the binary flag works; the real validation is Step 8 after deploy).

- [ ] **Step 7: Deploy and reload**

```bash
cp roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua
hyprctl reload
sleep 1
```

Expected: reload OK. If the sandbox blocks the `cp`, write the file with the Write tool instead (it sees the real FS). The overwrite triggers inotify auto-reload anyway; `hyprctl reload` is belt-and-braces. (Never delete `hyprland.lua` — deletion regenerates a stub and kills binds.)

- [ ] **Step 8: Validate the NEW config**

```bash
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i 'error'
```

Expected: empty. Also try `hyprctl binds 2>&1 | grep -i -A2 'shift.*f'` — if the request exists on 0.57, confirm the new bind is registered; if it errors, rely on Step 9–10 probes.

- [ ] **Step 9: GREEN (logic) — float on grouped decoy**

Rebuild the decoy group (Task 0 Step 3 commands), then run the new bind's exact body over the socket:

```bash
hyprctl dispatch 'function() local w = hl.get_active_window(); if w and w.group then hl.dispatch(hl.dsp.window.move({ out_of_group = true })) end; hl.dispatch(hl.dsp.window.float({ action = "toggle" })) end'
sleep 0.5
hyprctl -j clients | grep -o '"floating":[a-z]*' | sort | uniq -c
```

Expected (green): exactly **one** decoy `"floating":true` (the active one), and its `grouped` list no longer contains the other two (they remain grouped together).

- [ ] **Step 10: GREEN (logic) — workspace move on grouped decoy**

Re-group the floater (`hyprctl dispatch 'hl.dsp.window.float({ action = "toggle" })'`, re-run two `group.toggle()` cycles via Task 0 pattern), then:

```bash
hyprctl dispatch 'function() local w = hl.get_active_window(); if w and w.group then hl.dispatch(hl.dsp.window.move({ out_of_group = true })) end; hl.dispatch(hl.dsp.window.move({ workspace = "02" })) end'
sleep 0.5
hyprctl -j clients | grep -c '"workspace": { "id": 2'
```

Expected: exactly 1 (the active decoy moved; the other two stay on workspace 1). Then bring it back and clean up decoys (`pkill -f 'kitty --title g[123]'`).

- [ ] **Step 11: Commit**

```bash
git add roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua
git commit -m "feat(hyprland): window-first keyboard binds — extract from group before float/move/workspace"
```

---

### Task 2: Window-first mouse drag + tab-strip guard

**Files:**
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` (mouse bind, currently line ~78)

**Interfaces:**
- Consumes: `ungroupActive()` from Task 1.
- Produces: nothing downstream.

- [ ] **Step 1: Probe coordinate spaces on a decoy group**

Rebuild the decoy group (Task 0 Step 3). Warp the cursor to the active window and read both APIs:

```bash
hyprctl dispatch 'hl.dsp.exec_cmd("true")' >/dev/null 2>&1 # noop warm-up if needed
hyprctl dispatch 'function() local w = hl.get_active_window(); local c = hl.get_cursor_pos(); hl.print(string.format("AT %d,%d SIZE %dx%d CURSOR %d,%d", w.at.x, w.at.y, w.size.x, w.size.y, c.x, c.y)) end'
```

If `hl.print` is config-load-only, get the numbers via two requests instead: `hyprctl cursorpos` (if it exists on 0.57) and `hyprctl -j activewindow | grep -o '"at":\[[0-9,]*\]'`. Compare `cursor.y` to `at.y` after also running `hyprctl dispatch movecursortop` (warps cursor to window top). Decide the guard form:
  - If `at.y` ≈ cursor-y-at-top-of-groupbar → strip = `[at.y, at.y + 20)` → guard: `cursor.y - w.at.y > 20` means body.
  - If `at.y` is the content box (groupbar above it) → strip = `[at.y - 20, at.y)` → guard: `cursor.y > w.at.y`.
Record which form applies.

- [ ] **Step 2: Rewrite the drag bind**

Replace:

```lua
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
```

with (form A — adjust the single guard comparison if Step 1 said form B):

```lua
-- Window-first drag: grabbing the body extracts the focused window from
-- its group; grabbing the tab strip (top ~20px; groupbar is 14px) keeps
-- the built-in per-tab header drag. Position must be checked BEFORE
-- extracting.
hl.bind(mainMod .. " + mouse:272", function()
    local w      = hl.get_active_window()
    local cursor = hl.get_cursor_pos()
    if w and cursor and w.group and cursor.y - w.at.y > 20 then
        ungroupActive()
    end
    hl.dispatch(hl.dsp.window.drag())
end, { mouse = true })
```

The resize bind (`mouse:273`) below it stays unchanged (spec: resize exception).

- [ ] **Step 3: Validate, deploy, reload**

```bash
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i 'error'
cp roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua
hyprctl reload
```

Expected: no error lines.

- [ ] **Step 4: GREEN (mechanics) — extraction warps cursor onto the freed window**

On a fresh decoy group:

```bash
hyprctl dispatch 'hl.dsp.window.move({ out_of_group = true })'
sleep 0.3
hyprctl cursorpos 2>/dev/null || true
hyprctl -j activewindow | grep -o '"at":\[[0-9,]*\]'
```

Expected: cursor position falls inside the active window's `at`/`size` box (this is what makes the chained `window.drag()` grab the right window; relies on `group:focus_removed_window` default = true). If the cursor did NOT warp, stop and re-check that config value before relying on the drag bind.

- [ ] **Step 5: Hands-on verification (user) — the part sockets can't press**

Ask the user to confirm, on a group of ≥2 tabs:
1. Drag a tab by its **body** with Win+LMB → only that window comes out; the rest stay grouped.
2. Drag a **non-active tab's header** in the groupbar → exactly that tab comes out (built-in path undisturbed by the guard).
3. Win+LMB drag on an ungrouped window → behaves as before.
4. Optional: float/drag inside a floating group — if placement is weird, apply the spec fallback (skip extraction when `w.floating` is true).

- [ ] **Step 6: Clean up and commit**

```bash
pkill -f 'kitty --title g[123]'
git add roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua
git commit -m "feat(hyprland): window-first mouse drag — body-drag extracts current window, header-drag keeps per-tab"
```

---

## Post-plan (not tasks)

- The Ansible hyprland role will converge `~/.config/hypr/keybindings.lua` as a no-op on next deploy (same file content).
- Update auto-memory `hyprland-lua-config-reference` with findings: `hyprctl dispatch` accepts function literals; `hl.get_active_window().group/.floating/.at`; groupbar header-drag built-in; binds-accept-functions for `{mouse=true}`.
