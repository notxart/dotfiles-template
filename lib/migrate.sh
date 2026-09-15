#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lib/migrate.sh — Directory-level -> file-level symlink migration
#
# PLACEHOLDER (Step 1). Implemented in Step 5:
#   migrate_detect / migrate_plan / migrate_execute / migrate_foreign_files
#
# Migration moves third-party files out of the repository working tree before
# swapping a directory-level symlink for a real directory, and repairs
# self-referential loop symlinks. Nothing here may ever delete user data.
# ==============================================================================

# Intentionally empty during Step 1 — see the plan for the Step 5 interface.
