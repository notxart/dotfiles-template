#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/common.sh — Shared constants, logging, lifecycle and version utilities
#
# Sourced by manager.sh. May also be sourced standalone (e.g. by tests); the
# SCRIPT_DIR bootstrap below makes that safe regardless of source order.
# ==============================================================================

# --- Script Location Bootstrap -------------------------------------------------
# The entry point defines SCRIPT_DIR; a module sourced on its own derives it.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
readonly SCRIPT_DIR

# --- Constants & Global State --------------------------------------------------

# Script Metadata
# manager.sh sets SCRIPT_NAME readonly; re-declaring a readonly variable aborts
# the shell, so this guard is required for a standalone source, not cosmetic.
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
    readonly SCRIPT_NAME
fi

# Color Palette (POSIX compliant formatting)
readonly CLR_RESET="\033[0m"
readonly CLR_BLUE="\033[1;34m"
readonly CLR_GREEN="\033[1;32m"
readonly CLR_YELLOW="\033[1;33m"
readonly CLR_RED="\033[1;31m"
readonly CLR_MUTED="\033[0;37m"

# Feature Flags
#
# Default only when nothing outside supplied a value: an exported override or a
# recorded manifest flag would otherwise be clobbered on every source.
FLAG_GIT_TUI="${FLAG_GIT_TUI:-0}"
FLAG_WITH_DSH="${FLAG_WITH_DSH:-0}"
FLAG_GIT_TUI_SET=0
FLAG_WITH_DSH_SET=0

# Shell guidance shown in the installer's final message when the user's login
# shell is not bash (set by ensure_bash_shell; empty = keep the default message).
BASH_SHELL_GUIDANCE=""

# Dynamic Environment & Package Manager State
PM_STRATEGY=""
PM_UPDATE_CMD=()
PM_INSTALL_CMD=()
SORT_CMD="sort"
DISTRO_PKGS=()

# Resource Management State
TMP_DIRS=()

# ==============================================================================
# Cleanup & Signal Lifecycle Management
# ==============================================================================

cleanup() {
    local exit_code=$?
    # Prevent recursive signal handling during termination
    trap - EXIT INT TERM HUP

    for dir in "${TMP_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
        fi
    done

    exit "$exit_code"
}

create_temp_dir() {
    local tmp
    tmp="$(mktemp -d)"
    TMP_DIRS+=("$tmp")
    printf '%s\n' "$tmp"
}

# ==============================================================================
# Logging & Terminal Output
# ==============================================================================

log_step()    { printf "\n${CLR_BLUE}❯❯❯ %s${CLR_RESET}\n" "$1"; }
log_info()    { printf "  ${CLR_MUTED}%s${CLR_RESET}\n" "$1"; }
log_success() { printf "  ${CLR_GREEN}✓ %s${CLR_RESET}\n" "$1"; }
log_warn()    { printf "  ${CLR_YELLOW}⚠ %s${CLR_RESET}\n" "$1"; }
log_error()   { printf "\n${CLR_RED}Error: %s${CLR_RESET}\n" "$1" >&2; }

# ==============================================================================
# Interaction
#
# Every prompt is fail-closed: with no terminal the answer is the safe one, so
# automation can never trigger a file move by accident.
# ==============================================================================

is_tty() { [[ -t 0 && -t 1 ]]; }

# confirm <question> [default y|n]
# Returns 0 for yes, 1 for no. Without a TTY it returns the DEFAULT without
# asking, so a piped run can never block and never silently accepts.
confirm() {
    local question="$1" default="${2:-n}" reply
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
        return 0
    fi
    if ! is_tty; then
        [[ "$default" == "y" ]]
        return
    fi
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    printf '  %s %s ' "$question" "$hint" >&2
    read -r reply || reply=""
    [[ -z "$reply" ]] && reply="$default"
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ==============================================================================
# System & Version Utilities
# ==============================================================================

command_exists() { command -v "$1" >/dev/null 2>&1; }

# sha256_file <path> — hex digest on stdout, empty when no tool exists. Advisory
# only: git decides whether content drifted, so a missing tool is not an error.
sha256_file() {
    if command_exists sha256sum; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif command_exists openssl; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

init_version_sorter() {
    if sort --version-sort </dev/null >/dev/null 2>&1; then
        SORT_CMD="sort"
    elif command_exists gsort; then
        SORT_CMD="gsort"
    else
        SORT_CMD="sort"
        if [[ "$PM_STRATEGY" == "brew" ]]; then
            log_warn "GNU sort not found. 'coreutils' should be installed for accurate version sorting."
        fi
    fi
}

compare_versions_lt() {
    local v1="$1"
    local v2="$2"

    [[ -z "$v1" ]] && return 0
    [[ "$v1" == "$v2" ]] && return 1

    local smallest
    smallest=$(printf '%s\n%s\n' "$v1" "$v2" | $SORT_CMD -V | head -n1)
    [[ "$smallest" == "$v1" ]]
}

# get_installed_version <cmd> — the version of the binary this shell would run:
# pnpm's global bin, then ~/.local/bin, then PATH — the order the shell resolves.
# Reading ~/.local/bin first could report a copy that nothing executes.
get_installed_version() {
    local cmd="$1"
    local target_cmd=""
    local candidate
    local pnpm_bin="${PNPM_HOME:-$HOME/.local/share/pnpm}/bin/$cmd"

    for candidate in "$pnpm_bin" "$HOME/.local/bin/$cmd"; do
        if [[ -x "$candidate" ]]; then
            target_cmd="$candidate"
            break
        fi
    done

    if [[ -z "$target_cmd" ]]; then
        target_cmd="$(command -v "$cmd" 2>/dev/null || true)"
    fi
    [[ -n "$target_cmd" ]] || return 1

    local output
    output=$(LC_ALL=C "$target_cmd" --version 2>&1 | head -n1)

    case "$cmd" in
        starship) awk '{print $2}' <<< "$output" ;;
        fzf)      awk '{print $1}' <<< "$output" ;;
        # "v24.19.0" -> "24.19.0". The leading v is node's own convention and
        # nothing else in the project compares versions with it attached.
        node)     sed -E 's/^v//' <<< "$output" ;;
        lazygit)
            # Format: "..., version='0.50.0+ds1', ..., git version=2.47.3" -> "0.50.0"
            # Target the isolated 'version=' field and ignore trailing 'git version='
            grep -oE '(^|,)[[:space:]]*version=[^,]+' <<< "$output" \
                | grep -oE '[0-9]+(\.[0-9]+)+' \
                | head -n1
            ;;
        *)        awk '{print $NF}' <<< "$output" ;;
    esac
}

get_candidate_version() {
    local pkg="$1"
    local version=""

    case "$PM_STRATEGY" in
        apt)
            version=$(LC_ALL=C apt-cache policy "$pkg" 2>/dev/null | grep 'Candidate:' | awk '{print $2}' | cut -d- -f1)
            ;;
        dnf)
            version=$(LC_ALL=C dnf info --available "$pkg" 2>/dev/null | grep '^Version' | head -n1 | awk '{print $3}' | cut -d: -f2)
            ;;
        pacman)
            version=$(LC_ALL=C pacman -Si "$pkg" 2>/dev/null | grep '^Version' | awk '{print $3}' | cut -d- -f1)
            ;;
        brew)
            version=$(LC_ALL=C brew info "$pkg" 2>/dev/null | head -n1 | awk '{print $4}')
            ;;
    esac

    printf '%s\n' "$version" | xargs
}
