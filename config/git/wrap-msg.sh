#!/usr/bin/env bash
# ==============================================================================
# config/git/wrap-msg.sh — Format and validate a commit message.
#   wrap-msg.sh < draft > message     |  wrap-msg.sh --check < file
#   wrap-msg.sh --edit <file>         core.editor: format in place, then hand off
# stdout carries only the formatted message; exit 0 ok, 1 a problem, 2 usage.
# ==============================================================================
set -uo pipefail

readonly SUBJECT_MAX=50
readonly WIDTH=72

# One program, shared by filter and in-place mode, INLINED rather than sourced: this
# script runs through symlinks and bash resolves BASH_SOURCE to the LINK, so sourcing a
# sibling only worked until the link moved. One pass guarantees: the subject is never
# wrapped (50 columns is reported, not repaired); prose wraps at 72 with no continuation
# indent, because indented prose renders as a code block; bullets keep their marker and
# indent continuations by two; trailers are never wrapped. The hook carries the same
# program; ./check.sh compares the two.
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
    # An INDENTED line is a continuation of the item above -- which is what this
    # formatter produces for a broken bullet. It must keep that indent, or a second
    # pass would treat the continuation as fresh prose and re-wrap it at column zero:
    # the real commit path runs these rules twice (the hook, then here).
    if (line ~ /^[ \t]/) { print wrap("  ", "  ", line); next }
    if (line ~ /^- /) { print wrap("- ", "  ", substr(line, 3)); next }
    print wrap("", "", line)
}
'

# ------------------------------------------------------------------------------
# --edit <file> — core.editor, so every commit path that opens an editor is
# formatted, including `--amend` and `rebase -i`, which never run the hook.
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

    # VISUAL/EDITOR are read here because git replaces them with this script before
    # invoking it. A value pointing back at this script would recurse forever.
    real="${VISUAL:-${EDITOR:-}}"
    case "$real" in
        ""|*wrap-msg*) real="" ;;
    esac
    if [[ -z "$real" ]]; then
        # Falling back to vim is safe only with a terminal: an automation that runs a
        # plain `git commit` has none, and an editor started that way blocks instead of
        # failing. Refuse, and name what to set.
        if [[ ! -t 0 && ! -t 2 ]]; then
            printf 'wrap-msg.sh: no editor configured and no terminal; set VISUAL or EDITOR.\n' >&2
            exit 1
        fi
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

# Format FIRST, unconditionally: validation reports a problem, it never decides whether
# the message reaches stdout. Filter mode is `wrap-msg.sh < draft > message`, so a
# failure that printed nothing would leave an EMPTY file where the draft used to be.
awk "$WRAP_AWK" "$input" > "$formatted" || {
    printf 'ERROR: could not format the message.\n' >&2
    exit 2
}

rc=0
if [[ -z "$subject" ]]; then
    printf 'ERROR: the subject line (line 1) is empty.\n' >&2
    rc=1
elif [[ "$subject_len" -gt "$SUBJECT_MAX" ]]; then
    printf 'ERROR: subject is %d characters, limit is %d.\n' "$subject_len" "$SUBJECT_MAX" >&2
    printf '       %s\n' "$subject" >&2
    printf '       Shorten it and move the detail into the body.\n' >&2
    rc=1
fi

if [[ "$MODE" == "check" ]]; then
    # Verify the FORMATTED body, not the input: an already-wrapped message with an
    # over-long line is exactly the state a bad paste leaves behind.
    overlong="$(awk -v w="$WIDTH" 'length($0) > w { n++ } END { print n + 0 }' "$formatted")"
    if [[ "$overlong" -gt 0 ]]; then
        printf 'ERROR: %d formatted line(s) exceed %d characters.\n' "$overlong" "$WIDTH" >&2
        awk -v w="$WIDTH" 'length($0) > w { printf "       %3d | %s\n", length($0), $0 }' "$formatted" >&2
        rc=1
    fi
    trailing="$(awk '/[ \t]+$/ { n++ } END { print n + 0 }' "$formatted")"
    if [[ "$trailing" -gt 0 ]]; then
        printf 'ERROR: %d formatted line(s) end with whitespace.\n' "$trailing" >&2
        rc=1
    fi
    if [[ "$rc" -eq 0 ]]; then
        printf 'ok: subject %d/%d chars, %d lines, longest %d/%d\n' \
            "$subject_len" "$SUBJECT_MAX" \
            "$(wc -l < "$formatted")" \
            "$(awk '{print length}' "$formatted" | sort -rn | head -1)" "$WIDTH" >&2
    fi
fi

# Both modes print the formatted message, so a redirect cannot be emptied by a failed
# check; the verdict is the exit code and the summary on stderr.
cat "$formatted"
exit "$rc"
