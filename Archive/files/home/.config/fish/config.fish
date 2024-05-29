if status is-interactive
    # Commands to run in interactive sessions can go here
end

set -g fish_greeting

bind \v kill-whole-line
bind \e\[3\;5~ kill-word
bind \b backward-kill-word

# Open lf
bind \co lfcd

# Start X at login
if status is-login
    if test -z "$DISPLAY" -a "$XDG_VTNR" = 1
        source $HOME/.profile
        exec startx -- -keeptty
    end
end

for folder in ~/.local/bin/*/;
    set -x PATH $PATH $folder
end

