#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/scan.sh — Read-only inspection for `config sync`.
#
# Nothing here creates, moves or removes anything. Every function only reports,
# so a scan can run before the user has decided anything — which is the whole
# point of the reconciliation flow: show the situation, then act on request.
#
# Three questions are answered here:
#
#   scan_config_candidates  what exists under ~/.config that the repository does
#                           not manage? (something an application wrote, or a
#                           file the user added)
#   scan_classify           is that something worth syncing, or is it machine
#                           state that would break another computer?
#   scan_content_risk       does it look like it carries a secret or an absolute
#                           path, so that adopting it deserves a second look?
# ==============================================================================

# Anything larger than this is reported but never read for classification: a
# candidate that big is not a configuration file, and hashing it would stall the
# scan for no benefit.
readonly SCAN_MAX_BYTES=$((1024 * 1024))

# Paths inside ~/.config that are never candidates even though the repository
# does not manage them. These are conventions every tool on the machine relies
# on, and offering them for adoption would be noise at best.
readonly -a SCAN_NEVER_CANDIDATE=(
    "mimeapps.list"
    "user-dirs.dirs"
    "user-dirs.locale"
    "autostart"
    "systemd"
    "pulse"
    "gtk-2.0"
    "gtk-3.0"
    "gtk-4.0"
    "dconf"
    "fontconfig"
    "qt5ct"
    "qt6ct"
)

# scan_never_candidate <name> — 0 when the basename is on the never list.
scan_never_candidate() {
    local name="$1" n
    for n in "${SCAN_NEVER_CANDIDATE[@]}"; do
        [[ "$name" == "$n" ]] && return 0
    done
    return 1
}

# scan_is_managed <path> — 0 when the manifest already has a record for it, or
# it is a registry destination. Managed paths are reported by `config status`,
# not as candidates.
scan_is_managed() {
    local path="$1"
    manifest_has "$path" && return 0
    link_registry | awk -F'\t' -v d="$path" '$2 == d { found = 1; exit } END { exit !found }'
}

# scan_is_managed_parent <path> — 0 when <path> is a directory that CONTAINS
# registry destinations.
#
# ~/.config/bash/rc.d and ~/.config/git/hooks are real directories the manager
# created to hold linked files. They are not managed themselves, so a naive
# candidate walk offers them for adoption, which is noise: the user did not put
# them there and adopting a directory would move the manager's own links.
scan_is_managed_parent() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    link_registry | awk -F'\t' -v d="$path/" '
        index($2, d) == 1 { found = 1; exit }
        END { exit !found }'
}

# scan_config_candidates — files and directories under ~/.config that the
# repository does not manage and that are worth showing the user.
#
# Only the first two levels are walked: ~/.config/<tool>/<file>. Deeper trees
# belong to the tool and offering every file inside them would bury the signal.
scan_config_candidates() {
    local path name
    [[ -d "$XDG_CONFIG_HOME" ]] || return 0

    # Level 1: ~/.config/<entry>
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        name="$(basename "$path")"
        scan_never_candidate "$name" && continue
        scan_is_managed "$path" && continue
        scan_is_managed_parent "$path" && continue
        [[ -d "$path" && ! -L "$path" ]] || { printf '%s\n' "$path"; continue; }
        # A directory the repository does not manage: walk one level into it.
        local child
        while IFS= read -r child; do
            [[ -n "$child" ]] || continue
            scan_is_managed "$child" && continue
            scan_is_managed_parent "$child" && continue
            printf '%s\n' "$child"
        done < <(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
    done < <(find "$XDG_CONFIG_HOME" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
}

# scan_classify <path> — portable-config | machine-state | unknown
#
# A machine-state file is one that records THIS machine: a session, a cache, an
# absolute path, a window layout. Syncing it to another computer does not help
# that computer and can leak this one, so it is reported as such and ignored by
# default.
scan_classify() {
    local path="$1" name size mode
    name="$(basename "$path")"

    # Name conventions that always mean machine state.
    case "$name" in
        state.json|*.state|state.yml)        printf 'machine-state\n'; return 0 ;;
        session*|*.session)                  printf 'machine-state\n'; return 0 ;;
        *.lock|*.pid|*.sock|*.log)           printf 'machine-state\n'; return 0 ;;
        .DS_Store|Thumbs.db)                 printf 'machine-state\n'; return 0 ;;
    esac

    # A directory whose name says it is generated.
    if [[ -d "$path" ]]; then
        case "$name" in
            cache|Cache|cachedir|tmp|temp) printf 'machine-state\n'; return 0 ;;
        esac
        printf 'unknown\n'; return 0
    fi

    # Size gate: too large to be a configuration file.
    size="$(wc -c < "$path" 2>/dev/null || echo 0)"
    [[ "$size" -gt "$SCAN_MAX_BYTES" ]] && { printf 'machine-state\n'; return 0; }

    # Owner-only permissions are a strong hint of private state (hunk writes
    # state.json as 0600).
    mode="$(stat -c '%a' "$path" 2>/dev/null || echo "")"
    case "$mode" in
        600|0600) printf 'machine-state\n'; return 0 ;;
    esac

    # Content that records this machine rather than a preference.
    if [[ -f "$path" ]] && file --brief --mime "$path" 2>/dev/null | grep -q 'text'; then
        if grep -qE "\"?/(home|Users)/[^\"[:space:]]+" "$path" 2>/dev/null; then
            printf 'machine-state\n'; return 0
        fi
    fi

    printf 'portable-config\n'
    return 0
}

# scan_content_risk <path> — print one "kind<TAB>match" line per risk found.
# Empty output means nothing suspicious. This never blocks anything; it exists
# so that adoption can require an explicit acknowledgement.
scan_content_risk() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    grep -nEi '(api[_-]?key|secret|token|password|passwd|credential|private[_-]?key|BEGIN [A-Z ]*PRIVATE KEY)' \
        "$path" 2>/dev/null | head -n3 | while IFS= read -r hit; do
            printf 'credential\t%s\n' "${hit:0:120}"
        done
    grep -nE '/(home|Users)/[^"[:space:]]+' "$path" 2>/dev/null | head -n2 | while IFS= read -r hit; do
        printf 'absolute-path\t%s\n' "${hit:0:120}"
    done
    # "Nothing found" is a result, not a failure. Without this the function
    # returns the status of its last grep — 1 when it matched nothing — and every
    # caller that captures the output with $( ) inherits that status. Under
    # `set -e` an assignment from a command substitution takes the status of the
    # substitution, so a clean file aborted the whole command.
    return 0
}

# scan_redact <text> — keep a finding readable, remove the secret from it.
#
# The check below is about credentials, and a check that prints the credential
# it found has moved the leak rather than reported it: this output goes to a
# terminal, a scrollback buffer and often a pasted issue. The line number and
# the shape of the match are what a reader needs; the value is not.
scan_redact() {
    printf '%s' "$1" \
        | sed -E \
            -e 's/(gh[pousr]_)[A-Za-z0-9]+/\1***/g' \
            -e 's/(github_pat_)[A-Za-z0-9_]+/\1***/g' \
            -e 's/((token|password|passwd|secret|api[_-]?key)[[:space:]]*[=:][[:space:]]*).*/\1***/I'
}

# scan_credential_leaks <path> — print "line<TAB>kind" for content that must not
# be in a tracked file.
#
# Narrower than scan_content_risk on purpose. That one is a hint shown while
# adopting an unknown file, where a false positive costs a second look. This one
# runs on the repository's own tracked configuration and is meant to be believed,
# so it looks for two things that are unambiguous: a credential helper that
# stores secrets on disk, and a token-shaped string.
scan_credential_leaks() {
    local path="$1"
    [[ -f "$path" ]] || return 0

    # Two statements rather than one pattern: the messages differ, and mixing
    # them would produce "credential" for both a helper name (not a secret) and
    # a token (one).
    grep -nEi '^[[:space:]]*helper[[:space:]]*=[[:space:]]*(store|cache)' "$path" 2>/dev/null \
        | head -n3 | while IFS= read -r hit; do
            printf '%s\tstored-credential-helper\t%s\n' "${hit%%:*}" "$(scan_redact "$hit")"
        done

    grep -nE '(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|BEGIN [A-Z ]*PRIVATE KEY)' "$path" 2>/dev/null \
        | head -n3 | while IFS= read -r hit; do
            printf '%s\tsecret-token\t%s\n' "${hit%%:*}" "$(scan_redact "$hit")"
        done

    # Same reason as scan_content_risk: no findings is not a failure.
    return 0
}

# scan_size_note <path> — a human-readable size, used in the summary table.
scan_size_note() {
    local path="$1" size
    if [[ -d "$path" ]]; then
        printf 'dir'
        return 0
    fi
    size="$(wc -c < "$path" 2>/dev/null || echo 0)"
    if [[ "$size" -ge 1048576 ]]; then
        printf '%dM' $((size / 1048576))
    elif [[ "$size" -ge 1024 ]]; then
        printf '%dK' $((size / 1024))
    else
        printf '%dB' "$size"
    fi
}

# scan_same_content <a> <b> — 0 when both files have identical content.
# Used to decide whether a real file can be converted to a link silently: the
# repository version is then a byte-for-byte substitute, so nothing is lost.
scan_same_content() {
    local a="$1" b="$2"
    [[ -f "$a" && -f "$b" ]] || return 1
    local ha hb
    ha="$(sha256_file "$a")"
    hb="$(sha256_file "$b")"
    [[ -n "$ha" && "$ha" == "$hb" ]]
}

# scan_show_diff <left> <right> — display a diff, bounded to <limit> lines.
#
# Two hazards are handled here, both of which used to abort the whole sync:
#
#   * `git diff --no-index` exits 1 when the files differ. That is a RESULT, not
#     a failure, and under `set -e` it would end the run before the candidate
#     list was ever printed.
#   * Truncating the output with `head` closes the pipe while git is still
#     writing, so git dies of SIGPIPE and the caller inherits the failure. The
#     whole pipeline is therefore run for effect only, with its status ignored:
#     showing a diff must never be able to stop the reconciliation.
scan_show_diff() {
    local left="$1" right="$2" limit="${3:-40}"
    git --no-pager diff --no-index --color=always -- "$left" "$right" 2>/dev/null \
        | head -n "$limit" \
        | sed 's/^/      /' || true
    return 0
}
