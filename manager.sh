#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# manager.sh — Dotfiles manager (install / update / config)
#
# Description:
#   Single entry point for configuring a machine from this repository, keeping
#   the toolchain current, and reconciling ~/.config with the tracked config/.
#
# Usage:
#   ./manager.sh install [--with-git-tui] [--with-dsh]
#   ./manager.sh update
#   ./manager.sh config <status|sync|adopt|ignore|restore>
# ==============================================================================

set -euo pipefail

# --- Script Location (must be defined before the libraries are sourced) -------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly MANAGER_VERSION="0.1.0"

# --- Library Loading ----------------------------------------------------------
# Order matters: common defines the globals the later modules reference at
# call time, cmd last because it orchestrates all of them.
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/xdg.sh
source "$SCRIPT_DIR/lib/xdg.sh"
# shellcheck source=lib/link.sh
source "$SCRIPT_DIR/lib/link.sh"
# shellcheck source=lib/scan.sh
source "$SCRIPT_DIR/lib/scan.sh"
# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/packages.sh
source "$SCRIPT_DIR/lib/packages.sh"
# shellcheck source=lib/tools.sh
source "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=lib/shell.sh
source "$SCRIPT_DIR/lib/shell.sh"
# shellcheck source=lib/update.sh
source "$SCRIPT_DIR/lib/update.sh"
# shellcheck source=lib/cmd.sh
source "$SCRIPT_DIR/lib/cmd.sh"

trap cleanup EXIT INT TERM HUP

# --- Dispatch -----------------------------------------------------------------
main() {
    # A leading option (or no argument) means the historical `./install.sh`
    # style: `./manager.sh` and `./manager.sh --with-git-tui` both mean
    # `install`. Only a non-option first word is treated as a subcommand.
    local command="install"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        command="$1"
        shift
    fi

    case "$command" in
        install)    cmd_install "$@" ;;
        update)     cmd_update "$@" ;;
        config)     cmd_config "$@" ;;
        *)
            log_error "Unknown command: $command"
            show_help >&2
            exit 1
            ;;
    esac
}

main "$@"
