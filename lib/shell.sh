#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/shell.sh — Login shell management, Git feature validation, GPG hardening
#
# Moved verbatim from install.sh (Step 1: behavior unchanged).
# ==============================================================================

check_git_version() {
    log_step "Validating Git Feature Constraints"
    local ver
    ver=$(get_installed_version "git")

    if [[ -z "$ver" ]]; then
        log_error "Git binary missing from environment."
        exit 1
    fi

    if compare_versions_lt "$ver" "2.37"; then
        log_warn "Git $ver detected. Dotfiles configuration requires Git >= 2.37:"
        log_info "- push.autoSetupRemote (2.37), merge.conflictstyle=zdiff3 (2.35)"
        log_info "- help.autocorrect=prompt (2.34), push --force-if-includes (2.30)"
        log_warn "Please upgrade Git. Some configurations will degrade silently."
    else
        log_success "Git $ver satisfies requirements (>= 2.37)."
    fi
}

# ==============================================================================
# Login Shell & Bash Version Management
# ==============================================================================

# macOS ships /bin/bash 3.2 (Apple froze it under GPLv3) while ble.sh
# recommends Bash >= 4.0 — auto-complete and menu-filter are 4.0+ features.
# The installer never replaces /bin/bash: Homebrew's bash installs in parallel
# at $(brew --prefix)/bin/bash. The login shell is switched automatically ONLY
# when it is the system /bin/bash; zsh/fish/other login shells are never
# touched — those users get a one-time manual hint in the final message
# instead (BASH_SHELL_GUIDANCE). Everything here stays Bash-3.2-compatible on
# purpose: this installer itself may be running under /bin/bash 3.2 on macOS.

get_login_shell() {
    local user="${SUDO_USER:-$(whoami)}"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$user" 2>/dev/null | cut -d: -f7
    fi
}

# macOS only: one-time login-shell switch with verification. The /etc/shells
# append may be silently rejected (SIP/permissions), so verify with grep
# before chsh, then re-verify the result via dscl. Failures degrade to a
# manual instruction set in BASH_SHELL_GUIDANCE instead of exiting.
switch_login_shell() {
    local target="$1" current="$2" user="${SUDO_USER:-$(whoami)}" verify

    log_info "Switching login shell $current -> $target ..."
    if ! grep -qxF "$target" /etc/shells 2>/dev/null; then
        sudo sh -c "printf '%s\n' '$target' >> /etc/shells" 2>/dev/null || true
    fi
    if ! grep -qxF "$target" /etc/shells 2>/dev/null; then
        log_warn "Could not add $target to /etc/shells (permissions/SIP may block it)."
        BASH_SHELL_GUIDANCE="Add '$target' to /etc/shells and switch (one-time): sudo sh -c 'echo \"$target\" >> /etc/shells' && sudo chsh -s \"$target\" \"$user\""
        return 1
    fi

    if sudo chsh -s "$target" "$user" 2>/dev/null; then
        verify="$(dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}')"
        if [[ "$verify" == "$target" ]]; then
            log_success "Login shell switched to $target (takes effect in new terminal windows)."
            BASH_SHELL_GUIDANCE=""
        else
            log_warn "chsh reported success but the shell is still '${verify:-unknown}'."
            BASH_SHELL_GUIDANCE="Finish the shell switch manually (one-time): sudo chsh -s \"$target\" \"$user\", then open a new terminal."
        fi
    else
        log_warn "chsh failed (sudo prompt interrupted or unavailable)."
        BASH_SHELL_GUIDANCE="Switch manually (one-time): sudo sh -c 'echo \"$target\" >> /etc/shells' && sudo chsh -s \"$target\" \"$user\", then open a new terminal."
        return 1
    fi
}

ensure_bash_shell() {
    local login_shell brew_bash="" brew_major bash_path

    BASH_SHELL_GUIDANCE=""
    login_shell="$(get_login_shell)"
    [[ -z "$login_shell" ]] && login_shell="${SHELL:-}"

    # --- macOS + Homebrew: make sure the current Homebrew bash is present ---
    if [[ "$(uname -s)" == "Darwin" && "$PM_STRATEGY" == "brew" ]]; then
        brew_bash="$(brew --prefix)/bin/bash"

        # The installer runs with the user's interactive bash; if that is
        # still the ancient 3.2, install Homebrew bash (idempotent).
        if [[ ${BASH_VERSINFO[0]} -lt 4 ]] && [[ "$login_shell" != "$brew_bash" ]]; then
            log_step "Upgrading Bash for ble.sh (system bash is 3.2; ble.sh recommends >= 4.0)"
            "${PM_INSTALL_CMD[@]}" bash
        fi

        if [[ -x "$brew_bash" ]]; then
            brew_major="$("$brew_bash" -c 'echo ${BASH_VERSINFO[0]}')"
            if [[ "$brew_major" -ge 4 ]]; then
                log_success "Homebrew Bash $("$brew_bash" -c 'echo ${BASH_VERSION}') installed at $brew_bash"
            else
                brew_bash=""
                log_warn "Homebrew Bash at $brew_bash is below 4.0; ble.sh auto-complete/menu-filter will degrade."
            fi
        else
            brew_bash=""
            log_warn "Homebrew Bash not found ('brew install bash' may have failed)."
        fi
    fi

    # --- Cross-platform login-shell classification for the final message ---
    case "$login_shell" in
        *bash*)
            if [[ -n "$brew_bash" && "$login_shell" != "$brew_bash" ]]; then
                # macOS + login shell is the system /bin/bash (3.2): auto-switch.
                switch_login_shell "$brew_bash" "$login_shell"
            elif [[ "$(uname -s)" == "Darwin" && -z "$brew_bash" ]]; then
                # macOS + /bin/bash but brew bash unavailable: loud manual fix.
                BASH_SHELL_GUIDANCE="Homebrew bash could not be installed/verified; ble.sh features degrade on Bash 3.2. Fix (one-time): brew install bash && sudo sh -c 'echo \"$(brew --prefix)/bin/bash\" >> /etc/shells' && sudo chsh -s \"$(brew --prefix)/bin/bash\" \"${SUDO_USER:-$(whoami)}\""
            fi
            ;;
        "")
            BASH_SHELL_GUIDANCE="Could not detect your login shell; this setup only applies under bash. Set your login shell to bash (chsh) before restarting."
            ;;
        *)
            # zsh / fish / sh / other: never touch it, only guide.
            if [[ -n "$brew_bash" ]]; then
                BASH_SHELL_GUIDANCE="Your login shell is $login_shell; this setup only activates under bash. Switch (one-time): sudo sh -c 'echo \"$brew_bash\" >> /etc/shells' && sudo chsh -s \"$brew_bash\" \"${SUDO_USER:-$(whoami)}\", then open a new terminal."
            else
                bash_path="$(command -v bash)"
                if [[ -z "$bash_path" ]]; then
                    BASH_SHELL_GUIDANCE="Bash not found on PATH; this setup requires bash."
                elif grep -qxF "$bash_path" /etc/shells 2>/dev/null; then
                    BASH_SHELL_GUIDANCE="Your login shell is $login_shell; this setup only activates under bash. Switch (one-time): sudo chsh -s \"$bash_path\" \"${SUDO_USER:-$(whoami)}\", then open a new terminal."
                else
                    BASH_SHELL_GUIDANCE="Your login shell is $login_shell; this setup only activates under bash. Switch (one-time): sudo sh -c 'echo \"$bash_path\" >> /etc/shells' && sudo chsh -s \"$bash_path\" \"${SUDO_USER:-$(whoami)}\", then open a new terminal."
                fi
            fi
            ;;
    esac
}
