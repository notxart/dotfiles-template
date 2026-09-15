#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/cmd.sh — Subcommand orchestration (install / update / config)
# ==============================================================================

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME <command> [OPTIONS]

Commands:
  install         Configure this machine from the dotfiles repository.
  update          Update the toolchain (pnpm, hunk, dsh, lazygit, ...).
  config          Reconcile ~/.config with this repository.

Install Options:
  --with-git-tui  Install hunk, lazygit, and link their configurations.
  --with-dsh      Install DeepSeek Harness via pnpm and link skills.
  -h, --help      Display this help documentation.
  -V, --version   Display the manager version.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-git-tui)
                FLAG_GIT_TUI=1
                log_info "Option enabled: Git TUI Review Stack"
                shift
                ;;
            --with-dsh)
                FLAG_WITH_DSH=1
                log_info "Option enabled: DeepSeek Harness"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "$SCRIPT_NAME" "${MANAGER_VERSION:-unknown}"
                exit 0
                ;;
            *)
                log_warn "Ignoring unrecognized argument: $1"
                shift
                ;;
        esac
    done
}

cmd_install() {
    log_step "Dotfiles Setup Initialized"

    parse_args "$@"
    init_xdg_env

    # Verify the paths this manager is about to install into are the same ones
    # the user's shell will read. Runs before anything touches the system, so a
    # divergence is reported rather than silently acted upon.
    xdg_assert_consistency --strict || exit 1
    manifest_init
    manifest_flag_set "git_tui" "$FLAG_GIT_TUI"
    manifest_flag_set "dsh" "$FLAG_WITH_DSH"

    detect_environment
    install_base_packages
    ensure_bash_shell
    check_git_version
    install_pnpm

    # Version Enforcement Verification
    ensure_tool_version "fzf" "fzf" "0.60" "install_fzf_fallback"
    ensure_tool_version "starship" "starship" "1.20.0" "install_starship_fallback"

    if [[ "$FLAG_GIT_TUI" -eq 1 ]]; then
        ensure_tool_version "hunk" "hunk" "0.19.0" "install_hunk_fallback"
        ensure_tool_version "lazygit" "lazygit" "0.44.0" "install_lazygit_fallback"
    fi

    if [[ "$FLAG_WITH_DSH" -eq 1 ]]; then
        install_dsh
    fi

    configure_fd_alias
    setup_symlinks
    configure_gpg

    if [[ "$FLAG_GIT_TUI" -eq 0 || "$FLAG_WITH_DSH" -eq 0 ]]; then
        printf "\n"
        log_info "Tip: Run with '--with-git-tui' to enable the Lazygit/Hunk stack."
        log_info "     Run with '--with-dsh' to deploy the DeepSeek Harness ecosystem."
    fi

    log_step "Dotfiles Setup Completed Successfully"
    if [[ -n "$BASH_SHELL_GUIDANCE" ]]; then
        log_info "$BASH_SHELL_GUIDANCE"
    else
        log_info "Run 'source ~/.bashrc' or restart your terminal session to apply changes."
    fi
}

cmd_update() {
    log_error "The 'update' command is not implemented yet (planned: Step 8)."
    exit 1
}

cmd_config() {
    log_error "The 'config' command is not implemented yet (planned: Step 6)."
    exit 1
}
