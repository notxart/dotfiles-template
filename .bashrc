# shellcheck shell=bash
# ~/.bashrc: executed by bash(1) for non-login shells.

# If not running interactively, don't do anything.
case $- in
    *i*) ;;
      *) return;;
esac

# Define the bash config directory for clarity.
BASH_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash"

# Load main settings profile if it exists.
if [[ -f "$BASH_CONFIG_DIR/main.sh" ]]; then
    source "$BASH_CONFIG_DIR/main.sh"
else
    # Provide a basic warning to prevent accidental loss of the settings file.
    echo "Warning: Bash config file '$BASH_CONFIG_DIR/main.sh' does not exist." >&2
fi

# Clean up the variable to avoid polluting the global namespace.
unset BASH_CONFIG_DIR
