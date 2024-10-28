#!/bin/sh

xset s 300 5
numlockx &
dunst &
picom &
sxhkd -c ~/.config/herbstluftwm/sxhkd/sxhkdrc &
/usr/lib/gpaste/gpaste-daemon &
syncthing &
lxpolkit &

xrdb -merge $HOME/.Xresources
setxkbmap -option compose:ralt

# exec wm
exec herbstluftwm --locked
