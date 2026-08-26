# GitHub Flow (AI-Assisted HITL Edition)

A step-by-step guide to contributing to GitHub repositories with a linear,
signed, human-reviewed history. This is the modern successor to the classic
GitHub Flow: `git switch`/`git restore` replace the overloaded `git checkout`,
rebases happen in place (no branch-switching churn), and an AI agent may
prepare commit drafts that you — and only you — review and sign.

> **Prerequisites**: Git >= 2.37, a GPG key configured in
> `config/git/config.ini`, and this repo's dotfiles installed. The AI parts
> are optional (`./install.sh --with-git-tui --with-dsh`).

## Principles

1. **Non-blocking Human Oversight**: AI prepares drafts; humans review,
   edit, and cryptographically sign. The agent never runs `git commit` or
   `git push` (enforced by the `git-commit-architect` skill).
2. **Zero Filesystem Churn**: never switch to `main` just to rebase — sync
   the remote ref and rebase in place.
3. **Destructive Command Ban**: `git branch -D` (casual use) and un-leased
   `git push -f` are forbidden. Use `git pf` and informed deletions only.

## Steps

### 1. Get the repository

- **Collaborating on someone else's project**: fork it on GitHub, then:

  ```sh
  git clone git@github.com:<you>/<repo>.git
  cd <repo>
  git remote add upstream <original-repo-url>   # e.g. https://github.com/author/repo
  ```

- **Your own project**: just clone your repository. Skip the `upstream` step.

### 2. Create a feature branch

Never commit directly on `main`. Always branch off the latest remote `main`:

```sh
git fetch origin
git switch -c feat/<your-feature> origin/main
```

(`git switch -c` replaces the old `git checkout -b`; `git switch` for
branch switching, `git restore` for file restoration — `git checkout` no
longer needs to do both jobs.)

### 3. Develop — with or without the AI co-worker

Program as usual. If you are using the AI workflow:

1. The agent audits `git diff --staged` / `git diff`.
2. The agent writes a Conventional Commit draft to `.git/AI_COMMIT_MSG`
   (never commits itself).
3. You are notified to review — in [Hunk](https://github.com/modem-dev/hunk)
   (`hunk diff`), [lazygit](https://github.com/jesseduffield/lazygit) (key
   `H`), or simply in your editor.

### 4. Stage, review, and sign the commit

```sh
git add -p          # stage hunks selectively (alias: git ap)
git commit          # alias: git ci
```

For a plain `git commit`, the `prepare-commit-msg` hook injects the agent's
draft into your editor automatically (zero copy-paste) — already wrapped at
72 columns at injection, independent of your editor. Review and edit it —
Vim additionally rewraps long lines **on save** (vimrc `BufWritePre`, a
second line of defense for your hand edits) — save (`:wq`), and enter your
GPG passphrase in the pinentry prompt. The AI never sees your key.

> The hook does **not** inject into `git commit -m "..."`: a hand-written
> message always wins.

### 5. Sync with remote main — in place, zero churn

Do **not** switch to `main` and back (that re-indexes IDEs and invalidates
build caches twice). Stay on your feature branch:

```sh
git fetch origin main
git rebase origin/main
```

On conflict: resolve manually, `git add <files>`, then `git rebase --continue`.

### 6. Push (and safe force-push after a rebase)

```sh
git push -u origin <branch>          # first push (autoSetupRemote may make this just: git push)
git pf                               # after a rebase: force-with-lease + force-if-includes
```

`git pf` is `push --force-with-lease --force-if-includes`: it refuses to
overwrite the remote if your local history does not already contain the
remote's latest commit — even after a background `fetch` updated the
remote-tracking ref. Plain `git push -f` is banned.

### 7. Open a Pull Request

On GitHub, open a PR from your feature branch. If you use the GitHub CLI:

```sh
gh pr create --body-file .git/AI_PR_BODY
```

The `git-pr-architect` skill drafts the description into `.git/AI_PR_BODY`
(`## Summary`, `## Key Changes`, `## Impact`, `## Verification`,
`## Related Issues` — it never runs `gh pr create` itself; publishing is
yours). Without an agent, use the same template manually.

### 8. Merge with Squash and Merge

The project leader (or you, on your own project) merges with **Squash and
Merge** to keep `main` linear and atomic. Optionally, set the squash commit
message from the PR description.

### 9. Clean up

- Delete the remote branch on GitHub, or with `gh pr merge --squash
  --delete-branch` (merges *and* deletes remote + local branch in one step).
- Back on your machine, sync and clean local branches:

  ```sh
  git switch main
  git pull --rebase
  git bclean
  ```

> **Squash-merge caveat**: `git bclean` detects merged branches by ancestry,
> and squash merges create no ancestry — so a squash-merged branch is *not*
> auto-removed. That is safe-by-design. If `gh` was not used and the PR is
> confirmed merged, delete that one branch deliberately:
> `git branch -D <branch>`.

### 10. Loop

Start again from step 2.

## FAQ

**Q: Why do I get "Authentication failed" on push?**

Password authentication was removed from GitHub in 2021. Use SSH or a
fine-grained token:

```sh
git remote set-url origin git@github.com:<user>/<repo>.git
# or: git remote set-url origin https://<token>@github.com/<user>/<repo>.git
```

**Q: Why does `git commit` fail with "gpg: signing failed"?**

You have no usable GPG key for `commit.gpgSign = true`. Generate one
(`gpg --full-generate-key`), set `[user] signingkey` in
`config/git/config.ini`, and export it to GitHub (Settings → SSH and GPG
keys). If you use a smartcard/hardware key, make sure the agent is running
and `GPG_TTY` is exported (the dotfiles already do this).

**Q: The pinentry prompt hangs or never appears.**

Your distro's pinentry program is missing. The installer configures
`gpg-agent.conf` automatically (pinentry-mac / pinentry-curses / pinentry);
install the matching package or check `~/.local/share/gnupg/gpg-agent.conf`.

**Q: Why is my feature branch not deleted by `git bclean`?**

It was squash-merged (no ancestry) — see the caveat in step 9.

**Q: Where does the AI draft come from?**

An agent following the `git-commit-architect` skill writes
`.git/AI_COMMIT_MSG`; the global `prepare-commit-msg` hook injects it. If the
file does not exist, the hook does nothing — the workflow is fully manual
when no agent is involved.
