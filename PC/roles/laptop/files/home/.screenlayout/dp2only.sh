#!/bin/sh

xrandr --output eDP-1 --off --output DP-1 --off --output HDMI-1 --off --output DP-2 --mode 3440x1440 --pos 0x0 --rotate normal --scale 1.5x1.5 --output DP-3 --off --output DP-4 --off
herbstclient reload
