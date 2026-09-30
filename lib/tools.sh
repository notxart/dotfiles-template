#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/tools.sh — Tool provisioning, version enforcement and per-tool fallbacks
#
# Each tool has a version floor. A package manager that cannot meet it falls
# through to that tool's own installer.
# ==============================================================================

ensure_tool_version() {
    local cmd="$1"
    local pkg="$2"
    local req_ver="$3"
    local fallback_fn="$4"
    local current_ver=""
    local candidate_ver=""

    log_step "Checking Requirement: $cmd (>= $req_ver)"

    if command_exists "$cmd"; then
        current_ver=$(get_installed_version "$cmd")
        if ! compare_versions_lt "$current_ver" "$req_ver"; then
            log_success "Local $cmd version ($current_ver) satisfies constraint."
            return 0
        fi
        log_warn "Local $cmd version ($current_ver) is outdated."
    fi

    log_info "Querying upstream candidate for '$pkg'..."
    candidate_ver=$(get_candidate_version "$pkg")

    if [[ -n "$candidate_ver" ]] && ! compare_versions_lt "$candidate_ver" "$req_ver"; then
        log_info "Repository candidate ($candidate_ver) satisfies constraint. Installing via $PM_STRATEGY..."
        "${PM_INSTALL_CMD[@]}" "$pkg"

        current_ver=$(get_installed_version "$cmd")
        if ! compare_versions_lt "$current_ver" "$req_ver"; then
            log_success "$cmd ($current_ver) successfully installed via $PM_STRATEGY."
            return 0
        fi
        log_warn "Package manager installed $current_ver (below required $req_ver). Proceeding to fallback."
    else
        log_warn "Repository candidate (${candidate_ver:-none}) is insufficient or not available."
    fi

    log_info "Executing fallback installer: $fallback_fn"
    "$fallback_fn"
}

# --- Specific Tool Fallback Implementations ---

install_fzf_fallback() {
    log_info "Compiling fzf from source..."
    local fzf_dir="$XDG_DATA_HOME/fzf"
    local bin_dest="$HOME/.local/bin/fzf"

    [[ -d "$fzf_dir" ]] && rm -rf "$fzf_dir"

    if git clone --depth 1 https://github.com/junegunn/fzf.git "$fzf_dir"; then
        "$fzf_dir/install" --bin
        mkdir -p "$(dirname "$bin_dest")"
        ln -sf "$fzf_dir/bin/fzf" "$bin_dest"
        log_success "fzf successfully linked to $bin_dest"
    else
        log_error "Failed to clone fzf repository."
        exit 1
    fi
}

install_starship_fallback() {
    log_info "Installing Starship via official installer..."
    if ! curl -sS https://starship.rs/install.sh | sh -s -- -y; then
        log_warn "System-wide install failed. Installing locally to ~/.local/bin..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
    fi
    log_success "Starship installation completed."
}

ensure_node_runtime() {
    # The floor is set by what the tools actually declare. `hunkdiff` requires
    # Node >= 22, so an 18-or-20 runtime installs hunk and then cannot run it.
    local node_floor=22

    if command_exists node; then
        local node_major
        node_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
        if [[ -n "$node_major" ]] && [[ "$node_major" -ge "$node_floor" ]] 2>/dev/null; then
            log_success "Node.js $(node --version 2>/dev/null) detected (>= $node_floor)."
            return 0
        fi
        log_warn "Detected Node.js $(node --version 2>/dev/null || printf 'unknown') is older than $node_floor."
    fi

    log_info "Provisioning Node.js LTS via pnpm runtime..."
    if ! pnpm runtime set node lts -g && ! pnpm env use --global lts; then
        log_warn "Node.js provisioning via pnpm failed."
        return 1
    fi
    return 0
}

install_hunk_fallback() {
    if command_exists pnpm && ensure_node_runtime; then
        log_info "Installing Hunk via pnpm global repository..."
        if pnpm add -g hunkdiff; then
            log_success "Hunk installed via pnpm into $PNPM_HOME/bin."
            return 0
        fi
        log_warn "pnpm global installation failed; switching to prebuilt binary script."
    fi

    log_info "Installing Hunk via standalone official installer (XDG path)..."
    # The official installer honors HUNK_INSTALL_DIR / HUNK_NO_MODIFY_PATH env
    # vars: install under $XDG_DATA_HOME/hunk and never touch shell startup
    # files (keeps the README's XDG promise: nothing pollutes $HOME).
    local hunk_dir="$XDG_DATA_HOME/hunk"
    if ! HUNK_INSTALL_DIR="$hunk_dir/bin" HUNK_NO_MODIFY_PATH=1 \
        curl -fsSL https://hunk.dev/install.sh | sh -s; then
        log_error "Failed to install Hunk standalone binary."
        exit 1
    fi

    local hunk_bin="$hunk_dir/bin/hunk"
    if [[ -x "$hunk_bin" ]] && ! command_exists hunk; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$hunk_bin" "$HOME/.local/bin/hunk"
        log_info "Symlinked $hunk_bin to ~/.local/bin/hunk"
    fi
    log_success "Hunk installed."
    # Said out loud because it changes maintenance: `hunk update` does not
    # recognise a standalone install and keeps reporting itself as current.
    log_warn "This is a standalone install: 'hunk update' may not recognise it."
    log_info "Update it with '${SCRIPT_NAME:-manager.sh} update --only hunk', which re-runs this installer."
}

install_lazygit_fallback() {
    log_info "Fetching Lazygit release binary from GitHub..."

    local os arch
    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="darwin" ;;
        *)
            log_error "Unsupported OS for Lazygit: $(uname -s)"
            log_info "Lazygit publishes Linux and macOS builds; on anything else, use its package."
            return 1
            ;;
    esac

    # Asset names measured against the v0.65.1 release, all lowercase. Two are
    # not guessable from `uname -m`: there is no armv7 build (the armv6 one runs
    # on armv7 hardware), and 32-bit x86 is spelled `32-bit`, not `386`.
    case "$(uname -m)" in
        x86_64|amd64)        arch="x86_64" ;;
        aarch64|arm64)       arch="arm64" ;;
        armv6l|armv6)        arch="armv6" ;;
        armv7l|armv7)        arch="armv6" ;;
        i386|i486|i586|i686) arch="32-bit" ;;
        *)
            log_error "Unsupported CPU architecture for Lazygit: $(uname -m)"
            log_info "Available builds: x86_64, arm64, armv6, 32-bit."
            return 1
            ;;
    esac

    local asset="lazygit_*_${os}_${arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(create_temp_dir)"

    # gh first: no dependency on the release-JSON shape, no anonymous rate
    # limit. The API path below covers a machine without gh or without a login.
    if command_exists gh && gh auth status >/dev/null 2>&1; then
        log_info "Downloading ${asset} with gh..."
        gh release download --repo jesseduffield/lazygit --pattern "$asset" \
            --dir "$tmp_dir" --clobber >/dev/null 2>&1 \
            || log_warn "gh could not fetch the release; falling back to the GitHub API."
    else
        log_info "gh is unavailable or not authenticated; using the GitHub API."
    fi

    if ! ls "$tmp_dir"/lazygit_*.tar.gz >/dev/null 2>&1; then
        local release_url
        release_url="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
            | grep -oE "\"browser_download_url\": \"[^\"]*lazygit_[^\"]*_${os}_${arch}\\.tar\\.gz\"" \
            | head -n1 | cut -d'"' -f4)"

        if [[ -z "$release_url" ]]; then
            log_error "Failed to resolve a Lazygit release artifact for ${os}_${arch}."
            return 1
        fi

        curl -fsSL "$release_url" -o "$tmp_dir/lazygit.tar.gz" \
            || { log_error "Lazygit download failed."; return 1; }
    fi

    local archive
    archive="$(ls "$tmp_dir"/lazygit_*.tar.gz 2>/dev/null | head -n1)"
    [[ -n "$archive" ]] || archive="$tmp_dir/lazygit.tar.gz"

    tar -xzf "$archive" -C "$tmp_dir" || { log_error "Lazygit extraction failed."; return 1; }

    mkdir -p "$HOME/.local/bin"
    install -m 755 "$tmp_dir/lazygit" "$HOME/.local/bin/lazygit"
    log_success "Lazygit installed to ~/.local/bin/lazygit"
}

install_pnpm() {
    log_step "Verifying pnpm Infrastructure (Standalone Native)"

    if command_exists pnpm; then
        local existing_pnpm_version
        existing_pnpm_version="$(pnpm --version 2>/dev/null || true)"
        log_success "pnpm is already accessible: ${existing_pnpm_version:-unknown}"
        # `pnpm runtime` (see ensure_node_runtime) requires pnpm >= 11.
        if [[ -n "$existing_pnpm_version" ]] && compare_versions_lt "$existing_pnpm_version" "11"; then
            log_warn "Existing pnpm $existing_pnpm_version is below 11 — 'pnpm runtime' may be unavailable."
        fi
        log_info "To move it to the current release: ${SCRIPT_NAME:-manager.sh} update --only pnpm"
        return 0
    fi

    install_pnpm_standalone
}

# install_pnpm_standalone — the official installer, whether or not pnpm exists.
# `update` needs it as the fallback when `pnpm self-update` fails, which is the
# case install_pnpm's early return would skip.
install_pnpm_standalone() {
    # A bare major, not a full version: the installer resolves it through the
    # `latest-<major>` dist-tag, so the pin follows the stable release line.
    local pnpm_version="${PNPM_VERSION:-12}"

    local fake_home
    fake_home="$(create_temp_dir)"

    log_info "Executing standalone pnpm installer into $PNPM_HOME..."
    if ! curl -fsSL https://get.pnpm.io/install.sh \
        | env HOME="$fake_home" PNPM_HOME="$PNPM_HOME" PNPM_VERSION="$pnpm_version" SHELL="$(command -v bash)" sh -; then
        log_error "pnpm installation failed."
        exit 1
    fi

    if [[ -x "$PNPM_HOME/bin/pnpm" ]]; then
        if [[ ":$PATH:" != *":$PNPM_HOME/bin:"* ]]; then
            export PATH="$PNPM_HOME/bin:$PATH"
            log_info "Prepended $PNPM_HOME/bin to current execution PATH."
        fi
        log_success "pnpm installed to $PNPM_HOME/bin"
    else
        log_error "pnpm binary not found at $PNPM_HOME/bin/pnpm."
        exit 1
    fi
}

install_dsh() {
    log_step "Installing DeepSeek Harness Ecosystem"

    local dsh_home="${DSH_HOME:-$XDG_DATA_HOME/dsh}"
    export DSH_HOME="$dsh_home"

    if command_exists dsh; then
        log_success "dsh is already available: $(dsh --version 2>/dev/null || printf 'unknown')"
        return 0
    fi

    if ! command_exists pnpm; then
        log_error "pnpm is required to deploy DeepSeek Harness."
        exit 1
    fi

    if ! ensure_node_runtime; then
        log_error "A valid Node.js runtime (>= 22) is required for DeepSeek Harness."
        exit 1
    fi

    # Explicit so the logged command matches the one `update` issues: the two
    # paths cannot drift apart.
    if ! pnpm add -g @deepseek-ai/dsh@latest; then
        log_error "DeepSeek Harness global package installation failed."
        exit 1
    fi

    log_success "DeepSeek Harness installed successfully."
}

configure_fd_alias() {
    if command_exists fdfind && ! command_exists fd; then
        log_info "Creating compatibility alias 'fd' -> 'fdfind' in ~/.local/bin..."
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi
}

configure_gpg() {
    log_step "Securing GnuPG Environment"

    local gpg_home="$XDG_DATA_HOME/gnupg"
    local owner="${SUDO_USER:-$(whoami)}"

    mkdir -p "$gpg_home"
    chown -R "$owner" "$gpg_home"
    chmod 700 "$gpg_home"

    local agent_conf="$gpg_home/gpg-agent.conf"
    if [[ ! -f "$agent_conf" ]]; then
        local pinentry_program=""
        for candidate in pinentry-mac pinentry-curses pinentry; do
            if command_exists "$candidate"; then
                pinentry_program="$(command -v "$candidate")"
                break
            fi
        done

        if [[ -n "$pinentry_program" ]]; then
            cat <<EOF > "$agent_conf"
# Managed by dotfiles manager.sh
# Pinentry program for GPG passphrase prompts (TUI/CLI friendly)
pinentry-program $pinentry_program
EOF
            chown "$owner" "$agent_conf"
            log_success "Generated $agent_conf (pinentry: $pinentry_program)"

            if command_exists gpgconf; then
                gpgconf --kill gpg-agent >/dev/null 2>&1 || true
                log_info "Reloaded gpg-agent daemon."
            fi
        else
            log_warn "No supported pinentry binary detected. GPG signing in TUI may block."
        fi
    else
        log_info "$agent_conf already exists; retaining existing configuration."
    fi
}
