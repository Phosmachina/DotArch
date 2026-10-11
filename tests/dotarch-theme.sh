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
printf '#!/bin/sh\necho America/Sao_Paulo\n' > "$TEST_HOME/bin/timedatectl" # unmapped tz -> fixed defaults
run_script set dark
check "default DAY_TIME written to sun-cache" "07:00" "$(grep '^sunrise=' "$TEST_HOME/.local/state/dotarch-theme/sun-cache" | cut -d= -f2)"

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

echo "T2c: malformed cache values fall through to recomputation"
new_home
printf 'date=%s\nsunrise=banana\nsunset=19:11\nsource=sun\n' "$(date +%F)" > "$TEST_HOME/.local/state/dotarch-theme/sun-cache"
run_script status --json >/dev/null 2>&1
check "malformed cache survives status"   "0"     "$?"
check "sunrise rewritten well-formed"     "1"     "$(grep -cE '^sunrise=[0-9]{1,2}:[0-9]{2}$' "$TEST_HOME/.local/state/dotarch-theme/sun-cache")"
check "source still valid"                "sun"   "$(grep '^source=' "$TEST_HOME/.local/state/dotarch-theme/sun-cache" | cut -d= -f2)"

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
want=dark; [[ 10#$mode_now -ge 700 && 10#$mode_now -lt 2000 ]] && want=light
check "auto resolved by time of day" "$want" "$(state_of current)"

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

echo; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
