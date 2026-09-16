#!/usr/bin/env bash
# ==============================================================================
# config/git/wrap-msg.sh — Format and validate a commit message.
#
# Two modes:
#
#   config/git/wrap-msg.sh < draft > message      filter: format stdin to stdout
#   config/git/wrap-msg.sh --edit <file>          git editor: format IN PLACE, then
#                                            hand the file to the real editor
#
# The wrapping rules are INLINED (see the awk program below). That is not a
# style choice: this script is invoked through symlinks, and bash resolves
# BASH_SOURCE to the LINK's directory, so any attempt to source a file beside
# the real script fails. An earlier version kept the rules in a separate awk
# file and did not work when linked; the rules now travel with the script
# wherever the link points.
#
# `--edit` exists so that formatting does not depend on remembering to run a
# tool. config/git/config.ini sets it as core.editor, which makes every commit
# path that opens an editor formatted — including `git commit --amend` and
# `git rebase -i`, neither of which runs prepare-commit-msg. A rule that is only
# enforced when someone remembers to enforce it is not a rule.
#
# Rules applied:
#   * line 1 (the subject) is never wrapped; the 50-column convention is
#     reported, not repaired, because only the author knows what to cut
#   * prose wraps at 72 with no continuation indent (indenting prose renders it
#     as a code block in Markdown views of a commit message)
#   * bullets keep their marker and indent continuation lines by two spaces
#   * trailers (Refs:, Co-authored-by:, ...) are never wrapped
#   * no word is ever split and no line ever ends in whitespace
#
# Usage:
#   config/git/wrap-msg.sh < msg.txt            # print the formatted message
#   config/git/wrap-msg.sh --check < msg.txt    # validate only; exit 1 on a problem
#   config/git/wrap-msg.sh --edit <file>        # git core.editor entry point
#
# stdout carries ONLY the formatted message. Errors and the --check summary go
# to stderr, so `config/git/wrap-msg.sh < draft > message` is always safe.
#
# Exit codes: 0 ok, 1 subject too long or a formatted line over width, 2 usage/IO
# ==============================================================================
set -uo pipefail

readonly SUBJECT_MAX=50
readonly WIDTH=72

# Single source of the wrapping rules. Keeping this in a variable lets both the
# filter mode and the in-place mode use exactly the same program.
readonly WRAP_AWK='
function wrap(prefix, cont, text,    out, line, word, sep, i, n, w) {
    n = split(text, w, /[ \t]+/)
    out = ""
    line = prefix
    for (i = 1; i <= n; i++) {
        word = w[i]
        if (word == "") continue
        sep = (line == prefix) ? "" : " "
        if (length(line) + length(sep) + length(word) > 72 && line != prefix) {
            out = out line "\n"
            line = cont word
        } else {
            line = line sep word
        }
    }
    return out line
}

NR == 1 { sub(/[ \t]+$/, ""); print; next }
{
    line = $0
    sub(/[ \t]+$/, "", line)
    if (line == "") { print ""; next }
    if (line ~ /^(Refs|Closes|Fixes|Co-authored-by|Signed-off-by|Reviewed-by|Acked-by|Tested-by|Reported-by):/) {
        print line
        next
    }
    if (line ~ /^- /) { print wrap("- ", "  ", substr(line, 3)); next }
    print wrap("", "", line)
}
'

# ------------------------------------------------------------------------------
# --edit <file> — the core.editor entry point
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--edit" ]]; then
    msgfile="${2:-}"
    if [[ -z "$msgfile" || ! -f "$msgfile" ]]; then
        printf 'wrap-msg.sh --edit: no such message file: %s\n' "${msgfile:-<none>}" >&2
        exit 1
    fi

    tmp="$(mktemp)" || exit 1
    if awk "$WRAP_AWK" "$msgfile" > "$tmp" 2>/dev/null; then
        subj="$(head -n1 "$tmp")"
        # The subject is never wrapped, so an over-long one is REPORTED rather
        # than repaired: trimming it is an author decision.
        if [[ "${#subj}" -gt "$SUBJECT_MAX" ]]; then
            printf 'wrap-msg.sh: subject is %d characters (limit %d).\n' "${#subj}" "$SUBJECT_MAX" >&2
            printf '             %s\n' "$subj" >&2
        fi
        cat "$tmp" > "$msgfile"
    fi
    rm -f "$tmp"

    # Hand over to the real editor. VISUAL/EDITOR are read here because git
    # replaces them with this script before invoking it, so the previous value
    # is not available. Guard against pointing back at this script, which would
    # recurse forever.
    real="${VISUAL:-${EDITOR:-}}"
    case "$real" in
        ""|*wrap-msg*) real="" ;;
    esac
    if [[ -z "$real" ]]; then
        if command -v vim >/dev/null 2>&1; then
            real="vim"
        elif command -v vi >/dev/null 2>&1; then
            real="vi"
        else
            printf 'wrap-msg.sh: no editor found; set VISUAL or EDITOR.\n' >&2
            exit 1
        fi
    fi
    # shellcheck disable=SC2086
    exec $real "$msgfile"
fi

# ------------------------------------------------------------------------------
# filter and --check modes
# ------------------------------------------------------------------------------
MODE="format"
case "${1:-}" in
    --check) MODE="check" ;;
    "")      ;;
    *)       printf 'usage: %s [--check] < msg.txt | %s --edit <file>\n' \
                      "$(basename "$0")" "$(basename "$0")" >&2; exit 2 ;;
esac

# Slurp stdin ONCE. Validation and formatting must not both read the stream:
# the first reader consumes it and the second silently sees an empty input.
input="$(mktemp)" || exit 2
formatted="$(mktemp)" || { rm -f "$input"; exit 2; }
trap 'rm -f "$input" "$formatted"' EXIT

if ! cat > "$input"; then
    printf 'ERROR: could not read the message from stdin.\n' >&2
    exit 2
fi
if [[ ! -s "$input" ]]; then
    printf 'ERROR: the message is empty.\n' >&2
    exit 2
fi

subject="$(head -n1 "$input")"
subject_len="${#subject}"
if [[ -z "$subject" ]]; then
    printf 'ERROR: the subject line (line 1) is empty.\n' >&2
    exit 1
fi
if [[ "$subject_len" -gt "$SUBJECT_MAX" ]]; then
    printf 'ERROR: subject is %d characters, limit is %d.\n' "$subject_len" "$SUBJECT_MAX" >&2
    printf '       %s\n' "$subject" >&2
    printf '       Shorten it and move the detail into the body.\n' >&2
    exit 1
fi

awk "$WRAP_AWK" "$input" > "$formatted"

if [[ "$MODE" == "check" ]]; then
    # Two things are verified, because either can fail in practice: the subject
    # convention above, and the FORMATTED body staying inside the width.
    # Checking the input instead would miss an already-wrapped message with an
    # over-long line, which is the state a bad paste leaves behind.
    overlong="$(awk -v w="$WIDTH" 'length($0) > w { n++ } END { print n + 0 }' "$formatted")"
    if [[ "$overlong" -gt 0 ]]; then
        printf 'ERROR: %d formatted line(s) exceed %d characters.\n' "$overlong" "$WIDTH" >&2
        awk -v w="$WIDTH" 'length($0) > w { printf "       %3d | %s\n", length($0), $0 }' "$formatted" >&2
        exit 1
    fi
    trailing="$(awk '/[ \t]+$/ { n++ } END { print n + 0 }' "$formatted")"
    if [[ "$trailing" -gt 0 ]]; then
        printf 'ERROR: %d formatted line(s) end with whitespace.\n' "$trailing" >&2
        exit 1
    fi
    printf 'ok: subject %d/%d chars, %d lines, longest %d/%d\n' \
        "$subject_len" "$SUBJECT_MAX" \
        "$(wc -l < "$formatted")" \
        "$(awk '{print length}' "$formatted" | sort -rn | head -1)" "$WIDTH" >&2
    exit 0
fi

cat "$formatted"
