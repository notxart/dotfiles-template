# Configuration and installation for ble.sh (Bash Line Editor).

# --- Installation ---
BLESH_DIR="$XDG_DATA_HOME/blesh"
BLESH_INSTALLED_PATH="$BLESH_DIR/ble.sh"

# Install ble.sh using the recommended 'make install' method if not already installed.
if [[ ! -f "$BLESH_INSTALLED_PATH" ]]; then
    # Define a local logging function for robust installation.
    log_func() {
        if command -v log >/dev/null 2>&1; then log "$1"; else echo -e "\n\033[1;34m❯❯❯ $1\033[0m"; fi
    }
    log_func "Installing ble.sh..."
    TMP_DIR=$(mktemp -d)
    # Clone and install ble.sh according to its official documentation.
    git clone --recursive --depth 1 --shallow-submodules "https://github.com/akinomyoga/ble.sh.git" "$TMP_DIR"
    make -C "$TMP_DIR" install PREFIX="$HOME/.local"
    rm -rf "$TMP_DIR"
    log_func "ble.sh installed successfully to $BLESH_DIR"
    unset -f log_func
fi

# --- Sourcing and Configuration ---
if [[ -f "$BLESH_INSTALLED_PATH" ]]; then
    # Source ble.sh
    source "$BLESH_INSTALLED_PATH"

    # Note: If you want to combine fzf-completion with bash_completion, you need to
    # load bash_completion earlier than fzf-completion. This is required
    # regardless of whether to use ble.sh or not.
    # Check if bash_completion exists before sourcing.
    if [[ -f /etc/profile.d/bash_completion.sh ]]; then
        source /etc/profile.d/bash_completion.sh
    elif [[ -f /usr/share/bash-completion/bash_completion ]]; then
        source /usr/share/bash-completion/bash_completion
    fi

    # --- FZF Integration (ble.sh method) ---
    # This properly integrates fzf with ble.sh for completion and keybindings,
    # with delayed loading (-d) for faster shell startup.
    ble-import -d integration/fzf-completion
    ble-import -d integration/fzf-key-bindings

    # --- ble.sh Settings ---

    # Set Color Scheme (Matches Starship palette)
    bleopt color_scheme=catppuccin_mocha

    # Disable bell sound
    bleopt edit_bell:=

    # Disable error exit marker like "[ble: exit %d]"
    bleopt exec_errexit_mark=

    # Let elapsed-time marker like " elapsed 2.004s (󰍛 CPU 0.4%) for command: "
    bleopt exec_elapsed_mark=$'\e[94m elapsed %s (󰍛 CPU %s%%) for command:\e[m'

    # Show elapsed-time marker when total CPU usage time exceeds half a minute.
    bleopt exec_elapsed_enabled='sys+usr>=30*1000'

    # Enable vi editing mode. This is essential for the mode indicators to work.
    set -o vi

    # This function contains all vi-mode specific configurations for ble.sh.
    # It will be registered as a hook to be executed after the vi keymap is loaded.
    ble_config_vi_mode() {
        # This option forces the prompt to be re-evaluated and redrawn on mode change.
        bleopt keymap_vi_mode_update_prompt=1

        # Set the indicator for NORMAL mode (vicmd).
        bleopt keymap_vi_mode_string_nmap=$'-- \e[1;33mNORMAL\e[m --'

        # Set the indicator for VISUAL mode.
        bleopt keymap_vi_mode_name_visual=$'\e[1;36mVISUAL\e[m'

        # Set the indicator for INSERT mode.
        bleopt keymap_vi_mode_name_insert=$'\e[1;35mINSERT\e[m'

        # You can also customize other modes if needed.
        # bleopt keymap_vi_mode_name_replace='-- REPLACE --'
        ble-import contrib/prompt-vim-mode
    }

    # Register the configuration function to the 'keymap_vi_load' hook.
    # This ensures our settings are applied at the correct time during ble.sh initialization.
    blehook/eval-after-load keymap_vi ble_config_vi_mode

else
    echo "Warning: ble.sh not found at $BLESH_INSTALLED_PATH" >&2
fi

unset BLESH_DIR BLESH_INSTALLED_PATH
