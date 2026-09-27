# Config Sync

`config sync` is the command that reconciles this machine's `~/.config` with the
repository. It exists because the opposite approach — symlinking whole
directories into `~/.config` — destroys data: the first time an application
writes to `~/.config/tool/settings.json` through such a link, the write lands in
the repository, and the next install that re-points the link takes it with it.

This document explains the model, the vocabulary, and what happens when the
machine and the repository disagree.

## The three layers

Each layer has exactly one job, and the split is what keeps each of them honest.

| Layer | Command | Its job | It may move a file? |
| --- | --- | --- | --- |
| Seed | `manager.sh install` | Create what is missing. Link files whose destination is free. | **No** |
| Reconcile | `manager.sh config sync` | Compare the machine with the repository, and act on one decision at a time. | Yes, with a backup and a confirmation |
| Resolve | `git` | Own the content of the repository: what changed, what is committed, what a conflict means. | Yes, in the repository only |

The rule that follows from the table: **`install` decides nothing**. If a
destination already holds a real file, `install` reports it and leaves it alone.
That is not caution for its own sake — an install runs unattended, from a fresh
clone, on a machine it has never seen, and a command in that position must not be
able to lose work. Anything that needs a judgement call is left to a command that
can ask.

`config sync` is the only place in this project where a file is replaced, and it
is therefore the only place a question is asked.

## Vocabulary

| Term | Meaning |
| --- | --- |
| **registry** | The list of paths this repository manages: source in the repository, destination on the machine, and a mode. Defined in `lib/link.sh`. |
| **manifest** | `$XDG_STATE_HOME/dotfiles/manifest.tsv`. What this machine recorded: the feature flags it opted into, the links it created, and a hash of each. |
| **tracked** | The file exists in the git index. This — not the manifest — is the authority on whether a path belongs to the repository. |
| **link** | A symlink from the machine into the repository. The default mode. |
| **seed** | Copied once, then owned by the machine (`config/git/work.ini`). `sync` never offers to reconcile a seeded file, because the machine is supposed to diverge. |
| **ignored** | A recorded decision that a path is intentionally *not* managed. It stops being reported. |

Ownership is decided by `git ls-files`, deliberately. A record in the manifest
can be stale — a link deleted by hand, a source removed from the repository — but
the index is the same thing `git status` shows, so "does this repository own this
path?" has exactly one answer and the user can always check it themselves.

## Commands

```sh
manager.sh config status              # read-only: what is healthy, what is not
manager.sh config sync                # reconcile, asking before anything is replaced
manager.sh config sync --dry-run      # show the plan; change nothing
manager.sh config sync --yes          # apply only the changes that cannot lose data
manager.sh config adopt <path>...     # move a real file into the repository and link it back
manager.sh config ignore <path>...    # record that a path is intentionally unmanaged
manager.sh config restore <path>...   # put a file back as a real file and forget the record
```

### `config status`

Prints every registry path with one of four states, then a summary, then anything
else that needs attention: orphaned records (the source is gone), loop symlinks
(the damage the old directory-level installer produced), and credential risks in
the repository's own tracked `config/git/*.ini`.

| State | Meaning |
| --- | --- |
| `ok` | The destination is a symlink to the registered source. |
| `absent` | Nothing is there. `install` or `sync` will create it. |
| `stale` | A symlink pointing somewhere else: a different checkout, a file of your own, or a dead target. |
| `blocked` | A real file or directory is in the way. Nothing will touch it without you. |

Exit status: `0` when everything is healthy, `2` when something needs attention
(the number of issues is printed). It never returns non-zero merely because it
found something to report — that distinction matters when it is used in a script.

### `config sync`

1. **Scan.** Classify every registry path as *identical* (a real file whose bytes
   match the repository), *differing*, *missing*, or already a link.
2. **Ask once.** With a terminal it offers `[a]` apply the safe changes, `[d]`
   show the details first, or `[q]` quit. `--dry-run` stops before this point.
   Without a terminal and without `--yes` it changes nothing and exits `2`,
   printing the individual commands instead — a script cannot accidentally
   reconcile a machine.
3. **Act.** Link what is identical (after backing it up), create what is missing,
   and report what differs. A differing file is **never** touched, whatever flags
   were passed: `--yes` is not a licence to overwrite, it only skips the prompt
   for changes that cannot lose data.

## When the machine and the repository disagree

The interesting case is a real file at a registry destination whose content
differs from the repository. That is a genuine question — the machine's version
may be the newer one — so `sync` reports it and stops:

```text
❯❯❯ Registry Paths Needing Attention
  CONFLICT   .config/starship.toml
  ...
❯❯❯ Result
  ⚠ 1 item(s) need attention.
```

Three answers, all explicit:

```sh
# 1. The machine's file is the one I want, and I want it under version control.
manager.sh config adopt ~/.config/starship.toml

# 2. The file is mine and stays mine: stop offering it.
manager.sh config ignore ~/.config/starship.toml

# 3. The repository's version is the one I want. This deletes the machine's
#    copy, which is why sync will not do it for you.
rm ~/.config/starship.toml && manager.sh install
```

`config restore <path>` is the undo for the first two, not a third answer to the
conflict: it turns a link back into a real file and forgets the record, so the
path stops being managed. It refuses to touch a symlink that does not point into
this repository.

`adopt` is the interesting one: it moves the file **into** the repository at the
mirrored path and symlinks back to it, which is the configuration-side equivalent
of `git add`. It refuses to overwrite an existing repository file, and if the
symlink cannot be created it puts the file back where it was, so a failure cannot
leave a file half-adopted. A file that looks like it carries a credential or an
absolute path is flagged before adoption, because those are the two things that
break — or leak — when a configuration file starts travelling between machines.

## Backups

Every replacement takes a copy first, under the XDG state directory rather than
in `$HOME`:

```text
$XDG_STATE_HOME/dotfiles/backups/<YYYYmmdd_HHMMSS>/<path relative to $HOME>
```

- **One directory per run**, not per file, so everything a single `sync` replaced
  is restored together.
- **The newest ten runs are kept.** An unbounded backup directory is one nobody
  ever opens.
- **A backup of a symlink is the bytes the link resolved to**, not the link: a
  copy that still points at the file it was meant to protect is useless the
  moment that file is replaced.

Restoring is a plain copy, because the layout mirrors `$HOME`:

```sh
cp -a "$XDG_STATE_HOME"/dotfiles/backups/<timestamp>/.config/starship.toml ~/.config/
```

## What `sync` will not do

- It will not touch a file whose content differs from the repository.
- It will not replace a real file with a link unless the two are byte-identical.
- It will not act at all without a terminal, unless `--yes` says the changes are
  the safe ones.
- It will not reconcile a `seed` path. Those are copied once and belong to the
  machine afterwards.

## Skills travel with the repository

Agent skills are managed by the same registry, in a third location:
`$DSH_HOME/skills/`. The arrangement decides whether a skill you write survives a
move to another machine, so it is worth knowing.

- The **canonical copy lives in this repository**, at `skills/<name>/SKILL.md`.
  That is what gets committed, pushed and cloned onto the next machine.
- `$DSH_HOME/skills/<name>/` is a **real directory containing links** to those
  files, not a link to the directory. Anything written beside `SKILL.md` — a
  scratch note, a cache an agent drops — therefore stays on the machine instead
  of landing in the working tree. A directory link would carry all of it into the
  repository.
- The registry discovers `skills/*/` by itself, so a skill added to the
  repository needs no edit anywhere: run `./manager.sh install` and its files are
  linked.

A skill written **directly into `$DSH_HOME/skills/`** is outside the repository
and will not travel. Bring it in:

```sh
./manager.sh config adopt "$DSH_HOME/skills/<name>/SKILL.md"
```

`adopt` moves the file into `skills/<name>/` and links back to it, exactly as it
does for a configuration file under `~/.config`, and the skill keeps working
where it is. An agent working in this repository is told the same thing in
`AGENTS.md`.

## Related

- [README](../README.md) — installation, requirements, customization.
- [git-guide.md](git-guide.md) — git configuration and commit conventions.
- [github-flow.md](github-flow.md) — the branch, review and PR workflow.
