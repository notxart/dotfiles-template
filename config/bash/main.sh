# shellcheck shell=bash
# Bash entry point: rc.d drop-ins are sourced in lexicographic order, so 00-xdg runs
# before anything that depends on the XDG variables.

BASH_RCDIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash/rc.d"

if [[ -d "$BASH_RCDIR" ]]; then
    for file in "$BASH_RCDIR"/*.sh; do
        if [[ -r "$file" ]]; then
            # shellcheck disable=SC1090  # rc.d drop-ins are resolved at runtime
            source "$file"
        fi
    done
fi

unset BASH_RCDIR file
