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

# Where this dotfiles checkout lives. config/git/config.ini uses it to reach
# config/git/wrap-msg.sh, which formats commit messages before the editor opens.
#
# readlink -f resolves this file's OWN path, which is reached through
# ~/.config/bash -> <repo>/config/bash, so the value is this repository's real
# location rather than the $HOME path the symlink was entered through. That is
# what makes the absolute path in config.ini portable: each clone exports its
# own location instead of the path being hardcoded.
DSH_DOTFILES_DIR="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
if [[ -n "$DSH_DOTFILES_DIR" ]]; then
    # <repo>/config/bash/rc.d/00-xdg.sh -> <repo>: four levels up (the file
    # itself, rc.d, bash, config).
    DSH_DOTFILES_DIR="$(dirname "$(dirname "$(dirname "$(dirname "$DSH_DOTFILES_DIR")")")")"
    export DSH_DOTFILES_DIR
else
    # readlink -f is unavailable: fall back to the documented clone location.
    export DSH_DOTFILES_DIR="$HOME/dotfiles"
fi
