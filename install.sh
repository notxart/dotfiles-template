#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

# --- Helper Functions ---

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

# Check if a command exists.
# Usage: command_exists "git"
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Compare package version
# Usage: compare_version "ver1" "ver2"
compare_version() {
    local v1=$1
    local v2=$2
    local tmpv="$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)"
    if [ "$tmpv" = "$v1" ] && [ "$tmpv" != "$v2" ]; then
        return 0
    else
        return 1  # v1 > v2
    fi
}

# --- Global Logic: Detect Environment Once ---

# Define global variables for the installation strategy
PM_STRATEGY=""
INSTALL_CMD=""

detect_environment() {
    # Check for Sudo
    if ! command_exists sudo && ! command_exists brew; then
        error "sudo command not found. Please install necessary packages manually."
        exit 1
    fi

    # Identify Package Manager & set the Installation Strategy
    if command_exists apt-get; then
        PM_STRATEGY="apt"
        INSTALL_CMD="sudo apt install -y"
    elif command_exists dnf; then
        PM_STRATEGY="dnf"
        INSTALL_CMD="sudo dnf install -y"
    elif command_exists pacman; then
        PM_STRATEGY="pacman"
        INSTALL_CMD="sudo pacman -S --noconfirm"
    elif command_exists brew; then
        PM_STRATEGY="brew"
        INSTALL_CMD="brew install"
    else
        error "Could not detect a supported package manager."
        exit 1
    fi

    log "Detected Package Manager: $PM_STRATEGY"
}

# --- Main Installation Logic ---

# Install necessary packages, handling different package managers.
install_packages() {
    log "Installing necessary packages..."

    # A common set of development and shell enhancement tools.
    local pkgs="curl fzf gawk git gnupg2 man-db vim zoxide"

    log "You may be prompted for your password to install packages via sudo."

    # Execute the bootstrap logic based on the detected strategy
    case "$PM_STRATEGY" in
        apt)
            sudo apt update
            $INSTALL_CMD build-essential $pkgs
            ;;
        dnf)
            sudo dnf groupinstall -y "Development Tools"
            $INSTALL_CMD $pkgs
            ;;
        pacman)
            # Arch needs -Syu and base-devel
            sudo pacman -Syu --noconfirm --needed base-devel $pkgs
            ;;
        brew)
            $INSTALL_CMD ${pkgs// / }
            ;;
    esac

    log "Packages installed successfully."
}

# Use a fallback strategy when installing Starship.
install_starship() {
    log "Checking for Starship..."
    if command_exists starship; then
        log "Starship is already installed."
        return 0
    fi

    log "Attempting to install Starship via $PM_STRATEGY..."

    # Strategy: Try package manager first. If it fails, fall back to the official install script.
    if ! $INSTALL_CMD starship 2>/dev/null; then
        log "Starship package not found in system repositories. Falling back to official installer..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y
    fi
}

# Set up XDG Base Directories to organize config, data, and cache files.
# Ref: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
setup_xdg_dirs() {
    log "Setting up XDG base directories..."
    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

    mkdir -p "$XDG_CONFIG_HOME"
    mkdir -p "$XDG_CACHE_HOME"
    mkdir -p "$XDG_DATA_HOME"
    mkdir -p "$XDG_STATE_HOME"
    mkdir -p "$HOME/.local/bin" # Standard location for user-specific binaries
    log "XDG directories are ready."
}

# Create symbolic links for dotfiles, backing up any existing configurations.
setup_symlinks() {
    log "Setting up symlinks..."
    # Get the absolute path of the directory where this script is located.
    # This makes the script runnable from anywhere.
    local DOTFILES_DIR
    DOTFILES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    local BACKUP_DIR="$HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log "Backups of existing files will be stored in $BACKUP_DIR"

    # Define files and directories to symlink in "source:destination" format.
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

        # Resolve full paths
        local full_src="$DOTFILES_DIR/$src"
        local full_dest="$dest"

        # Ensure the parent directory of the destination exists.
        mkdir -p "$(dirname "$full_dest")"

        # If destination exists and is a regular file/dir (not a symlink), back it up.
        if [ -e "$full_dest" ] && [ ! -L "$full_dest" ]; then
            log "Backing up existing file/directory: $full_dest"
            mv "$full_dest" "$BACKUP_DIR/"
        fi

        # If the destination is a broken symlink, remove it.
        if [ -L "$full_dest" ] && [ ! -e "$full_dest" ]; then
            log "Removing broken symlink: $full_dest"
            rm "$full_dest"
        fi

        # Create symlink if it doesn't already exist.
        if [ ! -e "$full_dest" ]; then
            log "Creating symlink: $full_dest -> $full_src"
            ln -s "$full_src" "$full_dest"
        else
            log "Symlink already exists: $full_dest"
        fi
    done
    log "Symlinks created successfully."
}

# Configure GnuPG to use the XDG data directory.
configure_gpg() {
    log "Configuring GnuPG..."
    local GPG_HOME="$XDG_DATA_HOME/gnupg"
    mkdir -p "$GPG_HOME"

    # Correctly determine the user to chown to, even when run with sudo.
    local owner="${SUDO_USER:-$(whoami)}"

    # Set secure permissions required by GnuPG.
    chown -R "$owner" "$GPG_HOME"
    chmod 700 "$GPG_HOME"

    log "GnuPG home set to $GPG_HOME with correct permissions for user '$owner'."
}

# If the fzf package that agent using is outated then update the fzf version
update_fzf() {
    local version=""
    local required_version="0.60"

    if ! command_exists fzf; then
        log "Package fzf had not been founded, installing fzf..."
    else
        # get current fzf version
        version=$(fzf --version | cut -d ' ' -f1)
        log "fzf founded version: $version"
    fi
    
    if [ -z "$version" ] || compare_version "$version" "$required_version"; then
        # install fzf
        log "Updating fzf from source..."
        local DOTFILES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
        local FZF_DIR="$DOTFILES_DIR/config/fzf"
        [ -d "$FZF_DIR" ] && rm -rf "$FZF_DIR"
        if git clone --depth 1 https://github.com/junegunn/fzf.git "$FZF_DIR"; then
            "$FZF_DIR/install" --all
            log "Package fzf update successfully"
        else
            error "Failed to install fzf"
            rm -rf "$FZF_DIR"
            exit 1
        fi

        # Remove old fzf package
        if [ -n "$version" ]; then
            log "Removing old fzf version..."
            case "$PM_STRATEGY" in
                apt)
                    sudo apt purge -y fzf 2>/dev/null || true
                    sudo apt autoremove -y
                    ;;
                dnf)
                    sudo dnf remove -y fzf 2>/dev/null || true
                    ;;
                pacman)
                    sudo pacman -R --noconfirm fzf 2>/dev/null || true
                    ;;
                brew)
                    brew uninstall fzf 2>/dev/null || true
                    ;;
            esac
            log "Removing old fzf version successfully"
        fi
    fi
}

# Main function to orchestrate the entire setup process.
main() {
    log "Starting Bash dotfiles setup..."

    detect_environment  # Run once, use everywhere
    install_packages
    install_starship
    setup_xdg_dirs
    setup_symlinks
    configure_gpg
    update_fzf

    log "Setup complete! Please restart your shell or run 'source ~/.bashrc' to apply changes."
}

# Execute the main function to start the script.
main
