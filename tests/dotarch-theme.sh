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
