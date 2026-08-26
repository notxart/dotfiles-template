# My Personal Dotfiles for Bash

This repository serves as a robust, modular boilerplate for Bash configuration files, optimized for a modern development workflow. The setup is designed to be portable, maintainable, and strictly compliant with the XDG Base Directory Specification.

![Screenshot](https://i.postimg.cc/FzqLSLXP/Screenshot.png)

## ✨ Features

- **Modern Prompt**: Styled with [Starship](https://starship.rs/), providing rich, context-aware information.
- **Enhanced Shell Experience**: Powered by [ble.sh](https://github.com/akinomyoga/ble.sh) for syntax highlighting, auto-suggestions, and an advanced line editor with Vi mode.
- **Fuzzy Search Everywhere**: [fzf](https://github.com/junegunn/fzf) integration for blazing-fast history search (Ctrl+R) and file finding.
- **Smart Directory Navigation**: [zoxide](https://github.com/ajeetdsouza/zoxide) learns your habits, allowing you to jump to frequent directories with short commands.
- **XDG Compliance**: Keeps your `$HOME` directory clean by storing configuration, data, and cache files in standard locations (`~/.config`, `~/.local/share`, etc.). No `.vimrc`, no `~/.dsh` — even Vim, DeepSeek Harness, and the Hunk standalone fallback follow XDG (`$XDG_DATA_HOME/hunk`).
- **Multi-Identity Git**: Easily manage work and personal Git profiles using conditional includes.
- **Hardened Git**: `help.autocorrect = prompt`, double-lease safe force push (`git pf`), worktree-aware branch cleanup (`git bclean`), global hooks with `.local` chaining, GPG signing with TUI-friendly pinentry.
- **AI Git Workflow (optional)**: A non-blocking Human-in-the-Loop flow — the agent drafts commit messages into `.git/AI_COMMIT_MSG`, the `prepare-commit-msg` hook injects them, and you review + GPG-sign. Review diffs in [Hunk](https://github.com/modem-dev/hunk) or [lazygit](https://github.com/jesseduffield/lazygit).
- **Automated Setup**: A single script to install tools and set up configurations across different systems (supports Debian/Ubuntu, Fedora, Arch Linux, and macOS).

## 🚀 Installation

To ensure you can manage your own configurations and sync them across your machines, **do not clone this repository directly**. Instead, follow the steps below to create your own copy.

1. **Create Your Repository**

    Click the ![Use this template](https://custom-icon-badges.demolab.com/badge/Use_this_template-238636) button on GitHub to generate a new repository from this template. This detaches your dotfiles from the upstream, allowing you to push changes and maintain your own version.

2. **Clone and Install**

    Once you have your own repository, clone it to your local machine. It is recommended to clone into `~/dotfiles` to keep your home directory organized.

    1. Clone your repository to a hidden directory. (Replace `<YOUR_USERNAME>` with your actual GitHub username)

        ```sh
        git clone https://github.com/<YOUR_USERNAME>/dotfiles.git ~/dotfiles
        ```

    2. Navigate to the directory.

        ```sh
        cd ~/dotfiles
        ```

    3. Execute the installation script.

        ```sh
        chmod u+x install.sh
        ./install.sh
        ```

        Optional flags:

        | Flag | Installs |
        | --- | --- |
        | `--with-git-tui` | Git TUI tools: **hunk** (via pnpm, or official binary as fallback) + **lazygit** (package manager, release tarball as fallback) + their configs (`~/.config/hunk`, `~/.config/lazygit`) |
        | `--with-dsh` | **DeepSeek Harness** via pnpm (`dsh` command) + symlinks the agent-agnostic `skills/` bundle (`git-commit-architect`, `git-pr-architect`) into `$DSH_HOME/skills` |

        Flags are independent and combinable: `./install.sh --with-git-tui --with-dsh`.

        > **Starship Installation**: The script prioritizes installing starship via your system's package manager. If your distribution is older (e.g., Debian 12, Ubuntu 24.04) and does not include Starship in its repositories, the script will automatically fallback to the official Starship installer script. No manual action is required.

    The script will:
    1. Install necessary dependencies (starship, fzf, zoxide, gh, pinentry, pnpm, etc.) via your system's package manager and the pnpm standalone installer.
    2. Back up any existing configuration files to `~/dotfiles_backup_<timestamp>`.
    3. Create symlinks from `~/dotfiles` to the appropriate locations (mostly `~/.config/`).

3. **Restart Shell**

    Open a new terminal window or run `source ~/.bashrc` to apply the changes.

## ✅ Requirements

- **Git >= 2.37** (config floors: `autoSetupRemote` 2.37, `zdiff3` 2.35, `autocorrect=prompt` 2.34, `branch --format` 2.31, `--force-if-includes` 2.30).
- **GPG key** — `commit.gpgSign = true` requires a key. Replace the placeholder `[user] signingkey` in `config/git/config.ini` before your first commit, or every commit will fail.
- **Distros**: Debian >= bookworm, Fedora, Arch Linux, macOS (Homebrew). Older distros may lack native `gh`/`lazygit` packages; the installer falls back to release tarballs.
- **pnpm 12** is installed as a Node.js-free standalone binary, pinned to `12.0.0-rc.9` — the first pnpm shipped as a Rust-built standalone binary, so no Node.js needs to be pre-installed (override the pin with `PNPM_VERSION=<version> ./install.sh`). Node.js itself is provisioned on demand by pnpm (`pnpm runtime`, requires pnpm >= 11) only when the AI toolchain needs it — no system Node, no nvm.
- **Vim >= 9.0** (optional) — commit messages wrap at 72 columns via `~/.config/vim/vimrc` (rewrapped automatically on save). An existing `~/.vimrc` takes precedence over that XDG path and would silently disable the wrapping — merge or remove it (the installer warns you).
- **Default XDG paths** — the global `core.hooksPath` in `config/git/config.ini` points to `~/.config/git/hooks` (git resolves relative `hooksPath` values against the worktree, not the config file). If you set a custom `XDG_CONFIG_HOME`, the installer warns you and prints the exact `git config --global core.hooksPath "$XDG_CONFIG_HOME/git/hooks"` command to run; the `includeIf` work profile is XDG-aware and needs no adjustment.
- **Login shell = Bash (recommended)** — this setup only activates under bash. macOS's system `/bin/bash` is 3.2 (frozen under GPLv3) while ble.sh recommends Bash >= 4.0 (`auto-complete`/`menu-filter` need 4.0+): on macOS the installer installs the current Homebrew `bash` (5.x) and **automatically switches your login shell when it is the system `/bin/bash`**; if your login shell is zsh/fish or the switch fails, the installer's final message shows the one-time manual steps. On Linux no automatic switch is ever performed — but if your login shell is not bash, the same final-message guidance appears (`sudo chsh -s "$(command -v bash)" ...`).

## 🔧 Customization

This setup is designed to be extensible without modifying the core files, preventing merge conflicts when you update the core logic.

### Adding Personal Aliases or Scripts

The proper way to add your own configurations is to create a new file in the `config/bash/rc.d/` directory. The scripts are loaded in ***lexicographical order***.

For example, create `config/bash/rc.d/99-local.sh`:

```sh
# My custom aliases
alias k="kubectl"

# My custom functions
my_func() {
  echo "Hello from my local config!"
}
```

Then, run `./install.sh` again to ensure symlinks are correct (though for `rc.d` files, no new symlinks are needed as the directory is already linked).

### Git Identity Setup

This template uses a split-config approach for Git to separate personal and work identities.

Both `[user]` blocks ship with **empty values on purpose**: until you fill them in, `git commit` is refused with a clear `empty ident` error — no commits can silently happen under a placeholder name.

1. **Primary (personal) identity** — edit the `[user]` section of `config/git/config.ini` (or run the equivalent `git config --global` commands):

   ```sh
   git config --global user.name "Your Name"
   git config --global user.email "you@example.com"
   gpg --full-generate-key                      # generate a key once
   git config --global user.signingkey <GPG fingerprint>
   ```

2. **Work identity** — fill in `config/git/work.ini` (created next to `config.ini`, i.e. `$XDG_CONFIG_HOME/git/work.ini`) with your company details:

   ```ini
   [user]
       name = Company Name
       email = you@company.com
       signingkey = <GPG fingerprint>
   ```

3. **Activation** — in `config/git/config.ini`, update the path in `[includeIf "gitdir:~/workspace/"]` to match your work projects directory.

> [!IMPORTANT]
> Any git repository inside `~/workspace/` (or your chosen path) will automatically use the configuration defined in `config/git/work.ini`. These are also empty until you fill them in — same refuse-to-commit behavior.

> [!TIP]
> To make GitHub trust your commits, export the public key: `gpg --armor --export <GPG fingerprint>` → GitHub → Settings → SSH and GPG keys → New GPG key.

### The AI Git Workflow (optional layer)

The workflow is split into two layers:

- **Core (always installed)**: hardened git config, global hooks
  (`prepare-commit-msg` AI-draft injection + `.local` dispatchers), 72-column
  commit wrapping (Vim `gitcommit`), TUI-friendly GPG pinentry. Everything is
  inert by default: without an agent writing `.git/AI_COMMIT_MSG` and without
  repo-local `.local` hooks, nothing changes behavior.
- **Optional flags**: `--with-git-tui` (hunk + lazygit Git TUI tools) and
  `--with-dsh` (DeepSeek Harness + skill symlink). The skill itself lives at
  the repo-root `skills/` and is agent-agnostic — any agent tool can read it.

See [docs/git-guide.md](docs/git-guide.md) (configuration reference) and
[docs/github-flow.md](docs/github-flow.md) (step-by-step workflow, including
the AI-assisted HITL flow).

### DeepSeek Harness home

The dotfiles relocate DSH's config root from `~/.dsh` to `$DSH_HOME`
(`~/.local/share/dsh`, exported by `config/bash/rc.d/00-xdg.sh`). If you have
an existing `~/.dsh`, migrate it once:

```sh
mkdir -p ~/.local/share/dsh && mv ~/.dsh/* ~/.local/share/dsh/
```

> [!NOTE]
> `DSH_HOME` is an environment variable — DSH launched from a shell picks it
> up automatically; desktop launchers that bypass the shell fall back to
> `~/.dsh`.

### WSL integration

The script automatically detects if you are running inside WSL and attempts to retrieve your Windows User Profile path to enable integration with tools like VS Code (`code`).

However, for this to work flawlessly while keeping your environment clean, it is recommended to disable the default Windows PATH appending in `/etc/wsl.conf` and allow Interop:

```toml
[interop]
enabled = true
appendWindowsPath = false
```

> [!NOTE]
> The `config/bash/rc.d/30-wsl.sh` script will explicitly add the necessary VS Code paths and aliases (like `explorer.exe`) only if Interop works, preventing errors if you have disabled it.

## 📦 Managing Your Dotfiles

Since you have cloned your own repository, you can now track changes to your configuration:

```sh
cd ~/dotfiles
git add .

# Replace `<COMMIT_MSG>` with your actual commit message, e.g., "feat: added new alias for kubectl"
git commit -m <COMMIT_MSG>

git push
```

On a new machine, simply repeat the Installation steps using your repository URL to synchronize your environment.
