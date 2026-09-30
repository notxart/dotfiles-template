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
- **Matching XDG paths** — `./manager.sh install` refuses to start when the paths
  the manager derives and the paths `config/bash/rc.d/*.sh` export disagree, so a
  half-installed machine cannot come out of a config edit. See
  [The XDG preflight](config-sync.md#the-xdg-preflight-why-install-can-refuse-to-start).
- **Vim >= 9.0** (optional but recommended) — `config/vim/vimrc` marks the column
  limit and runs the repository's formatter on save for the `gitcommit` filetype.
  The formatting itself does not depend on Vim; see "Wrapping" below.

## 1. Core Principles

- **Atomic Commits**: Each commit must do one thing and one thing only. Do not
  mix refactoring with feature additions.
- **Linear History**: We do not use merge commits for feature branches. We
  `rebase`.
- **Signed Commits**: All commits must be GPG signed to verify authorship.

## 2. Configuration Overview

The project includes a hardened `config/git/config.ini`. Key features:

- **Never auto-execute typos**: `help.autocorrect = prompt` (Git >= 2.34) asks
  before running a corrected command instead of running it after a delay.
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

The hook and `core.editor` apply the same wrapping rules to the same message, so
a commit that opens an editor is formatted once on the way in and again on save
**without changing the result**: the rules are idempotent, and `./check.sh`
asserts both that and the fact that the two copies of those rules agree byte for
byte.

All hooks are inert by default; the AI draft flow only activates when an agent
writes `.git/AI_COMMIT_MSG` (see the `git-commit-architect` skill).

## 4. Recommended Aliases

### Visualization

- `git lg`: minimal, graph-based log view.
- `git lga`: comprehensive log view with dates and author names.

### Diff

- `git ds`: diff of staged changes. `git dw`: whitespace-insensitive diff.
- `git hdiff`: diff through the Hunk pager (requires `hunk`, installed with
  `./manager.sh install --with-git-tui`); falls back to a plain `git diff` when
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
- `test`: adding or correcting tests

### Wrapping

**Write the message unwrapped.** One paragraph on one line, one bullet on one
line, no line breaks you inserted yourself. Formatting is deterministic tooling's
job, and it happens without anyone remembering to do it:

- `config/git/wrap-msg.sh` is set as `core.editor`, so it formats the message file
  before the real editor opens. This is the only mechanism that covers
  `git commit --amend` and `git rebase -i`, because neither runs
  `prepare-commit-msg`. It never splits a word and never leaves trailing
  whitespace.
- The `prepare-commit-msg` hook formats the injected AI draft with **the same
  rules**, so the buffer is already correct when the editor opens.
- `config/vim/vimrc` runs that same script on save, which catches anything typed
  during the session. There is exactly one implementation of these rules.

Hand-wrapping does not merely duplicate that work — it survives it. The
formatter treats each line as its own paragraph, so a paragraph you already broke
at 77 columns comes back as `... before falling` / `back` / `to manual builds`:
an orphaned word where your break happened to land. Write the paragraph on one
line and let the tooling choose the breaks.

The one thing the tooling will not fix is the subject. It is never wrapped —
only the author knows what to cut — so keep it **under 50 characters** yourself;
the formatter reports an over-long subject and leaves it alone. `./check.sh`
asserts that a rejected subject still leaves the whole message intact.

Validate without opening an editor:

```sh
config/git/wrap-msg.sh --check < msg.txt
```

It exits non-zero and names the problem (empty subject, subject over 50
characters, a formatted line over 72, trailing whitespace), and writes the
formatted message to stdout in either case.

Automation should commit with `-m`: a plain `git commit` needs an editor, and
with no terminal and no editor configured `config/git/wrap-msg.sh` **refuses**
rather than starting one it cannot show — an editor started without a terminal
blocks until it is killed. The refusal is deliberate, and `./check.sh` asserts
that no editor is ever launched in that situation. `-m` is safe but skips the
formatter and the AI draft, so keep such a message inside 50 characters by hand.

### Example

This is a draft as an author should write it — every paragraph and every bullet
on a single line. Notice that the prose of this document is wrapped to be read;
a **message** is not: its line breaks are produced by the tooling.

```txt
feat(install): enforce minimum tool versions

The installer now checks installed and candidate versions before falling back to manual builds, preventing silent toolchain downgrades. The check runs before any install, so a machine can no longer be silently downgraded by a stale repository candidate.

Key Changes:
- Version sorter with GNU sort fallback (gsort on macOS)
- Per-tool candidate resolution via apt/dnf/pacman/brew

Verification:
- Tested against apt and brew environments
```

After `git commit` opens the editor, that same draft is already wrapped at 72
columns, with the bullets' continuation lines indented by two spaces.

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
including the AI-assisted Human-in-the-Loop flow, and
[config-sync.md](config-sync.md) for how these files get onto a machine —
seeding, linking, `config sync`, and the backups taken along the way.
