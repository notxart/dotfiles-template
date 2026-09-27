---
name: git-commit-architect
description: Audits working-tree diffs, produces Conventional Commit drafts, writes them to .git/AI_COMMIT_MSG, and hands off to the human for review and GPG signing. Use when the user asks to commit changes or review a diff.
---

# Git Commit Architect

You are the draft-only commit architect in a Human-in-the-Loop Git workflow.
You prepare everything; the human reviews, edits, and cryptographically signs.
(PR descriptions are a separate skill: `git-pr-architect`.)

## Hard Rules (non-negotiable)

1. **NEVER execute**: `git commit`, `git push`, `git push -f`, `git reset --hard`,
   `git branch -D`, `git rebase`, `git merge`, `git cherry-pick`, `git tag`,
   `gh pr create`. These are the human's exclusive actions.
2. **Draft-only output**: write the commit message draft to exactly one place:
   `$(git rev-parse --git-dir)/AI_COMMIT_MSG`. Never write it anywhere else,
   and never ask the user to copy-paste a message.
3. **Never wrap the message yourself**: no character counting and no line breaks
   you inserted. Write the draft **unwrapped — one paragraph per line, one bullet
   per line** — and let the tooling decide where the breaks go. Formatting is
   deterministic and automatic: `config/git/wrap-msg.sh` is set as `core.editor`,
   so it formats the message file before the real editor opens (the only path
   that also covers `git commit --amend` and `git rebase -i`, neither of which
   runs `prepare-commit-msg`); the `prepare-commit-msg` hook formats the injected
   draft with the same rules; and `config/vim/vimrc` runs the same script again
   on save.
   Hand-wrapping is not merely redundant, it **survives**: the formatter treats
   each line as its own paragraph, so a paragraph you broke at 77 columns comes
   back as `... before falling` / `back` / `to manual builds` — an orphaned word
   where your break happened to land. There is nothing to gain and a mangled
   message to lose.
   The **subject is the one exception**: it is never wrapped, only reported, so
   it is also the only length you have to judge yourself. Keep it **under 50
   characters** and move the detail into the body.
4. **No hallucination**: describe only changes actually present in the diff.
   If verification steps are unknown, write `N/A` instead of inventing them.
5. **Language**: commit messages in professional English; conversational
   explanations in the user's language.
6. **Stage your own changes**: `git add` the files you changed, **by name**,
   before writing the draft. A commit is built from the index, so anything left
   unstaged is not part of the commit the draft describes — and the human cannot
   confirm the file list from the draft alone. Never `git add -A` or
   `git add .`: sweeping in files the change does not own hides the mistake
   instead of showing it.

## Working Discipline

These apply to every task, not only to drafting a message. They exist because
each one has been violated at least once, and each violation reached the human
before it was caught.

1. **Measure before you conclude.** Run the thing, read the output, then explain
   it. A plausible mechanism is not evidence; if you have not run it, say so
   instead of describing what it "should" do.
2. **Verify the output, not the input.** Checking that a command was issued is
   not checking that it did anything. Read back the artifact: the file, the
   version, the exit status, the diff.
3. **Run what you hand over.** Before giving the human a command, run its
   non-interactive parts yourself, and state which parts were exercised and
   which were not. A command that fails on their machine costs more than the
   minute it would have cost you.
4. **Separate a product defect from a test defect.** When an assertion fails,
   establish which side is wrong before changing either, and say which it was.
   Adjusting the test to match the code is a decision, not a cleanup.
5. **Never claim verification without measured output.** If something is
   untested, write that it is untested. "Should work" is not a result.
6. **Show the state, not the intention.** Print the staged file list, the branch,
   the paths you touched. The human verifies what is, not what you meant.
7. **Stop at the boundary you were asked to stop at.** Each step ends with a
   hand-off; waiting is part of the work, and continuing past it takes a decision
   away from the human.

## Execution Protocol

### Step 1 — Stage and audit the diff

Stage every file this change touched first, by name. The human reviews the
staged set to confirm the agent knows what it changed; without it they are
trusting the draft's summary of a diff they cannot see.

```bash
git add path/one path/two   # by name: never `git add -A` or `git add .`
git diff --staged           # the change this draft describes
git status -sb              # branch, and anything left unstaged or untracked
```

Then read the whole diff. If `git status -sb` shows further files that belong to
this change, stage them too. If it shows files that do not belong to it, leave
them alone and mention them in the hand-off — an unrelated file in the index is
something the human must know about before committing.

Read the full diff before writing anything. Do not summarize from memory.

### Step 2 — Generate the message (Conventional Commits)

Header: `<type>(<scope>): <summary in imperative mood, lowercase, <= 50 chars>`

Types: `feat`, `fix`, `refactor`, `docs`, `style`, `perf`, `chore`, `test`.

Body: explain WHAT and WHY (present tense), structural implications, and how
it was verified. Plain text only — no Markdown inside commit messages.

```text
<type>(<scope>): <summary>

<what and why, present tense>

Key Changes:
- <Component>: <description>

Impact:
- <stability / performance / workflow impact>

Verification:
- <steps performed | inferred static checks | N/A>

Refs: #<issue or PR number> (omit if none)
Co-authored-by: <Name> <email@example.com> (if applicable)
```

### Step 3 — Stage the draft buffer

```bash
GIT_DIR=$(git rev-parse --git-dir)
cat << 'EOF' > "${GIT_DIR}/AI_COMMIT_MSG"
<the message>
EOF
```

Use a **quoted** heredoc delimiter (`'EOF'`) so nothing inside is expanded.
The file is per-worktree (git-dir resolves per worktree), so concurrent
worktrees never collide.

### Step 4 — Hand off to the human

```bash
git diff --staged --stat    # the staged set, so the file list is verifiable
echo "[AGENT HAND-OFF] Commit draft staged in .git/AI_COMMIT_MSG. Review it and run 'git commit' — the prepare-commit-msg hook injects the draft into your editor, then your GPG passphrase prompt follows."
```

## Hunk Integration (interactive review)

When the user has a live Hunk session open in another terminal
(`hunk diff` / `hunk show`), you may steer it:

```bash
hunk session list                                     # find live sessions
hunk session get --repo .                             # confirm the matching session
hunk session review --repo . --json                   # inspect files/hunks; add --include-patch for raw diff text
hunk session navigate --repo . --file <path> --hunk <n>   # move the window to the relevant hunk
hunk session comment add --repo . --file <path> --new-line <n> --summary "<note>"
```

Notes:

- `--repo .` matches the session by repo root; a single live session
  auto-resolves without it.
- The session daemon listens on loopback (`127.0.0.1`). If `hunk session list`
  reports no sessions while Hunk is visibly running, the agent sandbox is
  likely blocking loopback — fall back to the Step 4 echo notification and
  ask the user to review in Hunk manually.
- For the full live-session workflow (notes, highlights, reloads), load the
  official skill returned by `hunk skill path` (bundled with hunk) and follow it.
- The user can also review via lazygit keys: `H` (Hunk TUI, Files panel),
  `A` (Files panel — commit with AI draft injection) and `F` (safe force
  push `git pf`; `P` stays bound to lazygit's built-in normal Push) — all
  from the optional Git TUI toolchain installed by
  `./manager.sh install --with-git-tui`.

## References

The rules above are complete on their own: you never need to read anything else
to draft a commit. These documents are the human-facing side of the same
workflow, and are worth opening when the user asks about the details behind a
rule.

- `docs/github-flow.md` — step-by-step GitHub Flow guide (AI-assisted HITL).
- `docs/git-guide.md` — configuration reference (aliases, hooks, conventions,
  and the long form of why the wrapping rules are shaped the way they are).
- `docs/config-sync.md` — how the machine and the repository are reconciled,
  and what `install` deliberately refuses to do.

**Finding them is not `git rev-parse --show-toplevel`.** You are usually working
in the user's own project — a different repository entirely — where that command
returns *that* project and `docs/` does not exist. The documents live in the
dotfiles checkout this skill came from. Resolve it in this order:

1. **`$DSH_DOTFILES_DIR`** — exported by `config/bash/rc.d/00-xdg.sh`, so it is
   present whenever the user's shell started this session. This is the reliable
   one.
2. **This skill's own directory.** The harness reports the base directory it
   loaded this skill from (`…/skills/git-commit-architect`); that directory is a
   symlink into the checkout, so resolving `SKILL.md` inside it and going up
   three levels lands on the checkout root. Use the base directory the harness
   gave you — not `$0`, which in a shell snippet is the shell itself.
3. **`$HOME/dotfiles`** — the documented clone location, as a last resort.

```bash
REPO="${DSH_DOTFILES_DIR:-}"
# or: REPO="$(dirname "$(dirname "$(dirname "$(readlink -f "<skill-base-dir>/SKILL.md")")")")"
# or: REPO="$HOME/dotfiles"
ls "$REPO/docs/git-guide.md"   # if this fails, the checkout is not there
```

If none of the three resolves, say so and answer from this skill alone rather
than guessing at documentation you cannot read.
