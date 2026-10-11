# Day/Night Theme Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Time-based dark/light theme switching (sun-based, timezone-guided) with a self-rescheduling systemd user timer and a waybar auto/dark/light toggle module.

**Architecture:** A new `desktop/theming` Ansible role deploys a `dotarch-theme` CLI (state machine + sun calculation + apply pipeline), kitty and waybar theme layers, and a systemd user timer whose service applies the theme and rewrites its own `OnCalendar` drop-in to the next sun boundary. The waybar `custom/theme` module is a read-only display plus click handler. Cross-role hooks (kitty include line, waybar css array + module) are conditional on `enable_theme_switch` and stay owned by their existing roles.

**Tech Stack:** Bash (set -euo pipefail), embedded python3 (NOAA sunrise equation), systemd user units, Ansible (FQCN), waybar JSON config + GTK CSS, kitty conf includes, gsettings/dconf.

**Spec:** `docs/superpowers/specs/2026-10-11-theme-switching-design.md` (commits 9913fdd, adbfa21)

## Global Constraints

- FQCN everywhere (`ansible.builtin.*`, `community.general.pacman`); YAML 2-space indent.
- Tags: role tasks carry `[desktop, theme]`; config-copy/template tasks add `config`.
- snake_case for files/vars/units. No secrets in any new file (nothing to add to `encrypt.sh`).
- **Dark stays visually byte-identical**: `style.css` and `Dark_Pastel.conf` are never modified. The dark colors layer (`colors-dark.css`) may only contain rules for the NEW `#custom-theme` widget.
- Script must be safe to run with no graphical session, no dbus, no systemd user manager: always exit 0 on the timer/status paths; failures go to stderr.
- `~/.local/bin` is already on PATH via `/etc/zsh/zshenv` — no PATH work needed.
- Tests run with a sandbox `$HOME` and stubbed `pkill`/`systemctl`/`gsettings`/`timedatectl` so they never touch the real desktop session.
- Do not run `molecule test` (vagrant/libvirt, out of scope); lint via `yamllint` + `ansible-lint`.
- Host has NFS quirks: prefer system `ansible-playbook`/`ansible-lint` binaries if the `.venv` is broken; scoped deploys need `-e` flags because a playbook outside the repo does not auto-load `group_vars`.

## File Structure

```
tests/dotarch-theme.sh                                      # sandbox test harness (grows per task)
roles/desktop/theming/defaults/main.yml                     # role-default vars
roles/desktop/theming/tasks/main.yml                        # role task flow
roles/desktop/theming/files/home/.local/bin/dotarch-theme   # switcher CLI (0755)
roles/desktop/theming/templates/dotarch-theme.conf.j2       # runtime config (LOCATION/DAY_TIME/...)
roles/desktop/theming/files/home/.config/kitty/theme-light.conf
roles/desktop/theming/files/home/.config/waybar/colors-light.css
roles/desktop/theming/files/home/.config/waybar/colors-dark.css
roles/desktop/theming/files/home/.config/waybar/colors.css  # initial active copy (= dark layer)
roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.service
roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.timer
roles/desktop/terminal/templates/home/.config/kitty/kitty.conf.j2   # moved from files/, conditional include
roles/desktop/terminal/tasks/main.yml                       # copy -> template for kitty.conf
roles/desktop/waybar/templates/home/.config/waybar/config.j2  # css array + custom/theme module
roles/profiles/desktop-hyprland/tasks/main.yml              # include_role (gated)
group_vars/all/deployment_config.yml                        # enable_theme_switch + theme_* vars
AGENTS.md                                                   # role list line
docs/superpowers/specs/2026-10-11-theme-switching-design.md # drop theme_cycle_order (YAGNI)
```

Runtime artifacts owned by the script (not Ansible): `~/.local/state/dotarch-theme/{state,sun-cache,.lock}`, `~/.config/systemd/user/dotarch-theme.timer.d/schedule.conf`, `~/.config/kitty/current-theme.conf` (symlink, bootstrapped once by Ansible), `~/.config/waybar/colors.css` (rewritten by script).

---

### Task 1: Test harness + `dotarch-theme` state core (set/cycle/status with fixed-time resolution)

**Files:**
- Create: `tests/dotarch-theme.sh`
- Create: `roles/desktop/theming/files/home/.local/bin/dotarch-theme`

**Interfaces:**
- Produces: CLI `dotarch-theme set <auto|dark|light>` / `cycle` / `status --json` writing `$HOME/.local/state/dotarch-theme/state` with exactly two lines `mode=<auto|dark|light>` and `current=<dark|light|>`. Config read from `$HOME/.config/dotarch-theme.conf` keys `LOCATION`, `LATITUDE`, `LONGITUDE`, `DAY_TIME` (default `07:00`), `NIGHT_TIME` (default `20:00`) — in this task only `DAY_TIME`/`NIGHT_TIME` are consumed. `apply`/`plan`/`run` are parsed but print "not implemented" and exit 0 (wired in Tasks 3–4).

- [ ] **Step 1: Write the failing tests**

Create `tests/dotarch-theme.sh`:

```bash
#!/usr/bin/env bash
# Functional tests for dotarch-theme — sandboxed HOME, stubbed system tools.
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/roles/desktop/theming/files/home/.local/bin/dotarch-theme"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { # check DESC EXPECTED ACTUAL
    if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi
}

# new_home — fresh sandbox HOME with stubs; run_script — run script inside it
new_home() {
    TEST_HOME=$(mktemp -d)
    mkdir -p "$TEST_HOME/.local/state/dotarch-theme" "$TEST_HOME/bin"
    mkdir -p "$TEST_HOME/.config/kitty" "$TEST_HOME/.config/waybar"
    for tool in pkill systemctl gsettings; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$tool" "$TEST_HOME" > "$TEST_HOME/bin/$tool"
        chmod +x "$TEST_HOME/bin/$tool"
    done
    printf '#!/bin/sh\necho Europe/Paris\n' > "$TEST_HOME/bin/timedatectl"
    chmod +x "$TEST_HOME/bin/timedatectl"
    ln -s Dark_Pastel.conf "$TEST_HOME/.config/kitty/current-theme.conf"
    printf '/* dark layer */\n' > "$TEST_HOME/.config/waybar/colors-dark.css"
    printf '/* light layer */\n' > "$TEST_HOME/.config/waybar/colors-light.css"
    cp "$TEST_HOME/.config/waybar/colors-dark.css" "$TEST_HOME/.config/waybar/colors.css"
}
run_script() { HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" "$@"; }
sandbox() { new_home; run_script "$@"; }

state_of() { grep "^$1=" "$TEST_HOME/.local/state/dotarch-theme/state" | cut -d= -f2; }

echo "T1: bootstrap + set/cycle state machine"
sandbox status --json >/dev/null
check "bootstrap creates mode=auto" "auto" "$(state_of mode)"

new_home
run_script set dark >/dev/null
check "set dark writes mode"  "dark"  "$(state_of mode)"

run_script cycle >/dev/null; check "cycle dark->light"   "light" "$(state_of mode)"
run_script cycle >/dev/null; check "cycle light->auto"   "auto"  "$(state_of mode)"
run_script cycle >/dev/null; check "cycle auto->dark"    "dark"  "$(state_of mode)"

echo "T1b: status json shape"
out=$(sandbox status --json)
echo "$out" | grep -q '"text":' && ok "status has text" || fail "status text missing"
echo "$out" | grep -qE '"class": "(dark|light)' && ok "status class dark|light" || fail "status class: $out"

echo "T1c: config fallback times"
new_home
run_script set dark
check "default DAY_TIME written to sun-cache" "07:00" "$(grep '^sunrise=' "$TEST_HOME/.local/state/dotarch-theme/sun-cache" | cut -d= -f2)"

echo; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/dotarch-theme.sh`
Expected: FAIL — script file does not exist (`bash: .../dotarch-theme: No such file or directory`), final `failed>0`, non-zero exit.

- [ ] **Step 3: Write the script core**

Create `roles/desktop/theming/files/home/.local/bin/dotarch-theme`:

```bash
#!/usr/bin/env bash
# dotarch-theme — day/night theme switcher.
# Spec: docs/superpowers/specs/2026-10-11-theme-switching-design.md
set -euo pipefail

STATE_DIR="$HOME/.local/state/dotarch-theme"
STATE_FILE="$STATE_DIR/state"
SUN_CACHE="$STATE_DIR/sun-cache"
LOCK_FILE="$STATE_DIR/.lock"
CONFIG_FILE="$HOME/.config/dotarch-theme.conf"

KITTY_DIR="$HOME/.config/kitty"
WAYBAR_DIR="$HOME/.config/waybar"
TIMER_DROPIN_DIR="$HOME/.config/systemd/user/dotarch-theme.timer.d"
TIMER_DROPIN="$TIMER_DROPIN_DIR/schedule.conf"

MODE="auto"; CURRENT=""; SUNRISE=""; SUNSET=""; SOURCE="fixed"

log() { printf 'dotarch-theme: %s\n' "$*" >&2; }

config_value() { # config_value KEY DEFAULT
    local value=""
    if [[ -r "$CONFIG_FILE" ]]; then
        value=$(grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)
    fi
    printf '%s' "${value:-$2}"
}

read_state() {
    MODE=$(grep '^mode=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true); MODE=${MODE:-auto}
    CURRENT=$(grep '^current=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
}

write_state() { # write_state MODE CURRENT
    printf 'mode=%s\ncurrent=%s\n' "$1" "$2" > "$STATE_FILE"
}

bootstrap_state() {
    mkdir -p "$STATE_DIR"
    [[ -f "$STATE_FILE" ]] || write_state auto ""
}

minutes_now() { echo $(( $(date +%H) * 60 + $(date +%M) )); }
minutes_of() { echo $(( ${1%%:*} * 60 + ${1##*:} )); } # minutes_of HH:MM

sun_times() { # sets SUNRISE SUNSET SOURCE; cached per date (upgraded to real sun math in Task 2)
    local today
    today=$(date +%F)
    if [[ -r "$SUN_CACHE" ]]; then
        if [[ $(grep '^date=' "$SUN_CACHE" | cut -d= -f2) == "$today" ]]; then
            SUNRISE=$(grep '^sunrise=' "$SUN_CACHE" | cut -d= -f2)
            SUNSET=$(grep '^sunset=' "$SUN_CACHE" | cut -d= -f2)
            SOURCE=$(grep '^source=' "$SUN_CACHE" | cut -d= -f2)
            return 0
        fi
    fi
    SUNRISE=$(config_value DAY_TIME 07:00)
    SUNSET=$(config_value NIGHT_TIME 20:00)
    SOURCE=fixed
    printf 'date=%s\nsunrise=%s\nsunset=%s\nsource=%s\n' "$today" "$SUNRISE" "$SUNSET" "$SOURCE" > "$SUN_CACHE"
}

effective_theme() { # -> dark|light
    if [[ "$MODE" != "auto" ]]; then printf '%s' "$MODE"; return 0; fi
    local now rise set_
    now=$(minutes_now); rise=$(minutes_of "$SUNRISE"); set_=$(minutes_of "$SUNSET")
    if (( now < rise || now >= set_ )); then echo dark; else echo light; fi
}

cmd_status() {
    bootstrap_state; read_state; sun_times
    local effective text class tooltip
    effective=$(effective_theme)
    if [[ "$effective" == "light" ]]; then text=""; else text=""; fi
    class="$effective"
    tooltip="Theme: $effective"
    if [[ "$MODE" == "auto" ]]; then
        tooltip="$tooltip (auto · sunrise $SUNRISE / sunset $SUNSET [$SOURCE])"
    else
        class="$class pinned"
        tooltip="$tooltip (pinned)"
    fi
    printf '{"text": "%s", "class": "%s", "tooltip": "%s"}\n' "$text" "$class" "$tooltip"
}

main() {
    local cmd=${1:-status}
    case "$cmd" in
        run|apply|plan)
            log "$cmd not implemented yet"; exit 0 ;;
    esac
    case "$cmd" in
        set)
            [[ ${2:-} =~ ^(auto|dark|light)$ ]] || { log "usage: dotarch-theme set auto|dark|light"; exit 2; }
            bootstrap_state; read_state
            write_state "$2" "$CURRENT"
            log "mode set to $2 (apply/plan wired in later tasks)" ;;
        cycle)
            bootstrap_state; read_state
            local new_mode
            case "$MODE" in
                auto)  new_mode=dark ;;
                dark)  new_mode=light ;;
                light) new_mode=auto ;;
                *)     new_mode=auto ;;
            esac
            write_state "$new_mode" "$CURRENT"
            log "mode cycled to $new_mode" ;;
        status)   cmd_status ;;
        *) log "usage: dotarch-theme {run|apply|plan|set <auto|dark|light>|cycle|status}"; exit 2 ;;
    esac
}
main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/dotarch-theme.sh`
Expected: all `ok:`, `failed=0`, exit 0. Also run `bash -n roles/desktop/theming/files/home/.local/bin/dotarch-theme` — no output.

- [ ] **Step 5: Commit**

```bash
git add tests/dotarch-theme.sh roles/desktop/theming/files/home/.local/bin/dotarch-theme
git commit -m "feat(theme): dotarch-theme state core with sandboxed tests"
```

---

### Task 2: Sun-based resolution (tz→coords table, NOAA python, daily cache, fixed fallback)

**Files:**
- Modify: `roles/desktop/theming/files/home/.local/bin/dotarch-theme` (replace `sun_times` stub + add helpers)

**Interfaces:**
- Consumes: `sun_times` contract from Task 1 (sets `SUNRISE SUNSET SOURCE`, writes `sun-cache` with `date=`,`sunrise=`,`sunset=`,`source=` lines).
- Produces: `SOURCE` is one of `sun` or `fixed`. `sun` comes from `compute_sun LAT LON` (embedded python) using either `LOCATION=coords` (+`LATITUDE`/`LONGITUDE` from config) or the system timezone looked up via `timedatectl show -p Timezone --value` (fallback: `readlink /etc/localtime`) in a hardcoded `tz_coords` table.

- [ ] **Step 1: Add the failing tests**

Append to `tests/dotarch-theme.sh` (before the final `echo; echo "passed=..."` block):

```bash
echo "T2: sun-based resolution (real python, Paris coords via stubbed timedatectl)"
new_home
run_script set dark >/dev/null
cache="$TEST_HOME/.local/state/dotarch-theme/sun-cache"
check "source is sun"        "sun"    "$(grep '^source=' "$cache" | cut -d= -f2)"
sunrise=$(grep '^sunrise=' "$cache" | cut -d= -f2); sunset=$(grep '^sunset=' "$cache" | cut -d= -f2)
check "sunrise HH:MM format" "1"      "$(echo "$sunrise" | grep -cE '^0?[4-9]:[0-5][0-9]$')"
check "sunset HH:MM format"  "1"      "$(echo "$sunset" | grep -cE '^(1[6-9]|2[0-2]):[0-5][0-9]$')"
# Paris ranges hold for any day of the year (sunrise 04:4x–08:4x, sunset 16:5x–21:5x)
mtime=$(stat -c %Y "$cache")
run_script status --json >/dev/null
check "cache reused, not rewritten" "$mtime" "$(stat -c %Y "$cache")"

echo "T2b: fixed fallback on empty coords"
new_home
printf 'LOCATION=coords\nDAY_TIME=09:37\nNIGHT_TIME=18:11\n' > "$TEST_HOME/.config/dotarch-theme.conf"
run_script set dark
cache="$TEST_HOME/.local/state/dotarch-theme/sun-cache"
check "empty coords -> fixed source" "fixed" "$(grep '^source=' "$cache" | cut -d= -f2)"
check "DAY_TIME honored"            "09:37" "$(grep '^sunrise=' "$cache" | cut -d= -f2)"
check "NIGHT_TIME honored"          "18:11" "$(grep '^sunset=' "$cache" | cut -d= -f2)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/dotarch-theme.sh`
Expected: `FAIL: source is sun — expected [sun] got [fixed]` (T2), rest of T2 fails; T2b passes already (fallback path exists). Exit non-zero.

- [ ] **Step 3: Implement sun resolution**

In the script, add these functions directly above `sun_times`:

```bash
tz_coords() { # tz_coords TIMEZONE -> "LAT LON" or empty
    case "$1" in
        Europe/Paris)     echo "48.85 2.35" ;;
        Europe/London)    echo "51.50 -0.12" ;;
        Europe/Brussels)  echo "50.85 4.35" ;;
        Europe/Amsterdam) echo "52.37 4.90" ;;
        Europe/Berlin)    echo "52.52 13.40" ;;
        Europe/Zurich)    echo "47.37 8.54" ;;
        Europe/Madrid)    echo "40.42 -3.70" ;;
        Europe/Lisbon)    echo "38.72 -9.14" ;;
        Europe/Rome)      echo "41.90 12.50" ;;
        *)                echo "" ;;
    esac
}

system_timezone() {
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ -z "$tz" ]]; then
        tz=$(readlink /etc/localtime 2>/dev/null || true)
        tz=${tz##*zoneinfo/}
    fi
    printf '%s' "$tz"
}

compute_sun() { # compute_sun LAT LON -> "sunrise=HH:MM sunset=HH:MM" (local time, today)
    python3 - "$1" "$2" <<'PYEOF'
import math, sys
from datetime import date, datetime

lat, lon = float(sys.argv[1]), float(sys.argv[2])

# Sunrise equation (short NOAA form), see Wikipedia "Sunrise equation"
n = date.today().toordinal() - date(2000, 1, 1).toordinal() + 0.0008
j_star = n - lon / 360.0
m = (357.5291 + 0.98560028 * j_star) % 360.0
c = (1.9148 * math.sin(math.radians(m)) + 0.02 * math.sin(math.radians(2 * m))
     + 0.0003 * math.sin(math.radians(3 * m)))
lam = (m + c + 180 + 102.9372) % 360.0
j_transit = (2451545.0 + j_star + 0.0053 * math.sin(math.radians(m))
             - 0.0069 * math.sin(math.radians(2 * lam)))
delta = math.asin(math.sin(math.radians(lam)) * math.sin(math.radians(23.44)))
cos_omega = ((math.sin(math.radians(-0.83)) - math.sin(math.radians(lat)) * math.sin(delta))
             / (math.cos(math.radians(lat)) * math.cos(delta)))
if not -1.0 <= cos_omega <= 1.0:
    sys.exit(3)  # polar day/night -> caller falls back to fixed times
omega = math.degrees(math.acos(cos_omega))

def jd_to_local(jd):
    return datetime.fromtimestamp((jd - 2440587.5) * 86400.0)

print(f"sunrise={jd_to_local(j_transit - omega / 360.0):%H:%M} "
      f"sunset={jd_to_local(j_transit + omega / 360.0):%H:%M}")
PYEOF
}
```

Then replace the body of `sun_times` (keep the cache-hit block at the top; replace only the computation below it):

```bash
    local location lat lon latlon result
    location=$(config_value LOCATION auto)
    result=""
    if [[ "$location" == "coords" ]]; then
        lat=$(config_value LATITUDE ""); lon=$(config_value LONGITUDE "")
        if [[ -n "$lat" && -n "$lon" ]]; then
            result=$(compute_sun "$lat" "$lon" 2>/dev/null || true)
        fi
    else
        latlon=$(tz_coords "$(system_timezone)")
        if [[ -n "$latlon" ]]; then
            result=$(compute_sun $latlon 2>/dev/null || true)
        fi
    fi
    if [[ -n "$result" ]]; then
        SUNRISE=$(printf '%s\n' "$result" | cut -d' ' -f1 | cut -d= -f2)
        SUNSET=$(printf '%s\n' "$result" | cut -d' ' -f2 | cut -d= -f2)
        SOURCE=sun
    else
        SUNRISE=$(config_value DAY_TIME 07:00)
        SUNSET=$(config_value NIGHT_TIME 20:00)
        SOURCE=fixed
    fi
    printf 'date=%s\nsunrise=%s\nsunset=%s\nsource=%s\n' "$today" "$SUNRISE" "$SUNSET" "$SOURCE" > "$SUN_CACHE"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/dotarch-theme.sh`
Expected: all pass (T2 `source is sun` now hits the stubbed `timedatectl` → Paris → real python calc). `failed=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/dotarch-theme.sh roles/desktop/theming/files/home/.local/bin/dotarch-theme
git commit -m "feat(theme): sun-based day/night resolution with tz table and daily cache"
```

---

### Task 3: Apply pipeline (kitty symlink + waybar layer + gsettings) and wiring set/cycle

**Files:**
- Modify: `roles/desktop/theming/files/home/.local/bin/dotarch-theme`

**Interfaces:**
- Consumes: `MODE`/`CURRENT` state and `sun_times` from Tasks 1–2; deployed files `~/.config/waybar/colors-dark.css`, `colors-light.css`, `~/.config/kitty/{Dark_Pastel.conf,theme-light.conf}` (content authored in Task 5; only file presence matters here).
- Produces: `apply` command — resolves effective theme, and if `current` differs calls `apply_components dark|light` then persists state. `set`/`cycle` now end with `apply`. `apply_components` flips `~/.config/kitty/current-theme.conf` symlink to `Dark_Pastel.conf`|`theme-light.conf` + `pkill -USR1 -x kitty`; atomically copies `colors-<theme>.css` → `colors.css` + `pkill -USR2 -x waybar`; runs `gsettings set org.gnome.desktop.interface color-scheme prefer-<theme>` (guarded, non-fatal).

- [ ] **Step 1: Add the failing tests**

Append to `tests/dotarch-theme.sh` (before the final summary block):

```bash
echo "T3: apply pipeline"
sandbox set light >/dev/null
check "state current=light" "light" "$(state_of current)"
check "kitty symlink -> light" "theme-light.conf" "$(readlink "$TEST_HOME/.config/kitty/current-theme.conf")"
check "colors.css = light layer" "/* light layer */" "$(cat "$TEST_HOME/.config/waybar/colors.css")"
grep -q "gsettings set org.gnome.desktop.interface color-scheme prefer-light" "$TEST_HOME/calls.log" \
    && ok "gsettings prefer-light called" || fail "gsettings call missing"
grep -q "pkill -USR1 -x kitty" "$TEST_HOME/calls.log"  && ok "kitty signaled"  || fail "kitty signal missing"
grep -q "pkill -USR2 -x waybar" "$TEST_HOME/calls.log" && ok "waybar signaled" || fail "waybar signal missing"

sandbox set dark >/dev/null
check "kitty symlink -> dark" "Dark_Pastel.conf" "$(readlink "$TEST_HOME/.config/kitty/current-theme.conf")"
check "colors.css = dark layer" "/* dark layer */" "$(cat "$TEST_HOME/.config/waybar/colors.css")"

echo "T3b: idempotent apply"
new_home
run_script set light >/dev/null
calls=$(grep -c gsettings "$TEST_HOME/calls.log")
run_script apply >/dev/null
run_script apply >/dev/null
check "no duplicate gsettings on no-op apply" "$calls" "$(grep -c gsettings "$TEST_HOME/calls.log")"

echo "T3c: set auto resolves by time-of-day (fixed window via config)"
new_home
printf 'LOCATION=coords\nDAY_TIME=07:00\nNIGHT_TIME=20:00\n' > "$TEST_HOME/.config/dotarch-theme.conf"
run_script set auto
mode_now=$(date +%H%M)
want=dark; [[ $mode_now -ge 0700 && $mode_now -lt 2000 ]] && want=light
check "auto resolved by time of day" "$want" "$(state_of current)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/dotarch-theme.sh`
Expected: `T3` checks fail (`current=` empty, symlink unchanged) because `set` doesn't apply yet. Exit non-zero.

- [ ] **Step 3: Implement apply**

Add to the script (above `cmd_status`):

```bash
apply_components() { # apply_components dark|light
    local theme=$1 target="Dark_Pastel.conf"
    [[ "$theme" == "light" ]] && target="theme-light.conf"
    mkdir -p "$KITTY_DIR"
    ln -sfn "$target" "$KITTY_DIR/current-theme.conf"
    pkill -USR1 -x kitty 2>/dev/null || true

    mkdir -p "$WAYBAR_DIR"
    if [[ -f "$WAYBAR_DIR/colors-$theme.css" ]]; then
        cp "$WAYBAR_DIR/colors-$theme.css" "$WAYBAR_DIR/.colors.css.tmp"
        mv "$WAYBAR_DIR/.colors.css.tmp" "$WAYBAR_DIR/colors.css"
    else
        log "colors-$theme.css missing — waybar not switched"
    fi
    pkill -USR2 -x waybar 2>/dev/null || true

    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface color-scheme "prefer-$theme" 2>/dev/null \
            || log "gsettings failed (no dbus session?) — GTK apps not switched"
    else
        log "gsettings not found — GTK apps not switched"
    fi
}

apply() { # apply -> echoes effective theme applied (or already current)
    bootstrap_state; read_state; sun_times
    local target
    target=$(effective_theme)
    if [[ "$CURRENT" == "$target" ]]; then
        log "already $target — nothing to apply"
        echo "$target"; return 0
    fi
    apply_components "$target"
    write_state "$MODE" "$target"
    log "applied $target"
    echo "$target"
}
```

Introduce `cmd_set`/`cmd_cycle` (replacing the inline set/cycle branches from Task 1) and rewire `main`:

```bash
cmd_set() { # cmd_set auto|dark|light
    write_state "$1" "$CURRENT"
    apply >/dev/null
}

cmd_cycle() {
    local new_mode
    case "$MODE" in
        auto)  new_mode=dark ;;
        dark)  new_mode=light ;;
        light) new_mode=auto ;;
        *)     new_mode=auto ;;
    esac
    cmd_set "$new_mode"
}
```

In `main`, replace the `run|apply|plan` stub case and the `set` case:

```bash
    case "$cmd" in
        run|plan)
            log "$cmd not implemented yet"; exit 0 ;;
    esac
    case "$cmd" in
        apply)    bootstrap_state; apply ;;
        set)
            [[ ${2:-} =~ ^(auto|dark|light)$ ]] || { log "usage: dotarch-theme set auto|dark|light"; exit 2; }
            bootstrap_state; read_state
            cmd_set "$2" ;;
        cycle)    bootstrap_state; read_state; cmd_cycle ;;
        status)   cmd_status ;;
        *) log "usage: dotarch-theme {run|apply|plan|set <auto|dark|light>|cycle|status}"; exit 2 ;;
    esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/dotarch-theme.sh`
Expected: all pass, `failed=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/dotarch-theme.sh roles/desktop/theming/files/home/.local/bin/dotarch-theme
git commit -m "feat(theme): apply pipeline for kitty, waybar and GTK color-scheme"
```

---

### Task 4: Self-rescheduling timer (`plan`, `run`, flock) + systemd units

**Files:**
- Modify: `roles/desktop/theming/files/home/.local/bin/dotarch-theme`
- Create: `roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.service`
- Create: `roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.timer`

**Interfaces:**
- Consumes: `SUNRISE`/`SUNSET` from Task 2, `apply` from Task 3, unit names `dotarch-theme.service`/`dotarch-theme.timer`.
- Produces: `plan` writes `~/.config/systemd/user/dotarch-theme.timer.d/schedule.conf` containing `[Timer]` + `OnCalendar=*-*-* HH:MM:00` (next boundary, strictly future), then `systemctl --user daemon-reload && systemctl --user restart dotarch-theme.timer` (warn + exit 0 if unreachable). `run` = `apply` + `plan`. All of `run|set|cycle` take an exclusive `flock` on `$LOCK_FILE`. Unit files: service `Type=oneshot`, `Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus`, `ExecStart=%h/.local/bin/dotarch-theme run`; timer `OnBootSec=10s`, `Unit=dotarch-theme.service`, `WantedBy=default.target`.

- [ ] **Step 1: Add the failing tests**

Append to `tests/dotarch-theme.sh` (before the final summary block):

```bash
echo "T4: plan writes drop-in and re-arms timer"
sandbox plan
dropin="$TEST_HOME/.config/systemd/user/dotarch-theme.timer.d/schedule.conf"
[[ -f "$dropin" ]] && ok "drop-in exists" || fail "drop-in missing"
grep -qE '^\[Timer\]$' "$dropin" && ok "drop-in has [Timer]" || fail "no [Timer] section"
grep -qE '^OnCalendar=\*-\*-\* (0?[0-9]|1[0-9]|2[0-3]):[0-5][0-9]:00$' "$dropin" \
    && ok "OnCalendar HH:MM:00 format" || fail "OnCalendar format: $(cat "$dropin")"
grep -q "systemctl --user daemon-reload" "$TEST_HOME/calls.log"  && ok "daemon-reload called"  || fail "daemon-reload missing"
grep -q "systemctl --user restart dotarch-theme.timer" "$TEST_HOME/calls.log" && ok "timer restarted" || fail "timer restart missing"

echo "T4b: run applies + plans"
sandbox run
check "run bootstrapped mode=auto" "auto" "$(state_of mode)"
[[ -f "$TEST_HOME/.config/systemd/user/dotarch-theme.timer.d/schedule.conf" ]] \
    && ok "run wrote drop-in" || fail "run drop-in missing"

echo "T4c: plan survives dead systemctl"
new_home
printf '#!/bin/sh\nexit 1\n' > "$TEST_HOME/bin/systemctl"; chmod +x "$TEST_HOME/bin/systemctl"
run_script plan
rc=$?
check "plan exits 0 when systemctl dead" "0" "$rc"
[[ -f "$TEST_HOME/.config/systemd/user/dotarch-theme.timer.d/schedule.conf" ]] \
    && ok "drop-in still written" || fail "drop-in missing despite dead systemctl"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/dotarch-theme.sh`
Expected: T4 fails (`plan not implemented yet` → exit 0 but no drop-in). Exit non-zero overall.

- [ ] **Step 3: Implement plan/run/lock**

Add above `cmd_status`:

```bash
next_boundary() { # -> HH:MM of next switch (sunrise/sunset; tomorrow's sunrise approximated by today's)
    local now rise set_
    now=$(minutes_now); rise=$(minutes_of "$SUNRISE"); set_=$(minutes_of "$SUNSET")
    if   (( now < rise )); then printf '%s' "$SUNRISE"
    elif (( now < set_ )); then printf '%s' "$SUNSET"
    else printf '%s' "$SUNRISE"
    fi
}

plan() {
    bootstrap_state; read_state; sun_times
    local next
    next=$(next_boundary)
    mkdir -p "$TIMER_DROPIN_DIR"
    printf '[Timer]\nOnCalendar=*-*-* %s:00\n' "$next" > "$TIMER_DROPIN"
    if systemctl --user daemon-reload 2>/dev/null \
       && systemctl --user restart dotarch-theme.timer 2>/dev/null; then
        log "next theme switch at $next ($SOURCE)"
    else
        log "systemd user manager unreachable — timer not re-armed (will retry on next run)"
    fi
    return 0
}

run() {
    apply >/dev/null
    plan
}
```

Replace `main` entirely:

```bash
main() {
    local cmd=${1:-status}
    case "$cmd" in
        run|set|cycle)
            bootstrap_state
            exec 9>"$LOCK_FILE"
            flock 9
            ;;
    esac
    case "$cmd" in
        run)      run ;;
        apply)    apply ;;
        plan)     plan ;;
        set)
            [[ ${2:-} =~ ^(auto|dark|light)$ ]] || { log "usage: dotarch-theme set auto|dark|light"; exit 2; }
            read_state
            cmd_set "$2" ;;
        cycle)    read_state; cmd_cycle ;;
        status)   cmd_status ;;
        *) log "usage: dotarch-theme {run|apply|plan|set <auto|dark|light>|cycle|status}"; exit 2 ;;
    esac
}
main "$@"
```

(Mutating commands take the `flock` in the first `case`; `apply`/`plan` standalone are manual repair commands and bootstrap their own state via the `bootstrap_state` first line.)

- [ ] **Step 4: Create the systemd user units**

`roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.service`:

```ini
[Unit]
Description=Apply day/night theme and schedule the next switch

[Service]
Type=oneshot
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus
ExecStart=%h/.local/bin/dotarch-theme run
```

`roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.timer`:

```ini
[Unit]
Description=Day/night theme switching scheduler

[Timer]
OnBootSec=10s
Unit=dotarch-theme.service

[Install]
WantedBy=default.target
```

- [ ] **Step 5: Run tests + bash -n**

Run: `bash tests/dotarch-theme.sh && bash -n roles/desktop/theming/files/home/.local/bin/dotarch-theme`
Expected: all pass, no syntax errors.

- [ ] **Step 6: Commit**

```bash
git add tests/dotarch-theme.sh roles/desktop/theming/files/home/.local/bin/dotarch-theme \
        roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.service \
        roles/desktop/theming/files/home/.config/systemd/user/dotarch-theme.timer
git commit -m "feat(theme): self-rescheduling systemd user timer with flock and run command"
```

---

### Task 5: Theme content — kitty light theme + waybar color layers

**Files:**
- Create: `roles/desktop/theming/files/home/.config/kitty/theme-light.conf`
- Create: `roles/desktop/theming/files/home/.config/waybar/colors-light.css`
- Create: `roles/desktop/theming/files/home/.config/waybar/colors-dark.css`
- Create: `roles/desktop/theming/files/home/.config/waybar/colors.css`

**Interfaces:**
- Consumes: filenames consumed by `apply_components` (Task 3): `theme-light.conf` (kitty symlink target), `colors-dark.css`/`colors-light.css` (layer sources), `colors.css` (active copy; must ship as a byte-copy of `colors-dark.css`).
- Produces: the visible light theme. `Dark_Pastel.conf` and `style.css` are NOT touched (dark = byte-identical).

- [ ] **Step 1: Author the kitty light theme**

`theme-light.conf` — same hue family as Dark_Pastel (which is `background #000000`, `foreground #ffffff`, pastel `#ff5555/#55ff55/#ffff55/#5555ff/#ff55ff/#55ffff`, `color8 #8f8f8f`), with normal colors darkened for a near-white background and bright variants kept closer to the originals. `color8` is the mid-gray the zsh comment style relies on (see kitty-theme-comment-color-fix, commit 23fe0aa):

```conf
background            #fbfbfb
foreground            #1a1a1a
cursor                #555555
selection_background  #b5d5ff
selection_foreground  #1a1a1a
color0                #2e2e2e
color8                #6e6e6e
color1                #b04040
color9                #cc5555
color2                #3a8f3a
color10               #4fbf4f
color3                #997a2e
color11               #b89350
color4                #3a5fb0
color12               #5a7fd0
color5                #8a3a8a
color13               #aa5aaa
color6                #2e8a8a
color14               #4fb0b0
color7                #8a8a8a
color15               #000000
```

- [ ] **Step 2: Author the waybar layers**

`colors-dark.css` — near-no-op; only styles the NEW theme widget (amber accent when pinned):

```css
/* Dark layer: the dark look comes from style.css alone — this file only
   styles widgets that did not exist before theming (see spec). */
#custom-theme.pinned {
    color: #e6b450;
}
```

`colors-light.css` — overrides for the same selector set style.css uses (equal specificity, later file wins via the `css` array order):

```css
/* Light layer — loaded after style.css; equal-specificity rules win by order. */
window#waybar {
    color: #2e2e2e;
}
tooltip {
    background: rgba(250, 250, 252, 0.95);
    border: 1px solid rgba(0, 0, 0, 0.15);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.15);
}
tooltip label {
    color: #2e2e2e;
}
#window {
    color: #2e2e2e;
    text-shadow: none;
}
#workspaces button {
    background: rgba(255, 255, 255, 0.65);
    color: #2e2e2e;
}
#workspaces button:hover {
    background: rgba(255, 255, 255, 0.95);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.12);
}
/* active/urgent gradients from style.css kept: white text stays readable on them */
#clock,
#battery,
#cpu,
#memory,
#disk,
#temperature,
#backlight,
#network,
#custom-theme,
#custom-transcript,
#pulseaudio,
#tray {
    background-color: rgba(250, 250, 252, 0.85);
    color: #2e2e2e;
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.08);
    border: 1px solid rgba(0, 0, 0, 0.05);
}
#clock:hover,
#battery:hover,
#cpu:hover,
#memory:hover,
#disk:hover,
#temperature:hover,
#backlight:hover,
#network:hover,
#custom-theme:hover,
#custom-transcript:hover,
#pulseaudio:hover,
#tray:hover {
    background-color: rgba(255, 255, 255, 0.95);
    box-shadow: 0 3px 10px rgba(0, 0, 0, 0.12);
    border: 1px solid rgba(0, 0, 0, 0.1);
}
#network,
#network > label,
#battery,
#battery > label,
#battery.charging,
#battery.plugged,
#battery.warning:not(.charging),
#backlight,
#backlight > label,
#pulseaudio,
#pulseaudio > label,
#temperature,
#temperature > label,
#cpu,
#cpu > label,
#memory,
#memory > label,
#disk,
#disk > label {
    color: #2e2e2e;
}
#pulseaudio.muted {
    color: #2e2e2e;
    background-color: rgba(205, 205, 210, 0.9);
}
#battery.critical:not(.charging),
#temperature.critical {
    color: #2e2e2e;
    background-color: rgba(255, 70, 70, 0.18);
}
#custom-theme.pinned {
    color: #8a6d1a;
}
```

`colors.css` — byte-identical copy of `colors-dark.css` (the initial active layer):

```css
/* Dark layer: the dark look comes from style.css alone — this file only
   styles widgets that did not exist before theming (see spec). */
#custom-theme.pinned {
    color: #e6b450;
}
```

- [ ] **Step 3: Sanity checks**

Run:
```bash
diff roles/desktop/theming/files/home/.config/waybar/colors.css roles/desktop/theming/files/home/.config/waybar/colors-dark.css \
  && grep -c '^color' roles/desktop/theming/files/home/.config/kitty/theme-light.conf
```
Expected: `diff` silent (exit 0), grep count `16`.

- [ ] **Step 4: Commit**

```bash
git add roles/desktop/theming/files/home/.config/kitty/theme-light.conf \
        roles/desktop/theming/files/home/.config/waybar/colors-light.css \
        roles/desktop/theming/files/home/.config/waybar/colors-dark.css \
        roles/desktop/theming/files/home/.config/waybar/colors.css
git commit -m "feat(theme): kitty light theme and waybar color layers"
```

---

### Task 6: Ansible role + cross-role wiring + lint

**Files:**
- Create: `roles/desktop/theming/defaults/main.yml`, `roles/desktop/theming/tasks/main.yml`, `roles/desktop/theming/templates/dotarch-theme.conf.j2`
- Create: `roles/desktop/terminal/templates/home/.config/kitty/kitty.conf.j2` (moved+templated from `files/`)
- Modify: `roles/desktop/terminal/tasks/main.yml` (kitty.conf: copy → template)
- Modify: `roles/desktop/waybar/templates/home/.config/waybar/config.j2` (css array + custom/theme module)
- Modify: `roles/profiles/desktop-hyprland/tasks/main.yml` (include_role)
- Modify: `group_vars/all/deployment_config.yml` (vars)
- Modify: `AGENTS.md` (role list), `docs/superpowers/specs/2026-10-11-theme-switching-design.md` (drop `theme_cycle_order`)

**Interfaces:**
- Consumes: all files from Tasks 1–5; global var names `enable_theme_switch`, `theme_location`, `theme_latitude`, `theme_longitude`, `theme_day_time`, `theme_night_time`, `theme_enable_linger`; `ansible_facts['user_dir']`/`ansible_user` conventions from sibling roles.
- Produces: deployed runtime (script, config, layers, units, activated timer) plus the conditional hooks in terminal/waybar roles keyed on `enable_theme_switch | default(false)`.

- [ ] **Step 1: Role defaults**

`roles/desktop/theming/defaults/main.yml`:

```yaml
---
# Desktop Theming role defaults

theme_location: auto        # auto (system timezone -> coords table) | coords
theme_latitude: ""          # used when theme_location: coords
theme_longitude: ""
theme_day_time: "07:00"     # fallback sunrise when location unknown
theme_night_time: "20:00"   # fallback sunset when location unknown
theme_enable_linger: false  # keep the user manager (and timer) running before first login
```

- [ ] **Step 2: Role tasks**

`roles/desktop/theming/tasks/main.yml`:

```yaml
---
# Desktop Theming role - day/night theme switching
# Deploys the dotarch-theme switcher, theme layers and a self-rescheduling
# systemd user timer. Spec: docs/superpowers/specs/2026-10-11-theme-switching-design.md

- name: Install theming dependencies (Arch)
  become: true
  community.general.pacman:
    name:
      - dconf
      - gsettings-desktop-schemas
    state: present
  when: ansible_facts.distribution == 'Archlinux'
  tags: [desktop, theme, package]

- name: Create theming directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - "{{ ansible_facts['user_dir'] }}/.local/bin"
    - "{{ ansible_facts['user_dir'] }}/.local/state/dotarch-theme"
    - "{{ ansible_facts['user_dir'] }}/.config/systemd/user/dotarch-theme.timer.d"
  tags: [desktop, theme, config]

- name: Install dotarch-theme switcher
  ansible.builtin.copy:
    src: files/home/.local/bin/dotarch-theme
    dest: "{{ ansible_facts['user_dir'] }}/.local/bin/dotarch-theme"
    mode: '0755'
  tags: [desktop, theme, config]

- name: Template dotarch-theme runtime config
  ansible.builtin.template:
    src: dotarch-theme.conf.j2
    dest: "{{ ansible_facts['user_dir'] }}/.config/dotarch-theme.conf"
    mode: '0644'
  tags: [desktop, theme, config]

- name: Install kitty light theme
  ansible.builtin.copy:
    src: files/home/.config/kitty/theme-light.conf
    dest: "{{ ansible_facts['user_dir'] }}/.config/kitty/theme-light.conf"
    mode: '0644'
  tags: [desktop, theme, config]

- name: Bootstrap kitty current-theme symlink (dark default)
  ansible.builtin.file:
    src: Dark_Pastel.conf
    dest: "{{ ansible_facts['user_dir'] }}/.config/kitty/current-theme.conf"
    state: link
  when: not (ansible_facts['user_dir'] + '/.config/kitty/current-theme.conf') is exists
  tags: [desktop, theme, config]

- name: Install waybar color layers
  ansible.builtin.copy:
    src: "files/home/.config/waybar/{{ item }}"
    dest: "{{ ansible_facts['user_dir'] }}/.config/waybar/{{ item }}"
    mode: '0644'
  loop:
    - colors-dark.css
    - colors-light.css
    - colors.css
  tags: [desktop, theme, config]

- name: Install systemd user units
  ansible.builtin.copy:
    src: "files/home/.config/systemd/user/{{ item }}"
    dest: "{{ ansible_facts['user_dir'] }}/.config/systemd/user/{{ item }}"
    mode: '0644'
  loop:
    - dotarch-theme.service
    - dotarch-theme.timer
  tags: [desktop, theme, config]

- name: Enable linger for the timer (optional)
  become: true
  ansible.builtin.command: loginctl enable-linger {{ ansible_user }}
  changed_when: true
  when: theme_enable_linger | bool
  tags: [desktop, theme, config]

- name: Resolve ansible_user uid
  ansible.builtin.command: id -u {{ ansible_user }}
  register: theme_uid
  changed_when: false
  tags: [desktop, theme, config]

- name: Activate dotarch-theme timer
  ansible.builtin.shell: |
    systemctl --user daemon-reload
    systemctl --user enable --now dotarch-theme.timer
  environment:
    XDG_RUNTIME_DIR: "/run/user/{{ theme_uid.stdout }}"
  register: theme_timer_activate
  failed_when: false
  changed_when: true
  # noqa: command-instead-of-shell
  tags: [desktop, theme, config]

- name: Warn when the user manager was unreachable
  ansible.builtin.debug:
    msg: >
      Could not reach the systemd user manager (deploy from a pure SSH context?).
      The timer will activate at next graphical login; or re-run this role logged in.
  when: theme_timer_activate.rc | default(0) != 0
  tags: [desktop, theme, config]
```

The activation task deliberately has no `become`: the play connects as the desktop user and `systemctl --user` must run as that user — only `XDG_RUNTIME_DIR` is required. The `pacman` and `linger` tasks carry their own `become: true`.

- [ ] **Step 3: Runtime config template**

`roles/desktop/theming/templates/dotarch-theme.conf.j2`:

```ini
# Managed by Ansible (desktop/theming) — runtime config for dotarch-theme
LOCATION={{ theme_location | default('auto') }}
LATITUDE={{ theme_latitude | default('') }}
LONGITUDE={{ theme_longitude | default('') }}
DAY_TIME={{ theme_day_time | default('07:00') }}
NIGHT_TIME={{ theme_night_time | default('20:00') }}
```

- [ ] **Step 4: Terminal role — kitty.conf becomes a template**

Create `roles/desktop/terminal/templates/home/.config/kitty/kitty.conf.j2` = current `files/home/.config/kitty/kitty.conf` content with line 1 replaced:

```
include {% if enable_theme_switch | default(false) %}current-theme.conf{% else %}Dark_Pastel.conf{% endif %}
```

(Rest of the file unchanged: `background_opacity 0.7` through `url_style straight`.)

In `roles/desktop/terminal/tasks/main.yml`, split the copy loop — replace the `Copy Kitty configurations` task with:

```yaml
- name: Template Kitty configuration
  ansible.builtin.template:
    src: home/.config/kitty/kitty.conf.j2
    dest: "{{ ansible_facts['user_dir'] }}/.config/kitty/kitty.conf"
    mode: '0644'
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
  when: install_dotfiles | default(true)
  tags: [desktop, config]

- name: Copy Kitty theme files
  ansible.builtin.copy:
    src: "files/home/.config/kitty/{{ item }}"
    dest: "{{ ansible_facts['user_dir'] }}/.config/kitty/{{ item }}"
    mode: '0644'
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
  loop:
    - Dark_Pastel.conf
  when: install_dotfiles | default(true)
  tags: [desktop, config]
  failed_when: false
```

Then delete `roles/desktop/terminal/files/home/.config/kitty/kitty.conf` (`git rm`).

- [ ] **Step 5: Waybar role — css array + custom/theme module**

In `roles/desktop/waybar/templates/home/.config/waybar/config.j2`:

(a) After the `"margin-bottom": 0,` line add:

```
{% if enable_theme_switch | default(false) %}
    "css": ["style.css", "colors.css"],
{% endif %}
```

(b) In `"modules-right"`, insert `"custom/theme",` on its own line right after `"custom/transcript",`.

(c) After the `"custom/transcript"` block, add:

```
{% if enable_theme_switch | default(false) %}
    "custom/theme": {
        "exec": "~/.local/bin/dotarch-theme status --json",
        "return-type": "json",
        "interval": 5,
        "on-click": "~/.local/bin/dotarch-theme cycle",
        "on-scroll-up": "~/.local/bin/dotarch-theme set dark",
        "on-scroll-down": "~/.local/bin/dotarch-theme set light",
        "tooltip": true
    },
{% endif %}
```

- [ ] **Step 6: Meta-role + deployment config + AGENTS.md + spec**

In `roles/profiles/desktop-hyprland/tasks/main.yml`, after the "Include status bar" block add:

```yaml
- name: Include day/night theme switching
  ansible.builtin.include_role:
    name: desktop/theming
  tags: [desktop]
  when: enable_theme_switch | default(true)
```

In `group_vars/all/deployment_config.yml`, in the "Deployment options" area add:

```yaml
# Day/night theme switching (desktop/theming)
enable_theme_switch: true
theme_location: auto            # auto (timezone -> coords table) | coords
theme_latitude: ""              # used when theme_location: coords
theme_longitude: ""
theme_day_time: "07:00"         # fallback sunrise when location unknown
theme_night_time: "20:00"       # fallback sunset when location unknown
```

In `AGENTS.md`, extend the `desktop/` role list line with `, theming` (after `handlr`).

In the spec `docs/superpowers/specs/2026-10-11-theme-switching-design.md`, delete the `- \`theme_cycle_order: [auto, dark, light]\`` line (order is hardcoded `auto → dark → light` in the script; YAGNI) and remove `theme_enable_linger` from the spec's variable list if present (it ships as a role default, not a deployment_config var — keep spec and vars consistent).

- [ ] **Step 7: Lint**

Run:
```bash
yamllint roles/desktop/theming roles/desktop/terminal roles/desktop/waybar roles/profiles group_vars
ansible-lint roles/ 2>/dev/null || /usr/sbin/ansible-lint roles/ || true
```
Expected: no yamllint errors; ansible-lint reports nothing new for the touched roles (existing skips apply: `role-name[path]`, `var-naming[no-role-prefix]`, `yaml[empty-lines]`).

Fix any findings, re-run until clean.

- [ ] **Step 8: Full test suite still green**

Run: `bash tests/dotarch-theme.sh`
Expected: `failed=0`.

- [ ] **Step 9: Commit**

```bash
git add roles/desktop/theming roles/desktop/terminal roles/desktop/waybar \
        roles/profiles/desktop-hyprland group_vars/all/deployment_config.yml \
        AGENTS.md docs/superpowers/specs/2026-10-11-theme-switching-design.md
git commit -m "feat(theme): desktop/theming role with cross-role kitty/waybar hooks"
```

---

### Task 7: Deploy on host + live verification

**Files:**
- Create (ephemeral, outside repo): `/tmp/theme-deploy.yml`

**Interfaces:**
- Consumes: everything deployed by Task 6; the host's running Hyprland session (kitty, waybar, dbus, systemd user manager).
- Produces: a verified live install.

- [ ] **Step 1: Scoped deploy (repo tag scoping cannot reach through the meta-role — use a /tmp playbook with explicit vars)**

A playbook outside the repo does not auto-load `group_vars` (no `ansible_become_pass`), so run only become-free `config` tasks and install the packages directly:

```bash
pacman -Qi dconf >/dev/null 2>&1 || sudo pacman -S --needed dconf gsettings-desktop-schemas

cat > /tmp/theme-deploy.yml <<'EOF'
---
- hosts: arch
  connection: local
  become: false
  roles:
    - role: desktop/theming
    - role: desktop/terminal
    - role: desktop/waybar
EOF
cd /mnt/POOL_1_DATA/CONFIGURATION/DotArch
ANSIBLE_ROLES_PATH=roles /usr/sbin/ansible-playbook /tmp/theme-deploy.yml -i inventory.ini \
  --vault-password-file password.sh -e target=laptop -e enable_theme_switch=true \
  --tags config
```

Expected: all tasks ok/changed, no failures. (`.venv` on NFS is unreliable — use the system binary; the `linger` task is skipped by default; if the activation task warns about the user manager, re-run while logged into the desktop session.)

- [ ] **Step 2: Verify runtime behavior**

```bash
dotarch-theme status --json          # valid JSON, sensible icon/class/tooltip
dotarch-theme set light              # bar + kitty flip live; check visually
dotarch-theme set dark               # flips back; dark must look EXACTLY like before
systemctl --user list-timers dotarch-theme.timer --all   # NEXT = computed boundary
cat ~/.config/systemd/user/dotarch-theme.timer.d/schedule.conf
gsettings get org.gnome.desktop.interface color-scheme  # prefer-dark|prefer-light
```

Expected: state file transitions; kitty symlink flips; waybar restyles; timer shows next sunrise/sunset; color-scheme tracks the last applied theme.

- [ ] **Step 3: Verify a boundary fire (deterministic, ~3 min)**

Force a near boundary via the runtime config (`LOCATION=coords` with no coordinates → fixed times), clearing the date-keyed sun cache so the override takes effect immediately:

```bash
CONF=~/.config/dotarch-theme.conf
cp "$CONF" /tmp/dotarch-theme.conf.bak
BOUNDARY=$(date -d '+2 minutes' +%H:%M)
LATER=$(date -d '+3 hours' +%H:%M)
printf 'LOCATION=coords\nDAY_TIME=%s\nNIGHT_TIME=%s\n' "$BOUNDARY" "$LATER" > "$CONF"
rm -f ~/.local/state/dotarch-theme/sun-cache
dotarch-theme set auto          # now < DAY_TIME -> current=dark, timer planned at BOUNDARY
grep current= ~/.local/state/dotarch-theme/state    # expect current=dark
sleep 150
grep current= ~/.local/state/dotarch-theme/state    # expect current=light (timer fired)
grep OnCalendar ~/.config/systemd/user/dotarch-theme.timer.d/schedule.conf   # re-armed at LATER
cp /tmp/dotarch-theme.conf.bak "$CONF"
rm -f ~/.local/state/dotarch-theme/sun-cache
dotarch-theme run               # restore the real (sun-based) schedule
systemctl --user list-timers dotarch-theme.timer
```

Expected: `current=dark` → `current=light` flipped by the service firing at the planted boundary; the drop-in is then rewritten to `LATER` (self-rescheduling works); after restoring the config, `list-timers` shows the next real sunrise/sunset.

- [ ] **Step 4: User-visible acceptance**

Ask the user to confirm: light theme readability (kitty colors, bar contrast), Firefox/Betterbird flip when using "System theme — auto", the waybar button (click cycle + scroll pin) — aesthetics are first-pass values, tweakable in `theme-light.conf`/`colors-light.css`.

- [ ] **Step 5: Cleanup + commit any fixes**

```bash
rm /tmp/theme-deploy.yml
git status   # commit only files owned by this feature if fixes were needed
```

---

## Plan Self-Review (done)

- **Spec coverage:** sun-based resolution (T2), fixed fallback (T2), tz table (T2), coords override (T2/T6 vars), core scope apply pipeline (T3), self-rescheduling timer + boot catch-up + suspend semantics (T4 units), read-only waybar module + click/scroll (T6), dark byte-identical (T5, enforced by content), state + flock (T1/T4), activation guard + linger var (T6), lint/testing (T6/T7). GTK/Firefox live propagation needs no code (documented caveat).
- **Placeholders:** none — every step carries complete file content or exact commands.
- **Consistency:** `dotarch-theme`, `current-theme.conf`, `colors{,-dark,-light}.css`, `dotarch-theme.{service,timer}`, `schedule.conf`, state/sun-cache formats, and var names (`enable_theme_switch`, `theme_location`, `theme_latitude/longitude`, `theme_day_time/night_time`, `theme_enable_linger`) are used identically across tasks.
