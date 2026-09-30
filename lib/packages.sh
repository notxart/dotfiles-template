#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/packages.sh — Distribution detection and system package provisioning
#
# System packages are the OPTIONAL half of an install: links, the manifest and
# `config` need no privileges, so this module degrades instead of aborting.
# ==============================================================================

# PM_PRIVILEGED — 1 when system packages can actually be installed. Detection
# answers "which package manager is this"; being allowed to use it is a separate
# question that may cost a password, so it is asked only when about to install.
PM_PRIVILEGED=0

detect_environment() {
    # Never exits: it runs on every install and records what is POSSIBLE.
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

# acquire_privileges [--non-interactive] — may a package be installed, and set
# PM_PRIVILEGED. The default form may prompt; --non-interactive never does, and is
# what `update` uses, since a mid-run prompt would arrive without context.
acquire_privileges() {
    local noninteractive=0
    [[ "${1:-}" == "--non-interactive" ]] && noninteractive=1

    if command_exists brew; then
        PM_PRIVILEGED=1
        return 0
    fi

    if command_exists sudo; then
        if sudo -n true 2>/dev/null; then
            PM_PRIVILEGED=1
            return 0
        fi
        if [[ "$noninteractive" -eq 0 ]] && sudo -v 2>/dev/null; then
            PM_PRIVILEGED=1
            return 0
        fi
        log_warn "sudo is present but cannot be used without a password here."
    else
        log_warn "Neither sudo nor Homebrew is available."
    fi

    PM_PRIVILEGED=0
    return 1
}

install_base_packages() {
    log_step "Installing Base System Packages"

    # Test the strategy before the privilege: acquire_privileges is the only
    # prompt here, and a machine with no package manager has nothing to elevate.
    if [[ "${PM_STRATEGY:-none}" == "none" ]] || ! acquire_privileges; then
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

    install_packages_best_effort "${pkgs[@]}"

    init_version_sorter
    log_success "Base system packages processed."
}

# install_packages_best_effort <pkg>... — install what exists, report what does
# not. apt and dnf abort the whole transaction over one unknown name, so a failed
# batch is retried one package at a time.
install_packages_best_effort() {
    local -a pkgs=("$@")
    local -a missing=()
    local pkg installed=0

    if "${PM_INSTALL_CMD[@]}" "${pkgs[@]}" >/dev/null 2>&1; then
        log_success "Installed all ${#pkgs[@]} package(s) in one transaction."
        return 0
    fi

    log_warn "Installing them together failed; retrying one at a time."
    for pkg in "${pkgs[@]}"; do
        if "${PM_INSTALL_CMD[@]}" "$pkg" >/dev/null 2>&1; then
            installed=$((installed + 1))
        else
            missing+=("$pkg")
        fi
    done

    log_info "Installed $installed of ${#pkgs[@]} package(s)."
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_warn "Not available here: ${missing[*]}"
        log_info "These are optional; everything else, including every link, is done."
    fi
    return 0
}
