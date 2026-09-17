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

    # The repository's OWN tracked git configuration, which is the file most
    # likely to carry a secret by accident: it is synced to every machine the
    # user owns, and `credential.helper = store` or a pasted token would be
    # published the moment this repository is. Checked here rather than in
    # `install` because it is a property of the repository, not of the machine,
    # and this is the command a user runs to ask "is anything wrong?".
    local git_conf leak line kind detail
    for git_conf in "$SCRIPT_DIR"/config/git/*.ini; do
        [[ -f "$git_conf" ]] || continue
        leak="$(scan_credential_leaks "$git_conf" || true)"
        [[ -n "$leak" ]] || continue
        log_step "Credential Risk in the Repository"
        while IFS=$'\t' read -r line kind detail; do
            [[ -n "$kind" ]] || continue
            printf '  %s:%s  %s\n' "${git_conf#"$SCRIPT_DIR"/}" "$line" "$kind"
            printf '      %s\n' "$detail"
            CONFIG_STATUS_ISSUES=$((CONFIG_STATUS_ISSUES + 1))
        done <<< "$leak"
        log_warn "This file is tracked and synced to every machine you own."
        log_info "Use a credential helper that keeps secrets outside the file,"
        log_info "such as: helper = !gh auth git-credential"
    done

    log_step "Result"
    if [[ "$CONFIG_STATUS_ISSUES" -eq 0 ]]; then
        log_success "All links healthy; nothing to reconcile."
        return 0
    fi
    log_warn "$CONFIG_STATUS_ISSUES item(s) need attention."
    # $SCRIPT_NAME is the ENTRY POINT (manager.sh). Deriving it from
    # BASH_SOURCE here would name the sourced module instead, telling the user
    # to run a file that is not meant to be executed directly.
    log_info "Run '${SCRIPT_NAME:-manager.sh} config sync' to see what needs a decision."
    return 2
}

# ==============================================================================
# Reconciliation
#
# The model is three layers, and the split is what keeps each one honest:
#
#   install  seeds    -- creates what is missing, moves nothing, overwrites
#                        nothing. It can run unattended.
#   sync     reconciles -- the ONLY place a file is moved or replaced, because
#                        it is the only place a human is asked.
#   git      decides  -- conflict resolution stays in git (diff, restore,
#                        add), which the user already knows and which keeps a
#                        history of every accepted change.
#
# Everything below prints before it acts, and refuses to act without a terminal.
# ==============================================================================

# config_reconcile_items — the registry records that need a decision, one per
# line as "kind<TAB>src<TAB>dest". Read-only.
#
#   blocked-identical  a real file where a link belongs, byte-identical to the
#                      repository copy: converting it loses nothing
#   blocked-differs    a real file where a link belongs, content differs: the
#                      user must choose
#   missing            nothing there yet
config_reconcile_items() {
    local src dest mode n health
    while IFS=$'\t' read -r src dest mode; do
        [[ -n "$dest" ]] || continue
        [[ "$(link_mode "$dest")" == "ignored" ]] && continue
        # `seed` files are written once and then belong to the user. They are
        # never linked, so there is nothing to reconcile: if the file exists the
        # user owns it, and if it does not, `install` seeds it. Reporting a
        # seeded file as a missing link would offer to replace the user's own
        # work with a link to a template.
        [[ "$mode" == "seed" ]] && continue
        n="$(link_resolve "$src" "$dest")"
        src="${n%%$'\t'*}"
        dest="${n##*$'\t'}"
        health="$(link_health "$src" "$dest")"
        case "$health" in
            "$LINK_STATE_ABSENT")
                printf 'missing\t%s\t%s\n' "$src" "$dest"
                ;;
            "$LINK_STATE_BLOCKED")
                if scan_same_content "$src" "$dest"; then
                    printf 'blocked-identical\t%s\t%s\n' "$src" "$dest"
                else
                    printf 'blocked-differs\t%s\t%s\n' "$src" "$dest"
                fi
                ;;
        esac
    done < <(link_registry)
}

# config_backup <path> — a copy the user can recover from, under XDG state.
# Delegates to backup_path, which keeps one directory per RUN and prunes old
# runs, so a reconciliation touching several files stays recoverable as a unit
# without the backup tree growing without limit.
config_backup() {
    local path="$1" dest
    dest="$(backup_path "$path")" || {
        log_warn "Could not back up ${path#"$HOME"/}."
        return 1
    }
    [[ -n "$dest" ]] || return 0
    backup_prune
    log_info "Backed up: ${path#"$HOME"/} -> ${dest#"$HOME"/}"
    return 0
}

# config_adopt <path> — make a real file part of the repository.
#
# The file moves INTO the repository and a symlink takes its place, which is the
# configuration-side equivalent of a git add: from then on it is tracked,
# editable in either location, and synced to other machines.
config_adopt() {
    local path="$1" rel risk
    if [[ ! -f "$path" || -L "$path" ]]; then
        log_error "Not a real file to adopt: $path"
        return 1
    fi

    # Where it lands mirrors its position under ~/.config.
    case "$path" in
        "$XDG_CONFIG_HOME"/*) rel="config/${path#"$XDG_CONFIG_HOME"/}" ;;
        "$HOME"/*)            rel="${path#"$HOME"/}" ;;
        *) log_error "Cannot adopt a path outside \$HOME: $path"; return 1 ;;
    esac

    risk="$(scan_content_risk "$path")"
    if [[ -n "$risk" ]]; then
        log_warn "This file looks like it carries something private:"
        while IFS=$'\t' read -r kind hit; do
            [[ -n "$kind" ]] || continue
            log_info "  [$kind] $hit"
        done <<< "$risk"
        if ! confirm "Adopt it anyway? It will be committed and pushed." "n"; then
            log_info "Skipped: ${path#"$HOME"/}"
            return 1
        fi
    fi

    mkdir -p "$SCRIPT_DIR/$(dirname "$rel")"
    if [[ -e "$SCRIPT_DIR/$rel" ]]; then
        log_warn "Already exists in the repository: $rel — not overwriting."
        log_info "Compare them first, then remove whichever you do not want:"
        log_info "  diff '$path' '$SCRIPT_DIR/$rel'"
        return 1
    fi

    if ! mv "$path" "$SCRIPT_DIR/$rel"; then
        log_error "Could not move $path into the repository."
        return 1
    fi
    if ! ln -s "$SCRIPT_DIR/$rel" "$path"; then
        # The file is safe in the repository but the link is missing, so put it
        # back rather than leaving a half-finished adoption behind.
        log_error "Could not link $path back; restoring the original file."
        mv "$SCRIPT_DIR/$rel" "$path" 2>/dev/null || \
            log_error "The file is in the repository: $rel"
        return 1
    fi

    # Recorded directly rather than through link_record, so the manifest write
    # cannot depend on a hash that might fail after the file has already moved.
    manifest_set "link" "$rel" "$path" "link" "sha256:$(sha256_file "$SCRIPT_DIR/$rel" 2>/dev/null)"
    log_success "Adopted: ${path#"$HOME"/} -> $rel"
    log_info "Commit it when you are ready: git -C $SCRIPT_DIR add $rel"
}

# config_ignore <path> — record a decision to leave this path alone, so it
# stops being offered. The file is not touched.
config_ignore() {
    local path="$1" rel="-" kind="ignore" mode="ignored"
    # An ignored path that came from the repository keeps its source for context.
    if [[ -L "$path" ]]; then
        local target
        target="$(readlink "$path")"
        [[ "$target" == "$SCRIPT_DIR"/* ]] && rel="${target#"$SCRIPT_DIR"/}" && kind="ignore"
    fi
    manifest_set "$kind" "$rel" "$path" "$mode" "-"
    log_success "Ignored from now on: ${path#"$HOME"/}"
}

# config_restore <path> — put the file back as a real file and forget it.
config_restore() {
    local path="$1" target
    if ! manifest_has "$path"; then
        log_error "No record for: ${path#"$HOME"/}"
        return 1
    fi
    if [[ -L "$path" ]]; then
        target="$(readlink "$path")"
        if [[ "$target" == "$SCRIPT_DIR"/* && -f "$target" ]]; then
            rm -f "$path"
            if ! cp -a "$target" "$path" 2>/dev/null; then
                log_error "Could not restore $path — recreating the link."
                ln -s "$target" "$path" 2>/dev/null || true
                return 1
            fi
            log_success "Restored as a real file: ${path#"$HOME"/}"
            log_info "The repository still has it at ${target#"$SCRIPT_DIR"/};"
            log_info "delete that file if you want it gone for good."
        else
            log_error "Refusing: $path does not point at a file in this repository."
            return 1
        fi
    else
        log_info "Already a real file: ${path#"$HOME"/}"
    fi
    manifest_remove "$path"
}

# ==============================================================================
# config sync — the reconciliation table
# ==============================================================================

config_sync() {
    local dry=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            -y|--yes)  ASSUME_YES=1; shift ;;
            *)         log_warn "Ignoring unrecognized argument: $1"; shift ;;
        esac
    done

    init_xdg_env >/dev/null
    manifest_init

    # ---- 1. read-only scan -------------------------------------------------
    local plan candidates
    plan="$(config_reconcile_items)"
    candidates="$(scan_config_candidates)"

    local n_ident n_differ n_missing n_cand n_ignored
    n_ident="$(printf '%s\n'   "$plan" | grep -c '^blocked-identical' || true)"
    n_differ="$(printf '%s\n'  "$plan" | grep -c '^blocked-differs'   || true)"
    n_missing="$(printf '%s\n' "$plan" | grep -c '^missing'           || true)"
    n_cand="$(printf '%s\n'    "$candidates" | grep -c .              || true)"
    n_ignored="$(manifest_list ignore | grep -c . || true)"

    log_step "Reconciliation"
    log_info "Repository: $SCRIPT_DIR"
    log_info "Config root: $XDG_CONFIG_HOME"
    printf '\n'
    printf '  %-26s %s\n' "identical (safe to link)"  "$n_ident"
    printf '  %-26s %s\n' "conflicting files"        "$n_differ"
    printf '  %-26s %s\n' "missing links"            "$n_missing"
    printf '  %-26s %s\n' "new candidates"           "$n_cand"
    printf '  %-26s %s\n' "previously ignored"       "$n_ignored"

    if [[ "$n_ident" -eq 0 && "$n_differ" -eq 0 && "$n_missing" -eq 0 && "$n_cand" -eq 0 ]]; then
        printf '\n'
        log_success "Nothing to reconcile."
        return 0
    fi

    if [[ "$dry" -eq 1 ]]; then
        printf '\n'
        log_info "Dry run: no changes made."
        config_sync_details "$plan" "$candidates"
        return 0
    fi

    # ---- 2. the decision, taken once, before anything is touched -----------
    printf '\n'
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
        # --yes is the scripted path. It applies ONLY the changes that cannot
        # lose data (linking an identical copy, creating a missing link);
        # anything that needs a judgement call is still left for a human, so
        # this flag can never overwrite a file the user edited.
        log_info "Applying the safe changes (--yes); conflicts are still left alone."
    elif ! is_tty; then
        # Fail CLOSED. Without a terminal there is nobody to ask, and every
        # action below moves or replaces a file, so the safe answer is to do
        # nothing and say exactly how to proceed by hand.
        log_warn "No terminal: nothing was changed."
        log_info "Run this in an interactive shell, or apply individual decisions:"
        log_info "  ${SCRIPT_NAME:-manager.sh} config adopt <path>"
        log_info "  ${SCRIPT_NAME:-manager.sh} config ignore <path>"
        config_sync_details "$plan" "$candidates"
        return 2
    else
        log_info "[a] apply the safe changes (link identical files, create missing links)"
        log_info "[d] show details first"
        log_info "[q] quit without changing anything"
        local answer
        printf '  Choose [a/d/q]: ' >&2
        read -r answer || answer="q"
        case "$answer" in
            d|D) config_sync_details "$plan" "$candidates"
                 printf '\n'
                 printf '  Apply the safe changes now? [y/N]: ' >&2
                 read -r answer || answer="n"
                 [[ "$answer" == [yY]* ]] || { log_info "Nothing changed."; return 0; }
                 ;;
            a|A) ;;
            *)   log_info "Nothing changed."; return 0 ;;
        esac
    fi

    # ---- 3. act ------------------------------------------------------------
    local kind src dest
    # One backup directory for the whole run, so everything this command
    # replaces can be restored together.
    backup_begin
    while IFS=$'\t' read -r kind src dest; do
        [[ -n "$kind" ]] || continue
        case "$kind" in
            blocked-identical)
                # The repository copy is byte-identical, so replacing the file
                # with a link loses nothing. Backed up anyway: "identical" is
                # this scan's conclusion, and a backup costs nothing.
                config_backup "$dest"
                rm -f "$dest"
                local rc=0
                link_apply "$src" "$dest" "link" >/dev/null 2>&1 || rc=$?
                [[ "$rc" == "$LINK_CREATED" ]] \
                    && log_success "Linked (was an identical copy): ${dest#"$HOME"/}" \
                    || log_warn "Could not link: ${dest#"$HOME"/}"
                ;;
            missing)
                local rc2=0
                link_apply "$src" "$dest" "$(link_mode "$dest")" >/dev/null 2>&1 || rc2=$?
                [[ "$rc2" == "$LINK_CREATED" ]] \
                    && log_success "Created: ${dest#"$HOME"/}" \
                    || true
                ;;
            blocked-differs)
                log_warn "Left for you: ${dest#"$HOME"/} (content differs)"
                log_info "  compare: ${SCRIPT_NAME:-manager.sh} config sync --dry-run"
                log_info "  keep the file:  ${SCRIPT_NAME:-manager.sh} config ignore '${dest}'"
                log_info "  keep the repo:  rm '${dest}' && ${SCRIPT_NAME:-manager.sh} install"
                ;;
        esac
    done <<< "$plan"

    printf '\n'
    log_success "Reconciliation complete."
    [[ "$n_differ" -gt 0 ]] && log_warn "$n_differ conflicting file(s) still need your decision."
    [[ "$n_cand" -gt 0 ]] && log_info "$n_cand candidate(s) were not touched — adopt them with 'config adopt'."
    return 0
}

# config_sync_details <plan> <candidates> — the full picture, read-only.
config_sync_details() {
    local plan="$1" candidates="$2" kind src dest

    if [[ -n "$plan" ]]; then
        printf '\n'
        log_step "Registry Paths Needing Attention"
        while IFS=$'\t' read -r kind src dest; do
            [[ -n "$kind" ]] || continue
            case "$kind" in
                blocked-identical) log_info "identical  ${dest#"$HOME"/}" ;;
                blocked-differs)
                    log_warn "CONFLICT   ${dest#"$HOME"/}"
                    scan_show_diff "$src" "$dest" 40
                    ;;
                missing)           log_info "missing    ${dest#"$HOME"/}" ;;
            esac
        done <<< "$plan"
    fi

    if [[ -n "$candidates" ]]; then
        printf '\n'
        log_step "Candidates Under $XDG_CONFIG_HOME"
        log_info "These are not managed by the repository. Adopting copies them in;"
        log_info "ignoring records the decision so they stop being listed."
        local path class size risk
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            class="$(scan_classify "$path")"
            size="$(scan_size_note "$path")"
            printf '  %-16s %-6s %s\n' "$class" "$size" "${path#"$HOME"/}"
            risk="$(scan_content_risk "$path")"
            if [[ -n "$risk" ]]; then
                while IFS=$'\t' read -r rkind hit; do
                    [[ -n "$rkind" ]] || continue
                    printf '      [%s] %s\n' "$rkind" "$hit"
                done <<< "$risk"
            fi
        done <<< "$candidates"
    fi
}

cmd_config() {
    local sub="${1:-status}"
    [[ $# -gt 0 ]] && shift

    case "$sub" in
        status)  config_status ;;
        sync)    config_sync "$@" ;;
        adopt)
            [[ $# -gt 0 ]] || { log_error "Usage: config adopt <path>..."; return 1; }
            init_xdg_env >/dev/null; manifest_init
            local p rc=0
            for p in "$@"; do config_adopt "$p" || rc=1; done
            return "$rc"
            ;;
        ignore)
            [[ $# -gt 0 ]] || { log_error "Usage: config ignore <path>..."; return 1; }
            init_xdg_env >/dev/null; manifest_init
            local i
            for i in "$@"; do config_ignore "$i"; done
            return 0
            ;;
        restore)
            [[ $# -gt 0 ]] || { log_error "Usage: config restore <path>"; return 1; }
            init_xdg_env >/dev/null; manifest_init
            local r rc=0
            for r in "$@"; do config_restore "$r" || rc=1; done
            return "$rc"
            ;;
        *)
            log_error "Unknown config subcommand: $sub"
            log_info "Available: status, sync, adopt, ignore, restore"
            return 1
            ;;
    esac
}
