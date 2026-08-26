# This file handles shell completions.
#
# STRATEGY:
# 1. Static Completions (Preferred): Generate once, save to file. Fast startup.
# 2. Dynamic Completions (Fallback): Eval on startup. Slow startup.

# Ensure the custom completions directory exists.
COMPLETIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
mkdir -p "$COMPLETIONS_DIR"

# HELPER FUNCTION: generate_completion_if_missing
# Description: Generates a completion file only if the command exists and
#              the completion file is missing.
# Arguments:
#   $1: Command name (e.g., "rustup")
#   $2: Generation command (e.g., "rustup completions bash")
#   $3: (Optional) Output filename (defaults to $1)
generate_completion_if_missing() {
    local cmd_name="$1"
    local gen_cmd="$2"
    local out_file="${3:-$cmd_name}"
    local out_path="$COMPLETIONS_DIR/$out_file"

    # Strict check: If command doesn't exist, do nothing.
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        return 0
    fi

    # If completion file doesn't exist, generate it.
    if [[ ! -f "$out_path" ]]; then
        echo "Generating completions for $cmd_name..." >&2
        if eval "$gen_cmd" > "$out_path"; then
            echo "Done. Source ~/.bashrc to apply." >&2
        else
            echo "Error generating completions for $cmd_name." >&2
            rm -f "$out_path" # Cleanup empty/broken file
        fi
    fi
}


# ----------------------------------------------------------------------
# USER CUSTOMIZATIONS
# ----------------------------------------------------------------------
# Add your own completion logic below.

# --- Static Completions (Generated Once) ---

# pnpm (Node.js-free standalone install; see install.sh)
generate_completion_if_missing "pnpm" "pnpm completion bash"

# Example: Rust Toolchain
generate_completion_if_missing "rustup" "rustup completions bash"
generate_completion_if_missing "cargo" "rustup completions bash cargo"


# --- Dynamic Completions ---
# Use this ONLY if the tool does not support outputting a static file,
# or if the completion depends on the current environment state.
#
# WARNING: Heavy use of 'eval' here will significantly slow down shell startup.

# Example: uv (Python package installer) - fast enough to run dynamically if needed,
# but static generation is still preferred if possible.
if command -v uv >/dev/null 2>&1; then
    # Currently uv recommends eval, but keep an eye on startup time.
    eval "$(uv generate-shell-completion bash)"
fi


# ----------------------------------------------------------------------
# Clean up variables to keep the global namespace clean.
unset COMPLETIONS_DIR
unset -f generate_completion_if_missing
