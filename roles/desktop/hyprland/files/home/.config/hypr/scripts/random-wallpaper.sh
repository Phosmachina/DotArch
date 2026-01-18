#!/usr/bin/env bash

# Wallpaper logic
WALLPAPER_DIR="$HOME/Images/Wallpapers/"
CURRENT_WALL=$(hyprctl hyprpaper listloaded | xargs -0 basename)

# Pick a random file that's not the current one
WALLPAPER=$(find "$WALLPAPER_DIR" -type f ! -name "$CURRENT_WALL" | shuf -n1)
if [[ -n "$WALLPAPER" ]]; then
  hyprctl hyprpaper reload ,"$WALLPAPER"
fi
