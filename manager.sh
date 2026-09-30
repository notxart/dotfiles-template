#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# manager.sh — Dotfiles manager: the only entry point.
#
#   install [--with-git-tui] [--with-dsh]     update [--dry-run] [--only TOOL]
#   config <status|sync|adopt|ignore|restore>       -h prints the full help
# ==============================================================================

set -euo pipefail

# --- Script Location (must be defined before the libraries are sourced) -------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
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
    # Manager-level flags are answered before dispatch. Matching them here (not
    # in parse_args) keeps `--version` from running install's preamble, which
    # used to print "Dotfiles Setup Initialized" before the version string.
    case "${1:-}" in
        -h|--help)    show_help; return 0 ;;
        -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$MANAGER_VERSION"; return 0 ;;
    esac

    # The subcommand is ALWAYS explicit. There is deliberately no
    # "bare flags mean install" fallback: `./manager.sh --with-git-tui` and
    # `./manager.sh install --with-git-tui` doing the same thing is exactly the
    # ambiguity that makes a command line hard to reason about.
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$command" in
        install)    cmd_install "$@" ;;
        update)     cmd_update "$@" ;;
        config)     cmd_config "$@" ;;
        "")
            # No subcommand at all: show the commands instead of guessing.
            show_help
            ;;
        -*)
            log_error "Missing subcommand before '$command'."
            log_info "Did you mean: $SCRIPT_NAME install $command"
            printf '\n' >&2
            show_help >&2
            exit 1
            ;;
        *)
            log_error "Unknown command: $command"
            show_help >&2
            exit 1
            ;;
    esac
}

main "$@"
