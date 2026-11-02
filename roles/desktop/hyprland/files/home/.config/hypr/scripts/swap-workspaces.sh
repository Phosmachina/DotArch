#!/usr/bin/env bash
# Swap the contents of the current workspace with a picked one, then focus
# the picked workspace — you land on your content wherever it went. Picking
# an empty workspace degenerates to "move my windows there and switch".
# Mechanism: move every window current -> tmp, target -> current, tmp ->
# target. Moving by window (not by renaming workspaces) sidesteps Hyprland's
# workspace name/ID normalization; window.move carries whole groups natively.
# hyprctl dispatch takes a Lua expression (Hyprland >= 0.55 Lua config).
# vicinae dmenu contract: -f data prints the selected entry verbatim
# (Escape exits 1) — without -f data the output format is an index.

CURRENT_NAME=$(hyprctl activeworkspace -j | jq -r '.name')

# All ten standard workspaces (plus any other existing numeric ones), each
# with a preview of its windows, e.g. "2  mpv, kitty" / "7  (empty)"
LIST=$(hyprctl -j workspaces | jq -r --arg current "$CURRENT_NAME" \
    --slurpfile C <(hyprctl -j clients) '
    [.[] | select(.name | test("^[0-9]+$")) | .name] as $existing
    | (["1","2","3","4","5","6","7","8","9","10"] + $existing) | unique | .[]
    | select(. != $current)
    | . as $ws
    | "\($ws)  \([$C[0][] | select(.workspace.name == $ws) | .class] | unique
        | if length == 0 then "(empty)" else join(", ") end)"' | sort -n)

if [ -z "$LIST" ]; then
    notify-send "Swap workspaces" "No other workspaces are open."
    exit 0
fi

SELECTED=$(echo "$LIST" | vicinae dmenu -f data -n "Workspaces" -s "Swap $CURRENT_NAME with" -p "Search") || exit 0
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
hyprctl dispatch "hl.dsp.focus({workspace='$TARGET_NAME'})" || \
    notify-send "Swap workspaces" "Swap $CURRENT_NAME <-> $TARGET_NAME failed"
