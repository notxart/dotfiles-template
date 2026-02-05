#!/usr/bin/env bash

# ==============================================================================
# Dotfiles Installation Script
#
# Description:
#   Sets up the Bash environment, installs dependencies, and configures symlinks
#   compliant with the XDG Base Directory Specification.
#
# Author: Traxton Chen (Refactored)
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
set -euo pipefail

# ==============================================================================
# Global Configuration & Constants
# ==============================================================================

# Global variables for Package Manager Strategy.
# These will be populated by 'detect_environment'.
PM_STRATEGY=""
UPDATE_CMD=""
INSTALL_CMD=""
SORT_CMD="sort"

# Distro-specific packages (e.g., build tools, platform-specific naming variations)
DISTRO_PKGS=()

# ==============================================================================
# Utility Functions (Logging & Basic Checks)
# ==============================================================================

# Print a message in a consistent, colorful format.
# Usage: log "This is a message."
log() {
    # Blue color for the prompt arrow
    echo -e "\n\033[1;34m❯❯❯ $1\033[0m"
}

# Print an error message.
# Usage: error "Something went wrong."
error() {
    # Red color for error messages
    echo -e "\n\033[1;31mError: $1\033[0m" >&2
}

# Check if a command is available in the PATH.
# Usage: command_exists "git"
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ==============================================================================
# Version Control Logic
# ==============================================================================

# Initialize the sort command based on system capabilities.
# macOS 'sort' does not support -V, so we rely on 'gsort' from coreutils.
init_version_sorter() {
    # Check if default sort supports version sort
    if sort --version-sort </dev/null >/dev/null 2>&1; then
        SORT_CMD="sort"
    elif command_exists gsort; then
        SORT_CMD="gsort"
    else
        # Fallback warning, though install_packages should handle this for macOS
        if [[ "$PM_STRATEGY" == "brew" ]]; then
            log "Warning: GNU sort not found. 'coreutils' will be installed to ensure correct versioning."
        fi
        SORT_CMD="sort"
    fi
}

# Compare two semantic versions.
# Usage: compare_versions_lt "curr_ver" "req_ver"
# Returns 0 (true) if current < required (update needed).
# Returns 1 (false) if current >= required (sufficient).
compare_versions_lt() {
    local v1="$1"
    local v2="$2"

    # Treat empty v1 as the lowest possible version (needs update)
    [[ -z "$v1" ]] && return 0

    # If versions are identical, strictly not less than.
    [[ "$v1" == "$v2" ]] && return 1

    # Sort versions using sort -V (version sort) and pick the top one.
    # If the smallest of the two is v1, then v1 < v2.
    local smallest
    smallest=$(printf '%s\n%s\n' "$v1" "$v2" | $SORT_CMD -V | head -n1)

    [[ "$smallest" == "$v1" ]]
}

# Extract the version string from an installed command.
# Heuristics are used to parse different output formats from various tools.
get_installed_version() {
    local cmd="$1"

    # Priority check: Check local bin first to avoid detecting system binary if shadowed
    local local_bin="$HOME/.local/bin/$cmd"
    local target_cmd="$cmd"

    if [[ -x "$local_bin" ]]; then
        target_cmd="$local_bin"
    elif ! command_exists "$cmd"; then
        return 1
    fi

    # Retrieve version output once
    local output
    output=$(LC_ALL=C "$target_cmd" --version 2>&1 | head -n1)

    case "$cmd" in
        starship)
            # Format: "starship 1.22.1" -> "1.22.1"
            awk '{print $2}' <<< "$output"
            ;;
        fzf)
            # Format: "0.60 (devel)" -> "0.60"
            awk '{print $1}' <<< "$output"
            ;;
        *)
            # Fallback: Grab the last word (e.g., "git version 2.34.1" -> "2.34.1")
            awk '{print $NF}' <<< "$output"
            ;;
    esac
}

# Specific parsing logic for fetching version from remote repositories.
# Note: This is brittle and depends on the specific output format of PMs.
get_candidate_version() {
    local pkg="$1"
    local version=""

    case "$PM_STRATEGY" in
        apt)
            # Parse 'apt-cache policy' for Candidate version
            version=$(LC_ALL=C apt-cache policy "$pkg" 2>/dev/null | grep 'Candidate:' | awk '{print $2}' | cut -d- -f1)
            ;;
        dnf)
            # Parse 'dnf info' for Version
            version=$(LC_ALL=C dnf info --available "$pkg" 2>/dev/null | grep '^Version' | head -n1 | awk '{print $3}' | cut -d: -f2)
            ;;
        pacman)
            # Parse 'pacman -Si' for Version
            version=$(LC_ALL=C pacman -Si "$pkg" 2>/dev/null | grep '^Version' | awk '{print $3}' | cut -d- -f1)
            ;;
        brew)
            # Parse 'brew info'
            version=$(LC_ALL=C brew info "$pkg" 2>/dev/null | head -n1 | awk '{print $4}')
            ;;
    esac

    # Trim whitespace
    echo "$version" | xargs
}

# ==============================================================================
# Environment Detection
# ==============================================================================

detect_environment() {
    # Pre-flight check for sudo/root capabilities
    if ! command_exists sudo && ! command_exists brew; then
        error "Administrator privileges (sudo) or Homebrew are required."
        exit 1
    fi

    # Refresh sudo privileges upfront to prevent timeouts during long installs
    if command_exists sudo; then
        sudo -v
    fi

    # Detect Package Manager and configure commands
    if command_exists apt-get; then
        PM_STRATEGY="apt"
        UPDATE_CMD="sudo apt-get update"
        INSTALL_CMD="sudo apt-get install -y"
        DISTRO_PKGS=("build-essential" "fd-find")

    elif command_exists dnf; then
        PM_STRATEGY="dnf"
        UPDATE_CMD="sudo dnf makecache"
        INSTALL_CMD="sudo dnf install -y"
        DISTRO_PKGS=("@development-tools" "fd-find")

    elif command_exists pacman; then
        PM_STRATEGY="pacman"
        UPDATE_CMD="sudo pacman -Sy"
        INSTALL_CMD="sudo pacman -S --noconfirm --needed"
        DISTRO_PKGS=("base-devel" "fd")

    elif command_exists brew; then
        PM_STRATEGY="brew"
        UPDATE_CMD="brew update"
        INSTALL_CMD="brew install"
        # Homebrew needs coreutils for 'gsort' (GNU sort) to support version sorting
        DISTRO_PKGS=("coreutils" "fd")

    else
        error "Unsupported OS. Could not detect apt, dnf, pacman, or brew."
        exit 1
    fi

    log "Environment Detected: $PM_STRATEGY"
}

# ==============================================================================
# Installation Logic
# ==============================================================================

## Base Package Installation
install_packages() {
    log "Installing base packages..."

    # Common utilities list.
    # Note: 'fzf' and 'starship' are handled separately via verify_and_install_tool.
    local pkgs=(curl gawk git gnupg2 man-db vim zoxide)

    # Append distro-specific packages
    if [ ${#DISTRO_PKGS[@]} -gt 0 ]; then
        pkgs+=("${DISTRO_PKGS[@]}")
    fi

    log "Updating repositories..."
    $UPDATE_CMD

    log "Installing: ${pkgs[*]}"
    $INSTALL_CMD "${pkgs[@]}"

    # Re-evaluate sort command after installation (specifically for macOS/coreutils)
    init_version_sorter

    log "Base packages installed."
}

## Specific Install Callbacks (Fallback Strategies)
# These functions are called only when the system package manager fails to provide a sufficient version of the tool.

install_fzf_manual() {
    log "Fallback: Installing fzf from source..."

    local fzf_dir="$XDG_DATA_HOME/fzf"
    local bin_dest="$HOME/.local/bin/fzf"

    # Clean previous attempts
    [ -d "$fzf_dir" ] && rm -rf "$fzf_dir"

    if git clone --depth 1 https://github.com/junegunn/fzf.git "$fzf_dir"; then
        # Run installer, generate binary only
        "$fzf_dir/install" --bin

        # Symlink to local bin
        mkdir -p "$(dirname "$bin_dest")"
        ln -sf "$fzf_dir/bin/fzf" "$bin_dest"

        log "fzf installed manually to $bin_dest"
    else
        error "Failed to clone fzf repository."
        exit 1
    fi
}

install_starship_manual() {
    log "Fallback: Installing Starship via official script..."

    # Try default install (usually /usr/local/bin, requires sudo)
    if ! curl -sS https://starship.rs/install.sh | sh -s -- -y; then
        log "System-wide install failed. Attempting local install to ~/.local/bin..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
    fi
}

## Strategy Validator
# Checks if a tool meets version requirements. Priorities:
# 1. Current Local Version (if sufficient, skip)
# 2. Package Manager Version (if sufficient, install)
# 3. Manual Installation (Callback function)
#
# Arguments:
#   $1: cmd_name (e.g., "fzf")
#   $2: pkg_name (e.g., "fzf")
#   $3: req_ver  (e.g., "0.60")
#   $4: callback (Function name to call if PM fails)
verify_and_install_tool() {
    local cmd="$1"
    local pkg="$2"
    local req_ver="$3"
    local callback="$4"
    local current_ver=""
    local candidate_ver=""

    log "Checking Requirement: $cmd >= $req_ver"

    # Step 1: Check if currently installed version is sufficient
    if command_exists "$cmd"; then
        current_ver=$(get_installed_version "$cmd")
        if ! compare_versions_lt "$current_ver" "$req_ver"; then
            log "✓ Local $cmd version ($current_ver) is sufficient."
            return 0
        fi
        log "⚠ Local $cmd version ($current_ver) is outdated."
    fi

    # Step 2: Check Package Manager Candidate
    log "Checking repository candidate for '$pkg'..."
    candidate_ver=$(get_candidate_version "$pkg")

    # If candidate exists AND is >= required version
    if [[ -n "$candidate_ver" ]] && ! compare_versions_lt "$candidate_ver" "$req_ver"; then
        log "✓ Repository version ($candidate_ver) is sufficient. Installing via $PM_STRATEGY..."
        $INSTALL_CMD "$pkg"

        # Verification Post-Install
        current_ver=$(get_installed_version "$cmd")
        if compare_versions_lt "$current_ver" "$req_ver"; then
            error "Package manager installed $current_ver, which is still too old. Proceeding to fallback."
            # Fallthrough to callback if PM failed to deliver promises
        else
            return 0
        fi
    else
        log "⚠ Repository version (${candidate_ver:-not found}) is insufficient."
    fi

    # Step 3: Fallback to Manual Installation
    log "Proceeding with manual installation strategy ($callback)..."
    eval "$callback"
}

# ==============================================================================
# Configuration & Dotfiles Linking
# ==============================================================================

# Set up XDG Base Directories to organize config, data, and cache files.
# Ref: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
setup_xdg_dirs() {
    log "Configuring XDG Base Directories..."
    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
    mkdir -p "$HOME/.local/bin"

    log "XDG directories ready."
}

# Configure GnuPG permissions strictly as required by the tool.
configure_gpg() {
    log "Configuring GnuPG..."
    local gpg_home="$XDG_DATA_HOME/gnupg"
    local owner="${SUDO_USER:-$(whoami)}"

    mkdir -p "$gpg_home"
    chown -R "$owner" "$gpg_home"
    chmod 700 "$gpg_home"

    log "GnuPG permissions secured."
}

# Ensure fd is available as 'fd' even on systems that name it 'fdfind' (Debian/Ubuntu)
configure_fd_alias() {
    # If 'fdfind' exists (installed by apt) but 'fd' does not
    if command_exists fdfind && ! command_exists fd; then
        log "Mapping 'fdfind' to 'fd' in ~/.local/bin..."
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi
}

# Create symbolic links for dotfiles, backing up any existing configurations.
setup_symlinks() {
    log "Synchronizing Dotfiles..."

    local dotfiles_dir
    dotfiles_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local backup_dir="$HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    # "Source_Rel_Path:Dest_Abs_Path"
    local links=(
        ".bash_profile:$HOME/.bash_profile"
        ".bashrc:$HOME/.bashrc"
        "config/starship.toml:$XDG_CONFIG_HOME/starship.toml"
        "config/bash:$XDG_CONFIG_HOME/bash"
        "config/git:$XDG_CONFIG_HOME/git"
    )

    for link in "${links[@]}"; do
        local src="${link%%:*}"
        local dest="${link#*:}"
        local full_src="$dotfiles_dir/$src"

        # Ensure parent dir exists
        mkdir -p "$(dirname "$dest")"

        # Backup Logic:
        # 1. If dest exists and is NOT a symlink -> Backup
        # 2. If dest is a directory (even if empty) and not a symlink -> Backup
        if [ -e "$dest" ] && [ ! -L "$dest" ]; then
            log "Backing up existing: $dest"
            mv "$dest" "$backup_dir/"
        fi

        # Link Creation
        # ln -sf will force overwrite if it's a file or symlink.
        # But if dest is a directory, 'ln -sf src dest' creates 'dest/src', which is wrong.
        # The backup logic above should handle the directory case, but we double check.
        if [ -d "$dest" ] && [ ! -L "$dest" ]; then
             error "Destination $dest is a directory and failed to backup. Skipping."
             continue
        fi

        log "Linking: $dest -> $src"
        ln -sf "$full_src" "$dest"
    done
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================

main() {
    log "Starting Dotfiles Setup ❮❮❮"

    detect_environment
    setup_xdg_dirs
    install_packages

    # Install/Update smart tools with version enforcement
    # Arguments: verify_and_install_tool <cmd> <package> <min_version> <fallback_func>
    verify_and_install_tool "fzf" "fzf" "0.60" "install_fzf_manual"
    verify_and_install_tool "starship" "starship" "1.20.0" "install_starship_manual"

    # Post-installation configurations
    configure_fd_alias

    setup_symlinks
    configure_gpg

    log "Setup Complete! ❮❮❮"
    log "Please restart your shell or run 'source ~/.bashrc' to apply changes."
}

main
