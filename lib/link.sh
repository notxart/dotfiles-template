#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/link.sh — Symlink engine: registry, three ownership modes, health, orphans
#
# This engine never moves and never overwrites: anything in the way is reported as
# `blocked` and handed to `config sync`, where a human decides. Records are FILE level.
# ==============================================================================

readonly LINK_EXISTS=0
readonly LINK_CREATED=10
readonly LINK_BLOCKED=20
readonly LINK_UNMANAGED=30
readonly LINK_MISSING_SRC=40

# State suffixes, mirroring the four _release_ states of the registry below.
readonly LINK_STATE_ABSENT="absent"
readonly LINK_STATE_OK="ok"
readonly LINK_STATE_STALE="stale"
readonly LINK_STATE_BLOCKED="blocked"

# ==============================================================================
# Registry — the single source of truth for what this repository links where.
#
# Records are "<src relative to the repo root>\t<absolute dest>\t<mode>", all FILE level:
# `~/.config/<tool>/` stays a real directory, so nothing written there reaches the tree.
# ==============================================================================

# link_registry_skill_dest <name> — where a skill directory is linked.
link_registry_skill_dest() {
    printf '%s\n' "${DSH_HOME:-$XDG_DATA_HOME/dsh}/skills/$1"
}

# link_is_tracked <path> — is this file part of the repository (in the index)? Globs
# alone cannot tell a repository module from a private file that once landed inside
# the tree. No subprocess and no cached state: it is called from command
# substitutions, where a cache cannot survive, and per-file git/grep calls once cost
# 300 processes per install and swallowed the stream the caller was iterating.
link_is_tracked() {
    local rel="$1" set
    # A source must be BOTH tracked and present: `git ls-files` keeps reporting a file
    # deleted from the working tree but not yet staged.
    [[ -e "${LINK_REPO_ROOT:-$SCRIPT_DIR}/$rel" ]] || return 1

    # Exported so the command substitutions below inherit it instead of re-querying.
    set="${LINK_TRACKED_SET:-}"
    if [[ -z "$set" ]]; then
        set="$(git -C "${LINK_REPO_ROOT:-$SCRIPT_DIR}" ls-files 2>/dev/null </dev/null)"
        LINK_TRACKED_SET="$set"
        export LINK_TRACKED_SET
    fi
    [[ $'\n'"$set"$'\n' == *$'\n'"$rel"$'\n'* ]]
}

# link_repo_root — the working tree git actually knows about, cached once. Copied
# without .git (a fixture, an unzipped archive) git cannot answer and every file reads
# as untracked — the fail-safe direction: never link what is not tracked.
link_repo_root() {
    if [[ -z "${LINK_REPO_ROOT:-}" ]]; then
        if LINK_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null </dev/null)" \
           && [[ -n "$LINK_REPO_ROOT" ]]; then
            :
        else
            LINK_REPO_ROOT="$SCRIPT_DIR"
        fi
    fi
    printf '%s\n' "$LINK_REPO_ROOT"
}

# link_registry_bash — the shell layer. rc.d is globbed, not listed, so adding a
# tracked module needs no edit here; untracked files are excluded.
link_registry_bash() {
    printf '%s\t%s\t%s\n' "config/bash/main.sh" "$XDG_CONFIG_HOME/bash/main.sh" "link"
    local f rel
    for f in "$SCRIPT_DIR"/config/bash/rc.d/*.sh; do
        [[ -e "$f" ]] || continue
        rel="config/bash/rc.d/$(basename "$f")"
        link_is_tracked "$rel" || continue
        printf '%s\t%s\t%s\n' "$rel" "$XDG_CONFIG_HOME/bash/rc.d/$(basename "$f")" "link"
    done
}

# link_registry_git — identity, work identity, and the global hooks. work.ini is a
# SEED, not a link: it ships empty so a commit refuses until a company identity is
# filled in, and a link would point that email into the working tree.
link_registry_git() {
    printf '%s\t%s\t%s\n' "config/git/config.ini" "$XDG_CONFIG_HOME/git/config.ini" "link"
    printf '%s\t%s\t%s\n' "config/git/work.ini"   "$XDG_CONFIG_HOME/git/work.ini"   "seed"
    local f rel
    for f in "$SCRIPT_DIR"/config/git/hooks/*; do
        [[ -e "$f" ]] || continue
        rel="config/git/hooks/$(basename "$f")"
        # Same reasoning as rc.d: a *.local hook here is the user's, not ours.
        link_is_tracked "$rel" || continue
        printf '%s\t%s\t%s\n' "$rel" "$XDG_CONFIG_HOME/git/hooks/$(basename "$f")" "link"
    done
}

# link_registry — the registry, computed ONCE per process and cached, because callers
# consume it through process substitutions that stop early and so closed the pipe
# mid-print (up to 240 "write error: Broken pipe" per install). Deliberately not
# exported: a stale cache must not outlive a flag change.
link_registry() {
    if [[ -z "${LINK_REGISTRY_CACHE:-}" ]]; then
        local built
        built="$(link_registry_build)" || return 1
        # Mark as computed even when the registry is legitimately empty, so it
        # is not rebuilt on every call.
        if [[ -z "$built" ]]; then
            LINK_REGISTRY_CACHE=$'\n'
        else
            # Trailing newline is part of the contract: callers use
            # `while IFS= read -r line`, which drops a final line that lacks one.
            LINK_REGISTRY_CACHE="$built"$'\n'
        fi
    fi
    printf '%s' "$LINK_REGISTRY_CACHE"
}

# link_registry_build — the actual list. Call link_registry instead.
link_registry_build() {
    printf '%s\t%s\t%s\n' ".bash_profile"      "$HOME/.bash_profile"      "link"
    printf '%s\t%s\t%s\n' ".bashrc"            "$HOME/.bashrc"            "link"
    link_registry_bash
    link_registry_git
    printf '%s\t%s\t%s\n' "config/vim/vimrc"   "$XDG_CONFIG_HOME/vim/vimrc"      "link"
    printf '%s\t%s\t%s\n' "config/starship.toml" "$XDG_CONFIG_HOME/starship.toml" "link"

    # Optional toolchain, per machine. config.toml only: hunk keeps its session
    # state in state.json beside it, and that state must never be linked.
    if [[ "${FLAG_GIT_TUI:-0}" -eq 1 ]]; then
        printf '%s\t%s\t%s\n' "config/hunk/config.toml"     "$XDG_CONFIG_HOME/hunk/config.toml"     "link"
        printf '%s\t%s\t%s\n' "config/lazygit/config.yml"   "$XDG_CONFIG_HOME/lazygit/config.yml"   "link"
    fi

    # Agent skills are discovered dynamically, one link per FILE — never per directory:
    # a directory link would carry every file written beside SKILL.md into the working
    # tree. Nested files are linked too, so a skill shipping resources keeps working.
    if [[ "${FLAG_WITH_DSH:-0}" -eq 1 ]]; then
        local skill_dir skill_name skill_file rel
        for skill_dir in "$SCRIPT_DIR"/skills/*/; do
            [[ -d "$skill_dir" ]] || continue
            skill_name="$(basename "$skill_dir")"
            while IFS= read -r skill_file; do
                [[ -n "$skill_file" ]] || continue
                rel="${skill_file#"$skill_dir"}"
                printf '%s\t%s\t%s\n' \
                    "skills/$skill_name/$rel" "$(link_registry_skill_dest "$skill_name")/$rel" "link"
            done < <(find "$skill_dir" -type f 2>/dev/null | sort)
        done
    fi
}

# link_registry_records — the SETTLED half: no optional toolchain, no discovered
# skills. Orphan detection uses this, so a flag toggled off cannot look like a user
# who deleted repository files.
link_registry_records() {
    printf '%s\t%s\t%s\n' ".bash_profile"        "$HOME/.bash_profile"              "link"
    printf '%s\t%s\t%s\n' ".bashrc"              "$HOME/.bashrc"                    "link"
    link_registry_bash
    link_registry_git
    printf '%s\t%s\t%s\n' "config/vim/vimrc"     "$XDG_CONFIG_HOME/vim/vimrc"       "link"
    printf '%s\t%s\t%s\n' "config/starship.toml" "$XDG_CONFIG_HOME/starship.toml"  "link"
}

# link_registry_release — the DISCOVERED half: records that may legitimately
# disappear when a flag is turned off or a skill directory is removed.
link_registry_release() {
    local all
    all="$(link_registry)"
    printf '%s\n' "$all" | grep -vFf <(link_registry_records) || true
}

# link_registry_refs — the repository-relative sources, one per line. A batch lookup:
# per-file calls meant hundreds of subshells per install, plus SIGPIPE on early exit.
link_registry_refs() {
    link_registry | cut -f1
}

# link_registry_dest_dirs — every distinct parent of a registry destination, i.e. the
# directories that must be REAL. Derived rather than hardcoded, so a new record cannot
# forget it; `migrate` uses it to find what still needs converting.
link_registry_dest_dirs() {
    link_registry | awk -F'\t' '
        {
            d = $2
            sub(/\/[^\/]*$/, "", d)      # strip the final component
            if (d != "" && !seen[d]++) print d
        }
    ' | sort
}

# link_mode <dest> — which ownership rule applies. The manifest wins: it
# records what the user decided during `config sync` (an adopted file or an
# explicit ignore), and that decision outlives the registry default.
link_mode() {
    local dest="$1" record mode
    record="$(manifest_get "$dest" 2>/dev/null || true)"
    if [[ -n "$record" ]]; then
        mode="$(printf '%s\n' "$record" | cut -f4 | awk 'NR==1{print; exit}')"
        if [[ -n "$mode" ]]; then
            printf '%s\n' "$mode"
            return 0
        fi
    fi
    mode="$(link_registry | awk -F'\t' -v d="$dest" '$2 == d { print $3; exit }')"
    printf '%s\n' "${mode:-link}"
}

# link_resolve <src> <dest> — canonical absolute source and destination.
link_resolve() {
    local src="$1" dest="$2"
    [[ "$src" != /* ]] && src="$SCRIPT_DIR/$src"
    printf '%s\t%s\n' "$src" "$dest"
}

# link_health <src> <dest> — classify the current on-disk state.
#   absent   nothing there yet
#   ok       a symlink already pointing at src
#   stale    a symlink pointing elsewhere, or a dangling symlink
#   blocked  a real file or directory occupies the destination
link_health() {
    local src="$1" dest="$2" current
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
        printf '%s\n' "$LINK_STATE_ABSENT"
        return 0
    fi
    if [[ ! -L "$dest" ]]; then
        printf '%s\n' "$LINK_STATE_BLOCKED"
        return 0
    fi
    current="$(readlink "$dest")"
    if [[ "$current" != "$src" ]]; then
        printf '%s\n' "$LINK_STATE_STALE"
        return 0
    fi
    if [[ ! -e "$dest" ]]; then
        # Symlink points at src but src is gone (the user deleted it).
        printf '%s\n' "$LINK_STATE_STALE"
        return 0
    fi
    # No content comparison: a symlink to the registered source HAS the repository's
    # content by definition. Comparing it to a recorded hash reported every file the
    # repository later edited as stale, and nothing ever cleared the alarm. Divergence
    # that matters is caught above: not a symlink is blocked, a different target stale.
    printf '%s\n' "$LINK_STATE_OK"
}

# link_record <src> <dest> <mode> <kind> — persist the ownership decision.
# kind is the manifest column: link, seed or adopt.
link_record() {
    local src="$1" dest="$2" mode="$3" kind="$4"
    local hash="-" src_rel
    # src_rel is computed on its own line: `local a="$1" b="$a"` publishes all its
    # names first, so b would get "" and `set -u` would abort on the reference.
    src_rel="${src#"$SCRIPT_DIR"/}"
    # Only genuine repository files get a hash, and it is NOT an input to link_health:
    # a link's content is the repository's content by definition (see there).
    if [[ "$kind" != "seed" && -f "$src" ]]; then
        hash="sha256:$(sha256_file "$src")"
    fi
    manifest_set "$kind" "$src_rel" "$dest" "$mode" "$hash"
}

# link_apply <src> <dest> — create the link if and only if that is safe.
# Never moves a file, never overwrites a non-symlink. Returns one of the
# LINK_* codes; every non-zero code except LINK_CREATED means "left untouched".
link_apply() {
    local src="$1" dest="$2" mode="${3:-link}" health parent
    health="$(link_health "$src" "$dest")"

    # An explicit `ignored` decision is recorded but never acted upon.
    if [[ "$mode" == "ignored" ]]; then
        printf '  %s\n' "Ignored by manifest: $dest"
        return "$LINK_UNMANAGED"
    fi

    # seed: the file is a starting point the user then owns. Write it once,
    # never touch it again.
    if [[ "$mode" == "seed" ]]; then
        if [[ "$health" == "$LINK_STATE_ABSENT" ]]; then
            parent="$(dirname "$dest")"
            mkdir -p "$parent"
            if cp "$src" "$dest" 2>/dev/null; then
                log_info "Seeded: $dest (you own this file from now on)"
                link_record "$src" "$dest" "$mode" "seed"
                return "$LINK_CREATED"
            fi
            log_warn "Could not seed $dest"
            return "$LINK_BLOCKED"
        fi
        log_info "Kept existing: $dest (seed mode never overwrites)"
        link_record "$src" "$dest" "$mode" "seed"
        return "$LINK_EXISTS"
    fi

    case "$health" in
        "$LINK_STATE_OK")
            return "$LINK_EXISTS"
            ;;
        "$LINK_STATE_BLOCKED")
            log_warn "Blocked: $dest is a real file or directory, not a symlink."
            return "$LINK_BLOCKED"
            ;;
        "$LINK_STATE_STALE")
            # A DANGLING link carries no information and is safe to replace; one that
            # POINTS ELSEWHERE has a target that exists and removing it would destroy
            # that decision. The exception is a file destination pointing at a directory
            # — the old directory-level shape, which cannot serve the application.
            local current
            current="$(readlink "$dest" 2>/dev/null || true)"
            if [[ -n "$current" && -e "$dest" && ! -d "$dest" ]]; then
                log_warn "Points elsewhere: $dest -> $current"
                log_info "Left untouched. Re-point it or remove it, then re-run."
                return "$LINK_BLOCKED"
            fi
            if [[ ! -e "$src" ]]; then
                log_warn "Missing source for $dest: $src"
                return "$LINK_MISSING_SRC"
            fi
            rm -f "$dest"
            ;;
    esac

    if [[ ! -e "$src" ]]; then
        log_warn "Missing source for $dest: $src"
        return "$LINK_MISSING_SRC"
    fi

    parent="$(dirname "$dest")"
    mkdir -p "$parent"

    # `ln -s` onto an existing directory target would create a child inside it
    # instead of replacing it: assert the destination is gone or a plain file.
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        log_warn "Refusing to link over a real path: $dest"
        return "$LINK_BLOCKED"
    fi

    if ln -sfn "$src" "$dest" 2>/dev/null; then
        log_info "Linked: $dest -> $src"
        link_record "$src" "$dest" "$mode" "link"
        return "$LINK_CREATED"
    fi
    log_error "Failed to create symlink: $dest"
    return "$LINK_BLOCKED"
}

# link_find_orphans — manifest records whose source no longer exists in the repository,
# reported for both halves so a flag toggled off is surfaced rather than dropped.
# Prints "<dest>\t<src_rel>\t<reason>".
link_find_orphans() {
    local kind src dest seen=0 line
    while IFS=$'\t' read -r kind src dest _rest; do
        [[ -n "$dest" ]] || continue
        if [[ "$kind" == "ignore" || "$src" == "-" || -z "$src" ]]; then
            continue   # adopted/ignored records carry no repository source
        fi
        if [[ ! -e "$SCRIPT_DIR/$src" && ! -L "$SCRIPT_DIR/$src" ]]; then
            if printf '%s\n' "$(link_registry_release)" | awk -F'\t' -v d="$dest" '$2 == d { found = 1 } END { exit !found }'; then
                printf '%s\t%s\t%s\n' "$dest" "$src" "flag-toggled-off"
            else
                printf '%s\t%s\t%s\n' "$dest" "$src" "source-deleted"
            fi
            seen=1
        fi
    done < <(manifest_list)
    return $((seen == 1 ? 0 : 1))
}

# link_prune_orphans [--dry-run] — remove ONLY records whose destination is still a
# symlink into this repository. A destination the user replaced with a real file is
# left alone and reported: dropping the record would hide a file they care about.
link_prune_orphans() {
    local dry=0
    [[ "${1:-}" == "--dry-run" ]] && dry=1
    local dest src reason current removed=0 skipped=0

    while IFS=$'\t' read -r dest src reason; do
        [[ -n "$dest" ]] || continue
        if [[ ! -L "$dest" ]]; then
            log_info "Keeping record for $dest ($reason): destination is no longer a symlink."
            skipped=$((skipped + 1))
            continue
        fi
        current="$(readlink "$dest")"
        if [[ "$current" != "$SCRIPT_DIR"/* ]]; then
            log_info "Keeping record for $dest ($reason): symlink points outside this repository."
            skipped=$((skipped + 1))
            continue
        fi
        if [[ "$dry" -eq 1 ]]; then
            log_info "Would remove: $dest -> $current ($reason)"
        else
            rm -f "$dest"
            log_info "Removed dangling link: $dest ($reason)"
        fi
        manifest_remove "$dest"
        removed=$((removed + 1))
    done < <(link_find_orphans || true)

    [[ "$dry" -eq 1 ]] && log_info "Dry run: $removed link(s) would be removed, $skipped kept."
    return 0
}

# ==============================================================================
# Install-time orchestration
# ==============================================================================

# link_setup — create the links this machine asked for: it deliberately moves nothing
# and overwrites nothing, counting what is in the way and handing it to `config sync`
# for a human decision. A link pointing outside this repository is never silently
# retargeted — the user may have pointed that config at another checkout on purpose.
# The count left for reconciliation ends up in LINK_SETUP_PENDING.
link_setup() {
    log_step "Synchronizing Dotfiles & Symlinks"
    LINK_SETUP_PENDING=0
    LINK_SETUP_BLOCKED=()
    local src dest mode health n created=0 kept=0 blocked=0 wrong_target=0 missing_src=0

    # Buffer the registry FIRST: the loop body runs external commands that would
    # otherwise consume the producer's stream and end the loop early with SIGPIPE.
    local -a records=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && records+=("$line")
    done < <(link_registry)

    local record
    for record in "${records[@]}"; do
        IFS=$'\t' read -r src dest mode <<< "$record"
        [[ -n "$dest" ]] || continue
        n="$(link_resolve "$src" "$dest")"
        src="${n%%$'\t'*}"
        dest="${n##*$'\t'}"
        if [[ "$(link_mode "$dest")" == "ignored" ]]; then
            continue
        fi
        health="$(link_health "$src" "$dest")"
        if [[ "$health" == "$LINK_STATE_STALE" && -L "$dest" ]]; then
            # A symlink into a DIFFERENT checkout of this repository (one carrying
            # manager.sh) is not repointed silently: the user decides which clone wins.
            local current other_repo
            current="$(readlink "$dest")"
            other_repo=""
            if [[ "$current" == */* && -e "$current" ]]; then
                local probe
                probe="$(dirname "$current")"
                while [[ "$probe" != "/" && -n "$probe" ]]; do
                    if [[ -f "$probe/manager.sh" ]]; then
                        other_repo="$probe"
                        break
                    fi
                    probe="$(dirname "$probe")"
                done
            fi
            if [[ -n "$other_repo" && "$other_repo" != "$SCRIPT_DIR" ]]; then
                log_warn "Another clone owns this link: $dest -> $current"
                log_info "That is a different dotfiles checkout ($other_repo)."
                log_info "Re-point it or remove it, then re-run — left untouched."
                wrong_target=$((wrong_target + 1))
                continue
            fi
        fi
        local rc=0
        link_apply "$src" "$dest" "$mode" >/dev/null 2>&1 || rc=$?
        case "$rc" in
            "$LINK_CREATED") created=$((created + 1)) ;;
            "$LINK_EXISTS")  kept=$((kept + 1)) ;;
            "$LINK_BLOCKED")
                LINK_SETUP_BLOCKED+=("$dest")
                blocked=$((blocked + 1))
                ;;
            "$LINK_MISSING_SRC") missing_src=$((missing_src + 1)) ;;
            *) blocked=$((blocked + 1)) ;;
        esac
    done

    # Global Git hooks must stay executable.
    if [[ -d "$XDG_CONFIG_HOME/git/hooks" ]]; then
        local hook
        for hook in "$XDG_CONFIG_HOME/git/hooks"/*; do
            [[ -f "$hook" ]] && chmod +x "$hook"
        done
        log_success "Global Git hooks verified as executable."
    fi

    # A legacy ~/.vimrc takes precedence over the XDG vimrc (Vim reads it first), so
    # commit-message wrapping would silently not apply.
    if [[ -f "$HOME/.vimrc" ]]; then
        log_warn "$HOME/.vimrc exists and overrides $XDG_CONFIG_HOME/vim/vimrc"
        log_info "Remove it or merge your settings into the XDG vimrc to enable commit-message wrapping."
    fi

    # core.hooksPath is a fixed literal (~/.config/git/hooks) in config.ini, so a custom
    # XDG_CONFIG_HOME leaves git silently skipping the hooks installed there.
    if [[ "$XDG_CONFIG_HOME" != "$HOME/.config" ]]; then
        log_warn "XDG_CONFIG_HOME is not the default; core.hooksPath in config.ini still points to ~/.config/git/hooks"
        log_info "Set it explicitly: git config --global core.hooksPath \"$XDG_CONFIG_HOME/git/hooks\""
    fi

    log_success "Links: $created created, $kept already correct."
    LINK_SETUP_PENDING=$((blocked + wrong_target + missing_src))

    # One legacy directory link becomes one blocked record per file beneath it, so list
    # a few and count the rest; the migration consumes the full list to explain itself.
    if [[ "${#LINK_SETUP_BLOCKED[@]}" -gt 0 ]]; then
        local shown=0 p
        for p in "${LINK_SETUP_BLOCKED[@]}"; do
            [[ "$shown" -ge 3 ]] && break
            log_warn "In the way: ${p#"$HOME"/} (not a symlink)"
            shown=$((shown + 1))
        done
        if [[ "${#LINK_SETUP_BLOCKED[@]}" -gt "$shown" ]]; then
            log_info "…and $(( ${#LINK_SETUP_BLOCKED[@]} - shown )) more."
        fi
    fi

    # The caller (cmd_install) reports this count and explains what `config sync` does.
    return 0
}

# link_find_loops — self-referential links left by the old installer, on either side:
#   repo-side  <repo>/config/X/X            -> elsewhere    (injected by a 2nd clone)
#   dest-side  ~/.config/X/X -> ~/.config/X (ln -sf followed the directory link)
# Prints every offending path, one per line.
link_find_loops() {
    local root path parent
    for root in "$SCRIPT_DIR" "$XDG_CONFIG_HOME"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            parent="$(dirname "$path")"
            if [[ "$(readlink -f "$path")" == "$(readlink -f "$parent")" ]]; then
                printf '%s\n' "$path"
            fi
        done < <(find "$root" -maxdepth 4 -type l 2>/dev/null)
    done
}

# link_verify_all — report every registry record. Used by `config status`.
# Returns the number of records that are not healthy, via LINK_ISSUES.
link_verify_all() {
    LINK_ISSUES=0
    local src dest mode health n
    while IFS=$'\t' read -r src dest mode; do
        [[ -n "$dest" ]] || continue
        n="$(link_resolve "$src" "$dest")"
        src="${n%%$'\t'*}"
        dest="${n##*$'\t'}"
        [[ "$(link_mode "$dest")" == "ignored" ]] && continue
        health="$(link_health "$src" "$dest")"
        printf '%-8s %s -> %s\n' "$health" "$dest" "$src"
        [[ "$health" != "$LINK_STATE_OK" ]] && LINK_ISSUES=$((LINK_ISSUES + 1))
    done < <(link_registry)
    return 0
}
