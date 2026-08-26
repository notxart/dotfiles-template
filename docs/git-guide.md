# Strict Git Workflow Guide

This document outlines the required Git configuration and workflow patterns for
this project. We enforce a linear history, strict commit discipline, and
cryptographic signing to keep the repository maintainable and bisect-friendly.

## 0. Requirements

- **Git >= 2.37** — the shipped config relies on features with these floors:
  - `push.autoSetupRemote` (2.37), `merge.conflictstyle=zdiff3` (2.35),
    `help.autocorrect=prompt` (2.34), `git branch --format` (2.31),
    `push --force-if-includes` (2.30).
- **GPG key** — `commit.gpgSign = true` means every commit must be signed.
  Generate a key (`gpg --full-generate-key`) and put its fingerprint into
  `config/git/config.ini` (`[user] signingkey`) **before** your first commit;
  the template's placeholder key will fail otherwise.
- **Vim >= 9.0** (optional but recommended) — `~/.config/vim/vimrc` wraps
  commit messages at 72 columns via the `gitcommit` filetype.

## 1. Core Principles

- **Atomic Commits**: Each commit must do one thing and one thing only. Do not
  mix refactoring with feature additions.
- **Linear History**: We do not use merge commits for feature branches. We
  `rebase`.
- **Signed Commits**: All commits must be GPG signed to verify authorship.

## 2. Configuration Overview

The project includes a hardened `config/git/config.ini`. Key features:

- **Never auto-execute typos**: `help.autocorrect = prompt` (Git >= 2.34)
  requires explicit confirmation before running a corrected command. The old
  `10` (1-second auto-execute) is dangerous for destructive commands.
- **Global hooks path**: `core.hooksPath = ~/.config/git/hooks` — see the
  [Global Hooks](#3-global-hooks) section. Note that with `hooksPath` set,
  per-repo `.git/hooks/` are ignored; the shipped dispatchers re-enable them.
  The value is a fixed literal (git resolves relative `hooksPath` values
  against the worktree, not the config file), so a custom `XDG_CONFIG_HOME`
  triggers an installer warning with the exact `git config --global
  core.hooksPath ...` command to run.
- **GPG Signing**: `gpgSign = true` for both commits and tags.
- **Histogram Diff**: `diff.algorithm = histogram` is more aware of code
  structure than the default Myers algorithm.
- **Rebase on Pull**: `pull.rebase = true` prevents accidental merge bubbles.
- **Safe force push**: the `pf` alias is `push --force-with-lease
  --force-if-includes` — a double lease: the remote-tracking ref must match
  AND the remote tip must already be integrated into your local history
  (checked via reflog). This prevents overwriting others' work even after a
  background fetch.

## 3. Global Hooks

`~/.config/git/hooks/` (managed by this repo) contains:

- `prepare-commit-msg` — injects an AI-generated commit draft from
  `.git/AI_COMMIT_MSG` into the editor buffer **only for plain `git commit`**
  (never for `-m`/merge/amend), wrapped to 72 columns at injection (editor
  independent), then chains the repository-local
  `.git/hooks/prepare-commit-msg.local` if present. The draft buffer is kept
  — an editor abort or GPG signing failure does not lose it — and is removed
  by the `post-commit` dispatcher after the first successful commit (any
  source, incl. `-m`/amend, which also prevents stale drafts from leaking
  into later commits).
- `pre-commit`, `commit-msg`, `pre-push`, `post-commit` — generic dispatchers
  that chain `.git/hooks/<hook>.local`. Without a `.local` hook they are
  inert, so existing per-repo hooks keep working under the global `hooksPath`.

All hooks are inert by default; the AI draft flow only activates when an agent
writes `.git/AI_COMMIT_MSG` (see the `git-commit-architect` skill).

## 4. Recommended Aliases

### Visualization

- `git lg`: minimal, graph-based log view.
- `git lga`: comprehensive log view with dates and author names.

### Diff

- `git ds`: diff of staged changes. `git dw`: whitespace-insensitive diff.
- `git hdiff`: diff through the Hunk pager (requires `hunk`, installed with
  `./install.sh --with-git-tui`); falls back to a plain `git diff` when
  `hunk` is missing, so the alias never hard-errors.

### Rebase & Sync

- `git up`: `pull --rebase`. Always use this instead of a plain `git pull`.
- `git pf`: safe force push (double lease, see above).
- `git ri` / `git rc` / `git ra`: interactive rebase / continue / abort.

### Maintenance

- `git bclean [<ref>]`: deletes local branches already merged into `<ref>`
  (default `HEAD`). Worktree-aware and POSIX-safe: skips the current branch,
  branches checked out in other worktrees, and the protected set
  (`main|master|develop|staging|trunk`). Safe `-d` delete only.
- `git verify`: full object-database integrity check.

## 5. Branch Cleanup and the Squash-Merge Blind Spot

`git bclean` (and `git branch --merged` in general) detect merges **by
ancestry**. GitHub's **Squash and Merge creates no ancestry**, so a
squash-merged branch is invisible to `bclean` — `git branch -d` will refuse
with "not fully merged".

- Preferred cleanup after a squash merge (also deletes the remote branch):

  ```sh
  gh pr merge --squash --delete-branch
  ```

- If you do not use `gh`, verify the PR is merged on GitHub, then delete the
  branch deliberately with `git branch -D <branch>` — an explicit, informed
  `-D` is legitimate; the ban is on casual/automated force deletion.

## 6. Commit Message Convention

We follow the [Conventional Commits](https://www.conventionalcommits.org/)
specification.

### Format: `<type>(<scope>): <subject>`

- `feat`: a new feature
- `fix`: a bug fix
- `refactor`: a code change that neither fixes a bug nor adds a feature
- `style`: changes that do not affect the meaning of the code
- `docs`: documentation only changes
- `perf`: a code change that improves performance
- `chore`: changes to the build process or auxiliary tools

### Wrapping

Do **not** hand-wrap commit message lines: the editor wraps at 72 columns
automatically (Vim `gitcommit` filetype, see `config/vim/vimrc`). Keep the
subject under 50 characters and the body under ~72 characters per line as a
soft habit.

### Example

```txt
feat(install): enforce minimum tool versions via hybrid installation strategy

The installer now checks installed and candidate versions before falling back
to manual builds, preventing silent toolchain downgrades.

Key Changes:
- Version sorter with GNU sort fallback (gsort on macOS)
- Per-tool candidate resolution via apt/dnf/pacman/brew

Verification:
- Tested against apt and brew environments
```

## 7. The Workflow

1. **Start**: `git sw -c feat/your-feature`
2. **Work**: make changes.
3. **Stage**: `git ap` (interactive add) to select specific hunks.
4. **Commit**: `git ci` (verbose commit; AI drafts inject automatically via
   the `prepare-commit-msg` hook — review and edit in Vim, then enter your GPG
   passphrase in the pinentry prompt).
5. **Sync**: `git up` (pull --rebase) to fetch latest main.
6. **Push**: `git push` or `git pf` (if you rebased).
7. **PR & cleanup**: open a PR, merge with **Squash and Merge**, then
   `gh pr merge --squash --delete-branch` or `git bclean` where applicable.

See [github-flow.md](github-flow.md) for the full step-by-step guide,
including the AI-assisted Human-in-the-Loop flow.
