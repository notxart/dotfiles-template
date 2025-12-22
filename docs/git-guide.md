# Strict Git Workflow Guide

This document outlines the required Git configuration and workflow patterns for contributing to this project. We enforce a linear history and strict commit discipline to ensure the repository remains maintainable and bisect-friendly.

## 1. Core Principles

- **Atomic Commits**: Each commit must do one thing and one thing only. Do not mix refactoring with feature additions.
- **Linear History**: We do not use merge commits for feature branches. We `rebase`.
- **Signed Commits**: All commits must be GPG signed to verify authorship.

## 2. Configuration Overview

The project includes a hardened `config/git/config.ini` designed to enforce these principles. Key features include:

- **Autocrlf Input**: Forces LF line endings in the repository to prevent cross-platform whitespace noise.
- **GPG Signing**: `gpgSign = true` is enabled by default for both commits and tags.
- **Histogram Diff**: Uses a superior algorithm for calculating diffs, which is more aware of code structure than the default Myers algorithm.
- **Rebase on Pull**: `pull.rebase = true` prevents accidental merge bubbles when pulling upstream changes.

## 3. Recommended Aliases

The configuration provides several aliases to speed up the workflow. Below are the most critical ones:

### Visualization

- `git lg`: A minimal, graph-based log view. Use this to quickly see the DAG structure.
- `git lga`: A comprehensive log view with dates and author names.

### Maintenance

- `git bclean`: Automatically deletes local branches that have already been merged into `HEAD`. Use this to keep your local environment sanitary.

### Rebase & Sync

- `git up`: Equivalent to git `pull --rebase`. Always use this instead of git pull.
- `git pf`: `push --force-with-lease`. This is the safe way to force push after a rebase. It ensures you don't overwrite work pushed by others that you haven't seen yet.

## 4. Commit Message Convention

We follow the Conventional Commits specification.

### Format: `<type>: <subject>`

#### Types

- `feat`: A new feature
- `fix`: A bug fix
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `style`: Changes that do not affect the meaning of the code (white-space, formatting, etc)
- `docs`: Documentation only changes
- `perf`: A code change that improves performance
- `chore`: Changes to the build process or auxiliary tools and libraries

#### Example

```txt
feat: enhance installation robustness

Refactored `install.sh` to implement a Strategy Pattern for cleaner package manager detection.
```

## 5. The Workflow

1. **Start**: `git sw -c feat/your-feature`
2. **Work**: Make changes.
3. **Stage**: `git ap` (interactive add) to select specific hunks.
4. **Commit**: `git ci` (verbose commit).
5. **Sync**: `git up` (pull --rebase) to fetch latest main.
6. **Push**: `git push` or `git pf` (if you rebased).
