# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH="$ZDOTDIR/ohmyzsh"

ZSH_THEME="arrow"
DISABLE_AUTO_TITLE="false"
ENABLE_CORRECTION="true"
CORRECT_IGNORE="[_|.]*"
COMPLETION_WAITING_DOTS="true"

plugins=(
    git
    fzf
    aliases
    compleat
    command-not-found
    cp
    history
    zoxide
    jump
    systemd
    archlinux
    zsh-interactive-cd
)

source $ZSH/oh-my-zsh.sh

# User configuration
f="$HOME/.config/zsh/aliasrc" && test -f "$f" && source "$f"
f="$HOME/.config/zsh/functionrc" && test -f "$f" && source "$f"

# Load zsh-autosuggestions.
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
source /usr/share/zsh/plugins/zsh-autopair/autopair.zsh 2>/dev/null

# Load zsh-syntax-highlighting; should be last.
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null

WORDCHARS='*?_-.[]~=&;!#$%^(){}<>'
MOTION_WORDCHARS='~!#$%^&*(){}[]<>?.+;-/'
autoload -U select-word-style
select-word-style normal

# History in cache directory:
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=${XDG_CACHE_HOME:-$HOME/.cache}/zsh/history

setopt histsavenodups histignorespace appendhistory autocd beep notify promptsubst completealiases

# Keybinding for zle.
bindkey '^H' backward-delete-word       # ctrl + backspace
bindkey '^[[3;5~' delete-word           # ctrl + del
bindkey '^[[1;5D' backward-word         # ctrl + left
bindkey '^[[1;5C' forward-word          # ctrl + right
bindkey '^[[5~' beginning-of-history    # pgup
bindkey '^[[6~' end-of-history          # pgdn
bindkey '^[[H' beginning-of-line        # home
bindkey '^[[F' end-of-line              # end
bindkey '^?' backward-delete-char       # backspace
bindkey '^[[3~' delete-char             # del
bindkey '^U' backward-kill-line         # ctrl + u
bindkey '^K' kill-line                  # ctrl + k
bindkey -s '^o' 'lfcd\n'
bindkey -s '^n' 'newterm\n'

# Use lf to cd to a directory
lfcd() {
	tmp="$(mktemp)"
	lfub -last-dir-path="$tmp" "$@"
	if [ -f "$tmp" ]; then
		dir="$(cat "$tmp")"
		rm -f "$tmp"
		if [ -d "$dir" ]; then
			if [ "$dir" != "$(pwd)" ]; then
				cd "$dir"
			fi
		fi
	fi
}

newterm() {
	setsid -f kitty
}

