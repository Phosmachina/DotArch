# Export PATH recursively:
for dir in "$HOME/.local/bin"/*/; do
  export PATH="$dir:$PATH"
done

export PATH="$HOME/go/bin:$HOME/.local/opt/pso:$HOME/.local/bin:$PATH"

# Default programs:
export EDITOR="micro"
export TERMINAL="kitty"
export BROWSER="firefox"
export READER="zathura"
export FILE="setsid -f kitty -e 'lf \"%s\"'"

# Other program settings:
export XDG_CONFIG_HOME=$HOME/.config
export XDG_DATA_HOME=$HOME/.local/share

# ~/ Clean up:
export lESSHISTFILE="-"
export ZDOTDIR="$HOME/.config/zsh"

# Other:
export _JAVA_AWT_WM_NONREPARENTING=1
export LF_BOOKMARK_PATH="$XDG_CONFIG_HOME/lf/bookmarks"

# Added by Toolbox App
export PATH="$PATH:/home/michel/.local/share/JetBrains/Toolbox/scripts"

[ "$(tty)" = '/dev/tty1' ] && startx
