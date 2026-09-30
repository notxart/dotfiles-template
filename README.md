# My Personal Dotfiles for Bash

This repository serves as a robust, modular boilerplate for a modern development
workflow: bash configuration, hardened git configuration with GPG signing, an
optional AI-assisted review toolchain, and a manager that installs and
reconciles all of it. The setup is designed to be portable, maintainable, and
strictly compliant with the XDG Base Directory Specification.

![Screenshot](https://i.postimg.cc/FzqLSLXP/Screenshot.png)

## 📁 Repository layout

| Path | What it is |
| --- | --- |
| `manager.sh` | The only entry point: `install`, `update`, `config`. |
| `lib/` | The implementation, one module per concern: registry and links, scan, migration, packages, tools, update, config reconciliation. |
| `config/` | The master copy of every managed file — bash, git ([config.ini](config/git/config.ini) + global hooks), vim, starship, and the optional hunk/lazygit configs. |
| `skills/` | Agent skills. **The canonical location**; `$DSH_HOME/skills/` holds links to these files. |
| `docs/` | [git-guide.md](docs/git-guide.md), [github-flow.md](docs/github-flow.md), [config-sync.md](docs/config-sync.md). |
| `check.sh` | The acceptance matrix — see [Verifying the manager itself](#verifying-the-manager-itself). |
| `AGENTS.md` | The rules an AI agent working here loads automatically. |
| `$XDG_STATE_HOME/dotfiles/` | The manifest and the backups. Written on your machine, never in this repository. |

## ✨ Features

- **Modern Prompt**: Styled with [Starship](https://starship.rs/), providing rich, context-aware information.
- **Enhanced Shell Experience**: Powered by [ble.sh](https://github.com/akinomyoga/ble.sh) for syntax highlighting, auto-suggestions, and an advanced line editor with Vi mode.
- **Fuzzy Search Everywhere**: [fzf](https://github.com/junegunn/fzf) integration for blazing-fast history search (Ctrl+R) and file finding.
- **Smart Directory Navigation**: [zoxide](https://github.com/ajeetdsouza/zoxide) learns your habits, allowing you to jump to frequent directories with short commands.
- **XDG Compliance**: Keeps your `$HOME` directory clean by storing configuration, data, and cache files in standard locations (`~/.config`, `~/.local/share`, etc.). No `.vimrc`, no `~/.dsh` — even Vim, DeepSeek Harness, and the Hunk standalone fallback follow XDG (`$XDG_DATA_HOME/hunk`).
- **Multi-Identity Git**: Easily manage work and personal Git profiles using conditional includes.
- **Hardened Git**: `help.autocorrect = prompt`, double-lease safe force push (`git pf`), worktree-aware branch cleanup (`git bclean`), global hooks with `.local` chaining, GPG signing with TUI-friendly pinentry.
- **AI Git Workflow (optional)**: A non-blocking Human-in-the-Loop flow — the agent drafts commit messages into `.git/AI_COMMIT_MSG`, the `prepare-commit-msg` hook injects them, and you review + GPG-sign. Review diffs in [Hunk](https://github.com/modem-dev/hunk) or [lazygit](https://github.com/jesseduffield/lazygit).
- **Automated Setup**: One entry point, three jobs — `install` provisions the machine, `update` keeps the toolchain current, `config` reconciles `~/.config` with the repository. Supports Debian/Ubuntu, Fedora, Arch Linux, and macOS.
- **Nothing to lose**: `install` never moves or overwrites a file. Conflicts are reported and left for a decision, and `config sync` asks before it replaces anything. See [docs/config-sync.md](docs/config-sync.md).

## 🚀 Installation

To ensure you can manage your own configurations and sync them across your machines, **do not clone this repository directly**. Instead, follow the steps below to create your own copy.

1. **Create Your Repository**

    Click the ![Use this template](https://custom-icon-badges.demolab.com/badge/Use_this_template-238636) button on GitHub to generate a new repository from this template. This detaches your dotfiles from the upstream, allowing you to push changes and maintain your own version.

2. **Clone and Install**

    Once you have your own repository, clone it to your local machine. It is recommended to clone into `~/dotfiles` to keep your home directory organized.

    1. Clone your repository. (Replace `<YOUR_USERNAME>` with your actual GitHub username)

        ```sh
        git clone https://github.com/<YOUR_USERNAME>/dotfiles.git ~/dotfiles
        ```

    2. Navigate to the directory and install.

        ```sh
        cd ~/dotfiles
        ./manager.sh install
        ```

        Optional flags:

        | Flag | Installs |
        | --- | --- |
        | `--with-git-tui` | Git TUI tools: **hunk** (via pnpm, or the official binary as fallback) + **lazygit** (package manager, or `gh release download` as fallback) + their configs (`~/.config/hunk`, `~/.config/lazygit`) |
        | `--with-dsh` | **DeepSeek Harness** via pnpm (`dsh` command) + symlinks the agent-agnostic `skills/` bundle (`git-commit-architect`, `git-pr-architect`) into `$DSH_HOME/skills` |

        Flags are independent and combinable: `./manager.sh install --with-git-tui --with-dsh`.

        > **Starship Installation**: The installer prioritizes installing starship via your system's package manager. If your distribution is older (e.g., Debian 12, Ubuntu 24.04) and does not include Starship in its repositories, the script will automatically fallback to the official Starship installer script. No manual action is required.

    The install will:
    1. Install necessary dependencies (starship, fzf, zoxide, gh, pinentry, pnpm, etc.) via your system's package manager and the pnpm standalone installer. System packages are best effort — one unavailable name cannot abort the rest.
    2. Create the symlinks whose destinations are free, and record each one in the manifest.
    3. **Leave everything else alone.** A path that already holds a real file is reported, not replaced; `./manager.sh config sync` is where those get resolved, one decision at a time.

3. **Restart Shell**

    Open a new terminal window or run `source ~/.bashrc` to apply the changes.

4. **Reconcile (only if step 2 reported paths it left alone)**

    ```sh
    ./manager.sh config status   # read-only summary
    ./manager.sh config sync     # walks you through what differs
    ```

    On a machine that already had dotfiles, this is where you decide what wins.
    Nothing is replaced without a confirmation and a backup — see
    [docs/config-sync.md](docs/config-sync.md).

### Coming from `./install.sh`

`install.sh` no longer exists: it was a shim that translated the old invocation
style, and the entry point is `manager.sh` with an explicit subcommand. Every old
command has an exact equivalent.

| Old | New |
| --- | --- |
| `./install.sh` | `./manager.sh install` |
| `./install.sh --with-git-tui --with-dsh` | `./manager.sh install --with-git-tui --with-dsh` |
| *nothing* | `./manager.sh update` — bring the toolchain up to date |
| *nothing* | `./manager.sh config status` / `sync` / `adopt` / `ignore` / `restore` |

Three behaviours changed with it, and they are the point of the rewrite:

| | Old `install.sh` | Now |
| --- | --- | --- |
| A conflicting file | Moved it to `~/.dotfiles_backup_<timestamp>/` and replaced it with a symlink | Reported and left untouched; `config sync` asks first |
| Backups | `~/.dotfiles_backup_<timestamp>/<basename>` — one directory per run, never pruned, basename collisions possible | `$XDG_STATE_HOME/dotfiles/backups/<timestamp>/…` mirroring `$HOME`, newest ten runs kept |
| Directory symlinks | `~/.config/<tool>` → `repo/config/<tool>`, so an app writing there wrote into the repository | File-level links only; `~/.config/<tool>/` is a real directory |

An existing machine that ran the old installer keeps working: `manager.sh install`
detects the old directory symlinks and offers to convert them to real directories
with file-level links inside, before creating anything new.

## ✅ Requirements

- **Git >= 2.37** (config floors: `autoSetupRemote` 2.37, `zdiff3` 2.35, `autocorrect=prompt` 2.34, `branch --format` 2.31, `--force-if-includes` 2.30).
- **GPG key** — `commit.gpgSign = true` requires a key. Replace the placeholder `[user] signingkey` in `config/git/config.ini` before your first commit, or every commit will fail.
- **Distros**: Debian >= bookworm, Fedora, Arch Linux, macOS (Homebrew). Older distros may lack native `gh`/`lazygit` packages; those fall back to `gh release download` and then to the GitHub API.
- **pnpm 12** is installed as a Node.js-free standalone binary, pinned to the major (`PNPM_VERSION=12`, which the installer resolves through the `latest-12` dist-tag; override with `PNPM_VERSION=<version> ./manager.sh install`). Node.js itself is provisioned on demand by pnpm (`pnpm runtime`, requires pnpm >= 11) only when the AI toolchain needs it — no system Node, no nvm. The floor is Node 22, which is what `hunkdiff` declares.
- **Credentials** — `config/git/config.ini` sets `credential.helper = !gh auth git-credential`, so HTTPS credentials come from the GitHub CLI's keyring and never from a file in this repository. Run `gh auth login` once. `manager.sh config status` warns if a token or a plaintext `helper = store` ever appears in the tracked config.
- **Vim >= 9.0** (optional) — commit messages are formatted by `config/git/wrap-msg.sh`, which is set as `core.editor`; `config/vim/vimrc` adds a rewrap on save for the `gitcommit` filetype. An existing `~/.vimrc` takes precedence over that XDG path and would disable the save-time rewrap — merge or remove it (the installer warns you). The `core.editor` formatting does not depend on Vim.
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

Then, run `./manager.sh install` again to create the link for the new file. With
file-level links a new `rc.d` script needs a link of its own — the directory is a
real directory now, precisely so that an application writing into `~/.config`
cannot write into this repository.

### Keeping the toolchain current

```sh
./manager.sh update                 # everything this machine opted into
./manager.sh update --dry-run       # what it would do, changing nothing
./manager.sh update --only hunk     # one tool
```

Tools installed by a package manager are reported rather than shadowed, and no
password is ever requested: `update` runs a whole toolchain in a row, so a prompt
arriving in the middle of it would have no context.

### Verifying the manager itself

`./check.sh` runs the manager against a throwaway `$HOME` (created under
`.sandbox-e2e/`, which is gitignored), so nothing on your own machine is
touched: `sudo`, `apt-get`, the network and every tool the manager would install
are stubs that record what they were asked to do instead of doing it.

```sh
./check.sh            # the acceptance matrix; exits non-zero on failure
./check.sh --report   # one install, then a report to read; exits 0
./check.sh --lint     # shellcheck over the source tree (needs shellcheck)
```

`--lint` is opt-in on purpose: shellcheck is a contributor tool, not something
this project needs, so a host that has never installed it still runs the matrix.
It prints the shellcheck version and exits non-zero on any finding.

`--report` is for looking: it leaves `report.txt` holding the resulting links, the
entries directly under `~/.config`, the skill destinations, any symlink left
inside the repository, and everything written under `~/.local`. Without a flag
the script asserts instead, walking fourteen scenarios in order — a fresh
install, an idempotent second install, an application's own file surviving, an
interrupted link being repaired, the legacy directory-symlink migration, loop
detection, every `config sync` verdict, a refused install when the manager and
shell disagree, orphaned records, the manifest round-trip, the no-terminal
refusal, and the seeded-file contract — plus the guards that keep the
commit-message formatter honest.

> [!NOTE]
> An agent working in this repository is told to run `./check.sh` before claiming
> a change works: that instruction lives in [AGENTS.md](AGENTS.md), which DSH
> loads automatically from the project root. It also records the two mistakes
> that are easy to make here — committing on the user's behalf, and overwriting
> the identity values in `config/git/config.ini`.

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
  commit formatting (`config/git/wrap-msg.sh`, set as `core.editor`, so it also
  covers `--amend` and `rebase -i`, which never run the hook), TUI-friendly GPG
  pinentry. Everything is inert by default: without an agent writing
  `.git/AI_COMMIT_MSG` and without repo-local `.local` hooks, nothing changes
  behavior.
- **Optional flags**: `--with-git-tui` (hunk + lazygit Git TUI tools) and
  `--with-dsh` (DeepSeek Harness + skill symlink). The skill itself lives at
  the repo-root `skills/` and is agent-agnostic — any agent tool can read it.

See [docs/git-guide.md](docs/git-guide.md) (configuration reference) and
[docs/github-flow.md](docs/github-flow.md) (step-by-step workflow, including
the AI-assisted HITL flow).

**Write messages unwrapped.** One paragraph per line, one bullet per line — no
line breaks of your own, as an author or as an agent. The tooling decides where
the breaks go, and it is idempotent, so a break you insert by hand is not undone:
it is kept and re-wrapped around. `./check.sh` asserts that the hook and
`core.editor` produce byte-identical output, that the formatter is idempotent,
and that a message it rejects is still left intact.

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

`manager.sh install` automatically detects if you are running inside WSL and attempts to retrieve your Windows User Profile path to enable integration with tools like VS Code (`code`).

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
git add -p            # stage hunks selectively (alias: git ap)
git commit            # opens the editor: formats the message, injects any AI draft
git push
```

Stage **by name** (`git add <path>`, or `git add -p`), never `git add .`: this
repository's whole job is deciding what is tracked, and a blanket add is how a
`.local` file, a state cache or a secret gets committed. `git commit -m "..."`
skips both the formatter and the AI draft — it is fine for a one-line message
you have already kept under 50 characters, but plain `git commit` is the path
that formats. Automation should stay on `-m`: with no terminal and no editor
configured, the formatter refuses rather than starting an editor that would
block.

A configuration file that lives on the machine rather than in the repository can
be brought under version control without moving it by hand:

```sh
./manager.sh config adopt ~/.config/starship.toml
```

On a new machine, repeat the Installation steps with your repository URL, then
`./manager.sh config sync` to reconcile anything the machine already had.
