# Base
abbr -a !! --position anywhere --function last_history_item
alias l='exa -F --group-directories-first'
alias ll='exa -F -1la --icons --group-directories-first'
alias llt='exa -FR -aL2 --icons --group-directories-first'
alias cat="bat --theme 'Sublime Snazzy'"
alias doas='doas --'

# File
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -sh'
alias lf='lfcd'
alias progress='progress -m'

# Editor
alias m='micro'
abbr -a -- c code

# Mount
abbr -a -- mnt-cifs ''
abbr -a -- mnt-dk ''
