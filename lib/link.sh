#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/link.sh — Dotfile symlink synchronization
#
# Moved verbatim from install.sh (Step 1: behavior unchanged).
#
# KNOWN LIMITATIONS (deliberately preserved for Step 1; addressed in Steps 3–7):
#   * sync_symlink moves conflicting targets aside and links over them. Any
#     real file that a third-party tool wrote into a managed directory is
#     therefore relocated without inspection.
#   * The "remains a non-symlink directory" guard runs after the move, so it
#     cannot fire.
#   * There is no manifest, no orphan handling and no loop detection.
# Step 3 replaces this with the link/seed/ignored engine.
# ==============================================================================

ensure_backup_dir() {
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        log_info "Allocated backup directory: $BACKUP_DIR"
    fi
}

sync_symlink() {
    local src="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"

    # Lazy backup trigger: only backup if the destination physically exists and is not a symlink
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        ensure_backup_dir
        log_warn "Backing up conflicting target: $dest -> $BACKUP_DIR/"
        mv "$dest" "$BACKUP_DIR/"
    fi

    # Guard against dangling non-symlink directories that failed to move
    if [[ -d "$dest" && ! -L "$dest" ]]; then
        log_error "Destination $dest remains a non-symlink directory. Skipping link."
        return 1
    fi

    ln -sf "$src" "$dest"
    log_info "Linked: $dest -> $src"
}

setup_symlinks() {
    log_step "Synchronizing Dotfiles & Symlinks"

    # Deterministic ordered linking specifications: "rel_src:abs_dest"
    local link_specs=(
        ".bash_profile:$HOME/.bash_profile"
        ".bashrc:$HOME/.bashrc"
        "config/starship.toml:$XDG_CONFIG_HOME/starship.toml"
        "config/bash:$XDG_CONFIG_HOME/bash"
        "config/git:$XDG_CONFIG_HOME/git"
        "config/vim:$XDG_CONFIG_HOME/vim"
    )

    if [[ "$FLAG_GIT_TUI" -eq 1 ]]; then
        link_specs+=(
            "config/lazygit:$XDG_CONFIG_HOME/lazygit"
            "config/hunk:$XDG_CONFIG_HOME/hunk"
        )
    fi

    for spec in "${link_specs[@]}"; do
        local rel_src="${spec%%:*}"
        local abs_dest="${spec#*:}"
        sync_symlink "$SCRIPT_DIR/$rel_src" "$abs_dest"
    done

    # Legacy ~/.vimrc takes precedence over the XDG vimrc (Vim reads ~/.vimrc
    # first), so commit-message wrapping (config/vim/vimrc) would silently not
    # apply. Warn so the user can remove or merge it deliberately.
    if [[ -f "$HOME/.vimrc" ]]; then
        log_warn "$HOME/.vimrc exists and overrides $XDG_CONFIG_HOME/vim/vimrc"
        log_info "Remove it or merge your settings into the XDG vimrc to enable commit-message wrapping."
    fi

    # Dynamic DeepSeek Harness Skills Symlinks
    if [[ "$FLAG_WITH_DSH" -eq 1 ]]; then
        local dsh_home="${DSH_HOME:-$XDG_DATA_HOME/dsh}"
        for skill_dir in "$SCRIPT_DIR"/skills/*/; do
            [[ -d "$skill_dir" ]] || continue
            local skill_name
            skill_name="$(basename "$skill_dir")"
            sync_symlink "$skill_dir" "$dsh_home/skills/$skill_name"
        done
    fi

    # Mark global Git hooks as executable
    if [[ -d "$XDG_CONFIG_HOME/git/hooks" ]]; then
        for hook in "$XDG_CONFIG_HOME/git/hooks"/*; do
            [[ -f "$hook" ]] && chmod +x "$hook"
        done
        log_success "Global Git hooks verified as executable."
    fi

    # core.hooksPath is a fixed literal in config.ini (~/.config/git/hooks):
    # with a custom XDG_CONFIG_HOME the hooks are installed at $XDG_CONFIG_HOME
    # instead and git would silently skip them. Warn so the user can fix it.
    if [[ "$XDG_CONFIG_HOME" != "$HOME/.config" ]]; then
        log_warn "XDG_CONFIG_HOME is not the default; core.hooksPath in config.ini still points to ~/.config/git/hooks"
        log_info "Set it explicitly: git config --global core.hooksPath \"$XDG_CONFIG_HOME/git/hooks\""
    fi
}
