#!/usr/bin/env bash

direction=$1

# Get current workspace ID
current_ws=$(hyprctl activeworkspace -j | jq '.id')

# Define min and max workspaces for cycling
MIN_WS=1
MAX_WS=9

if [ "$direction" == "next" ]; then
    if [ "$current_ws" -ge "$MAX_WS" ]; then
        target_ws=$MIN_WS
    else
        target_ws=$((current_ws + 1))
    fi
elif [ "$direction" == "prev" ]; then
    if [ "$current_ws" -le "$MIN_WS" ]; then
        target_ws=$MAX_WS
    else
        target_ws=$((current_ws - 1))
    fi
fi

if [ -n "$target_ws" ]; then
    hyprctl dispatch workspace "$target_ws"
fi
