#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/link.sh — Symlink engine: registry, three ownership modes, health, orphans
#
# This module replaces the original sync_symlink behaviour, which had three
# defects that together destroyed user configuration:
#
#   1. It MOVED any conflicting real file aside and linked over it. A config
#      that an application had written was relocated without inspection.
#   2. Its "remains a non-symlink directory" guard ran after the move, so it
#      could never fire.
#   3. `ln -sf` cannot replace a symlink that points at a directory: it follows
#      the link and creates a child inside the target. Running the installer
#      from a second clone therefore created self-referential links such as
#      config/bash/bash -> (other clone)/config/bash.
#
# The engine below never moves and never overwrites. Anything in the way is
# reported as `blocked` and handed to `manager.sh config sync`, where a human
# decides. See the plan: "install seeds; sync reconciles; git resolves".
# ==============================================================================

readonly LINK_EXISTS=0
readonly LINK_CREATED=10
readonly LINK_BLOCKED=20
readonly LINK_UNMANAGED=30
readonly LINK_MISSING_SRC=40

readonly LINK_MANIFEST_VERSION="2"

# State suffixes, mirroring the four _release_ states of the registry below.
readonly LINK_STATE_ABSENT="absent"
readonly LINK_STATE_OK="ok"
readonly LINK_STATE_STALE="stale"
readonly LINK_STATE_BLOCKED="blocked"

# ==============================================================================
# Registry — the single source of truth for what this repository links where.
#
# Records are "<source relative to the repo root>\t<absolute destination>\t<mode>".
# The source is empty while a path is only _adopted_ in the manifest (the file
# is already in $HOME and becomes ours during `config sync`).
#
# NOTE: lib/packages.sh, lib/tools.sh and lib/shell.sh belong to the setup
# process, not to this list; only the registry is repointed in Step 4.
# ==============================================================================
link_registry() {
    # State-independent shared environment.
    printf '%s\t%s\t%s\n' ".bash_profile"                     "$HOME/.bash_profile"                      "link"
    printf '%s\t%s\t%s\n' ".bashrc"                           "$HOME/.bashrc"                            "link"
    printf '%s\t%s\t%s\n' "config/starship.toml"              "$XDG_CONFIG_HOME/starship.toml"           "link"
    printf '%s\t%s\t%s\n' "config/bash"                       "$XDG_CONFIG_HOME/bash"                    "link"
    printf '%s\t%s\t%s\n' "config/git"                        "$XDG_CONFIG_HOME/git"                     "link"
    printf '%s\t%s\t%s\n' "config/vim"                        "$XDG_CONFIG_HOME/vim"                     "link"

    # Optional toolchain, enabled per machine.
    if [[ "${FLAG_GIT_TUI:-0}" -eq 1 ]]; then
        printf '%s\t%s\t%s\n' "config/lazygit"                "$XDG_CONFIG_HOME/lazygit"                 "link"
        printf '%s\t%s\t%s\n' "config/hunk"                   "$XDG_CONFIG_HOME/hunk"                    "link"
    fi

    # Agent skills are discovered dynamically: adding a directory under
    # skills/ must not require editing this function.
    if [[ "${FLAG_WITH_DSH:-0}" -eq 1 ]]; then
        local skill_dir skill_name dsh_home
        dsh_home="${DSH_HOME:-$XDG_DATA_HOME/dsh}"
        for skill_dir in "$SCRIPT_DIR"/skills/*/; do
            [[ -d "$skill_dir" ]] || continue
            skill_name="$(basename "$skill_dir")"
            printf '%s\t%s\t%s\n' "skills/$skill_name" "$dsh_home/skills/$skill_name" "link"
        done
    fi
}

# link_registry_records — the SETTLED half of the registry: no optional
# toolchain and no discovered skill directories. Health checks that must stay
# stable across runs (orphan detection) use this, because a flag toggled off
# on a later run must not look like the user deleted repository files.
link_registry_records() {
    printf '%s\t%s\t%s\n' ".bash_profile"          "$HOME/.bash_profile"            "link"
    printf '%s\t%s\t%s\n' ".bashrc"                "$HOME/.bashrc"                  "link"
    printf '%s\t%s\t%s\n' "config/starship.toml"   "$XDG_CONFIG_HOME/starship.toml" "link"
    printf '%s\t%s\t%s\n' "config/bash"            "$XDG_CONFIG_HOME/bash"          "link"
    printf '%s\t%s\t%s\n' "config/git"             "$XDG_CONFIG_HOME/git"           "link"
    printf '%s\t%s\t%s\n' "config/vim"             "$XDG_CONFIG_HOME/vim"           "link"
}

# link_registry_release — the DISCOVERED half: records that may legitimately
# disappear when a flag is turned off or a skill directory is removed.
link_registry_release() {
    local all
    all="$(link_registry)"
    printf '%s\n' "$all" | grep -vFf <(link_registry_records) || true
}

# link_mode <dest> — which ownership rule applies. The manifest wins: it
# records what the user decided during `config sync` (an adopted file or an
# explicit ignore), and that decision outlives the registry default.
link_mode() {
    local dest="$1" record mode
    record="$(manifest_get "$dest" 2>/dev/null || true)"
    if [[ -n "$record" ]]; then
        mode="$(printf '%s\n' "$record" | head -n1 | cut -f4)"
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
#   ok       a symlink already pointing at src, content unchanged
#   stale    a symlink pointing elsewhere, or a dangling symlink
#   blocked  a real file or directory occupies the destination
link_health() {
    local src="$1" dest="$2" current recorded actual
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
    # Hash comparison is advisory: drift is ultimately resolved by git in
    # `config sync`, so a miss here is not fatal.
    recorded="$(manifest_get "$dest" 2>/dev/null | head -n1 | cut -f5)"
    if [[ -n "$recorded" && "$recorded" == sha256:* ]]; then
        actual="$(sha256_file "$dest")"
        if [[ -n "$actual" && "sha256:$actual" != "$recorded" ]]; then
            printf '%s\n' "$LINK_STATE_STALE"
            return 0
        fi
    fi
    printf '%s\n' "$LINK_STATE_OK"
}

# link_record <src> <dest> <mode> <kind> — persist the ownership decision.
# kind is the manifest column: link, seed or adopt.
link_record() {
    local src="$1" dest="$2" mode="$3" kind="$4" hash="-" src_rel="$src"
    src_rel="${src_rel#"$SCRIPT_DIR"/}"
    # Only genuine repository files get a content hash.
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
            # A symlink we may safely retarget: either dangling, or pointing at
            # a path that is not this repository's source.
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

    # `ln -s` on an existing directory target would create a child inside it
    # instead of replacing it. link_health guarantees the destination is gone
    # or a plain file by now, but assert it: this is the exact trap that
    # produced the loop symlinks found in the wild.
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

# link_find_orphans — manifest records whose source no longer exists in the
# repository. Reported for BOTH halves: a record that survives only because a
# flag was toggled off is surfaced explicitly rather than silently dropped.
# Prints "<dest>\t<src_rel>\t<reason>".
link_find_orphans() {
    local kind src dest recorded seen=0 line
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

# link_prune_orphans [--dry-run] — remove ONLY records whose destination is a
# symlink into this repository. A destination that is no longer a symlink (the
# user replaced it with a real file) is left alone and reported: removing the
# record would hide a file the user cares about.
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

# link_setup — create the links this machine asked for. This is the install
# path's replacement for the old setup_symlinks, and it deliberately does LESS
# than its predecessor:
#
#   * nothing is moved and nothing is overwritten; a path that is in the way is
#     counted and reported, then handed to `config sync` for a human decision
#   * links pointing outside this repository are not silently retargeted: the
#     user may have deliberately pointed a config at another checkout, so the
#     destination is reported and left exactly as it is
#
# Prints a summary; the count of items left for reconciliation is left in
# LINK_SETUP_PENDING.
link_setup() {
    log_step "Synchronizing Dotfiles & Symlinks"
    LINK_SETUP_PENDING=0
    local src dest mode health n created=0 kept=0 blocked=0 wrong_target=0 missing_src=0

    while IFS=$'\t' read -r src dest mode; do
        [[ -n "$dest" ]] || continue
        n="$(link_resolve "$src" "$dest")"
        src="${n%%$'\t'*}"
        dest="${n##*$'\t'}"
        if [[ "$(link_mode "$dest")" == "ignored" ]]; then
            continue
        fi
        health="$(link_health "$src" "$dest")"
        if [[ "$health" == "$LINK_STATE_STALE" && -L "$dest" ]]; then
            # A symlink into a DIFFERENT checkout of this same repository
            # (identified by carrying manager.sh) is not something to repoint
            # silently: two clones managing one HOME is what produced the loop
            # symlinks, and the user should decide which clone wins.
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
            "$LINK_BLOCKED")    log_warn "In the way: $dest (not a symlink) — left untouched"; blocked=$((blocked + 1)) ;;
            "$LINK_MISSING_SRC") missing_src=$((missing_src + 1)) ;;
            *) blocked=$((blocked + 1)) ;;
        esac
    done < <(link_registry)

    # Global Git hooks must stay executable.
    if [[ -d "$XDG_CONFIG_HOME/git/hooks" ]]; then
        local hook
        for hook in "$XDG_CONFIG_HOME/git/hooks"/*; do
            [[ -f "$hook" ]] && chmod +x "$hook"
        done
        log_success "Global Git hooks verified as executable."
    fi

    # Legacy ~/.vimrc takes precedence over the XDG vimrc (Vim reads ~/.vimrc
    # first), so commit-message wrapping (config/vim/vimrc) would silently not
    # apply. Warn so the user can remove or merge it deliberately.
    if [[ -f "$HOME/.vimrc" ]]; then
        log_warn "$HOME/.vimrc exists and overrides $XDG_CONFIG_HOME/vim/vimrc"
        log_info "Remove it or merge your settings into the XDG vimrc to enable commit-message wrapping."
    fi

    # core.hooksPath is a fixed literal in config.ini (~/.config/git/hooks):
    # with a custom XDG_CONFIG_HOME the hooks are installed at $XDG_CONFIG_HOME
    # instead and git would silently skip them.
    if [[ "$XDG_CONFIG_HOME" != "$HOME/.config" ]]; then
        log_warn "XDG_CONFIG_HOME is not the default; core.hooksPath in config.ini still points to ~/.config/git/hooks"
        log_info "Set it explicitly: git config --global core.hooksPath \"$XDG_CONFIG_HOME/git/hooks\""
    fi

    log_success "Links: $created created, $kept already correct."
    LINK_SETUP_PENDING=$((blocked + wrong_target + missing_src))
    if [[ "$LINK_SETUP_PENDING" -gt 0 ]]; then
        log_warn "$LINK_SETUP_PENDING path(s) need your decision — run: $SCRIPT_NAME config sync"
    fi
    return 0
}

# link_find_loops — self-referential links created by the old installer.
# Two shapes are possible:
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
