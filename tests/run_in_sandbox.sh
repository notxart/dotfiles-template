#!/usr/bin/env bash
# ==============================================================================
# tests/run_in_sandbox.sh — End-to-end harness for the dotfiles manager
#
# Runs ./manager.sh against a throwaway HOME with stubbed privileged commands
# (sudo / apt-get) and stubbed tool binaries, so no system state is touched and
# no package is ever installed for real.
#
# Usage:
#   tests/run_in_sandbox.sh <case-name> [--second-clone]
#
#   <case-name>       creates .sandbox-e2e/<case-name>/
#   --second-clone    run twice from two different clones into the same HOME
#                     (reproduces the cross-clone symlink-loop defect)
#
# Outputs, under .sandbox-e2e/<case-name>/:
#   stdout.clean      installer stdout with ANSI escapes stripped
#   stderr.clean      installer stderr with ANSI escapes stripped
#   report.txt        exit code + resulting symlink / directory topology
# ==============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE="${1:?usage: run_in_sandbox.sh <case-name> [--second-clone]}"
MODE="${2:-}"
RUN="$REPO_ROOT/.sandbox-e2e/$CASE"
PNPM_BIN="${PNPM_HOME_BIN:-$HOME/.local/share/pnpm/bin}"

rm -rf "$RUN"
mkdir -p "$RUN/home" "$RUN/bin" "$RUN/repo"

# --- stage the repository (source of truth copied in, so the run is hermetic) --
cp -a "$REPO_ROOT"/{lib,manager.sh,skills,config,.bashrc,.bash_profile} "$RUN/repo/"
chmod +x "$RUN/repo/manager.sh"

# --- stubs: privileged commands do nothing ------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$RUN/bin/sudo"
printf '#!/bin/sh\nexit 0\n' > "$RUN/bin/apt-get"
chmod +x "$RUN/bin/sudo" "$RUN/bin/apt-get"

# --- stubs: tool binaries report versions that satisfy the requirements -------
printf '#!/bin/sh\necho "0.60 (devel)"\n' > "$RUN/bin/fzf"
printf '#!/bin/sh\necho "starship 1.22.1"\n' > "$RUN/bin/starship"
printf '#!/bin/sh\necho "0.22.0"\n' > "$RUN/bin/hunk"
# Real lazygit prints "lazygit, version=0.50.0+ds1, ..., git version=2.47.3"
printf '#!/bin/sh\necho "lazygit, version=0.50.0+ds1, commit=abc, builddate=x, git version=2.47.3"\n' > "$RUN/bin/lazygit"
chmod +x "$RUN/bin/"*

# --- deterministic environment -------------------------------------------------
# Clear every variable the manager and config/bash/rc.d share BEFORE setting the
# sandbox values. Without this, a value exported by the invoking shell (a real
# GNUPGHOME or GIT_CONFIG_GLOBAL) leaks into the run and the cross-layer
# consistency check correctly — but uselessly — reports a mismatch.
unset PNPM_HOME DSH_HOME GNUPGHOME GIT_CONFIG_GLOBAL 2>/dev/null || true

export HOME="$RUN/home"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME_OVERRIDE:-$HOME/.config}"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export PATH="$RUN/bin:$PNPM_BIN:$PATH"
export LC_ALL=C

run_once() { # run_once <repo-dir> <log-prefix>
    local repo="$1" prefix="$2"
    "$repo/manager.sh" install --with-git-tui --with-dsh \
        > "$RUN/$prefix.stdout.raw" 2> "$RUN/$prefix.stderr.raw"
    echo "$?" > "$RUN/$prefix.exit"
}

# --- execute -------------------------------------------------------------------
if [[ "$MODE" == "--second-clone" ]]; then
    cp -a "$RUN/repo" "$RUN/repoB"
    run_once "$RUN/repo"  "pass1"
    run_once "$RUN/repoB" "pass2"
    cp "$RUN/pass2.stdout.raw" "$RUN/stdout.raw"
    cp "$RUN/pass2.stderr.raw" "$RUN/stderr.raw"
else
    run_once "$RUN/repo" "pass1"
    cp "$RUN/pass1.stdout.raw" "$RUN/stdout.raw"
    cp "$RUN/pass1.stderr.raw" "$RUN/stderr.raw"
fi

# --- normalise (strip ANSI so diffs are stable) --------------------------------
sed -e 's/\x1b\[[0-9;]*m//g' "$RUN/stdout.raw" > "$RUN/stdout.clean"
sed -e 's/\x1b\[[0-9;]*m//g' "$RUN/stderr.raw" > "$RUN/stderr.clean"

# --- report --------------------------------------------------------------------
{
    echo "exit_code=$(cat "$RUN/pass1.exit")${MODE:+ (pass1) }"
    [[ "$MODE" == "--second-clone" ]] && echo "exit_code_pass2=$(cat "$RUN/pass2.exit")"
    echo
    echo "=== symlinks under \$HOME (dest -> src) ==="
    find "$HOME" -type l -printf '%p -> %l\n' 2>/dev/null | sed "s|$HOME|~|g" | sort
    echo
    echo "=== real directories under ~/.config ==="
    find "$HOME/.config" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort
    echo
    echo "=== config/ entries that are symlinks (loop check) ==="
    find "$RUN/repo/config" -mindepth 2 -type l -printf '%p -> %l\n' 2>/dev/null \
        | sed "s|$RUN/repo/||" | sort
    echo
    echo "=== files written under ~/.local ==="
    find "$HOME/.local" -mindepth 1 -printf '%y %p\n' 2>/dev/null | sed "s|$HOME|~|g" | sort
} > "$RUN/report.txt"

echo "sandbox: $RUN"
echo "  exit: $(cat "$RUN/pass1.exit")${MODE:+ / $(cat "$RUN/pass2.exit" 2>/dev/null)}"
echo "  report: $RUN/report.txt"
