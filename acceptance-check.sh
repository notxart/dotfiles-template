#!/usr/bin/env bash
# ==============================================================================
# acceptance-check.sh — The T1–T14 acceptance matrix.
#
# sandbox-check.sh answers "what did the manager do to a throwaway HOME?" and
# leaves a report to read. This one answers "does it behave the way it promises?"
# and asserts it: fourteen scenarios a user actually meets, walked in order
# against one sandbox that keeps its state between them.
#
#   T1  fresh install                  T8  local content wins (adopt)
#   T2  second install is idempotent   T9  XDG mismatch refuses to install
#   T3  an app's own file survives     T10 a renamed source leaves no orphan
#   T4  an atomic rename is repaired   T11 update --dry-run changes nothing
#   T5  directory-link migration       T12 manifest round-trip and migration
#   T6  loop symlinks are found        T13 no TTY changes nothing, exits 2
#   T7  sync verdicts + fail-closed    T14 a seeded file is never overwritten
#
# Plus one guard that is not a scenario: the hook and wrap-msg.sh carry the same
# wrapping rules inline and must produce byte-identical output.
#
# Usage: ./acceptance-check.sh
# ==============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$REPO_ROOT/.sandbox-e2e/step10"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/pmbin" "$SANDBOX/versions"

export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export PNPM_HOME="$HOME/.local/share/pnpm"
export STUB_LOG="$SANDBOX/calls.log"
export STUB_VERSIONS="$SANDBOX/versions"
export SANDBOX
mkdir -p "$PNPM_HOME/bin" "$HOME/.local/bin"
: > "$STUB_LOG"
unset GNUPGHOME GIT_CONFIG_GLOBAL DSH_HOME 2>/dev/null || true

# .git travels with the copy: ownership is decided by the git index, and without
# it almost nothing is linkable and every scenario below would test the wrong
# thing.
stage_repo() {
    local dest="$1"
    mkdir -p "$dest"
    cp -a "$REPO_ROOT"/{.git,lib,skills,config,.bashrc,.bash_profile,manager.sh} "$dest/"
    chmod +x "$dest/manager.sh"
}

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then
        printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  \033[1;31mFAIL\033[0m  %s\n        expected: [%s]\n        actual:   [%s]\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

COREUTILS="$SANDBOX/coreutils"
mkdir -p "$COREUTILS"
for util in awk sed grep cut sort find head tail tr wc cat mkdir rm cp mv ln \
            date mktemp dirname basename uname whoami id chmod touch env bash sh \
            xargs sleep tar install git sha256sum readlink realpath getent uniq \
            diff cmp stat tee chown gpg gpgconf gpg-agent gzip echo; do
    resolved="$(command -v "$util" 2>/dev/null || true)"
    [[ -n "$resolved" ]] && ln -sf "$resolved" "$COREUTILS/$util"
done

# --- stubs --------------------------------------------------------------------
cat > "$SANDBOX/bin/_tool" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s|%s\n' "$name" "$*" >> "${STUB_LOG:-/dev/null}"
vfile="${STUB_VERSIONS:-/dev/null}/$name"
if [[ "$1" == "--version" || "$1" == "-V" ]]; then
    [[ -f "$vfile" ]] || exit 0
    case "$name" in
        starship) printf 'starship %s\n' "$(cat "$vfile")" ;;
        lazygit)  printf 'lazygit, commit=abc, version=%s, git version=2.47.3\n' "$(cat "$vfile")" ;;
        node)     printf 'v%s\n' "$(cat "$vfile")" ;;
        *)        cat "$vfile" ;;
    esac
    exit 0
fi
[[ -f "${STUB_VERSIONS:-}/$name.$1.fail" ]] && exit 1
exit 0
STUB
chmod +x "$SANDBOX/bin/_tool"
for t in pnpm node hunk dsh; do ln -sf "$SANDBOX/bin/_tool" "$PNPM_HOME/bin/$t"; done
for t in fzf starship lazygit; do ln -sf "$SANDBOX/bin/_tool" "$SANDBOX/bin/$t"; done
stub_versions() {
    printf '12.3.4\n'     > "$STUB_VERSIONS/pnpm"
    printf '24.19.0\n'    > "$STUB_VERSIONS/node"
    printf '0.22.0\n'     > "$STUB_VERSIONS/hunk"
    printf '0.1.5-rc.1\n' > "$STUB_VERSIONS/dsh"
    printf '1.22.1\n'     > "$STUB_VERSIONS/starship"
    printf '0.60\n'       > "$STUB_VERSIONS/fzf"
    printf '0.50.0\n'     > "$STUB_VERSIONS/lazygit"
}
stub_versions

printf '#!/bin/sh\nprintf "sudo|%%s\\n" "$*" >> "${STUB_LOG:-/dev/null}"\nexit 0\n' > "$SANDBOX/pmbin/sudo"
printf '#!/bin/sh\nprintf "apt-get|%%s\\n" "$*" >> "${STUB_LOG:-/dev/null}"\nexit 0\n' > "$SANDBOX/pmbin/apt-get"
chmod +x "$SANDBOX/pmbin/"*

# mgr <repo-dir> <args...> — run the manager with a hermetic environment.
mgr() {
    local repo="$1"; shift
    env -i \
        HOME="$HOME" \
        PATH="$SANDBOX/bin:$HOME/.local/bin:$PNPM_HOME/bin:$SANDBOX/pmbin:$COREUTILS" \
        PNPM_HOME="$PNPM_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
        XDG_CACHE_HOME="$XDG_CACHE_HOME" \
        STUB_LOG="$STUB_LOG" STUB_VERSIONS="$STUB_VERSIONS" SANDBOX="$SANDBOX" \
        TERM=dumb \
        "$repo/manager.sh" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

link_count() { find "$HOME" -type l -not -path "$PNPM_HOME/*" -not -path "$HOME/.local/bin/*" 2>/dev/null | wc -l; }

stage_repo "$SANDBOX/repo"

# ==============================================================================
echo
echo "### T1  a fresh install links files, and every config directory is real"
mgr "$SANDBOX/repo" install --with-git-tui --with-dsh > "$SANDBOX/t1.out" 2>&1
check "install succeeds" "1" "$(grep -c 'Dotfiles Setup Completed Successfully' "$SANDBOX/t1.out")"
check "the registry's links were created" "22" "$(link_count)"
check "~/.config/git is a real directory" "directory" \
    "$([[ -L "$XDG_CONFIG_HOME/git" ]] && echo symlink || echo directory)"
check "~/.config/bash is a real directory" "directory" \
    "$([[ -L "$XDG_CONFIG_HOME/bash" ]] && echo symlink || echo directory)"
check "~/.config/hunk is a real directory" "directory" \
    "$([[ -L "$XDG_CONFIG_HOME/hunk" ]] && echo symlink || echo directory)"
# A file directly under ~/.config (starship.toml) is a link by design; what must
# never appear again is a link that stands in for a whole config DIRECTORY.
check "no directory symlink was created under ~/.config" "0" \
    "$(find "$XDG_CONFIG_HOME" -maxdepth 1 -type l -exec test -d {} \; -print 2>/dev/null | wc -l)"
check "a config file is a link into the repository" "yes" \
    "$([[ "$(readlink "$XDG_CONFIG_HOME/starship.toml")" == "$SANDBOX/repo/config/starship.toml" ]] && echo yes || echo no)"

echo
echo "### T2  a second install changes nothing"
before_links="$(link_count)"
touch "$SANDBOX/t2.marker"
mgr "$SANDBOX/repo" install --with-git-tui --with-dsh > "$SANDBOX/t2.out" 2>&1
check "still succeeds" "1" "$(grep -c 'Dotfiles Setup Completed Successfully' "$SANDBOX/t2.out")"
check "no link was added or removed" "$before_links" "$(link_count)"
check "nothing was created (0 files newer than the marker)" "0" \
    "$(find "$HOME" -newer "$SANDBOX/t2.marker" -not -path "$XDG_STATE_HOME/*" -not -path "$STUB_LOG" 2>/dev/null | wc -l)"
# 23 records: the 22 links plus the seeded work.ini, which reports as settled
# without being a link.
check "every record is reported as already correct" "1" \
    "$(grep -cE 'Links: 0 created, 23 already correct' "$SANDBOX/t2.out")"

echo
echo "### T3  a file an application writes is never carried into the repository"
printf '{"session":"abc","cwd":"/tmp"}\n' > "$XDG_CONFIG_HOME/hunk/state.json"
sum_before="$(sha256sum "$XDG_CONFIG_HOME/hunk/state.json" | awk '{print $1}')"
mgr "$SANDBOX/repo" install --with-git-tui --with-dsh > "$SANDBOX/t3.out" 2>&1
check "the application's file survived" "$sum_before" \
    "$(sha256sum "$XDG_CONFIG_HOME/hunk/state.json" | awk '{print $1}')"
check "it is NOT in the repository" "0" "$([[ -e "$SANDBOX/repo/config/hunk/state.json" ]] && echo 1 || echo 0)"
check "the link beside it is still healthy" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -cE '^  ok +.*hunk/config\.toml')"
# It IS offered, and labelled: the session state is visible next to the config
# the repository manages, with the classification that says not to adopt it.
# A candidate is a hint, not an action — sync never adopts anything by itself.
check "it is offered as a candidate, labelled machine-state" "1" \
    "$(mgr "$SANDBOX/repo" config sync --dry-run | grep -cE 'machine-state +[0-9]+B +\.config/hunk/state\.json')"
rm -f "$XDG_CONFIG_HOME/hunk/state.json"

echo
echo "### T4  an application that replaces the link atomically is detected and repaired"
# The pattern every editor and every config library uses: write a temporary file,
# rename it over the destination. The link is gone and a real file is in its place.
cp "$XDG_CONFIG_HOME/starship.toml" "$SANDBOX/atomic.tmp"
rm -f "$XDG_CONFIG_HOME/starship.toml"
mv "$SANDBOX/atomic.tmp" "$XDG_CONFIG_HOME/starship.toml"
check "the destination is now a real file" "regular" \
    "$([[ -L "$XDG_CONFIG_HOME/starship.toml" ]] && echo symlink || echo regular)"
check "status reports it as blocked" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -cE 'blocked +.*starship\.toml')"
mgr "$SANDBOX/repo" config sync --yes > "$SANDBOX/t4.out" 2>&1
check "sync converts it back to a link" "yes" \
    "$([[ -L "$XDG_CONFIG_HOME/starship.toml" ]] && echo yes || echo no)"
check "and takes a backup first" "1" \
    "$(find "$XDG_STATE_HOME/dotfiles/backups" -name starship.toml 2>/dev/null | wc -l)"

echo
echo "### T5  the old directory-level links are migrated with nothing lost"
# Reproduce the legacy shape on a second clone: ~/.config/vim -> repo/config/vim,
# with a file inside that the repository does not track (written by an
# application through the directory link).
stage_repo "$SANDBOX/legacy"
rm -f "$XDG_CONFIG_HOME/vim/vimrc" 2>/dev/null; rmdir "$XDG_CONFIG_HOME/vim" 2>/dev/null
ln -sfn "$SANDBOX/legacy/config/vim" "$XDG_CONFIG_HOME/vim"
printf 'set number\n' > "$SANDBOX/legacy/config/vim/foreign.lua"
mgr "$SANDBOX/legacy" install --yes > "$SANDBOX/t5.out" 2>&1
check "the migration was planned" "1" "$(grep -c 'convert: .config/vim' "$SANDBOX/t5.out")"
check "~/.config/vim is now a real directory" "directory" \
    "$([[ -L "$XDG_CONFIG_HOME/vim" ]] && echo symlink || echo directory)"
check "the application's file is back at the destination" "yes" \
    "$([[ -f "$XDG_CONFIG_HOME/vim/foreign.lua" ]] && echo yes || echo no)"
check "it is not inside the repository" "0" \
    "$([[ -e "$SANDBOX/legacy/config/vim/foreign.lua" ]] && echo 1 || echo 0)"
check "the repository's own file is linked" "yes" \
    "$([[ "$(readlink "$XDG_CONFIG_HOME/vim/vimrc")" == "$SANDBOX/legacy/config/vim/vimrc" ]] && echo yes || echo no)"

echo
echo "### T6  a loop symlink is found, and real files beside it are left alone"
mkdir -p "$SANDBOX/repo/config/loopy"
ln -sfn "$SANDBOX/repo/config/loopy" "$SANDBOX/repo/config/loopy/self"
printf 'keep me\n' > "$XDG_CONFIG_HOME/keepme.txt"
check "status reports the loop" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -c 'config/loopy/self')"
check "status counts it as an issue" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -c 'item(s) need attention')"
check "the file beside it is untouched" "keep me" "$(cat "$XDG_CONFIG_HOME/keepme.txt")"
rm -rf "$SANDBOX/repo/config/loopy"

echo
echo "### T7  every verdict config sync can reach"
check "a healthy link is ok" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -cE '^  ok +.*starship\.toml')"
check "a missing link is absent" "1" "$(rm -f "$XDG_CONFIG_HOME/lazygit/config.yml"; \
    mgr "$SANDBOX/repo" config status | grep -cE 'absent +.*lazygit/config\.yml')"
mgr "$SANDBOX/repo" install --with-git-tui >/dev/null 2>&1
# A tool directory the repository does not manage at all: its files are walked
# and offered. (Inside a directory that holds managed files, only the managed
# ones are known and the rest is left alone — which is why the app's state file
# above was neither offered nor touched.)
mkdir -p "$XDG_CONFIG_HOME/mytool"
printf 'setting = 1\n' > "$XDG_CONFIG_HOME/mytool/settings.conf"
check "an unmanaged tool's file is a candidate" "1" \
    "$(mgr "$SANDBOX/repo" config sync --dry-run | grep -c 'mytool/settings\.conf')"
rm -rf "$XDG_CONFIG_HOME/mytool"
# A differing real file: the link has to be broken first, or the write goes
# through it into the repository — which is what the file-level design prevents
# for an application, and what this test would otherwise walk into.
rm -f "$XDG_CONFIG_HOME/lazygit/config.yml"
printf 'mine, differs\n' > "$XDG_CONFIG_HOME/lazygit/config.yml"
check "a differing real file is a conflict" "1" \
    "$(mgr "$SANDBOX/repo" config sync --dry-run | grep -c 'CONFLICT.*lazygit/config\.yml')"
check "it was not written into the repository" "0" \
    "$(grep -c 'mine, differs' "$SANDBOX/repo/config/lazygit/config.yml")"
check "sync refuses to touch it without a decision" "1" \
    "$(grep -c 'mine, differs' "$XDG_CONFIG_HOME/lazygit/config.yml")"
rm -f "$XDG_CONFIG_HOME/lazygit/config.yml"; mgr "$SANDBOX/repo" install --with-git-tui >/dev/null 2>&1

echo
echo "### T8  local content wins by being adopted"
printf '[mytool]\n    theme = local\n' > "$XDG_CONFIG_HOME/mytool.conf"
mgr "$SANDBOX/repo" config adopt "$XDG_CONFIG_HOME/mytool.conf" > "$SANDBOX/t8.out" 2>&1
check "the file moved into the repository" "1" \
    "$([[ -f "$SANDBOX/repo/config/mytool.conf" ]] && echo 1 || echo 0)"
check "the local content is what the repository now holds" "1" \
    "$(grep -c 'theme = local' "$SANDBOX/repo/config/mytool.conf")"
check "the destination is a link to it" "yes" \
    "$([[ "$(readlink "$XDG_CONFIG_HOME/mytool.conf")" == "$SANDBOX/repo/config/mytool.conf" ]] && echo yes || echo no)"
# Adopting over a file the repository already has is refused: that is the one
# case where adopting would replace repository content instead of adding to it.
printf '[user]\n    name = Local Person\n' > "$XDG_CONFIG_HOME/git/work.ini"
mgr "$SANDBOX/repo" config adopt "$XDG_CONFIG_HOME/git/work.ini" > "$SANDBOX/t8c.out" 2>&1 || true
check "adopting over an existing repository file is refused" "1" \
    "$(grep -c 'Already exists in the repository' "$SANDBOX/t8c.out")"
check "and the local file is still there" "1" \
    "$(grep -c 'Local Person' "$XDG_CONFIG_HOME/git/work.ini")"
SECRET='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
printf 'token = %s\n' "$SECRET" > "$XDG_CONFIG_HOME/risky.conf"
mgr "$SANDBOX/repo" config adopt "$XDG_CONFIG_HOME/risky.conf" > "$SANDBOX/t8b.out" 2>&1 || true
check "adopting a credential-looking file is flagged" "1" \
    "$(grep -c 'credential' "$SANDBOX/t8b.out" || true)"
rm -f "$XDG_CONFIG_HOME/risky.conf" "$SANDBOX/repo/config/risky.conf" 2>/dev/null

echo
echo "### T9  a value that disagrees between manager and shell refuses to install"
stage_repo "$SANDBOX/mismatch"
sed -i 's|^export DSH_HOME=.*|export DSH_HOME="$HOME/somewhere-else/dsh"|' \
    "$SANDBOX/mismatch/config/bash/rc.d/10-env.sh"
rc=0
OUT="$(mgr "$SANDBOX/mismatch" install)" || rc=$?
check "the install refuses" "1" "$rc"
check "it names the value that disagrees" "1" "$(printf '%s\n' "$OUT" | grep -c 'DSH_HOME MISMATCH')"
check "it prints what the manager would use" "1" "$(printf '%s\n' "$OUT" | grep -c 'manager uses:')"
check "it prints what the shell will use" "1" "$(printf '%s\n' "$OUT" | grep -c 'shell will use:')"
check "it says it is refusing" "1" "$(printf '%s\n' "$OUT" | grep -c 'refusing to continue in strict mode')"

echo
echo "### T10  a source renamed in the repository leaves no orphan behind"
# The renamed file is a NEW file as far as git is concerned, and ownership is
# decided by the index, so it stays unmanaged until it is added — that is the
# design, not an omission. What must not survive is the record and the dangling
# link the old name left behind.
cp "$SANDBOX/repo/config/bash/rc.d/50-ble.sh" "$SANDBOX/repo/config/bash/rc.d/55-ble.sh"
rm "$SANDBOX/repo/config/bash/rc.d/50-ble.sh"
check "status reports the orphaned record" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -c 'Orphaned Records')"
check "the renamed file stays unmanaged while it is untracked" "0" \
    "$(mgr "$SANDBOX/repo" install >/dev/null 2>&1; [[ -L "$XDG_CONFIG_HOME/bash/rc.d/55-ble.sh" ]] && echo 1 || echo 0)"
mgr "$SANDBOX/repo" config sync --yes > "$SANDBOX/t10.out" 2>&1
check "sync removes the orphaned link" "0" \
    "$([[ -L "$XDG_CONFIG_HOME/bash/rc.d/50-ble.sh" ]] && echo 1 || echo 0)"
check "the record is gone from the manifest" "0" \
    "$(grep -c '50-ble.sh' "$XDG_STATE_HOME/dotfiles/manifest.tsv" || true)"
check "sync says what it removed" "1" "$(grep -c 'Removed dangling link' "$SANDBOX/t10.out")"
git -C "$SANDBOX/repo" add config/bash/rc.d/55-ble.sh
mgr "$SANDBOX/repo" install >/dev/null 2>&1
check "once tracked, the next install links it" "yes" \
    "$([[ -L "$XDG_CONFIG_HOME/bash/rc.d/55-ble.sh" ]] && echo yes || echo no)"

echo
echo "### T11  update reports without upgrading"
stub_versions
: > "$STUB_LOG"
OUT="$(mgr "$SANDBOX/repo" update --dry-run)"
check "the plan names the tools" "1" "$(printf '%s\n' "$OUT" | grep -c 'pnpm self-update')"
check "it says nothing was changed" "1" "$(printf '%s\n' "$OUT" | grep -c 'Dry run: nothing was changed')"
# Version probes are expected; an update command is not.
check "no update command was issued" "0" \
    "$(grep -cE '(^|\|)(self-update|add -g|runtime set|update)$' "$STUB_LOG" || true)"
check "pnpm's version did not move" "12.3.4" "$(cat "$STUB_VERSIONS/pnpm")"

echo
echo "### T12  the manifest round-trips, and an unversioned one is migrated"
MF="$XDG_STATE_HOME/dotfiles/manifest.tsv"
check "the manifest is versioned" "1" "$(grep -c '^version	2$' "$MF")"
run_fn() {
    ( cd "$SANDBOX/repo" || exit 1
      export PATH="$SANDBOX/bin:$HOME/.local/bin:$PNPM_HOME/bin:$COREUTILS"
      # shellcheck disable=SC1091
      source lib/common.sh; source lib/xdg.sh
      init_xdg_env >/dev/null 2>&1
      "$@"
    ) 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
run_fn manifest_set link config/x "$HOME/.config/roundtrip" link deadbeef >/dev/null
check "a record reads back with its hash" "1" \
    "$(run_fn manifest_get "$HOME/.config/roundtrip" | grep -c 'deadbeef')"
run_fn manifest_set link config/y "$HOME/.config/roundtrip" link cafe >/dev/null
check "writing again replaces rather than appends" "1" \
    "$(grep -c 'roundtrip' "$MF")"
run_fn manifest_remove "$HOME/.config/roundtrip" >/dev/null
check "removing it leaves no record" "0" "$(grep -c 'roundtrip' "$MF" || true)"
cp "$MF" "$SANDBOX/manifest.keep"
printf 'link\tconfig/z\t%s/.config/legacy\tlink\t-\n' "$HOME" > "$MF"
run_fn manifest_init >/dev/null
check "an unversioned manifest gains a header" "1" "$(grep -c '^version	2$' "$MF")"
check "and keeps its records" "1" "$(grep -c 'legacy' "$MF")"
cp "$SANDBOX/manifest.keep" "$MF"

echo
echo "### T13  without a terminal nothing is changed, and the exit status says so"
printf 'mine, differs again\n' > "$XDG_CONFIG_HOME/lazygit/config.yml"
rc=0; mgr "$SANDBOX/repo" config sync > "$SANDBOX/t13.out" 2>&1 || rc=$?
check "config sync exits 2" "2" "$rc"
check "it says why" "1" "$(grep -c 'No terminal: nothing was changed' "$SANDBOX/t13.out")"
check "the differing file is untouched" "1" "$(grep -c 'mine, differs again' "$XDG_CONFIG_HOME/lazygit/config.yml")"
check "install never prompts without a terminal" "1" \
    "$(mgr "$SANDBOX/repo" install > "$SANDBOX/t13b.out" 2>&1; grep -c 'Dotfiles Setup Completed Successfully' "$SANDBOX/t13b.out")"

echo
echo "### T14  a seeded file belongs to the machine"
# Back to the state a fresh machine is in: a real file at the seed destination.
# (T8 adopted work.ini, so it is a link by now and writing to it would write
# into the repository -- which is the very thing this test exists to check.)
rm -f "$XDG_CONFIG_HOME/git/work.ini"
printf '[user]\n    name = Hand Written\n' > "$XDG_CONFIG_HOME/git/work.ini"
mgr "$SANDBOX/repo" install --with-git-tui --with-dsh > "$SANDBOX/t14.out" 2>&1
check "the seeded file is not overwritten" "1" \
    "$(grep -c 'Hand Written' "$XDG_CONFIG_HOME/git/work.ini")"
check "it stays a real file, not a link" "regular" \
    "$([[ -L "$XDG_CONFIG_HOME/git/work.ini" ]] && echo symlink || echo regular)"
check "sync does not offer it as a conflict" "0" \
    "$(mgr "$SANDBOX/repo" config sync --dry-run | grep -c 'CONFLICT.*work\.ini')"
# The other half of the seed contract: a real file there is the intended end
# state, so status must not report the machine as needing attention because of
# it. It did, on every run, and a warning that is always on is a warning nobody
# reads.
check "status calls it seeded, not blocked" "1" \
    "$(mgr "$SANDBOX/repo" config status | grep -cE '^  seeded +.*work\.ini')"
# And with nothing else outstanding — the conflict T13 deliberately left, and
# the link T5 pointed at the second clone — a repaired machine reports no issues
# at all. Both are put back to the single checkout this sandbox manages.
rm -f "$XDG_CONFIG_HOME/lazygit/config.yml" "$XDG_CONFIG_HOME/vim/vimrc"
mgr "$SANDBOX/repo" install --with-git-tui >/dev/null 2>&1
rc=0; mgr "$SANDBOX/repo" config status > "$SANDBOX/t14status.out" 2>&1 || rc=$?
check "a fully repaired machine reports no issues at all" "0" "$rc"

echo
echo "### Wrapping parity — the hook and the formatter must agree byte for byte"
# Both carry the same awk rules inline, because neither can locate a sibling
# file reliably through a symlinked directory. That duplication is deliberate,
# and this is what keeps the two copies in step: the hook's injected draft and
# the formatter's output for the same source must be identical, or a message
# would change shape depending on whether an agent wrote it.
DRAFT="$SANDBOX/draft.txt"
printf 'fix(scope): a subject line\n\nA paragraph long enough that it has to wrap somewhere before the seventy-second column is reached, followed by a bullet.\n\n- a bullet long enough to need a continuation line, which has to stay indented under its marker instead of starting at column zero\n\nRefs: #12\n' > "$DRAFT"
cp "$DRAFT" "$SANDBOX/repo/.git/AI_COMMIT_MSG"
: > "$SANDBOX/msg.txt"
( cd "$SANDBOX/repo" && config/git/hooks/prepare-commit-msg "$SANDBOX/msg.txt" "" ) >/dev/null 2>&1
"$SANDBOX/repo/config/git/wrap-msg.sh" < "$DRAFT" > "$SANDBOX/expected.txt"
# The hook prepends the wrapped draft and leaves the (empty) message beneath it;
# command substitution drops the trailing blank line both sides end with.
printf '%s\n' "$(cat "$SANDBOX/msg.txt")" > "$SANDBOX/msg.one"
printf '%s\n' "$(cat "$SANDBOX/expected.txt")" > "$SANDBOX/expected.one"
check "the hook and the formatter produce the same message" "identical" \
    "$(cmp -s "$SANDBOX/msg.one" "$SANDBOX/expected.one" && echo identical || echo different)"
check "the draft was actually wrapped" "1" \
    "$(grep -c 'has to wrap somewhere before' "$SANDBOX/expected.txt")"
check "no line exceeds 72 columns" "0" "$(awk 'length > 72' "$SANDBOX/expected.txt" | wc -l)"
check "the bullet keeps its continuation indent" "1" \
    "$(grep -c '^  indented under its marker' "$SANDBOX/expected.txt")"
check "the trailer is not wrapped" "1" "$(grep -c '^Refs: #12$' "$SANDBOX/expected.txt")"
rm -f "$SANDBOX/repo/.git/AI_COMMIT_MSG"

echo
echo "───────────────────────────────────────────────"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
echo
echo "NOT RUN HERE: the interactive prompts ([a/d/q], y/N). This sandbox has no"
echo "PTY, so T7's and T13's fail-closed paths are asserted instead. The prompts"
echo "themselves are run by hand — see the note at the end of the step."
echo
[[ "$FAIL" -eq 0 ]]
