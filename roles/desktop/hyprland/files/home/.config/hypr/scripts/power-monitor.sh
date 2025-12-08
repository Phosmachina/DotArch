#!/bin/bash

# Configuration
HYPRIDLE_AC_CONF="$HOME/.config/hypr/hypridle_ac.conf"
HYPRIDLE_BAT_CONF="$HOME/.config/hypr/hypridle_bat.conf"

# Function to apply power settings
apply_settings() {
    local state=$1
    echo "Applying power settings for state: $state"

    if [ "$state" == "AC" ]; then
        # AC Mode: Performance, Relaxed idle
        powerprofilesctl set performance 2>/dev/null
        pkill hypridle
        hypridle -c "$HYPRIDLE_AC_CONF" &
        notify-send "Power Mode" "Switched to AC Power (Performance)"
    else
        # Battery Mode: Balanced/PowerSaver, Aggressive idle
        powerprofilesctl set balanced 2>/dev/null
        pkill hypridle
        hypridle -c "$HYPRIDLE_BAT_CONF" &
        notify-send "Power Mode" "Switched to Battery Power (Balanced)"
    fi
}

# Initial detection
if upower -i $(upower -e | grep 'BAT') | grep -q "state:\s*discharging"; then
    current_state="BAT"
else
    current_state="AC"
fi
apply_settings "$current_state"

# Monitor for changes
upower -m | while read -r line; do
    if echo "$line" | grep -q "on-battery: no"; then
        if [ "$current_state" != "AC" ]; then
            current_state="AC"
            apply_settings "AC"
        fi
    elif echo "$line" | grep -q "on-battery: yes"; then
        if [ "$current_state" != "BAT" ]; then
            current_state="BAT"
            apply_settings "BAT"
        fi
    fi
done
