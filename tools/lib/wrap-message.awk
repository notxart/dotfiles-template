# ==============================================================================
# tools/lib/wrap-message.awk — Wrap a Git commit message for reading.
#
# Single source of truth for the wrapping RULES. Two callers share it:
#
#   tools/wrap-msg.sh                          (used by humans and by an agent
#                                                preparing a draft; adds 50-char
#                                                subject validation)
#   config/git/hooks/prepare-commit-msg        (wraps .git/AI_COMMIT_MSG at
#                                                injection time)
#
# Keeping the rules here rather than inlining them in the hook means the two
# can never drift apart, and awk is available on every system Git runs on
# without an extra dependency.
#
# Input:  an UNWRAPPED message — one paragraph / one bullet per line.
# Output: the same message wrapped for a terminal diff of ~80 columns.
#
# Rules:
#   * line 1 (the subject) is never wrapped. Git treats it as the subject and
#     every "oneline" view would otherwise show a truncated one; the 50-column
#     convention is enforced by tools/wrap-msg.sh, not here.
#   * prose wraps at 72 with NO continuation indent (indenting prose renders it
#     as a code block in Markdown views of a commit message).
#   * bullets ("- ") keep their marker and indent continuation lines by two
#     spaces so the text stays visually inside the item.
#   * trailers (Refs:, Co-authored-by:, ...) are emitted verbatim: Git requires
#     them on a single line.
#   * no word is ever split, and no line ever ends in whitespace. `fold -s`,
#     which this replaces, does all three of the wrong things: it splits a word
#     with no space before the margin, drops a bullet's continuation indent, and
#     leaves a trailing space at every wrap point.
#
# Set the width with -v width=N (default 72).
#
# Input may be either shape, and the file is buffered so the two can be told
# apart before anything is printed:
#
#   * an UNWRAPPED message (one paragraph / bullet per line) is wrapped
#   * an ALREADY-FORMATTED message is passed through byte for byte
#
# Without that second case the formatter is not idempotent: it would unindent
# a wrapped bullet's continuation line, because an indented continuation is
# indistinguishable from a plain unwrapped line once the lines are considered
# one at a time. The hook re-wraps whatever it finds in .git/AI_COMMIT_MSG, so
# a formatted file must survive a second pass unchanged.
# ==============================================================================
function wrap(prefix, cont, text,    out, line, word, sep, i, n, w) {
    # Split on runs of whitespace so a simple index loop is safe (no reliance
    # on substr() arithmetic, which is where hand-written wrappers go wrong).
    n = split(text, w, /[ \t]+/)
    out = ""
    line = prefix
    for (i = 1; i <= n; i++) {
        word = w[i]
        if (word == "") continue
        sep = (line == prefix) ? "" : " "
        if (length(line) + length(sep) + length(word) > width && line != prefix) {
            out = out line "\n"
            line = cont word
        } else {
            line = line sep word
        }
    }
    return out line
}

BEGIN { if (width == 0) width = 72 }

# --- pass 1: buffer, and look for the signature of an already-wrapped list ---
{
    raw[NR] = $0
    if (NR > 1 && $0 ~ /^  [^ ]/) already_formatted = 1
}
END {
    if (already_formatted) {
        for (i = 1; i <= NR; i++) {
            line = raw[i]
            sub(/[ \t]+$/, "", line)
            print line
        }
        exit 0
    }

    for (i = 1; i <= NR; i++) {
        line = raw[i]
        sub(/[ \t]+$/, "", line)

        if (i == 1) { print line; continue }        # the subject is never wrapped
        if (line == "") { print ""; continue }

        if (line ~ /^(Refs|Closes|Fixes|Co-authored-by|Signed-off-by|Reviewed-by|Acked-by|Tested-by|Reported-by):/) {
            print line
            continue
        }

        if (line ~ /^- /) {
            print wrap("- ", "  ", substr(line, 3))
            continue
        }

        print wrap("", "", line)
    }
}
