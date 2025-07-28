#!/usr/bin/env bash

# Set runtime dir
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Find the Hyprland IPC socket and extract the signature
SOCKET=$(ls "$XDG_RUNTIME_DIR"/hyprland-ipc.* 2>/dev/null | head -n1)
if [[ -z "$SOCKET" ]]; then
  echo "⛔ Cannot find Hyprland IPC socket in $XDG_RUNTIME_DIR" >&2
  exit 1
fi
export HYPRLAND_INSTANCE_SIGNATURE="${SOCKET##*.}"

# Wallpaper logic
WALLPAPER_DIR="$HOME/Images/Wallpapers/"
CURRENT_WALL=$(hyprctl hyprpaper listloaded | xargs basename)

# Pick a random file that's not the current one
WALLPAPER=$(find "$WALLPAPER_DIR" -type f ! -name "$CURRENT_WALL" | shuf -n1)
if [[ -n "$WALLPAPER" ]]; then
  hyprctl hyprpaper reload ,"$WALLPAPER"
fi
