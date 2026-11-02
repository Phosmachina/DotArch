# Mouse-Free Window Resize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make window resizing fully usable without a mouse: Super + three-finger touchpad tap starts an interactive resize, and the SUPER+CTRL+arrow chords work again with position-aware, edge-push semantics.

**Architecture:** All changes live in one file — the Hyprland Lua keybinding config — plus live-session probes on the host. The touchpad bind is probed user-assisted before shipping (three unknowns: tap→`mouse:274` emission, non-drag mouse bind firing, interactive resize surviving the tap's synthetic release). The chords switch from a dead 0.56-era `hyprctl dispatch resizeactive` workaround to the native `hl.dsp.window.resize` dispatcher, sign-flipped so arrows push window boundaries in the arrow direction; floating windows get a Lua handler that moves one edge at a time instead of the dispatcher's center-symmetric growth.

**Tech Stack:** Hyprland 0.57.0 Lua config (`hl.bind`, `hl.dsp.*`, `hl.get_active_window`, `hl.get_active_monitor`, `hl.get_window`), hyprctl socket dispatch (Lua-expression form), decoy-window verification via `kitty --class probe-rsz` + `hyprctl -j clients`.

## Global Constraints

- Repo source of truth: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua`. Live host file: `~/.config/hypr/keybindings.lua`. They must be byte-identical after the final task.
- **Never edit `keybindings.conf`** — hyprlang is dead on 0.57, the file never loads.
- **`hyprctl reload` only after `Hyprland --verify-config` shows no errors** (it exits 0 even on errors — always grep the output).
- Scratch scripts live in the repo's `.zcode/` directory (sandboxed `/tmp` is invisible to the host). Probe marker files go to `/home/michel/.cache/` (visible to both sides).
- Decoy windows (`kitty --class probe-rsz`): **`out_of_group=true` BEFORE any workspace move** (`group:auto_group` adds spawns to the focused group; moving a grouped member hauls the whole group). Special workspaces must be **visible** during measurement (hidden ones don't run layout). Count-check decoys before and after every state-changing command.
- `hyprctl dispatch` takes a Lua expression, not legacy `dispatcher arg` strings. Dispatcher globals like `resizeactive` do **not** exist on 0.57.
- Commits stage **only the named files** — the user edits this repo mid-session.
- API facts (verified 2026-11-02): `hl.dsp.window.resize({x, y, relative, window})` — numbers only; no-arg form = interactive mouse resize. `hl.dsp.window.move({x, y, relative, window})` — pixel move, x and y required together. `hl.get_active_monitor()` → `.width .height .x .y` numbers. `hl.get_window("address:0x…")` works. Tiled resize moves the split boundary in the delta direction regardless of target side; floating resize is center-symmetric (±d/2 per edge); fullscreen resizes are rejected by the dispatcher.

---

### Task 1: Touchpad tap probe — pick the bind form (live, user-assisted)

**Files:**
- Modify (temporarily, with backup): `~/.config/hypr/keybindings.lua` (live host file only — repo untouched in this task)
- Create: `.zcode/probe-tap.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a recorded outcome — one of `FORM_NOFLAG` (plain bind + no-arg resize), `FORM_BINDM` (`{mouse = true}` + tap-drag), or `BLOCKED` (neither works; report to user before doing anything else).

- [ ] **Step 1: Back up the live config**

```bash
cp ~/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua.bak-resizeprobe
```

- [ ] **Step 2: Append the probe bind and validate**

```bash
cat >> ~/.config/hypr/keybindings.lua <<'EOF'

-- TEMP PROBE: Super + three-finger tap -> interactive resize (remove after test)
hl.bind("SUPER + mouse:274", function()
    local f = io.open("/home/michel/.cache/tap-probe.log", "a")
    if f then f:write("tap\n"); f:close() end
    hl.dispatch(hl.dsp.window.resize())
end)
EOF
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i error
```

Expected: no error lines. If the no-flag mouse bind is rejected at parse time, skip to Step 5's fallback.

- [ ] **Step 3: Reload and confirm registration**

```bash
hyprctl reload
hyprctl binds | grep -B4 -A8 "mouse:274"
```

Expected: one bind block with `key: mouse:274`, `modmask: 64`, a `function: 0x…` dispatcher (not `HL.Dispatcher(resize)`).

- [ ] **Step 4: User finger test (ask the user, ~15 seconds)**

```bash
rm -f /home/michel/.cache/tap-probe.log
```

Ask the user: *"Focus any window, hold Super, three-finger tap the touchpad once, then move one finger — does the window resize from a corner? Tap once to finish."* Then:

```bash
wc -l < /home/michel/.cache/tap-probe.log 2>/dev/null
```

- Marker lines ≥ 1 **and** user reports interactive resize → outcome `FORM_NOFLAG`. Continue to Step 6.
- Marker ≥ 1 but no resize happened (or it died instantly) → outcome `FORM_BINDM`. Continue to Step 5.

- [ ] **Step 5: Fallback probe — bindm + tap-drag (only if Step 4 failed)**

Replace the probe block with:

```bash
python3 - <<'PY'
import re
p = "/home/michel/.config/hypr/keybindings.lua"
s = open(p).read()
s = s.split("-- TEMP PROBE: Super + three-finger tap")[0] + '''-- TEMP PROBE: Super + three-finger tap -> interactive resize (remove after test)
hl.bind("SUPER + mouse:274", hl.dsp.window.resize(), { mouse = true })
'''
open(p, "w").write(s)
PY
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i error
hyprctl reload
```

Ask the user: *"Hold Super, three-finger tap and immediately touch three fingers again, keep them down and drag — the window resizes while you drag; release ends it."*

- Works → outcome `FORM_BINDM`.
- Doesn't work → outcome `BLOCKED`: restore the backup (Step 6), **stop, and report to the user** — the remaining fallback (keyboard submap) was explicitly rejected during design; it needs their sign-off, not a unilateral decision.

- [ ] **Step 6: Restore the live config and clean up**

```bash
cp ~/.config/hypr/keybindings.lua.bak-resizeprobe ~/.config/hypr/keybindings.lua
hyprctl reload
rm -f ~/.config/hypr/keybindings.lua.bak-resizeprobe /home/michel/.cache/tap-probe.log
```

Record the outcome (`FORM_NOFLAG` / `FORM_BINDM` / `BLOCKED`) in the task list before moving on.

---

### Task 2: Fixed chords — native dispatcher, edge-push arrows (tiled)

**Files:**
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` (repo) — replace lines 120–124 (the `-- Resize focused window (percent deltas via hyprctl…` comment and the four `SUPER + CTRL` binds) and add helpers after `ungroupActive()` (ends line 16)
- Deploy target: `~/.config/hypr/keybindings.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: module-local `stepFor(len) -> number` (5% of `len`, floored, min 10) and `resizeDir(sx, sy)` (arrow-sign pair; tiled dispatch). Task 3 extends `resizeDir` with a floating branch calling `resizeFloatingEdge(w, sx, sy)`.

- [ ] **Step 1: Add the helpers after `ungroupActive()`**

Insert directly after the `ungroupActive` function (line 16):

```lua
-- Keyboard resize step: 5% of the resized axis, floored, minimum 10px
local function stepFor(len)
    return math.max(10, math.floor(len * 0.05))
end

-- Resize the focused window. Arrows push the window's boundary in the
-- arrow direction (→/↓ = +, ←/↑ = −). For tiled windows the dispatcher
-- moves the split boundary in the delta's direction regardless of which
-- side the window is on — no position math needed.
local function resizeDir(sx, sy)
    local w = hl.get_active_window()
    if not w or (w.fullscreen and w.fullscreen ~= 0) then return end
    if w.floating then
        return -- single-edge handler arrives with the floating task
    end
    hl.dispatch(hl.dsp.window.resize({
        x = sx * stepFor(w.size.x),
        y = sy * stepFor(w.size.y),
        relative = true,
    }))
end
```

- [ ] **Step 2: Replace the four broken binds**

Delete lines 120–124 (comment + four `hl.bind("SUPER + CTRL + …` lines using `exec_cmd('hyprctl dispatch resizeactive …')`). In their place:

```lua
-- Resize focused window — arrows push the boundary (→/↓ positive, ←/↑ negative)
hl.bind("SUPER + CTRL + left",  function() resizeDir(-1, 0) end)
hl.bind("SUPER + CTRL + right", function() resizeDir(1, 0) end)
hl.bind("SUPER + CTRL + up",    function() resizeDir(0, -1) end)
hl.bind("SUPER + CTRL + down",  function() resizeDir(0, 1) end)
```

- [ ] **Step 3: Validate and deploy to the host**

```bash
cp roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i error
hyprctl reload
hyprctl binds | paste -d'|' - - - - - - - - - - - - | grep "modmask: 68" | grep -c "function:"
```

Expected: no parse errors; last command prints `4` (the four chords now registered with Lua-function dispatchers instead of `exec_cmd`).

- [ ] **Step 4: Commit (this file only)**

```bash
git add roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua
git commit -m "fix(hyprland): resize chords — native window.resize dispatcher, edge-push arrows (0.57 broke hyprctl resizeactive)"
```

---

### Task 3: Position-aware floating resize — single moving edge

**Files:**
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` — add `resizeFloatingEdge` after `resizeDir`, and replace the floating `return` placeholder in `resizeDir` with the branch
- Create: `.zcode/probe-float.sh` (verification harness)

**Interfaces:**
- Consumes: `stepFor` (Task 2).
- Produces: `resizeFloatingEdge(w, sx, sy)` — moves one floating-window edge by one step in the arrow direction, opposite edge pinned.

- [ ] **Step 1: Add the floating handler after `resizeDir`**

```lua
-- Floating windows: the dispatcher grows them symmetrically (±d/2 per
-- edge), which pushes windows off-screen near monitor edges. Instead move
-- ONE boundary per axis — the edge facing the monitor center — and pin the
-- opposite edge by compensating the position after the resize.
local function resizeFloatingEdge(w, sx, sy)
    local m = hl.get_active_monitor()
    if not m then return end
    local addr, oldW, oldH = w.address, w.size.x, w.size.y
    local growRightEdge  = (w.at.x + oldW / 2) < (m.x + m.width / 2)
    local growBottomEdge = (w.at.y + oldH / 2) < (m.y + m.height / 2)
    -- on the right/bottom half the boundary is the LEFT/TOP edge, so the
    -- dispatcher delta flips sign (→ shrinks a right-half window)
    local dx = (growRightEdge  and 1 or -1) * sx * stepFor(oldW)
    local dy = (growBottomEdge and 1 or -1) * sy * stepFor(oldH)
    hl.dispatch(hl.dsp.window.resize({ x = dx, y = dy, relative = true }))
    local w2 = hl.get_window("address:" .. addr)
    if not w2 then return end
    -- clamp safety: compensate by what was ACTUALLY applied (min-size
    -- clamping can shrink the delta), not by what we asked for
    local ax, ay = w2.size.x - oldW, w2.size.y - oldH
    local mx = (dx ~= 0 and ax ~= 0) and (growRightEdge and (ax / 2) or (-ax / 2)) or 0
    local my = (dy ~= 0 and ay ~= 0) and (growBottomEdge and (ay / 2) or (-ay / 2)) or 0
    if mx ~= 0 or my ~= 0 then
        hl.dispatch(hl.dsp.window.move({ x = mx, y = my, relative = true }))
    end
end
```

- [ ] **Step 2: Wire it into `resizeDir`**

Replace the floating placeholder branch:

```lua
    if w.floating then
        resizeFloatingEdge(w, sx, sy)
        return
    end
```

- [ ] **Step 3: Validate, deploy, register**

Same command triple as Task 2 Step 3 (copy → verify-config grep → reload → binds count `4`). Expected: identical.

- [ ] **Step 4: Decoy verification — all four edge cases**

Write `.zcode/probe-float.sh` and run it. It stages one floating decoy on the visible special workspace, positions it in each monitor half, applies the exact resize+compensate sequence the handler performs (targeting the decoy by address — the handler math is replicated statement-for-statement), and asserts which edge moved:

```bash
#!/bin/bash
J() { hyprctl -j clients; }
MON_W=3456; MON_H=2160   # from hl.get_active_monitor() — re-read if this errors
hyprctl dispatch 'hl.dsp.exec_cmd("kitty --class probe-rsz")' >/dev/null; sleep 1.0
A=$(J | jq -r '.[] | select(.class=="probe-rsz") | .address' | head -1)
G=$(J | jq -r ".[] | select(.address==\"$A\") | (.grouped|length)")
[ "$G" -gt 0 ] && hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$A\"), out_of_group=true})" >/dev/null && sleep 0.4
hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$A\"), workspace=\"special:probe\"})" >/dev/null; sleep 0.4
hyprctl dispatch 'hl.dsp.workspace.toggle_special("probe")' >/dev/null; sleep 0.5
hyprctl dispatch "hl.dsp.window.float({window=hl.get_window(\"address:$A\"), action=\"on\"})" >/dev/null; sleep 0.4

geom() { J | jq -r ".[] | select(.address==\"$A\") | \"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])\""; }
pin() { # $1=x $2=y  — replicate resizeFloatingEdge's exact sequence on the decoy
  hyprctl dispatch "function()
    local w = hl.get_window(\"address:$A\"); if not w then return end
    local m = hl.get_active_monitor(); if not m then return end
    local addr, oldW, oldH = w.address, w.size.x, w.size.y
    local gR = (w.at.x + oldW/2) < (m.x + m.width/2)
    local gB = (w.at.y + oldH/2) < (m.y + m.height/2)
    local dx = (gR and 1 or -1) * $1 * math.max(10, math.floor(oldW * 0.05))
    local dy = (gB and 1 or -1) * $2 * math.max(10, math.floor(oldH * 0.05))
    hl.dispatch(hl.dsp.window.resize({window=w, x=dx, y=dy, relative=true}))
    local w2 = hl.get_window(\"address:\" .. addr); if not w2 then return end
    local ax, ay = w2.size.x - oldW, w2.size.y - oldH
    local mx = (dx ~= 0 and ax ~= 0) and (gR and (ax/2) or (-ax/2)) or 0
    local my = (dy ~= 0 and ay ~= 0) and (gB and (ay/2) or (-ay/2)) or 0
    if mx ~= 0 or my ~= 0 then hl.dispatch(hl.dsp.window.move({window=w, x=mx, y=my, relative=true})) end
  end"; sleep 0.5; }

echo "=== LEFT-half, press -> (right edge must grow, left edge pinned) ==="
hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$A\"), x=200, y=900, relative=false})" >/dev/null; sleep 0.4; geom
pin 1 0; geom
echo "=== RIGHT-half, press -> (left edge must move RIGHT=shrink, right edge pinned) ==="
hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$A\"), x=2600, y=900, relative=false})" >/dev/null; sleep 0.4; geom
pin 1 0; geom
echo "=== TOP-half, press v (bottom edge grows, top pinned) ==="
hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$A\"), x=1600, y=100, relative=false})" >/dev/null; sleep 0.4; geom
pin 0 1; geom
echo "=== BOTTOM-half, press ^ (top edge moves DOWN=shrink, bottom pinned) ==="
hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$A\"), x=1600, y=1800, relative=false})" >/dev/null; sleep 0.4; geom
pin 0 -1; geom
echo "--- cleanup ---"
hyprctl dispatch "hl.dsp.window.close({window=hl.get_window(\"address:$A\")})" >/dev/null
hyprctl dispatch 'hl.dsp.workspace.toggle_special("probe")' >/dev/null; sleep 0.4
echo "decoys left: $(J | jq -r '.[] | select(.class=="probe-rsz") | .address' | wc -l)"
```

Run: `bash .zcode/probe-float.sh`
Expected per case — parse each `at.x at.y size.x size.y` pair:
- LEFT-half `→`: `at.x` unchanged, `size.x` grew by ~5% of itself.
- RIGHT-half `→`: `at.x` increased by ~5%-of-width, `at.x + size.x` unchanged.
- TOP-half `↓`: `at.y` unchanged, `size.y` grew.
- BOTTOM-half `↑`: `at.y` increased, `at.y + size.y` unchanged.
Also: `decoys left: 0` and the user's windows untouched (no zcode/telegram in the output — verify with `hyprctl -j clients | jq -r '.[] | select(.class=="zcode") | .workspace.name'` showing their normal workspace).

- [ ] **Step 5: Commit (this file only)**

```bash
git add roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua
git commit -m "feat(hyprland): position-aware floating resize — single moving edge chosen by window position"
```

---

### Task 4: Ship the touchpad bind + regression + user smoke test

**Files:**
- Modify: `roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua` — add the bind next to the `mouse:273` bind (line ~110 area)

**Interfaces:**
- Consumes: Task 1's recorded outcome.
- Produces: the shipped three-finger-tap resize bind.

- [ ] **Step 1: Add the bind (form depends on Task 1)**

If `FORM_NOFLAG`, directly under the `mouse:273` bind:

```lua
-- Super + three-finger tap (libinput middle-button tap) starts an
-- interactive resize: finger motion resizes the corner nearest the
-- cursor, any tap/click ends it. Bare taps still middle-click-paste.
hl.bind("SUPER + mouse:274", hl.dsp.window.resize())
```

If `FORM_BINDM`, same placement but:

```lua
hl.bind("SUPER + mouse:274", hl.dsp.window.resize(), { mouse = true })
```

and adjust the comment to describe the tap-drag gesture (tap three fingers, re-touch immediately, drag; release ends).

If `BLOCKED`: skip this task's Steps 2–5 — the design fallback needs user sign-off first.

- [ ] **Step 2: Validate, deploy, register**

```bash
cp roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua 2>&1 | grep -i error
hyprctl reload
hyprctl binds | grep "key: mouse"
```

Correct expectation: the listing shows `mouse:272`, `mouse:273`, `mouse:274` plus the two `mouse_down`/`mouse_up` scroll binds; the `mouse:272`/`mouse:273` blocks still carry their original dispatchers (drag binds unchanged), and `mouse:274` has `modmask: 64`.

- [ ] **Step 3: User smoke test (~30 seconds, ask the user)**

1. Super + three-finger tap → resize → tap to end (or tap-drag per form).
2. SUPER+CTRL+arrows on a tiled left window: `→` widens it, `←` narrows it.
3. Float a window (Super+Shift+F), park it on the right half: `→` shrinks it from the left edge, `←` grows it leftward; nothing goes off-screen.
4. Optional: a grouped window's chord resize still resizes the whole group.

- [ ] **Step 4: Commit (this file only)**

```bash
git add roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua
git commit -m "feat(hyprland): Super+three-finger-tap interactive resize — mouse-free resizing on the laptop"
```

---

### Task 5: Role-deploy parity check

**Files:**
- No source changes. Deploy path: `.zcode/hypr-scoped.yml` (pre-existing scoped playbook; if missing or failing on known NFS/become quirks, note it — the direct-copy deployment from Tasks 2–4 is already live and identical).

**Interfaces:**
- Consumes: final repo state from Tasks 2–4.
- Produces: proof that the role path delivers the same bytes as the live session.

- [ ] **Step 1: Deploy via the role**

```bash
/usr/sbin/ansible-playbook .zcode/hypr-scoped.yml
```

- [ ] **Step 2: Verify byte parity and bind sanity**

```bash
cmp roles/desktop/hyprland/files/home/.config/hypr/keybindings.lua ~/.config/hypr/keybindings.lua && echo IDENTICAL
hyprctl binds | paste -d'|' - - - - - - - - - - - - | grep -c "modmask: 68"   # still 4 chords
```

Expected: `IDENTICAL`, `4`.

- [ ] **Step 3: Update project memory**

Append to `~/.zcode/cli/memories/projects/dotarch-54d5847410afeee4/memory/hyprland-lua-config-reference.md`: the shipped bind form from Task 1, the floating edge-pin recipe (resize-symmetric + move-compensate with actual-applied-delta clamp safety), and any probe surprises.

---

## Self-Review (completed during planning)

- **Spec coverage:** Feature 1 (tap resize) → Tasks 1+4; Feature 2 (fixed chords, edge-push) → Task 2; Feature 3 (floating single-edge) → Task 3; verification plan → Task 3 Step 4 decoys + Task 4 Step 3 user smoke; fallback chain → Task 1 Steps 4–5 with explicit user-gate on the rejected submap; `keybindings.conf` untouched per out-of-scope.
- **Placeholders:** none — every step carries exact code/commands; the only conditional (bind form) is expressed as concrete alternatives with a decision gate.
- **Consistency:** `stepFor`/`resizeDir(sx, sy)`/`resizeFloatingEdge(w, sx, sy)` signatures match across Tasks 2–3; the Task 3 decoy harness replicates the handler statement-for-statement including the `{window=…}` kwarg form used all session.
