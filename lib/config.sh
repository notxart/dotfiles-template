#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/config.sh — Config reconciliation between ~/.config and this repository
#
# Step 3 implements the read-only half: `config status`. It reports what the
# registry links, what state each record is in, and whether the machine still
# carries damage from the original installer (loop symlinks, orphaned records).
#
# Still to come in Step 6: sync / adopt / ignore / restore, the interactive
# reconciliation table, and the `[l]ocal` two-stage confirmation.
# ==============================================================================

# Counters shared with the status renderer.
CONFIG_STATUS_ISSUES=0

# config_status — read-only. Never creates, moves or removes anything.
config_status() {
    init_xdg_env >/dev/null
    manifest_init

    log_step "Dotfile Link Status"
    local line health dest src mode
    local n_ok=0 n_absent=0 n_stale=0 n_blocked=0
    while IFS=$'\t' read -r src dest mode; do
        [[ -n "$dest" ]] || continue
        n="$(link_resolve "$src" "$dest")"
        src="${n%%$'\t'*}"
        dest="${n##*$'\t'}"
        if [[ "$(link_mode "$dest")" == "ignored" ]]; then
            continue
        fi
        health="$(link_health "$src" "$dest")"
        case "$health" in
            "$LINK_STATE_OK")      n_ok=$((n_ok + 1)) ;;
            "$LINK_STATE_ABSENT")  n_absent=$((n_absent + 1)) ;;
            "$LINK_STATE_STALE")   n_stale=$((n_stale + 1)) ;;
            "$LINK_STATE_BLOCKED") n_blocked=$((n_blocked + 1)) ;;
        esac
        printf '  %-8s %s\n' "$health" "$dest"
    done < <(link_registry)

    log_step "Summary"
    printf '  %-10s %d\n' "ok" "$n_ok"
    printf '  %-10s %d\n' "absent" "$n_absent"
    printf '  %-10s %d\n' "stale" "$n_stale"
    printf '  %-10s %d\n' "blocked" "$n_blocked"
    CONFIG_STATUS_ISSUES=$((n_absent + n_stale + n_blocked))

    # Records whose source vanished from the repository. Reported even when the
    # cause was a flag being turned off: a silently dropped record is how links
    # rot.
    local orphans
    orphans="$(link_find_orphans || true)"
    if [[ -n "$orphans" ]]; then
        log_step "Orphaned Records"
        while IFS=$'\t' read -r dest src reason; do
            [[ -n "$dest" ]] || continue
            printf '  %-18s %s  (source: %s)\n' "$reason" "$dest" "$src"
            CONFIG_STATUS_ISSUES=$((CONFIG_STATUS_ISSUES + 1))
        done <<< "$orphans"
    fi

    # Damage left by the original installer: `ln -sf` follows a symlink to a
    # directory, so running the installer from a second clone injected links
    # such as config/bash/bash -> (other clone)/config/bash.
    local loops
    loops="$(link_find_loops)"
    if [[ -n "$loops" ]]; then
        log_step "Loop Symlinks (damage from the original installer)"
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf '  %s -> %s\n' "$line" "$(readlink "$line")"
            CONFIG_STATUS_ISSUES=$((CONFIG_STATUS_ISSUES + 1))
        done <<< "$loops"
    fi

    log_step "Result"
    if [[ "$CONFIG_STATUS_ISSUES" -eq 0 ]]; then
        log_success "All links healthy; nothing to reconcile."
        return 0
    fi
    log_warn "$CONFIG_STATUS_ISSUES item(s) need attention."
    # $SCRIPT_NAME is the ENTRY POINT (manager.sh). Deriving it from
    # BASH_SOURCE here would name the sourced module instead, telling the user
    # to run a file that is not meant to be executed directly.
    log_info "Run '${SCRIPT_NAME:-manager.sh} config sync' to reconcile them (Step 6)."
    return 2
}

cmd_config() {
    local sub="${1:-status}"
    [[ $# -gt 0 ]] && shift

    case "$sub" in
        status)
            config_status
            ;;
        sync|adopt|ignore|restore)
            log_error "'config $sub' is not implemented yet (planned: Step 6)."
            return 1
            ;;
        *)
            log_error "Unknown config subcommand: $sub"
            log_info "Available: status"
            return 1
            ;;
    esac
}
