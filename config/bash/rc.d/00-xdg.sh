# This file sets up XDG Base Directory environment variables.
# It should be sourced first to make these variables available to other scripts.

export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# Set PATH to include user's private bin if it exists and is not already in PATH
if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Set GnuPG home to follow XDG spec
export GNUPGHOME="${XDG_DATA_HOME}/gnupg"
export GPG_TTY=$(tty)

# Tell Git to use our XDG-compliant config file
export GIT_CONFIG_GLOBAL="${XDG_CONFIG_HOME}/git/config.ini"
