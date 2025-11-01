#!/bin/bash

# cliphist-rofi integration script

case $1 in
    d) cliphist list | rofi -dmenu -p "Clipboard History" | cliphist delete ;;
    w) cliphist list | rofi -dmenu -p "Clipboard History" | cliphist decode | wl-copy ;;
    i) cliphist list-images | rofi -dmenu -p "Clipboard Images" | cliphist decode | wl-copy ;;
    *) cliphist list | rofi -dmenu -p "Clipboard History" | cliphist decode | wl-copy ;;
esac
