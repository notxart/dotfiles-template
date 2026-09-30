# AGENTS.md

Instructions for an AI agent working **in this repository**. They are project
rules, not general workflow rules: the git conventions that apply in every
repository live in the skills (`skills/git-commit-architect`,
`skills/git-pr-architect`), which the agent loads on its own. DSH reads this file
automatically from the project root down to the working directory, so anything
here reaches an agent without being asked for.

## Run the check before claiming a change works

```sh
./check.sh            # the acceptance matrix; exits non-zero on failure
./check.sh --report   # one install in a throwaway HOME, then a report to read
./check.sh --lint     # shellcheck over the source tree (opt-in; needs shellcheck)
```

`./check.sh` is this project's unit test. Run it after any change to `lib/`,
`config/`, `manager.sh` or the skills, and **before saying a change is done**. It
needs no privileges and touches nothing outside `.sandbox-e2e/`: `HOME` is a
sandbox and `sudo`, `apt-get`, the network and every installable tool are stubs
that record their argv instead of running.

If it fails, report the failing assertion and its measured output. A change that
was not checked is not verified — do not describe it as if it were. When an
assertion fails in a way that looks like the test's fault, fix the test only when
you can show the product behaves correctly; otherwise fix the product.

## Never commit, never push

`git commit`, `git push`, `git tag`, `git rebase`, `git merge`, `gh pr create`
and `gh pr merge` belong to the human. The agent stages what it changed — **by
name**, never `git add -A` — prints the staged set, writes a draft message to
`.git/AI_COMMIT_MSG`, and hands off. The human reviews, edits and signs.

## Never touch the identity in `config/git/config.ini`

`[user] name`, `email` and `signingkey` are this machine's own values, and this
repository is the mechanism that syncs them. Copying another checkout's version
of that file over this one **silently wipes the user's identity** — a mistake
that has already happened once while repairing a machine, and was recoverable
only because a backup existed. Apply changes to that file surgically, or take a
backup first and restore those three values immediately.

`config/git/work.ini` is a *seed*: copied once, then owned by the machine. It is
never overwritten and never offered as a conflict.

## Where things live

| Path | What it is |
| --- | --- |
| `manager.sh` | The only entry point: `install`, `update`, `config`. |
| `lib/` | The implementation, one module per concern. |
| `config/` | The master copy of every managed configuration file. |
| `skills/<name>/SKILL.md` | Agent skills. **This is the canonical location.** |
| `docs/` | Human-facing documentation. |
| `check.sh` | The acceptance matrix, `--report` and `--lint`. |
| `.sandbox-e2e/` | Throwaway runs from `check.sh`. Gitignored. |

The live machine reads `config/` through file-level symlinks; `~/.config/<tool>/`
is a real directory, and `$XDG_STATE_HOME/dotfiles/manifest.tsv` records what was
linked. The git index decides ownership: a file the repository does not track is
not managed, which is why renaming a source makes it unmanaged until it is
staged.

## Skills: the repository is the source, `$DSH_HOME` is a view

`$DSH_HOME/skills/<name>/` is a real directory containing links to files under
`skills/<name>/`. A **new** skill written straight into `$DSH_HOME/skills/` lives
outside the repository and does not travel to another machine, so:

- to author or edit a skill, write in `skills/<name>/` and run
  `./manager.sh install` — the registry discovers `skills/*/` by itself;
- to bring an existing skill under version control, use
  `./manager.sh config adopt <path>`, which moves the file into the repository
  and links back to it.

Anything else written beside `SKILL.md` stays local by design: a directory link
would carry every such file into the working tree.
