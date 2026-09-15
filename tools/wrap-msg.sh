#!/usr/bin/env bash
# ==============================================================================
# tools/wrap-msg.sh — Format and validate a commit message.
#
# Reads an UNWRAPPED commit message on stdin (one paragraph / one bullet per
# line) and prints it ready to paste into a commit editor:
#
#   * subject    (line 1)          must be <= 50 characters, hard failure
#   * body                         wrapped to 72, no word is ever cut
#   * bullets    ("- ")            continuation lines indented two spaces
#   * prose                        continuation lines NOT indented
#   * trailers   (Refs:, ...)      never wrapped, even past 72
#
# The wrapping RULES live in tools/lib/wrap-message.awk, shared with
# config/git/hooks/prepare-commit-msg so the two cannot drift apart. See that
# file for why `fold -s -w 72` is not good enough.
#
# Usage:
#   tools/wrap-msg.sh < msg.txt            # print the formatted message
#   tools/wrap-msg.sh --check < msg.txt    # validate; exit 1 on a problem
#
# stdout carries ONLY the formatted message. Errors and the --check summary go
# to stderr, so `tools/wrap-msg.sh < draft > message` is always safe.
#
# Exit codes: 0 ok, 1 subject empty/too long or a formatted line over width, 2 usage/IO error
# ==============================================================================
set -uo pipefail

readonly SUBJECT_MAX=50
readonly WIDTH=72
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly AWK_RULES="$SCRIPT_DIR/lib/wrap-message.awk"

MODE="format"
case "${1:-}" in
    --check) MODE="check" ;;
    "")      ;;
    *)       printf 'usage: %s [--check] < msg.txt\n' "$(basename "$0")" >&2; exit 2 ;;
esac

if [[ ! -f "$AWK_RULES" ]]; then
    printf 'ERROR: missing wrapping rules: %s\n' "$AWK_RULES" >&2
    exit 2
fi

# Slurp stdin ONCE. Validation and formatting must not both read the stream:
# the first reader consumes it and the second silently sees an empty input
# (which is exactly how the subject line went missing during development).
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

# --- validate the subject: what humans and `git log --oneline` see ------------
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

# --- format ------------------------------------------------------------------
awk -v width="$WIDTH" -f "$AWK_RULES" "$input" > "$formatted"

# --- report ------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
    # Two things are verified, because either can fail in practice:
    #   1. the subject fits the 50-character convention (checked above)
    #   2. the FORMATTED body keeps every line inside the width. Checking the
    #      input instead would miss an already-wrapped message that contains an
    #      over-long line, which is the state a bad paste leaves behind.
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
