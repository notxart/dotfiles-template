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
#
# Set by acquire_privileges, never by detect_environment. Detection answers
# "which package manager is this", which needs no privileges; being allowed to
# use it is a separate question, and one that may cost the user a password, so it
# is asked only at the point where a package is about to be installed. Probing
# during detection meant an install that only creates links could stop at a
# password prompt for work it was never going to do.
PM_PRIVILEGED=0

detect_environment() {
    # detect_environment() must never exit: it runs on every install, including
    # ones that only need links. It records what is POSSIBLE instead.
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

# acquire_privileges [--non-interactive] — decide whether packages can be
# installed, and set PM_PRIVILEGED accordingly.
#
# The default form may ask for a password, because the caller has already
# decided that something needs installing. --non-interactive never asks: sudo
# must already work without a prompt, or Homebrew is present. `update` uses that
# form, since it runs a whole toolchain in a row and a prompt arriving in the
# middle of it would have no context.
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

    # Ask the cheap question first. A machine with no package manager has
    # nothing to elevate for, and testing the strategy before the privilege
    # keeps acquire_privileges — the only function here that can prompt — from
    # running at all in that case.
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

# install_packages_best_effort <pkg>... — install what exists, report what does not.
#
# The list mixes names that exist nearly everywhere with names that are
# distribution-specific, and apt and dnf abort the WHOLE transaction when one
# name is unknown. A single call therefore used to leave a machine with none of
# the packages because of one of them. One transaction is still tried first,
# because it is faster and lets the package manager resolve everything together;
# only when it fails is the list retried one package at a time.
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
