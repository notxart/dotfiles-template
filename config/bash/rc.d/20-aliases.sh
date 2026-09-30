# shellcheck shell=bash
# This file contains shell aliases for convenience.

# General alias
# The trailing space in "sudo " allows aliases to be expanded after sudo.
alias sudo="sudo "
alias diff="diff --color=auto"

# Safety nets
# Forces interactive mode to prevent accidents.
alias rm="rm -i"
alias mv="mv -i"
alias cp="cp -i"

# Grep family
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Listing
alias ls="ls -F --color=auto --group-directories-first"
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Portable System Update (automatically detects the package manager and aliases 'update')
if command -v apt >/dev/null 2>&1; then
    # Debian / Ubuntu
    alias update='sudo apt update && sudo apt upgrade'
elif command -v dnf >/dev/null 2>&1; then
    # Fedora / RHEL
    alias update='sudo dnf upgrade --refresh'
elif command -v pacman >/dev/null 2>&1; then
    # Arch Linux
    alias update='sudo pacman -Syu'
elif command -v brew >/dev/null 2>&1; then
    # macOS Homebrew
    alias update='brew update && brew upgrade'
fi

# ----------------------------------------------------------------------
# USER CUSTOMIZATIONS
# ----------------------------------------------------------------------
# Define your custom aliases below.

# Example: Custom Tool Shortcuts
# if command -v kubectl >/dev/null 2>&1; then alias k="kubectl"; fi
