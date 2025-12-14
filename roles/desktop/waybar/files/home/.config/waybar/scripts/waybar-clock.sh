#!/usr/bin/env bash

# Initial mode: 0 = normal (minutes), 1 = seconds
MODE=0

# Function to toggle mode on SIGUSR1
toggle_mode() {
    if [ "$MODE" -eq 0 ]; then
        MODE=1
    else
        MODE=0
    fi
}

trap 'toggle_mode' SIGUSR1

while true; do
    # Get current time components
    current_time=$(date +%s)
    
    # Generate Tooltip (Calendar)
    # Highlight today's date
    calendar=$(cal --color=always | sed "s/..7m/<b><span color='red'>/g;s/..27m/<\/span><\/b>/g")
    
    # Generate Text based on mode
    if [ "$MODE" -eq 0 ]; then
        # Normal mode: Day, Month Date Hour:Minute
        text=$(date +" %a, %b %d %H:%M")
        # Sleep until the start of the next minute
        sleep_duration=$((60 - $(date +%S)))
    else
        # Seconds mode: Day, Month Date Hour:Minute:Second
        text=$(date +" %a, %b %d %H:%M:%S")
        sleep_duration=1
    fi
    
    # Output JSON
    # Use jq to safely create JSON if available, otherwise manual
    # We need to escape newlines for the tooltip in JSON
    tooltip_escaped="${calendar//$'\n'/\\n}"
    
    printf '{"text": "%s", "tooltip": "%s", "class": "custom-clock"}\n' "$text" "$tooltip_escaped"
    
    # Wait in background to allow signal handling
    sleep "$sleep_duration" &
    wait $!
done
