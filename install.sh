#!/usr/bin/env bash
# ==============================================================================
# install.sh — Backwards-compatible entry point
#
# The installer was split into lib/ modules and a single entry point,
# ./manager.sh, which also provides `update` and `config` subcommands.
#
# This shim keeps existing clones, documentation links and muscle memory
# working. It only translates the historical invocation style:
#
#   ./install.sh --with-git-tui --with-dsh  ->  ./manager.sh install --with-git-tui --with-dsh
#
# Prefer ./manager.sh directly — see ./manager.sh --help.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/manager.sh" install "$@"
