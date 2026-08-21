# Waybar Native Clock Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken `custom/clock` script module with waybar's built-in `clock` module (calendar tooltip on hover, click-toggles-seconds kept natively, no script to die after suspend).

**Architecture:** One template edit (`config.j2`), one task-file edit plus script deletion (`tasks/main.yml`, `files/.../waybar-clock.sh`), then a scoped localhost deploy and live verification. Spec: `docs/superpowers/specs/2026-08-21-waybar-clock-calendar-design.md`.

**Tech Stack:** Ansible (DotArch repo, uv-managed venv), waybar 0.15.0, JSON-with-comments config (jsoncpp parser).

## Global Constraints

- YAML 2-space indent; FQCN `ansible.builtin.*` module names (repo AGENTS.md).
- Waybar task tags: `[desktop, waybar, config]` for config-file tasks.
- config.j2 stays in the file's existing relaxed JSON style (`//` comments, trailing commas — jsoncpp accepts both; the deployed config already uses them).
- Never commit secrets; nothing in this plan touches vaulted files.

---

### Task 1: Swap custom/clock for built-in clock in config.j2

**Files:**
- Modify: `roles/desktop/waybar/templates/home/.config/waybar/config.j2` (lines 18, 85-91)

**Interfaces:**
- Produces: `"clock"` module referenced by `modules-center`; consumed by the live waybar after deploy (Task 3).

- [ ] **Step 1: Edit modules-center**

Replace line 18:
```json
    "modules-center": ["custom/clock"],
```
with:
```json
    "modules-center": ["clock"],
```

- [ ] **Step 2: Replace the custom/clock module block**

Replace the block:
```json
    "custom/clock": {
        "exec": "~/.config/waybar/scripts/waybar-clock.sh",
        "return-type": "json",
        "format": "{}",
        "on-click": "pkill -SIGUSR1 -f waybar-clock.sh",
        "tooltip": true
    },
```
with:
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
    },
```

- [ ] **Step 3: Verify both render variants are valid JSON**

Run from repo root (`.venv` has jinja2):
```bash
uv run python - <<'PY'
import json, re
from jinja2 import Template
src = open("roles/desktop/waybar/templates/home/.config/waybar/config.j2").read()
for target in ("laptop", "desktop"):
    text = Template(src).render(target=target)
    text = re.sub(r"//.*", "", text)            # strip // comments
    text = re.sub(r",(\s*[}\]])", r"\1", text)  # strip trailing commas
    cfg = json.loads(text)
    assert cfg["modules-center"] == ["clock"]
    assert "custom/clock" not in cfg
    assert cfg["clock"]["tooltip-format"] == "<tt>{calendar}</tt>"
    print(target, "OK")
PY
```
Expected: `laptop OK` and `desktop OK`, no assertion errors.

- [ ] **Step 4: Commit**

```bash
git add roles/desktop/waybar/templates/home/.config/waybar/config.j2
git commit -m "feat(waybar): built-in clock module with calendar tooltip replaces custom script"
```

---

### Task 2: Remove the clock script from the role

**Files:**
- Delete: `roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-clock.sh`
- Modify: `roles/desktop/waybar/tasks/main.yml` (lines 41-46)

**Interfaces:**
- Consumes: nothing.
- Produces: deployed hosts get the stale script removed (Task 3 deploy runs this).

- [ ] **Step 1: Replace the copy task with a removal task**

In `roles/desktop/waybar/tasks/main.yml`, replace:
```yaml
- name: Copy Waybar clock script
  ansible.builtin.copy:
    src: files/home/.config/waybar/scripts/waybar-clock.sh
    dest: "{{ ansible_facts['user_dir'] }}/.config/waybar/scripts/waybar-clock.sh"
    mode: '0755'
  tags: [desktop, waybar, config]
```
with:
```yaml
- name: Remove legacy Waybar clock script (replaced by built-in clock module)
  ansible.builtin.file:
    path: "{{ ansible_facts['user_dir'] }}/.config/waybar/scripts/waybar-clock.sh"
    state: absent
  tags: [desktop, waybar, config]
```

- [ ] **Step 2: Delete the script from the role**

```bash
git rm roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-clock.sh
```

- [ ] **Step 3: Lint**

```bash
uv run ansible-lint roles/desktop/waybar/
```
Expected: no findings for the waybar role (pre-existing repo-wide findings, if any, are out of scope).

- [ ] **Step 4: Commit**

```bash
git add roles/desktop/waybar/tasks/main.yml
git commit -m "refactor(waybar): drop waybar-clock.sh, remove stale copy on deploy"
```

---

### Task 3: Scoped deploy to localhost + live verification

**Files:**
- Create (outside repo): `/tmp/waybar-clock-deploy.yml`

**Interfaces:**
- Consumes: Tasks 1-2 changes; repo-root `ansible.cfg` (roles resolve `desktop/waybar` from `./roles`); `password.sh` only if vault vars are touched (they are not, but group_vars auto-loads — pass the flag anyway per AGENTS.md).

- [ ] **Step 1: Scoped playbook in /tmp (avoids meta-role tag reach problem)**

`/tmp/waybar-clock-deploy.yml`:
```yaml
---
- name: Deploy waybar clock change only
  hosts: localhost
  connection: local
  gather_facts: true
  roles:
    - role: desktop/waybar
```
Run from repo root:
```bash
uv run ansible-playbook /tmp/waybar-clock-deploy.yml --vault-password-file password.sh
```
Expected: templated config copied, `waybar-clock.sh` reported absent/removed. If become/NFS quirks block it (see memory), re-run with `--become` omitted — the role's file tasks run as the local user.

- [ ] **Step 2: Verify deployed artifacts**

```bash
grep -c '"clock"' ~/.config/waybar/config && test ! -f ~/.config/waybar/scripts/waybar-clock.sh && echo CLEAN
```
Expected: count ≥ 2 and `CLEAN`.

- [ ] **Step 3: Restart waybar inside the Hyprland session**

```bash
pkill -x waybar
HYPRLAND_INSTANCE_SIGNATURE=$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/" | head -1) \
  hyprctl dispatch exec waybar
```
Expected: `ok` from hyprctl; `pgrep -x waybar` shows a fresh PID; `pgrep -f waybar-clock.sh` is empty.

- [ ] **Step 4: Visual check**

Screenshot the bar and confirm the clock text renders:
```bash
grim -g "0,0,2560x32" /tmp/waybar-bar.png
```
Then read `/tmp/waybar-bar.png` and confirm the date/time is present and styled like the old clock. (If grim region syntax fails on multi-monitor, use `grim -o $(hyprctl monitors -j | jq -r '.[0].name') /tmp/waybar-bar.png`.)

- [ ] **Step 5: Manual user checks (report to user)**

Hover the clock → month calendar with today in bold red; left-click → HH:MM:SS and back; scroll → month navigation. These need a human pointer; leave as the acceptance step for the user.

- [ ] **Step 6: No repo commit needed** (artifacts in /tmp only; clean up `/tmp/waybar-clock-deploy.yml`, `/tmp/waybar-bar.png` optional)
