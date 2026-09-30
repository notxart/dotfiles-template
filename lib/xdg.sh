#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/xdg.sh — XDG initialization, manifest, and cross-layer value validation
#
# Scope: this module prepares paths for the manager's OWN process and reads the rc.d
# files as text — it never sources them. The manifest records what dotfiles owns.
# ==============================================================================

# Vars both layers define; a divergence installs files where the shell never looks.
readonly MANAGER_SHARED_VARS=(
    XDG_CONFIG_HOME
    XDG_DATA_HOME
    XDG_STATE_HOME
    XDG_CACHE_HOME
    PNPM_HOME
    DSH_HOME
    GNUPGHOME
    GIT_CONFIG_GLOBAL
)

init_xdg_env() {
    log_step "Initializing XDG Environment & Paths"

    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
    export PNPM_HOME="${PNPM_HOME:-$XDG_DATA_HOME/pnpm}"
    export DSH_HOME="${DSH_HOME:-$XDG_DATA_HOME/dsh}"
    export GNUPGHOME="${GNUPGHOME:-$XDG_DATA_HOME/gnupg}"
    export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$XDG_CONFIG_HOME/git/config.ini}"

    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$HOME/.local/bin" "$PNPM_HOME"

    # Inject paths into the current execution subshell immediately
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    if [[ ":$PATH:" != *":$PNPM_HOME/bin:"* && -d "$PNPM_HOME/bin" ]]; then
        export PATH="$PNPM_HOME/bin:$PATH"
    fi

    log_success "XDG Base Directories and Execution Paths prepared."
}

# ==============================================================================
# State Directory & Manifest
# ==============================================================================

state_dir() {
    printf '%s\n' "$XDG_STATE_HOME/dotfiles"
}

manifest_path() {
    printf '%s\n' "$(state_dir)/manifest.tsv"
}

# Backups live outside $HOME by design: the whole point of this repository is
# to keep the home directory clean (see README).
backup_root() {
    printf '%s\n' "$(state_dir)/backups"
}

# How many past runs to keep: every operation that can replace a file backs it up
# first, and without a limit those copies accumulate forever.
readonly BACKUP_KEEP=10

# backup_dir_current — this run's backup directory, created on first call. It must
# run before backup_path: callers capture backup_path's output with $( ), which runs
# in a subshell, so a variable assigned there would never reach the next call.
backup_dir_current() {
    if [[ -z "${BACKUP_RUN_DIR:-}" ]]; then
        BACKUP_RUN_DIR="$(backup_root)/$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$BACKUP_RUN_DIR" || return 1
    printf '%s\n' "$BACKUP_RUN_DIR"
}

# backup_begin — start a backup run. Only the first call creates the directory, so
# every file one command touches is recoverable under a single timestamp.
backup_begin() {
    backup_dir_current >/dev/null
    return 0
}

# backup_path <path> — copy <path> into this run's backup directory and print
# the copy's location. Requires backup_begin (or backup_dir_current) to have run.
backup_path() {
    local path="$1" dest dir
    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ -z "${BACKUP_RUN_DIR:-}" ]]; then
        # Convenience for a standalone caller: derive the directory without
        # relying on it surviving this function's own command substitution.
        dir="$(backup_dir_current)" || return 1
    else
        dir="$BACKUP_RUN_DIR"
        mkdir -p "$dir" || return 1
    fi

    # Mirrors the home layout rather than flattening it:
    #   ~/.config/git/hooks/commit-msg -> <run>/.config/git/hooks/commit-msg
    # Same basenames cannot collide, and restoring is `cp -a <run>/.config ~/`.
    local rel
    case "$path" in
        "$HOME"/*) rel="${path#"$HOME"/}" ;;
        *)         rel="${path#/}" ;;
    esac
    dest="$dir/$rel"
    mkdir -p "$(dirname "$dest")" || return 1

    # A symlink is copied THROUGH, not as a link: `cp -a` would preserve it, so the
    # "backup" would still point at the live file it was meant to protect — useless
    # the moment that file is replaced, which is when a backup matters.
    if [[ -L "$path" ]]; then
        cp -L --preserve=mode,timestamps "$path" "$dest" 2>/dev/null || \
            cp -L "$path" "$dest" 2>/dev/null || return 1
    else
        cp -a "$path" "$dest" 2>/dev/null || return 1
    fi
    printf '%s\n' "$dest"
}

# backup_prune — keep only the newest BACKUP_KEEP run directories.
# Called after a backup, so the limit holds without a separate cron-like task.
backup_prune() {
    local root
    root="$(backup_root)"
    [[ -d "$root" ]] || return 0
    # Directory names are timestamps, so reverse lexical order is newest first.
    local -a runs=()
    while IFS= read -r d; do
        [[ -n "$d" ]] && runs+=("$d")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

    local i
    for (( i = BACKUP_KEEP; i < ${#runs[@]}; i++ )); do
        rm -rf "${runs[i]}" 2>/dev/null || true
    done
    return 0
}

manifest_init() {
    local mf
    mf="$(manifest_path)"
    mkdir -p "$(dirname "$mf")"
    if [[ ! -f "$mf" ]]; then
        printf 'version\t2\n' > "$mf"
        return 0
    fi
    # Records written before the format was versioned carry no header. Adding
    # one is purely additive: both shapes have the same columns.
    if ! grep -q '^version	' "$mf"; then
        local tmp="$mf.tmp.$$"
        { printf 'version\t2\n'; cat "$mf"; } > "$tmp" && mv "$tmp" "$mf"
    fi
}

# manifest_set <kind> <src> <dest> <mode> [hash]
# Replaces any existing record for <dest> and appends the new one, so repeated
# calls are idempotent and never accumulate duplicates.
manifest_set() {
    local kind="$1" src="$2" dest="$3" mode="$4" hash="${5:--}"
    local mf tmp
    mf="$(manifest_path)"
    manifest_init
    tmp="$mf.tmp.$$"

    awk -F'\t' -v OFS='\t' -v dest="$dest" -v k="$kind" -v s="$src" -v m="$mode" -v h="$hash" '
        $1 == "version" { print; next }
        NF >= 5 && $3 == dest { next }
        { print }
        END { print k, s, dest, m, h }
    ' "$mf" > "$tmp" && mv "$tmp" "$mf"
}

manifest_has() {
    local dest="$1" mf
    mf="$(manifest_path)"
    [[ -f "$mf" ]] || return 1
    grep -qF "	$dest	" "$mf"
}

manifest_get() {
    local dest="$1" mf
    mf="$(manifest_path)"
    [[ -f "$mf" ]] && grep -F "	$dest	" "$mf"
}

manifest_remove() {
    local dest="$1" mf tmp
    mf="$(manifest_path)"
    [[ -f "$mf" ]] || return 0
    tmp="$mf.tmp.$$"
    awk -F'\t' -v OFS='\t' -v dest="$dest" '!($3 == dest)' "$mf" > "$tmp" && mv "$tmp" "$mf"
}

# manifest_list [kind] — records only, header and flags excluded.
manifest_list() {
    local kind="${1:-}" mf
    mf="$(manifest_path)"
    [[ -f "$mf" ]] || return 0
    if [[ -n "$kind" ]]; then
        awk -F'\t' -v OFS='\t' -v k="$kind" '$1 == k' "$mf"
    else
        awk -F'\t' -v OFS='\t' '$1 != "version" && $1 != "flag"' "$mf"
    fi
}

manifest_flag_set() {
    local name="$1" value="$2" mf tmp
    mf="$(manifest_path)"
    manifest_init
    tmp="$mf.tmp.$$"
    awk -F'\t' -v OFS='\t' -v n="$name" -v v="$value" '
        $1 == "flag" && $2 == n { next }
        { print }
        END { print "flag", n, v }
    ' "$mf" > "$tmp" && mv "$tmp" "$mf"
}

manifest_flag_get() {
    local name="$1" mf value
    mf="$(manifest_path)"
    [[ -f "$mf" ]] || return 0
    value="$(awk -F'\t' -v n="$name" '$1 == "flag" && $2 == n { print $3 }' "$mf")"
    printf '%s\n' "$value"
}

# ==============================================================================
# Cross-layer value validation
#
# The manager and rc.d/*.sh derive the same paths independently and must agree.
# rc.d is read as TEXT: `tty` would fail here, and 99-local.sh would execute.
# ==============================================================================

# xdg_parse_repo_env — print "VAR<TAB>value" for each shared var assigned in
# the repository's rc.d files. Unparseable assignments are reported, never
# guessed at.
xdg_parse_repo_env() {
    local files=(
        "$SCRIPT_DIR/config/bash/rc.d/00-xdg.sh"
        "$SCRIPT_DIR/config/bash/rc.d/10-env.sh"
    )
    local file line rest name value
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"   # ltrim
            [[ "$line" == export[[:space:]]* ]] && line="${line#export}" && \
                line="${line#"${line%%[![:space:]]*}"}"
            [[ "$line" == *=* ]] || continue
            name="${line%%=*}"
            [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            rest="${line#*=}"

            # Only variables both layers care about.
            local shared=0 v
            for v in "${MANAGER_SHARED_VARS[@]}"; do
                [[ "$name" == "$v" ]] && shared=1 && break
            done
            [[ "$shared" -eq 1 ]] || continue

            # Strip one layer of optional surrounding quotes.
            case "$rest" in
                \"*\") rest="${rest#\"}"; rest="${rest%\"}" ;;
                \'*\') rest="${rest#\'}"; rest="${rest%\'}" ;;
            esac

            # Values built by running commands cannot be validated statically.
            if [[ "$rest" == *'$('* || "$rest" == *'`'* ]]; then
                printf '%s\t%s\n' "$name" "<skip:computed>"
                continue
            fi

            # Expand ${VAR:-default} against the CURRENT environment: $HOME is
            # whatever this process has, which is the context being compared.
            # shellcheck disable=SC2016
            value="$(eval "printf '%s' \"${rest}\"" 2>/dev/null)" || value="<skip:unexpanded>"
            printf '%s\t%s\n' "$name" "$value"
        done < "$file"
    done
}

# xdg_assert_consistency [--strict] — 0 when the repository's declared values and
# the manager's own agree, 1 when they diverge. Both sides are printed, because the
# user has to know which one is in effect before changing anything.
xdg_assert_consistency() {
    local strict=0
    [[ "${1:-}" == "--strict" ]] && strict=1

    local declarations name declared mine mismatches=0 unparseable=0
    declarations="$(xdg_parse_repo_env)"

    if [[ -z "$declarations" ]]; then
        log_warn "Could not read shared values from config/bash/rc.d/ — skipping the consistency check."
        return 0
    fi

    printf '\n'
    log_step "Verifying Shared Values Across Both Layers"

    local rc=0
    while IFS=$'\t' read -r name declared; do
        [[ -n "$name" ]] || continue
        rc=0
        mine="$(eval "printf '%s' \"\${$name:-}\"")" || rc=1
        if [[ "$rc" -ne 0 || -z "$mine" ]]; then
            log_error "$name is not initialized in the manager — cannot verify. This is a manager bug."
            mismatches=$((mismatches + 1))
            continue
        fi
        if [[ "$declared" == "<skip:"* ]]; then
            log_warn "$name: shell config uses a value this check cannot verify ($declared)"
            unparseable=$((unparseable + 1))
            continue
        fi
        if [[ "$declared" == "$mine" ]]; then
            log_success "$name = $mine"
        else
            log_warn "$name MISMATCH"
            log_info "manager uses: $mine"
            log_info "shell will use: $declared"
            mismatches=$((mismatches + 1))
        fi
    done <<< "$declarations"

    if [[ "$mismatches" -eq 0 ]]; then
        if [[ "$unparseable" -gt 0 ]]; then
            log_info "All verifiable shared values agree ($unparseable skipped)."
        else
            log_success "All shared values agree between manager and shell configuration."
        fi
        # DSH_HOME and PNPM_HOME decide where files are INSTALLED, so a
        # mismatch there cannot be waved through under --strict.
        return 0
    fi

    printf '\n'
    log_info "Fix the mismatch in ONE place (recommended: config/bash/rc.d/) and re-run."
    log_info "The manager deliberately does not overwrite your shell configuration."

    if [[ "$strict" -eq 1 ]]; then
        log_error "$mismatches shared value(s) disagree — refusing to continue in strict mode."
        return 1
    fi
    log_warn "$mismatches shared value(s) disagree — files may be installed where your shell will not look."
    return 0
}
