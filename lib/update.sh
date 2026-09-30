#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/update.sh — Bring the toolchain this machine opted into up to date
#
# Runs each tool's own updater once and reports what changed. It never links or
# installs, never shadows a distribution package, and never asks for a password.
# ==============================================================================

# Update State
UPDATE_ROWS=()          # "<tool>\t<before>\t<after>\t<status>", for the report
UPDATE_ONLY=()          # non-empty = act only on these tools
UPDATE_DRY_RUN=0
UPDATE_FAILED=0
UPDATE_PM_READY=0
UPDATE_PM_REFRESHED=0

# Cached answers to capability probes. Each one costs a process, and the plan,
# the command list and the run all ask the same question about the same tool.
UPDATE_HUNK_SELF=""

# The resolution of the tool currently being handled. Set by update_resolve,
# read by update_one and update_plan. A subshell would lose it, which is why
# this is state rather than a printed value.
UPDATE_MECH_KIND=""
UPDATE_MECH_DESC=""
UPDATE_MECH_CMD=()
UPDATE_MECH_FALLBACK=""

# tool | distribution package | self-update command | fallback installer
#
# One row per tool, in the order update touches them; an empty field means the
# mechanism does not exist. A self-updater paired with a fallback is not redundant:
# `pnpm self-update` moves a working pnpm but cannot repair a broken one.
readonly -a UPDATE_TABLE=(
    "pnpm||pnpm self-update|install_pnpm_standalone"
    "node||pnpm runtime set node lts -g|"
    "fzf|fzf||install_fzf_fallback"
    "starship|starship||install_starship_fallback"
    "hunk|hunk|hunk update|install_hunk_fallback"
    "lazygit|lazygit||install_lazygit_fallback"
    "dsh||pnpm add -g @deepseek-ai/dsh@latest|install_dsh"
)

# --- Argument Handling --------------------------------------------------------

update_known_tools() {
    local row
    for row in "${UPDATE_TABLE[@]}"; do
        printf '%s ' "${row%%|*}"
    done
    printf '\n'
}

update_is_known_tool() {
    local row
    for row in "${UPDATE_TABLE[@]}"; do
        [[ "${row%%|*}" == "$1" ]] && return 0
    done
    return 1
}

update_parse_args() {
    local list tool
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                UPDATE_DRY_RUN=1
                shift
                ;;
            --only)
                if [[ $# -lt 2 ]]; then
                    log_error "--only needs a tool name."
                    log_info "Available: $(update_known_tools)"
                    return 1
                fi
                list="${2//,/ }"
                for tool in $list; do
                    if ! update_is_known_tool "$tool"; then
                        log_error "Unknown tool: $tool"
                        log_info "Available: $(update_known_tools)"
                        return 1
                    fi
                    UPDATE_ONLY+=("$tool")
                done
                shift 2
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_warn "Ignoring unrecognized argument: $1"
                shift
                ;;
        esac
    done
    return 0
}

# --- Tool Selection -----------------------------------------------------------

# update_selected_tools — the tools this machine asked for, mirroring what install
# provisions rather than what happens to be present: a hunk installed by hand is
# left alone unless it is named with --only.
update_selected_tools() {
    # An explicit --only answers outright, including for a tool this machine never
    # opted into: that is how something installed by hand gets updated.
    if [[ "${#UPDATE_ONLY[@]}" -gt 0 ]]; then
        printf '%s\n' "${UPDATE_ONLY[@]}"
        return 0
    fi
    printf '%s\n' pnpm
    if [[ "${FLAG_GIT_TUI:-0}" -eq 1 || "${FLAG_WITH_DSH:-0}" -eq 1 ]]; then
        printf '%s\n' node
    fi
    printf '%s\n' fzf starship
    if [[ "${FLAG_GIT_TUI:-0}" -eq 1 ]]; then
        printf '%s\n' hunk lazygit
    fi
    if [[ "${FLAG_WITH_DSH:-0}" -eq 1 ]]; then
        printf '%s\n' dsh
    fi
    return 0
}

# --- Resolution ---------------------------------------------------------------

update_version() {
    local version
    version="$(get_installed_version "$1" 2>/dev/null || true)"
    printf '%s\n' "$version"
}

# update_is_system_owned <cmd> — true when the command the shell would run belongs
# to the distribution rather than to this user. $HOME alone is not the test: a
# machine that moved its XDG directories still owns PNPM_HOME and XDG_DATA_HOME.
update_is_system_owned() {
    local path
    path="$(command -v "$1" 2>/dev/null || true)"
    [[ -n "$path" ]] || return 1
    case "$path" in
        "$HOME"/*) return 1 ;;
        "${PNPM_HOME:-$HOME/.local/share/pnpm}"/*) return 1 ;;
        "${XDG_DATA_HOME:-$HOME/.local/share}"/*) return 1 ;;
    esac
    return 0
}

update_is_pnpm_managed() {
    local path
    path="$(command -v "$1" 2>/dev/null || true)"
    [[ -n "$path" && ( "$path" == "${PNPM_HOME:-$HOME/.local/share/pnpm}"/* ) ]]
}

# update_hunk_is_standalone — true when hunk came from this repository's standalone
# installer. That installer points ~/.local/bin/hunk at $XDG_DATA_HOME/hunk, so the
# command the shell finds is the SYMLINK: the comparison has to follow it.
update_hunk_is_standalone() {
    local path resolved
    path="$(command -v "$1" 2>/dev/null || true)"
    [[ -n "$path" ]] || return 1
    resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    [[ "$resolved" == "${XDG_DATA_HOME:-$HOME/.local/share}/hunk/bin/"* ]]
}

# update_self_applicable <tool> — whether the tool's own updater applies here. node
# counts only when pnpm manages it, hunk only from 0.20 and not as a standalone
# install, whose location `hunk update` will not touch. The answer is cached.
update_self_applicable() {
    case "$1" in
        node) update_is_pnpm_managed node ;;
        hunk)
            command_exists hunk || return 1
            update_hunk_is_standalone hunk && return 1
            if [[ -z "${UPDATE_HUNK_SELF:-}" ]]; then
                if hunk update --help >/dev/null 2>&1; then
                    UPDATE_HUNK_SELF=1
                else
                    UPDATE_HUNK_SELF=0
                fi
            fi
            [[ "$UPDATE_HUNK_SELF" -eq 1 ]]
            ;;
        dsh)  command_exists pnpm ;;
        *)    return 0 ;;
    esac
}

# update_pm_state — package-manager state without prompting: which manager this is,
# and whether packages can be installed without asking.
update_pm_state() {
    [[ "$UPDATE_PM_READY" -eq 1 ]] && return 0
    UPDATE_PM_READY=1
    detect_environment >/dev/null 2>&1 || true
    acquire_privileges --non-interactive >/dev/null 2>&1 || true
    return 0
}

update_pm_can_install() {
    update_pm_state
    [[ "${PM_PRIVILEGED:-0}" -eq 1 \
        && "${PM_STRATEGY:-none}" != "none" \
        && "${#PM_INSTALL_CMD[@]}" -gt 0 ]]
}

# update_pm_refresh_once — refresh the package index once per run, and only when
# a package-manager update is actually about to happen.
update_pm_refresh_once() {
    [[ "$UPDATE_MECH_KIND" == "pm" ]] || return 0
    [[ "$UPDATE_PM_REFRESHED" -eq 1 ]] && return 0
    UPDATE_PM_REFRESHED=1
    "${PM_UPDATE_CMD[@]}" || log_warn "Package index refresh failed; using the cached index."
    return 0
}

# update_resolve <tool> — how this tool would be updated: its own updater first (it
# knows how it was installed), then the distribution's package manager when it owns
# the file and elevation is available, then this repository's installer for anything
# under $HOME. update_one reaches the fallback only when the first attempt fails.
update_resolve() {
    local tool="$1" row candidate pkg self fallback

    UPDATE_MECH_KIND=""
    UPDATE_MECH_DESC=""
    UPDATE_MECH_CMD=()
    UPDATE_MECH_FALLBACK=""

    row=""
    for candidate in "${UPDATE_TABLE[@]}"; do
        if [[ "${candidate%%|*}" == "$tool" ]]; then
            row="$candidate"
            break
        fi
    done
    if [[ -z "$row" ]]; then
        UPDATE_MECH_KIND="manual"
        UPDATE_MECH_DESC="not a known tool"
        return 1
    fi

    IFS='|' read -r _ pkg self fallback <<< "$row"
    UPDATE_MECH_FALLBACK="$fallback"

    if ! command_exists "$tool"; then
        UPDATE_MECH_KIND="missing"
        UPDATE_MECH_DESC="not installed (run install)"
        return 0
    fi

    if [[ -n "$self" ]] && update_self_applicable "$tool"; then
        UPDATE_MECH_KIND="self"
        read -r -a UPDATE_MECH_CMD <<< "$self"
        UPDATE_MECH_DESC="$self"
        return 0
    fi

    if update_is_system_owned "$tool"; then
        if [[ -n "$pkg" ]] && update_pm_can_install; then
            UPDATE_MECH_KIND="pm"
            UPDATE_MECH_CMD=("${PM_INSTALL_CMD[@]}" "$pkg")
            UPDATE_MECH_DESC="${PM_INSTALL_CMD[*]} $pkg"
        else
            UPDATE_MECH_KIND="manual"
            UPDATE_MECH_DESC="held by the system; needs sudo to upgrade"
        fi
        return 0
    fi

    if [[ -n "$fallback" ]]; then
        UPDATE_MECH_KIND="fallback"
        UPDATE_MECH_CMD=("$fallback")
        UPDATE_MECH_DESC="$fallback"
        return 0
    fi

    UPDATE_MECH_KIND="manual"
    UPDATE_MECH_DESC="no updater available; re-run install"
    return 0
}

# --- Acting -------------------------------------------------------------------

update_record() {
    # Fields are '|'-separated, not tab: a tab is IFS *whitespace*, so `read`
    # collapses runs and strips leading ones, and a row with an empty field would
    # lose that column and shift every value after it one place left.
    UPDATE_ROWS+=("$(printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4")")
}

update_one() {
    local tool="$1" before after status="current" rc=0

    update_resolve "$tool" || true
    before="$(update_version "$tool")"

    case "$UPDATE_MECH_KIND" in
        missing)
            update_record "$tool" "" "" "not installed"
            return 0
            ;;
        manual)
            log_warn "$tool: $UPDATE_MECH_DESC"
            update_record "$tool" "$before" "$before" "skipped"
            return 0
            ;;
    esac

    log_info "$tool: $UPDATE_MECH_DESC"

    case "$UPDATE_MECH_KIND" in
        self|pm)
            update_pm_refresh_once
            "${UPDATE_MECH_CMD[@]}" || rc=$?
            ;;
        fallback)
            # The installers are written to abort an INSTALL (they call exit 1), not
            # to return a status. A subshell turns that abort into a value this loop
            # can report and survive, so one failing tool does not take the rest down.
            ( "${UPDATE_MECH_CMD[@]}" ) || rc=$?
            ;;
    esac

    # A tool that carries both mechanisms gets one second chance: `pnpm self-update`
    # moves a working pnpm but cannot repair a broken one, and the installer that put
    # it there can. Without this, a failure hides a fix one column away in the table.
    if [[ "$rc" -ne 0 && -n "$UPDATE_MECH_FALLBACK" && "$UPDATE_MECH_KIND" != "fallback" ]]; then
        log_warn "$tool: ${UPDATE_MECH_DESC%% *} failed; retrying with $UPDATE_MECH_FALLBACK."
        rc=0
        ( "$UPDATE_MECH_FALLBACK" ) || rc=$?
    fi

    after="$(update_version "$tool")"

    if [[ "$rc" -ne 0 ]]; then
        status="failed"
        UPDATE_FAILED=$((UPDATE_FAILED + 1))
        log_warn "$tool: update command failed (exit $rc)."
    elif [[ -z "$before" ]]; then
        # The command ran, but this tool reports its version in a shape that could
        # not be read, so "current" would assert more than the run can support.
        status="ran"
    elif [[ "$after" == "$before" ]]; then
        status="current"
    else
        status="updated"
    fi

    update_record "$tool" "$before" "$after" "$status"
    return 0
}

# --- Reporting ----------------------------------------------------------------

update_plan() {
    local tool before
    printf '\n'
    printf '  %-10s %-14s %s\n' "TOOL" "INSTALLED" "UPDATE"
    for tool in $(update_selected_tools); do
        update_resolve "$tool" || true
        before="$(update_version "$tool")"
        printf '  %-10s %-14s %s\n' "$tool" "${before:--}" "$UPDATE_MECH_DESC"
    done
}

# update_commands — the same plan as commands the user can run by hand. Printed
# whenever nothing was changed, so a refusal is always actionable.
update_commands() {
    local tool
    for tool in $(update_selected_tools); do
        update_resolve "$tool" || true
        case "$UPDATE_MECH_KIND" in
            missing) printf '  install  %s\n' "$tool" ;;
            manual)  printf '  (manual) %s: %s\n' "$tool" "$UPDATE_MECH_DESC" ;;
            *)       printf '  %s\n' "$UPDATE_MECH_DESC" ;;
        esac
    done
}

update_report() {
    local row tool before after status colour
    printf '\n'
    log_step "Update Report"
    for row in "${UPDATE_ROWS[@]}"; do
        IFS='|' read -r tool before after status <<< "$row"
        case "$status" in
            updated) colour="$CLR_GREEN" ;;
            failed)  colour="$CLR_RED" ;;
            skipped|"not installed") colour="$CLR_YELLOW" ;;
            *)       colour="$CLR_MUTED" ;;
        esac
        printf "  %-10s %-14s %-14s ${colour}%s${CLR_RESET}\n" \
            "$tool" "${before:--}" "${after:--}" "$status"
    done
}

# update_run — the command. Plan first, decide once, then act.
update_run() {
    log_step "Toolchain Update"

    update_parse_args "$@" || return 1
    init_xdg_env >/dev/null
    manifest_init

    # Which tools this machine opted into comes from the manifest, not from the
    # command line: `update` re-applies a decision that was already made.
    resolve_feature_flags

    update_plan

    if [[ "$UPDATE_DRY_RUN" -eq 1 ]]; then
        printf '\n'
        log_info "Dry run: nothing was changed."
        return 0
    fi

    # Fail-closed like config sync: with no terminal there is nobody to confirm
    # with, so change nothing and print the commands instead.
    if [[ "${ASSUME_YES:-0}" -ne 1 ]] && ! is_tty; then
        printf '\n'
        log_warn "No terminal: nothing was changed."
        log_info "Run this in an interactive shell, pass --yes, or run these by hand:"
        update_commands
        return 2
    fi

    if [[ "${ASSUME_YES:-0}" -ne 1 ]]; then
        printf '\n'
        if ! confirm "Update these tools now?" "n"; then
            log_info "Nothing changed."
            return 0
        fi
    fi

    local tool
    for tool in $(update_selected_tools); do
        update_one "$tool"
    done

    update_report
    printf '\n'
    if [[ "$UPDATE_FAILED" -gt 0 ]]; then
        log_warn "$UPDATE_FAILED tool(s) could not be updated."
        return 1
    fi
    log_success "Toolchain is up to date."
    log_info "Versions only: this command did not touch git or your configuration."
    return 0
}
