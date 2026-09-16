#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/packages.sh — Distribution detection and system package provisioning
#
# System packages are the OPTIONAL half of an install: the links, the manifest
# and every `config` subcommand work entirely in the user's own directories and
# need no privileges at all. This module therefore degrades instead of aborting,
# so a container, a locked-down machine or a machine without sudo still gets a
# usable dotfiles installation.
# ==============================================================================

# PM_PRIVILEGED — 1 when system packages can actually be installed.
PM_PRIVILEGED=0

detect_environment() {
    # detect_environment() must never exit: it runs on every install, including
    # ones that only need links. It records what is possible instead.
    if command_exists sudo; then
        if sudo -n true 2>/dev/null || sudo -v 2>/dev/null; then
            PM_PRIVILEGED=1
        else
            log_warn "sudo is present but cannot be used here; skipping system packages."
        fi
    elif command_exists brew; then
        PM_PRIVILEGED=1
    else
        log_warn "Neither sudo nor Homebrew is available; skipping system packages."
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
        log_warn "No supported package manager found (apt, dnf, pacman, brew)."
        log_info "Skipping system packages; the dotfiles links do not need them."
        PM_STRATEGY="none"
        return 0
    fi

    log_info "Package Manager Strategy: $PM_STRATEGY"
}

install_base_packages() {
    log_step "Installing Base System Packages"

    if [[ "${PM_PRIVILEGED:-0}" -ne 1 || "${PM_STRATEGY:-none}" == "none" ]]; then
        log_info "Skipped: system packages cannot be installed in this environment."
        log_info "The dotfiles links, the manifest and 'config' do not need them."
        init_version_sorter
        return 0
    fi

    local pkgs=(curl gawk git gnupg2 man-db ripgrep vim zoxide)
    if [[ ${#DISTRO_PKGS[@]} -gt 0 ]]; then
        pkgs+=("${DISTRO_PKGS[@]}")
    fi

    log_info "Updating repository indexes..."
    "${PM_UPDATE_CMD[@]}" || log_warn "Index update failed; continuing with what is cached."

    # Best effort: one unavailable package name must not abort an install whose
    # actual job — linking files and recording ownership — needs no privileges.
    log_info "Installing: ${pkgs[*]}"
    if ! "${PM_INSTALL_CMD[@]}" "${pkgs[@]}"; then
        log_warn "Some system packages could not be installed."
        log_info "Re-run later, or install them manually: ${pkgs[*]}"
    fi

    init_version_sorter
    log_success "Base system packages processed."
}
