#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/packages.sh — Distribution detection and system package provisioning
#
# Moved verbatim from install.sh (Step 1: behavior unchanged). Step 9 will
# make install_base_packages best-effort and defer `sudo -v`.
# ==============================================================================

detect_environment() {
    if ! command_exists sudo && ! command_exists brew; then
        log_error "Administrator privileges (sudo) or Homebrew are required."
        exit 1
    fi

    if command_exists sudo; then
        sudo -v
    fi

    if command_exists apt-get; then
        PM_STRATEGY="apt"
        PM_UPDATE_CMD=("sudo" "apt-get" "update")
        PM_INSTALL_CMD=("sudo" "apt-get" "install" "-y")
        DISTRO_PKGS=("build-essential" "fd-find" "gh" "pinentry-curses" "libatomic1")
    elif command_exists dnf; then
        PM_STRATEGY="dnf"
        PM_UPDATE_CMD=("sudo" "dnf" "makecache")
        PM_INSTALL_CMD=("sudo" "dnf" "install" "-y")
        DISTRO_PKGS=("@development-tools" "fd-find" "gh" "pinentry" "libatomic")
    elif command_exists pacman; then
        PM_STRATEGY="pacman"
        PM_UPDATE_CMD=("sudo" "pacman" "-Sy")
        PM_INSTALL_CMD=("sudo" "pacman" "-S" "--noconfirm" "--needed")
        DISTRO_PKGS=("base-devel" "fd" "github-cli" "pinentry")
    elif command_exists brew; then
        PM_STRATEGY="brew"
        PM_UPDATE_CMD=("brew" "update")
        PM_INSTALL_CMD=("brew" "install")
        DISTRO_PKGS=("coreutils" "fd" "gh" "pinentry-mac")
    else
        log_error "Unsupported OS. Could not detect apt, dnf, pacman, or brew."
        exit 1
    fi

    log_info "Package Manager Strategy: $PM_STRATEGY"
}

install_base_packages() {
    log_step "Installing Base System Packages"

    local pkgs=(curl gawk git gnupg2 man-db ripgrep vim zoxide)
    if [[ ${#DISTRO_PKGS[@]} -gt 0 ]]; then
        pkgs+=("${DISTRO_PKGS[@]}")
    fi

    log_info "Updating repository indexes..."
    "${PM_UPDATE_CMD[@]}"

    log_info "Installing: ${pkgs[*]}"
    "${PM_INSTALL_CMD[@]}" "${pkgs[@]}"

    init_version_sorter
    log_success "Base system packages installed successfully."
}
