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

# set_feature_flag <git_tui|dsh> — record that the user asked for this
# explicitly. The SET marker is what lets resolve_feature_flags tell "the user
# chose this now" apart from "nothing was said, keep what the machine had".
set_feature_flag() {
    case "$1" in
        git_tui) FLAG_GIT_TUI="$2"; FLAG_GIT_TUI_SET=1 ;;
        dsh)     FLAG_WITH_DSH="$2"; FLAG_WITH_DSH_SET=1 ;;
        *)       log_error "Unknown feature flag: $1"; return 1 ;;
    esac
}

# resolve_feature_flags — decide the effective flags.
#
# Precedence, highest first:
#   1. an explicit command-line flag (already applied, marker set)
#   2. an exported override (lets tests and users force a value)
#   3. what this machine recorded in the manifest on its last install
#   4. the compiled-in default, off
#
# Step 3 uses this only for the registry, but the same resolution is what lets
# `update` re-apply the toolchain this machine actually chose, without the user
# re-typing --with-git-tui every time.
resolve_feature_flags() {
    if [[ "${FLAG_GIT_TUI_SET:-0}" -eq 0 && "${FLAG_GIT_TUI_ENV:-0}" -eq 0 ]]; then
        FLAG_GIT_TUI="$(manifest_flag_get git_tui)"
        [[ -n "$FLAG_GIT_TUI" ]] || FLAG_GIT_TUI=0
    fi
    if [[ "${FLAG_WITH_DSH_SET:-0}" -eq 0 && "${FLAG_WITH_DSH_ENV:-0}" -eq 0 ]]; then
        FLAG_WITH_DSH="$(manifest_flag_get dsh)"
        [[ -n "$FLAG_WITH_DSH" ]] || FLAG_WITH_DSH=0
    fi
    export FLAG_GIT_TUI FLAG_WITH_DSH
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-git-tui)
                set_feature_flag git_tui 1
                log_info "Option enabled: Git TUI Review Stack"
                shift
                ;;
            --with-dsh)
                set_feature_flag dsh 1
                log_info "Option enabled: DeepSeek Harness"
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
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
    xdg_assert_consistency --strict || return 1

    # The manifest is authoritative for what this machine already opted into;
    # an explicit command-line flag overrides it.
    manifest_init
    resolve_feature_flags
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

    # Convert legacy directory-level links BEFORE linking. With the file-level
    # registry, every path underneath such a link resolves to a regular file
    # and is therefore reported as blocked; the migration is what makes those
    # paths linkable. It runs before link_setup so the same run can finish the
    # job, and it is a no-op on a machine that never had directory links.
    if migrate_needed; then
        migrate_print_plan
        if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
            migrate_execute || return 1
        elif is_tty && confirm "Convert these directory links now?" "y"; then
            migrate_execute || return 1
        else
            log_warn "Skipped. Links stay blocked until you re-run and accept the conversion."
        fi
    fi

    link_setup
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
    return 1
}
