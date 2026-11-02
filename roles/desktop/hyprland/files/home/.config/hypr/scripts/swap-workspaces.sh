#!/usr/bin/env bash
# Swap the contents of the current workspace with a picked one.
# Mechanism: move every window current -> tmp, target -> current, tmp ->
# target. Moving by window (not by renaming workspaces) sidesteps Hyprland's
# workspace name/ID normalization; window.move carries whole groups natively.
# hyprctl dispatch takes a Lua expression (Hyprland >= 0.55 Lua config).

CURRENT_NAME=$(hyprctl activeworkspace -j | jq -r '.name')

# Other open workspaces, labeled with their monitor
LIST=$(hyprctl workspaces -j | jq -r \
    --arg current "$CURRENT_NAME" \
    '.[] | select(.name | test("^[0-9]+$")) | select(.name != $current) | "\(.name) (\(.monitor))"' \
    | sort -n)

if [ -z "$LIST" ]; then
    notify-send "Swap workspaces" "No other workspaces are open."
    exit 0
fi

SELECTED=$(echo "$LIST" | vicinae dmenu -p "Swap $CURRENT_NAME with:")
[ -z "$SELECTED" ] && exit 0

TARGET_NAME=${SELECTED%% *}

if [ "$TARGET_NAME" = "$CURRENT_NAME" ]; then
    exit 0
fi

# Special workspaces are invisible to waybar's workspace module, so the
# shuffle never flashes or leaves an empty-labeled chip in the bar
TMP="special:swapping"

move_all() { # $1 = source workspace name, $2 = destination workspace name
    hyprctl -j clients | jq -r --arg ws "$1" \
        '.[] | select(.workspace.name == $ws) | .address' | \
    while read -r addr; do
        hyprctl dispatch "hl.dsp.window.move({window=hl.get_window(\"address:$addr\"), workspace='$2'})" >/dev/null
    done
}

move_all "$CURRENT_NAME" "$TMP" && \
move_all "$TARGET_NAME" "$CURRENT_NAME" && \
move_all "$TMP" "$TARGET_NAME" && \
hyprctl dispatch "hl.dsp.focus({workspace='$CURRENT_NAME'})" || \
    notify-send "Swap workspaces" "Swap $CURRENT_NAME <-> $TARGET_NAME failed"
