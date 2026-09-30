# shellcheck shell=bash
# Configuration for shell plugins.

# --- Starship ---
# Initialize Starship prompt
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi

# --- zoxide ---
# A smarter 'cd' command. It must be initialized *after* plugins that might affect 'cd'
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init bash)"
fi
