#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/migrate.sh — Convert directory-level links into file-level links.
#
# The registry needs real directories, so a legacy whole-directory link must be swapped
# for one: files git does not track are rescued into $HOME first.
# ==============================================================================

# migrate_is_repo_dir <path> — true when <path> is a symlink resolving to a
# directory inside this repository. The second condition is what makes removal
# safe: a link pointing anywhere else is the user's business.
migrate_is_repo_dir() {
    local path="$1" resolved
    [[ -L "$path" ]] || return 1
    resolved="$(readlink -f "$path" 2>/dev/null)" || return 1
    [[ -n "$resolved" ]] || return 1
    [[ "$resolved" == "$SCRIPT_DIR"/* ]]
}

# migrate_repo_dir_for <destdir> — the repository directory a converted
# destination came from, or empty. Derived from the registry rather than
# guessed, so a destination is only ever adopted from its declared source.
migrate_repo_dir_for() {
    local destdir="$1" src
    # `awk ... exit` rather than `| head -n1`: head closes the pipe while the
    # producer is still printing, and bash then reports a write error per record.
    src="$(link_registry | awk -F'\t' -v d="$destdir/" '
        index($2, d) == 1 {          # $2 starts with the destination directory
            rest = substr($2, length(d) + 1)
            if (rest != "" && index(rest, "/") == 0) { print $1; exit }
        }
    ')"
    [[ -n "$src" ]] || return 1
    # config/bash/rc.d/10-env.sh -> config/bash
    local rel="${src%/*}"
    [[ "$rel" == "$src" ]] && return 1
    printf '%s\n' "$SCRIPT_DIR/$rel"
}

# migrate_registry_srcs — the repository-relative sources the registry owns, computed
# ONCE per run: re-deriving the registry per file costs hundreds of subshells.
migrate_registry_srcs() {
    if [[ -z "${MIGRATE_REGISTRY_SRCS:-}" ]]; then
        MIGRATE_REGISTRY_SRCS="$(link_registry_refs)"
    fi
    printf '%s\n' "$MIGRATE_REGISTRY_SRCS"
}

# migrate_repo_tracked <repodir> — files under <repodir> that git tracks but the
# registry does not link, such as config/git/wrap-msg.sh, which core.editor calls by
# absolute path. They stay in the repository, but must be named as not-foreign.
migrate_repo_tracked() {
    local repodir="$1"
    [[ -d "$repodir" ]] || return 0
    find "$repodir" -type f 2>/dev/null | sort | awk \
        -v root="$SCRIPT_DIR/" \
        -v tracked="$(git -C "$SCRIPT_DIR" ls-files 2>/dev/null </dev/null)" \
        -v linked="$(link_registry_refs)" '
        BEGIN {
            n = split(tracked, a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") is_tracked[a[i]] = 1
            m = split(linked, b, "\n")
            for (i = 1; i <= m; i++) if (b[i] != "") is_linked[b[i]] = 1
        }
        {
            rel = $0
            sub("^" root, "", rel)
            if ((rel in is_tracked) && !(rel in is_linked)) print $0
        }
    '
}

# migrate_foreign_in <repodir> — files under <repodir> that git does NOT track: user
# or application data that must leave the working tree before the directory is
# converted. The authority is the git index, not the registry — see above.
migrate_foreign_in() {
    local repodir="$1"
    [[ -d "$repodir" ]] || return 0
    find "$repodir" -type f 2>/dev/null | sort | awk \
        -v root="$SCRIPT_DIR/" \
        -v tracked="$(git -C "$SCRIPT_DIR" ls-files 2>/dev/null </dev/null)" '
        BEGIN {
            n = split(tracked, a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") is_tracked[a[i]] = 1
        }
        {
            rel = $0
            sub("^" root, "", rel)
            if (!(rel in is_tracked)) print $0
        }
    '
}

# migrate_plan — describe the conversion. Read-only: it prints what would
# happen and changes nothing. Output is a sequence of "ACTION\tARG..." lines so
# callers can render or count it without parsing prose.
migrate_plan() {
    local destdir repodir rel target
    while IFS= read -r destdir; do
        [[ -n "$destdir" ]] || continue
        migrate_is_repo_dir "$destdir" || continue
        repodir="$(migrate_repo_dir_for "$destdir" 2>/dev/null || true)"
        [[ -n "$repodir" ]] || continue

        printf 'convert\t%s\t%s\n' "$destdir" "$repodir"

        # Foreign files first: they must be out of the repository before the directory
        # is replaced. The destination is the link path ITSELF, not its dirname and not
        # its resolved target: the relative path from migrate_foreign_in already carries
        # the directory name, and `readlink -f` would point back inside the working tree.
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            target="$destdir/${rel#"$repodir"/}"
            printf 'move-file\t%s\t%s\n' "$rel" "$target"
        done < <(migrate_foreign_in "$repodir")


        # Loop symlinks injected by running the installer from a second clone.
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            printf 'remove-loop\t%s\n' "$rel"
        done < <(find "$repodir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null \
                 | while IFS= read -r l; do
                       [[ "$(readlink -f "$l" 2>/dev/null)" == "$(readlink -f "$repodir")" ]] && printf '%s\n' "$l"
                   done)
    done < <(link_registry_dest_dirs)
}

# migrate_needed — 0 when at least one destination still needs conversion. The stream
# is consumed, not tested with grep -q, for the SIGPIPE reason above.
migrate_needed() {
    migrate_plan | awk 'NF { found = 1 } END { exit !found }'
}

# migrate_print_plan [--all] — human-readable rendering of migrate_plan.
migrate_print_plan() {
    local plan line
    plan="$(migrate_plan)"
    if [[ -z "$plan" ]]; then
        return 0
    fi
    local converts=0 moves=0 loops=0
    while IFS=$'\t' read -r action a b; do
        case "$action" in
            convert)     converts=$((converts + 1)) ;;
            move-file)   moves=$((moves + 1)) ;;
            remove-loop) loops=$((loops + 1)) ;;
        esac
    done <<< "$plan"

    printf '\n'
    log_step "Legacy Directory Links Found"
    log_info "$converts director$([[ $converts -eq 1 ]] && echo y || echo ies) still linked as a whole; they must become real directories."

    while IFS=$'\t' read -r action a b; do
        case "$action" in
            convert)
                log_info "convert: ${a#"$HOME"/}"
                log_info "         from ${b#"$SCRIPT_DIR"/} (was a directory symlink)"
                ;;
            move-file)
                log_info "  rescue: ${a#"$SCRIPT_DIR"/} -> ${b#"$HOME"/}"
                log_info "          your file stays yours; adopt it later with 'config sync'"
                ;;
            remove-loop)
                log_info "  repair: remove loop symlink ${a#"$SCRIPT_DIR"/}"
                ;;
        esac
    done <<< "$plan"

    printf '\n'
    log_info "Nothing is deleted. Files the registry does not own are moved out of"
    log_info "the repository first and remain in your home directory."
}

# migrate_execute — perform the plan; safe to re-run, and every action comes from the
# plan, not recomputed. The link is renamed aside and a real directory created FIRST,
# because until then <destdir>/<name> and <repodir>/<name> are the same file and any
# "does the target exist?" test answers yes — which is how the rescue was once skipped
# and a user's file lost. Then the rescue, then cleanup. Tracked files never move.
migrate_execute() {
    local plan
    plan="$(migrate_plan)"
    [[ -n "$plan" ]] || return 0

    local action a b staging_dir
    staging_dir="$(state_dir)/migrate.$$"
    mkdir -p "$staging_dir" || {
        log_error "Could not create a staging directory at $staging_dir"
        return 1
    }

    # (1) Swap: rename the link aside, then create the real directory.
    local swapped=0
    while IFS=$'\t' read -r action a _b; do
        [[ "$action" == "convert" ]] || continue
        if ! migrate_is_repo_dir "$a"; then
            log_warn "Skipping ${a#"$HOME"/}: it is no longer a symlink into this repository."
            continue
        fi
        if ! mv "$a" "$staging_dir/$(basename "$a")" 2>/dev/null; then
            log_error "Could not move the link aside: ${a#"$HOME"/}"
            continue
        fi
        if ! mkdir -p "$a"; then
            log_error "Could not create the real directory: ${a#"$HOME"/}"
            mv "$staging_dir/$(basename "$a")" "$a" 2>/dev/null || true
            continue
        fi
        swapped=$((swapped + 1))
    done <<< "$plan"

    # (2) Rescue: the files are visible only through the staging link now, and each
    # target is a path in a real directory rather than an alias of the source.
    while IFS=$'\t' read -r action a b; do
        [[ "$action" == "move-file" ]] || continue
        if [[ -e "$b" || -L "$b" ]]; then
            log_warn "Not rescuing ${a#"$SCRIPT_DIR"/}: ${b#"$HOME"/} already exists."
            continue
        fi
        mkdir -p "$(dirname "$b")"
        if mv -n "$a" "$b" 2>/dev/null; then
            log_info "Rescued into your home: ${b#"$HOME"/}"
        else
            log_error "Could not rescue ${a#"$SCRIPT_DIR"/} — your file is still at:"
            log_error "  $a"
        fi
    done <<< "$plan"

    # (3) Clean up: loop symlinks, then the staging links. Removing a symlink never
    # removes its target, and only the LINK was moved aside, so tracked files the
    # registry does not link were never disturbed and need no action here.
    while IFS=$'\t' read -r action a _b; do
        [[ "$action" == "remove-loop" ]] || continue
        rm -f "$a" && log_info "Removed loop symlink: ${a#"$SCRIPT_DIR"/}"
    done <<< "$plan"

    while IFS=$'\t' read -r action a _b; do
        [[ "$action" == "convert" ]] || continue
        [[ -L "$staging_dir/$(basename "$a")" ]] || continue
        rm -f "$staging_dir/$(basename "$a")"
        # The DIRECTORY's record is dropped: its files are the managed destinations
        # from now on. Left behind it would be an orphan, and link_prune_orphans
        # refuses to remove a record whose destination is no longer a symlink.
        manifest_remove "$a" 2>/dev/null || true
        log_info "Converted to a real directory: ${a#"$HOME"/}"
    done <<< "$plan"

    rmdir "$staging_dir" 2>/dev/null || true

    if [[ "$swapped" -eq 0 ]]; then
        return 0
    fi

    # The file-level links themselves are created by link_setup, which runs
    # next and now finds real directories instead of blocked paths.
    log_success "Legacy links converted. Run '${SCRIPT_NAME:-manager.sh} config sync' afterwards to see what needs a decision."
    return 0
}
