#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/xdg.sh — XDG initialization, manifest, and cross-layer value validation
#
# Scope note: this module only prepares paths for the *manager's own* process.
# It never sources the user's shell rc.d files. `xdg_parse_repo_env` reads them
# as plain text for verification only — see `xdg_assert_consistency`.
#
# The manifest is the manager's record of what it owns, plus the feature flags
# chosen at install time. It is what lets `update` and `config` know about a
# machine without re-asking, and what distinguishes "dotfiles owns this path"
# from "some application wrote this".
# ==============================================================================

# Vars the manager and config/bash/rc.d/*.sh both define. They must agree:
# a divergence installs files where the user's shell will never look for them.
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
# The manager and config/bash/rc.d/*.sh derive the same paths independently.
# They must agree, or the manager installs into a directory the user's shell
# never reads (e.g. DSH_HOME: skills land where `dsh` never looks).
#
# `xdg_parse_repo_env` reads the rc.d files as TEXT. It never sources them:
# rc.d/00-xdg.sh contains `export GPG_TTY=$(tty)`, and `tty` fails in a
# non-interactive process like this one. Sourcing them would also execute
# arbitrary user code (99-local.sh) inside the installer.
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

            # Expand ${VAR:-default} / ${VAR-default} using the CURRENT
            # environment. $HOME therefore resolves to whatever HOME this
            # process has — which is exactly the context we compare in.
            # shellcheck disable=SC2016
            value="$(eval "printf '%s' \"${rest}\"" 2>/dev/null)" || value="<skip:unexpanded>"
            printf '%s\t%s\n' "$name" "$value"
        done < "$file"
    done
}

# xdg_assert_consistency [--strict]
# Compares the repository's declared values against the manager's own.
# Returns 0 when consistent, 1 when they diverge. Prints the manager's value
# and the shell's value side by side, because the user needs to know which one
# is currently in effect before deciding what to change.
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
