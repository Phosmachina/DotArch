#!/usr/bin/env bash

# Get current workspace ID and Name
# We need the ID for operations and Name for display
CURRENT_JSON=$(hyprctl activeworkspace -j)
CURRENT_ID=$(echo "$CURRENT_JSON" | jq -r '.id')
CURRENT_NAME=$(echo "$CURRENT_JSON" | jq -r '.name')

# Define a temporary ID for swapping
# Using a high number to avoid conflicts with typical workspace IDs
TEMP_ID=9999

# Get list of other active workspaces excluding the current one
# Format: "ID: Name"
# We exclude the current workspace to avoid swapping with self
LIST=$(hyprctl workspaces -j | jq -r --argjson current "$CURRENT_ID" '.[] | select(.id != $current) | "\(.id): \(.name)"' | sort -n)

if [ -z "$LIST" ]; then
    notify-send "Swap Workspaces" "No other active workspaces found."
    exit 0
fi

# Select target workspace using vicinae dmenu
# We use -p to set the prompt
SELECTED=$(echo "$LIST" | vicinae dmenu -p "Swap workspace $CURRENT_NAME with:")

if [ -z "$SELECTED" ]; then
    exit 0
fi

# Extract Target ID from selection (format "ID: Name")
TARGET_ID=$(echo "$SELECTED" | cut -d':' -f1)

if [ -z "$TARGET_ID" ]; then
    notify-send "Swap Workspaces" "Invalid selection."
    exit 1
fi

# Swap logic using the renaming technique:
# 1. Rename Current Workspace -> Temp ID (vacating Current ID)
# 2. Rename Target Workspace -> Current ID (moving Target content to Current ID)
# 3. Rename Temp ID (old Current) -> Target ID (moving Current content to Target ID)
# 4. Ensure we focus the workspace with the "Current ID"

# Use --batch to ensure atomicity and avoid race conditions where IDs might not be freed immediately
hyprctl --batch "dispatch renameworkspace $CURRENT_ID $TEMP_ID ; dispatch renameworkspace $TARGET_ID $CURRENT_ID ; dispatch renameworkspace $TEMP_ID $TARGET_ID ; dispatch workspace $CURRENT_ID"
