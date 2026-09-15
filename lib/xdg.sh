#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/xdg.sh — XDG Base Directory initialization and execution PATH bootstrap
#
# Scope note: this module only prepares XDG paths for the *manager's own*
# process. It never reads or sources the user's shell rc.d files — see the
# README section "Shared values across both layers" for the contract.
# ==============================================================================

init_xdg_env() {
    log_step "Initializing XDG Environment & Paths"

    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
    export PNPM_HOME="${PNPM_HOME:-$XDG_DATA_HOME/pnpm}"

    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$HOME/.local/bin" "$PNPM_HOME"

    # Inject paths into the current execution subshell immediately
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    if [[ ":$PATH:" != *":$PNPM_HOME/bin:"* && -d "$PNPM_HOME/bin" ]]; then
        export PATH="$PNPM_HOME/bin:$PATH"
    fi

    log_success "XDG Base Directories and Execution Paths prepared."
}
