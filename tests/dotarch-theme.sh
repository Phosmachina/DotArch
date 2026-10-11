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

echo; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
