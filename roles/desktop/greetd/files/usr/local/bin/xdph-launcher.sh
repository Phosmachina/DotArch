#!/bin/sh

# This script ensures xdg-desktop-portal-hyprland is properly started
# XDPH is normally automatically started by D-Bus, but this provides a fallback

sleep 1
killall -e xdg-desktop-portal-hyprland
killall xdg-desktop-portal
/usr/lib/xdg-desktop-portal-hyprland &
sleep 2
/usr/lib/xdg-desktop-portal &
