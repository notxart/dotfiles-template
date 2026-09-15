#!/usr/bin/env bash

# ==============================================================================
# Dotfiles Installation Script
#
# Description:
#   Configures user development environment, resolves dependencies with version
#   constraints, and links dotfiles compliant with XDG Base Directory specs.
#
# Usage:
#   ./install.sh [--with-git-tui] [--with-dsh] [--help]
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. Constants & Global State
# ==============================================================================

# Script Metadata
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Color Palette (POSIX compliant formatting)
readonly CLR_RESET="\033[0m"
readonly CLR_BLUE="\033[1;34m"
readonly CLR_GREEN="\033[1;32m"
readonly CLR_YELLOW="\033[1;33m"
readonly CLR_RED="\033[1;31m"
readonly CLR_MUTED="\033[0;37m"

# Feature Flags
FLAG_GIT_TUI=0
FLAG_WITH_DSH=0

# Shell guidance shown in the installer's final message when the user's login
# shell is not bash (set by ensure_bash_shell; empty = keep the default message).
BASH_SHELL_GUIDANCE=""

# Dynamic Environment & Package Manager State
PM_STRATEGY=""
PM_UPDATE_CMD=()
PM_INSTALL_CMD=()
SORT_CMD="sort"
DISTRO_PKGS=()

# Resource Management State
TMP_DIRS=()
BACKUP_DIR=""

# ==============================================================================
# 2. Cleanup & Signal Lifecycle Management
# ==============================================================================

cleanup() {
    local exit_code=$?
    # Prevent recursive signal handling during termination
    trap - EXIT INT TERM HUP

    for dir in "${TMP_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
        fi
    done

    exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

create_temp_dir() {
    local tmp
    tmp="$(mktemp -d)"
    TMP_DIRS+=("$tmp")
    printf '%s\n' "$tmp"
}

# ==============================================================================
# 3. Logging & Terminal Output
# ==============================================================================

log_step()    { printf "\n${CLR_BLUE}❯❯❯ %s${CLR_RESET}\n" "$1"; }
log_info()    { printf "  ${CLR_MUTED}%s${CLR_RESET}\n" "$1"; }
log_success() { printf "  ${CLR_GREEN}✓ %s${CLR_RESET}\n" "$1"; }
log_warn()    { printf "  ${CLR_YELLOW}⚠ %s${CLR_RESET}\n" "$1"; }
log_error()   { printf "\n${CLR_RED}Error: %s${CLR_RESET}\n" "$1" >&2; }

# ==============================================================================
# 4. System & Version Utilities
# ==============================================================================

command_exists() { command -v "$1" >/dev/null 2>&1; }

init_version_sorter() {
    if sort --version-sort </dev/null >/dev/null 2>&1; then
        SORT_CMD="sort"
    elif command_exists gsort; then
        SORT_CMD="gsort"
    else
        SORT_CMD="sort"
        if [[ "$PM_STRATEGY" == "brew" ]]; then
            log_warn "GNU sort not found. 'coreutils' should be installed for accurate version sorting."
        fi
    fi
}

compare_versions_lt() {
    local v1="$1"
    local v2="$2"

    [[ -z "$v1" ]] && return 0
    [[ "$v1" == "$v2" ]] && return 1

    local smallest
    smallest=$(printf '%s\n%s\n' "$v1" "$v2" | $SORT_CMD -V | head -n1)
    [[ "$smallest" == "$v1" ]]
}

get_installed_version() {
    local cmd="$1"
    local local_bin="$HOME/.local/bin/$cmd"
    local target_cmd="$cmd"

    if [[ -x "$local_bin" ]]; then
        target_cmd="$local_bin"
    elif ! command_exists "$cmd"; then
        return 1
    fi

    local output
    output=$(LC_ALL=C "$target_cmd" --version 2>&1 | head -n1)

    case "$cmd" in
        starship) awk '{print $2}' <<< "$output" ;;
        fzf)      awk '{print $1}' <<< "$output" ;;
        lazygit)
            # Format: "..., version='0.50.0+ds1', ..., git version=2.47.3" -> "0.50.0"
            # Target the isolated 'version=' field and ignore trailing 'git version='
            grep -oE '(^|,)[[:space:]]*version=[^,]+' <<< "$output" \
                | grep -oE '[0-9]+(\.[0-9]+)+' \
                | head -n1
            ;;
        *)        awk '{print $NF}' <<< "$output" ;;
    esac
}

get_candidate_version() {
    local pkg="$1"
    local version=""

    case "$PM_STRATEGY" in
        apt)
            version=$(LC_ALL=C apt-cache policy "$pkg" 2>/dev/null | grep 'Candidate:' | awk '{print $2}' | cut -d- -f1)
            ;;
        dnf)
            version=$(LC_ALL=C dnf info --available "$pkg" 2>/dev/null | grep '^Version' | head -n1 | awk '{print $3}' | cut -d: -f2)
            ;;
        pacman)
            version=$(LC_ALL=C pacman -Si "$pkg" 2>/dev/null | grep '^Version' | awk '{print $3}' | cut -d- -f1)
            ;;
        brew)
            version=$(LC_ALL=C brew info "$pkg" 2>/dev/null | head -n1 | awk '{print $4}')
            ;;
    esac

    printf '%s\n' "$version" | xargs
}

# ==============================================================================
# 5. Environment & Package Manager Detection
# ==============================================================================

init_xdg_env() {
    log_step "Initializing XDG Environment & Paths"

    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
    export PNPM_HOME="${PNPM_HOME:-$XDG_DATA_HOME/pnpm}"

    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$HOME/.local/bin" "$PNPM_HOME"

    # Inject paths into the current execution subshell immediately
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    if [[ ":$PATH:" != *":$PNPM_HOME/bin:"* && -d "$PNPM_HOME/bin" ]]; then
        export PATH="$PNPM_HOME/bin:$PATH"
    fi

    log_success "XDG Base Directories and Execution Paths prepared."
}

detect_environment() {
    if ! command_exists sudo && ! command_exists brew; then
        log_error "Administrator privileges (sudo) or Homebrew are required."
        exit 1
    fi

    if command_exists sudo; then
        sudo -v
    fi

    if command_exists apt-get; then
        PM_STRATEGY="apt"
        PM_UPDATE_CMD=("sudo" "apt-get" "update")
        PM_INSTALL_CMD=("sudo" "apt-get" "install" "-y")
        DISTRO_PKGS=("build-essential" "fd-find" "gh" "pinentry-curses" "libatomic1")
    elif command_exists dnf; then
        PM_STRATEGY="dnf"
        PM_UPDATE_CMD=("sudo" "dnf" "makecache")
        PM_INSTALL_CMD=("sudo" "dnf" "install" "-y")
        DISTRO_PKGS=("@development-tools" "fd-find" "gh" "pinentry" "libatomic")
    elif command_exists pacman; then
        PM_STRATEGY="pacman"
        PM_UPDATE_CMD=("sudo" "pacman" "-Sy")
        PM_INSTALL_CMD=("sudo" "pacman" "-S" "--noconfirm" "--needed")
        DISTRO_PKGS=("base-devel" "fd" "github-cli" "pinentry")
    elif command_exists brew; then
        PM_STRATEGY="brew"
        PM_UPDATE_CMD=("brew" "update")
        PM_INSTALL_CMD=("brew" "install")
        DISTRO_PKGS=("coreutils" "fd" "gh" "pinentry-mac")
    else
        log_error "Unsupported OS. Could not detect apt, dnf, pacman, or brew."
        exit 1
    fi

    log_info "Package Manager Strategy: $PM_STRATEGY"
}

# ==============================================================================
# 6. Tool Provisioning & Fallbacks
# ==============================================================================

install_base_packages() {
    log_step "Installing Base System Packages"

    local pkgs=(curl gawk git gnupg2 man-db ripgrep vim zoxide)
    if [[ ${#DISTRO_PKGS[@]} -gt 0 ]]; then
        pkgs+=("${DISTRO_PKGS[@]}")
    fi

    log_info "Updating repository indexes..."
    "${PM_UPDATE_CMD[@]}"

    log_info "Installing: ${pkgs[*]}"
    "${PM_INSTALL_CMD[@]}" "${pkgs[@]}"

    init_version_sorter
    log_success "Base system packages installed successfully."
}

ensure_tool_version() {
    local cmd="$1"
    local pkg="$2"
    local req_ver="$3"
    local fallback_fn="$4"
    local current_ver=""
    local candidate_ver=""

    log_step "Checking Requirement: $cmd (>= $req_ver)"

    # Step 1: Check existing local binary
    if command_exists "$cmd"; then
        current_ver=$(get_installed_version "$cmd")
        if ! compare_versions_lt "$current_ver" "$req_ver"; then
            log_success "Local $cmd version ($current_ver) satisfies constraint."
            return 0
        fi
        log_warn "Local $cmd version ($current_ver) is outdated."
    fi

    # Step 2: Check repository candidate
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

    # Step 3: Trigger safe dynamic fallback
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
    if command_exists node; then
        local node_major
        node_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
        if [[ -n "$node_major" ]] && [[ "$node_major" -ge 18 ]] 2>/dev/null; then
            log_success "Node.js $(node --version 2>/dev/null) detected (>= 18)."
            return 0
        fi
        log_warn "Detected Node.js $(node --version 2>/dev/null || printf 'unknown') is older than 18."
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
}

install_lazygit_fallback() {
    log_info "Fetching Lazygit release binary from GitHub..."

    local os arch
    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="darwin" ;;
        *) log_error "Unsupported OS for Lazygit manual build."; exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="x86_64" ;;
        aarch64|arm64)  arch="arm64" ;;
        *) log_error "Unsupported CPU architecture for Lazygit manual build."; exit 1 ;;
    esac

    local release_url
    release_url="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
        | grep -oE "\"browser_download_url\": \"[^\"]*lazygit_[0-9.]+_${os}_${arch}\\.tar\\.gz\"" \
        | head -n1 | cut -d'"' -f4)"

    if [[ -z "$release_url" ]]; then
        log_error "Failed to resolve Lazygit release artifact URL for ${os}_${arch}."
        exit 1
    fi

    local tmp_dir
    tmp_dir="$(create_temp_dir)"

    curl -fsSL "$release_url" -o "$tmp_dir/lazygit.tar.gz" || { log_error "Lazygit download failed."; exit 1; }
    tar -xzf "$tmp_dir/lazygit.tar.gz" -C "$tmp_dir" || { log_error "Lazygit extraction failed."; exit 1; }

    mkdir -p "$HOME/.local/bin"
    install -m 755 "$tmp_dir/lazygit" "$HOME/.local/bin/lazygit"
    log_success "Lazygit installed to ~/.local/bin/lazygit"
}

install_pnpm() {
    log_step "Verifying pnpm Infrastructure (Standalone Native)"

    local pnpm_version="${PNPM_VERSION:-12.0.0-rc.9}"

    if command_exists pnpm; then
        local existing_pnpm_version
        existing_pnpm_version="$(pnpm --version 2>/dev/null || true)"
        log_success "pnpm is already accessible: ${existing_pnpm_version:-unknown}"
        # `pnpm runtime` (see ensure_node_runtime) requires pnpm >= 11.
        if [[ -n "$existing_pnpm_version" ]] && compare_versions_lt "$existing_pnpm_version" "11"; then
            log_warn "Existing pnpm $existing_pnpm_version is below 11 — 'pnpm runtime' may be unavailable."
        fi
        return 0
    fi

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
        log_error "A valid Node.js runtime (>= 18) is required for DeepSeek Harness."
        exit 1
    fi

    if ! pnpm add -g @deepseek-ai/dsh; then
        log_error "DeepSeek Harness global package installation failed."
        exit 1
    fi

    log_success "DeepSeek Harness installed successfully."
}

check_git_version() {
    log_step "Validating Git Feature Constraints"
    local ver
    ver=$(get_installed_version "git")

    if [[ -z "$ver" ]]; then
        log_error "Git binary missing from environment."
        exit 1
    fi

    if compare_versions_lt "$ver" "2.37"; then
        log_warn "Git $ver detected. Dotfiles configuration requires Git >= 2.37:"
        log_info "- push.autoSetupRemote (2.37), merge.conflictstyle=zdiff3 (2.35)"
        log_info "- help.autocorrect=prompt (2.34), push --force-if-includes (2.30)"
        log_warn "Please upgrade Git. Some configurations will degrade silently."
    else
        log_success "Git $ver satisfies requirements (>= 2.37)."
    fi
}

# ==============================================================================
# 7. Dotfiles, Symlinks & Environment Configuration
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
# Managed by dotfiles install.sh
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

configure_fd_alias() {
    if command_exists fdfind && ! command_exists fd; then
        log_info "Creating compatibility alias 'fd' -> 'fdfind' in ~/.local/bin..."
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi
}

# ==============================================================================
# 7.5 Login Shell & Bash Version Management
# ==============================================================================

# macOS ships /bin/bash 3.2 (Apple froze it under GPLv3) while ble.sh
# recommends Bash >= 4.0 — auto-complete and menu-filter are 4.0+ features.
# The installer never replaces /bin/bash: Homebrew's bash installs in parallel
# at $(brew --prefix)/bin/bash. The login shell is switched automatically ONLY
# when it is the system /bin/bash; zsh/fish/other login shells are never
# touched — those users get a one-time manual hint in the final message
# instead (BASH_SHELL_GUIDANCE). Everything here stays Bash-3.2-compatible on
# purpose: this installer itself may be running under /bin/bash 3.2 on macOS.

get_login_shell() {
    local user="${SUDO_USER:-$(whoami)}"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}'
    else
        getent passwd "$user" 2>/dev/null | cut -d: -f7
    fi
}

# macOS only: one-time login-shell switch with verification. The /etc/shells
# append may be silently rejected (SIP/permissions), so verify with grep
# before chsh, then re-verify the result via dscl. Failures degrade to a
# manual instruction set in BASH_SHELL_GUIDANCE instead of exiting.
switch_login_shell() {
    local target="$1" current="$2" user="${SUDO_USER:-$(whoami)}" verify

    log_info "Switching login shell $current -> $target ..."
    if ! grep -qxF "$target" /etc/shells 2>/dev/null; then
        sudo sh -c "printf '%s\n' '$target' >> /etc/shells" 2>/dev/null || true
    fi
    if ! grep -qxF "$target" /etc/shells 2>/dev/null; then
        log_warn "Could not add $target to /etc/shells (permissions/SIP may block it)."
        BASH_SHELL_GUIDANCE="Add '$target' to /etc/shells and switch (one-time): sudo sh -c 'echo \"$target\" >> /etc/shells' && sudo chsh -s \"$target\" \"$user\""
        return 1
    fi

    if sudo chsh -s "$target" "$user" 2>/dev/null; then
        verify="$(dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{print $2}')"
        if [[ "$verify" == "$target" ]]; then
            log_success "Login shell switched to $target (takes effect in new terminal windows)."
            BASH_SHELL_GUIDANCE=""
        else
            log_warn "chsh reported success but the shell is still '${verify:-unknown}'."
            BASH_SHELL_GUIDANCE="Finish the shell switch manually (one-time): sudo chsh -s \"$target\" \"$user\", then open a new terminal."
        fi
    else
        log_warn "chsh failed (sudo prompt interrupted or unavailable)."
        BASH_SHELL_GUIDANCE="Switch manually (one-time): sudo sh -c 'echo \"$target\" >> /etc/shells' && sudo chsh -s \"$target\" \"$user\", then open a new terminal."
        return 1
    fi
}

ensure_bash_shell() {
    local login_shell brew_bash="" brew_major bash_path

    BASH_SHELL_GUIDANCE=""
    login_shell="$(get_login_shell)"
    [[ -z "$login_shell" ]] && login_shell="${SHELL:-}"

    # --- macOS + Homebrew: make sure the current Homebrew bash is present ---
    if [[ "$(uname -s)" == "Darwin" && "$PM_STRATEGY" == "brew" ]]; then
        brew_bash="$(brew --prefix)/bin/bash"

        # The installer runs with the user's interactive bash; if that is
        # still the ancient 3.2, install Homebrew bash (idempotent).
        if [[ ${BASH_VERSINFO[0]} -lt 4 ]] && [[ "$login_shell" != "$brew_bash" ]]; then
            log_step "Upgrading Bash for ble.sh (system bash is 3.2; ble.sh recommends >= 4.0)"
            "${PM_INSTALL_CMD[@]}" bash
        fi

        if [[ -x "$brew_bash" ]]; then
            brew_major="$("$brew_bash" -c 'echo ${BASH_VERSINFO[0]}')"
            if [[ "$brew_major" -ge 4 ]]; then
                log_success "Homebrew Bash $("$brew_bash" -c 'echo ${BASH_VERSION}') installed at $brew_bash"
            else
                brew_bash=""
                log_warn "Homebrew Bash at $brew_bash is below 4.0; ble.sh auto-complete/menu-filter will degrade."
            fi
        else
            brew_bash=""
            log_warn "Homebrew Bash not found ('brew install bash' may have failed)."
        fi
    fi

    # --- Cross-platform login-shell classification for the final message ---
    case "$login_shell" in
        *bash*)
            if [[ -n "$brew_bash" && "$login_shell" != "$brew_bash" ]]; then
                # macOS + login shell is the system /bin/bash (3.2): auto-switch.
                switch_login_shell "$brew_bash" "$login_shell"
            elif [[ "$(uname -s)" == "Darwin" && -z "$brew_bash" ]]; then
                # macOS + /bin/bash but brew bash unavailable: loud manual fix.
                BASH_SHELL_GUIDANCE="Homebrew bash could not be installed/verified; ble.sh features degrade on Bash 3.2. Fix (one-time): brew install bash && sudo sh -c 'echo \"$(brew --prefix)/bin/bash\" >> /etc/shells' && sudo chsh -s \"$(brew --prefix)/bin/bash\" \"${SUDO_USER:-$(whoami)}\""
            fi
            ;;
        "")
            BASH_SHELL_GUIDANCE="Could not detect your login shell; this setup only applies under bash. Set your login shell to bash (chsh) before restarting."
            ;;
        *)
            # zsh / fish / sh / other: never touch it, only guide.
            if [[ -n "$brew_bash" ]]; then
                BASH_SHELL_GUIDANCE="Your login shell is $login_shell; this setup only activates under bash. Switch (one-time): sudo sh -c 'echo \"$brew_bash\" >> /etc/shells' && sudo chsh -s \"$brew_bash\" \"${SUDO_USER:-$(whoami)}\", then open a new terminal."
            else
                bash_path="$(command -v bash)"
                if [[ -z "$bash_path" ]]; then
                    BASH_SHELL_GUIDANCE="Bash not found on PATH; this setup requires bash."
                elif grep -qxF "$bash_path" /etc/shells 2>/dev/null; then
                    BASH_SHELL_GUIDANCE="Your login shell is $login_shell; this setup only activates under bash. Switch (one-time): sudo chsh -s \"$bash_path\" \"${SUDO_USER:-$(whoami)}\", then open a new terminal."
                else
                    BASH_SHELL_GUIDANCE="Your login shell is $login_shell; this setup only activates under bash. Switch (one-time): sudo sh -c 'echo \"$bash_path\" >> /etc/shells' && sudo chsh -s \"$bash_path\" \"${SUDO_USER:-$(whoami)}\", then open a new terminal."
                fi
            fi
            ;;
    esac
}

# ==============================================================================
# 8. Command-Line Interface & Orchestration
# ==============================================================================

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --with-git-tui  Install hunk, lazygit, and link their configurations.
  --with-dsh      Install DeepSeek Harness via pnpm and link skills.
  -h, --help      Display this help documentation.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-git-tui)
                FLAG_GIT_TUI=1
                log_info "Option enabled: Git TUI Review Stack"
                shift
                ;;
            --with-dsh)
                FLAG_WITH_DSH=1
                log_info "Option enabled: DeepSeek Harness"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_warn "Ignoring unrecognized argument: $1"
                shift
                ;;
        esac
    done
}

main() {
    log_step "Dotfiles Setup Initialized"

    parse_args "$@"
    init_xdg_env
    detect_environment
    install_base_packages
    ensure_bash_shell
    check_git_version
    install_pnpm

    # Version Enforcement Verification
    ensure_tool_version "fzf" "fzf" "0.60" "install_fzf_fallback"
    ensure_tool_version "starship" "starship" "1.20.0" "install_starship_fallback"

    if [[ "$FLAG_GIT_TUI" -eq 1 ]]; then
        ensure_tool_version "hunk" "hunk" "0.19.0" "install_hunk_fallback"
        ensure_tool_version "lazygit" "lazygit" "0.44.0" "install_lazygit_fallback"
    fi

    if [[ "$FLAG_WITH_DSH" -eq 1 ]]; then
        install_dsh
    fi

    configure_fd_alias
    setup_symlinks
    configure_gpg

    if [[ "$FLAG_GIT_TUI" -eq 0 || "$FLAG_WITH_DSH" -eq 0 ]]; then
        printf "\n"
        log_info "Tip: Run with '--with-git-tui' to enable the Lazygit/Hunk stack."
        log_info "     Run with '--with-dsh' to deploy the DeepSeek Harness ecosystem."
    fi

    log_step "Dotfiles Setup Completed Successfully"
    if [[ -n "$BASH_SHELL_GUIDANCE" ]]; then
        log_info "$BASH_SHELL_GUIDANCE"
    else
        log_info "Run 'source ~/.bashrc' or restart your terminal session to apply changes."
    fi
}

main "$@"
