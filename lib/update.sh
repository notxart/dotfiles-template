#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/update.sh — Bring the toolchain this machine opted into up to date
#
# `install` provisions a toolchain and `config sync` reconciles configuration;
# neither answers "my tools are old". This module does the third thing: it runs
# each tool's own update mechanism, once, for the whole toolchain, and reports
# what changed.
#
# What it deliberately does NOT do:
#   * it never links, migrates, adopts or reconciles. An update changes
#     versions, not the relationship between this machine and the repository.
#   * it never installs a tool that is absent. That is install's job: a missing
#     tool needs a decision (--with-git-tui, --with-dsh), not an upgrade.
#   * it never shadows a distribution package. When the running binary lives
#     outside $HOME, the distribution owns that path, and dropping a second copy
#     into ~/.local/bin would decide which one wins by PATH order. Without
#     elevation that is reported, not worked around.
#   * it never asks for a password. install may, because the user just asked for
#     an install; update runs several tools in a row, so a password prompt would
#     arrive with no context. System-owned tools are updated only when
#     elevation is already available (see update_pm_state).
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
UPDATE_MECH_PKG=""
UPDATE_MECH_FALLBACK=""

# tool | distribution package | self-update command | fallback installer
#
# One row per tool, in the order update touches them: pnpm comes first because
# hunk and dsh are installed through it. An empty field means that mechanism
# does not exist for that tool.
#
# A row may carry both a self-updater and a fallback. That pairing is not
# redundant: `pnpm self-update` is the right way to move pnpm and cannot repair
# a broken one, so a failure falls through to the installer that put it there.
#
# The distribution package column is empty for node: the name differs across
# distributions (nodejs, node) and install provisions node through pnpm, so a
# system-owned node is reported rather than upgraded under a guessed name.
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

# update_selected_tools — the tools this machine asked for.
#
# It mirrors what install provisions, not what happens to be on the machine:
# the manifest flags decide. A hunk the user installed by hand is therefore not
# touched unless they ask for it by name with --only.
update_selected_tools() {
    # An explicit --only answers the question outright, including for a tool
    # this machine never opted into. That is the point of naming one: it is how
    # a tool installed by hand gets brought up to date.
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

# update_is_system_owned <cmd> — true when the command the shell would run is
# owned by the distribution rather than by this user.
#
# $HOME alone is not the test. PNPM_HOME and XDG_DATA_HOME are user-owned
# locations wherever they happen to point, and pnpm puts its global binaries in
# the first of them; calling those "the system's" would refuse to update the
# tools this repository installed on a machine that moved its XDG directories.
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

# update_hunk_is_standalone — true when hunk came from this repository's
# standalone installer rather than from a package manager.
#
# That installer places hunk under $XDG_DATA_HOME/hunk and points
# ~/.local/bin/hunk at it, so the command the shell finds is the SYMLINK, not
# the file. The comparison therefore has to follow it: testing the link's own
# path would classify every real standalone install as a package-manager one,
# and `hunk update` does not recognise a location it did not create.
update_hunk_is_standalone() {
    local path resolved
    path="$(command -v "$1" 2>/dev/null || true)"
    [[ -n "$path" ]] || return 1
    resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    [[ "$resolved" == "${XDG_DATA_HOME:-$HOME/.local/share}/hunk/bin/"* ]]
}

# update_self_applicable <tool> — whether the tool's own updater applies here.
#
# Three tools cannot answer that from the table alone. node is provisioned by
# pnpm only when pnpm manages it; upgrading a distribution's node through pnpm
# would create a second runtime that quietly takes precedence. hunk gained its
# own updater in 0.20, so an older hunk is asked rather than assumed — and a
# standalone hunk is excluded even when it is new enough, because its location
# is one `hunk update` will not touch. The answer is cached: the plan, the
# command list and the run all resolve the same tool.
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

# update_pm_state — establish package-manager state WITHOUT prompting.
#
# Both halves live in lib/packages.sh: detection answers which package manager
# this is, and acquire_privileges --non-interactive answers whether packages can
# be installed without asking. That flag is the whole point: `update` runs a
# whole toolchain in a row, so a password prompt arriving in the middle of it
# would have no context.
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

# update_resolve <tool> — decide how this tool would be updated.
#
# Order, and the reason for it:
#   1. the tool's own updater, when it has one. It knows how it was installed
#      (npm, brew, curl), which nothing outside the tool can know reliably.
#   2. the distribution's package manager, when the distribution owns the file
#      and elevation is already available.
#   3. this repository's installer, for everything installed under $HOME.
#
# A tool may also carry a fallback alongside a self-updater, which update_one
# reaches for only when the first attempt fails.
update_resolve() {
    local tool="$1" row candidate pkg self fallback

    UPDATE_MECH_KIND=""
    UPDATE_MECH_DESC=""
    UPDATE_MECH_CMD=()
    UPDATE_MECH_PKG=""
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
    UPDATE_MECH_PKG="$pkg"
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
    # Fields are separated by '|', not a tab, and that is not cosmetic: a tab is
    # an IFS *whitespace* character, so `read` collapses runs of them and strips
    # leading ones. A row with an empty field — a tool whose version could not be
    # read, or one that is not installed — would lose that column and shift every
    # value after it one place to the left.
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
            # The installers are written to abort an INSTALL (they call exit 1),
            # not to return a status. A subshell turns that abort into a value
            # this loop can report and survive, so one failing tool does not
            # take the rest of the toolchain down with it.
            ( "${UPDATE_MECH_CMD[@]}" ) || rc=$?
            ;;
    esac

    # A tool that carries both mechanisms gets one second chance. `pnpm
    # self-update` is the right way to move a working pnpm and cannot repair a
    # broken one; the installer that put it there can. Without this, a failed
    # self-update is reported as a tool that could not be updated when a way to
    # update it was sitting one column away in the table.
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
        # The command ran but this tool reports its version in a shape that
        # could not be read, so "current" would be an assertion the run cannot
        # support. Say only what happened.
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

    # Same fail-closed rule as config sync: without a terminal there is nobody
    # to confirm with, so the safe answer is to change nothing and print the
    # commands instead.
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
