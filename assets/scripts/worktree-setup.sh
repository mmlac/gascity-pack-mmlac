#!/bin/sh
# worktree-setup.sh — idempotent git worktree creation for Gas City agents.
#
# Usage: worktree-setup.sh <rig-root> <target-dir> <agent-name> [--sync]
#
# Ensures the target directory is a git worktree of the rig repo. For
# backward compatibility, the older <repo-dir> <agent-name> <city-root>
# signature still works and resolves the target under
# <city-root>/.gc/worktrees/<rig>/<agent-name>.
#
# Called from pre_start in pack configs. Runs before the session is created
# so the agent starts IN the worktree directory.

set -eu

RIG_ROOT="${1:?usage: worktree-setup.sh <rig-root> <target-dir> <agent-name> [--sync]}"
ARG2="${2:?missing target-dir}"
ARG3="${3:?missing agent-name}"

is_path_like() {
    # Legacy mode passes the city path as arg 3. Agent names are validated
    # elsewhere and are not expected to look like filesystem paths.
    case "$1" in
        */*|.*|*:*|*\\*) return 0 ;;
        *) return 1 ;;
    esac
}

if is_path_like "$ARG3"; then
    AGENT="$ARG2"
    CITY="$ARG3"
    RIG=$(basename "$RIG_ROOT")
    WT="$CITY/.gc/worktrees/$RIG/$AGENT"
    SYNC="${4:-}"
else
    WT="$ARG2"
    AGENT="$ARG3"
    SYNC="${4:-}"
fi

branch_name() {
    # Namescape worktree branches by target path so multiple cities or rigs
    # can share one underlying repo without colliding on global refs like
    # gc-refinery or gc-polecat-1.
    HASH=$(printf '%s' "$WT" | git -C "$RIG_ROOT" hash-object --stdin | cut -c1-12)
    printf 'gc-%s-%s' "$AGENT" "$HASH"
}

# Compute the upstream default ref once (origin/HEAD). Used both when
# creating a new worktree (explicit start-point — avoids cutting from a
# stale local default) and when resetting an existing reused worktree so
# the per-instance branch can't bleed commits across beads.
DEFAULT_REF=$(git -C "$RIG_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
DEFAULT_BRANCH=""
if [ -n "$DEFAULT_REF" ]; then
    DEFAULT_BRANCH=${DEFAULT_REF#refs/remotes/origin/}
    git -C "$RIG_ROOT" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
fi

# When an existing worktree is reused across bead claims, the per-instance
# branch (gc-<agent>-<hash>) may carry commits from a prior bead. Reset it
# to origin/<default> so the polecat formula's branch-setup step starts
# from clean state. Without this, new bead work stacks on top of stale
# commits and produces cross-bead branch contamination.
refresh_existing_worktree() {
    [ "$SYNC" = "--sync" ] || return 0
    if ! git -C "$WT" remote get-url origin >/dev/null 2>&1; then
        return 0
    fi
    git -C "$WT" fetch origin >/dev/null 2>&1 || true

    [ -n "$DEFAULT_REF" ] || return 0  # no upstream default → nothing to reset to

    BRANCH=$(branch_name)
    # Move onto the per-instance branch (creating it from DEFAULT_REF if absent).
    if ! git -C "$WT" rev-parse --verify --quiet "$BRANCH" >/dev/null 2>&1; then
        git -C "$WT" checkout -q -B "$BRANCH" "$DEFAULT_REF" 2>/dev/null || return 0
    else
        git -C "$WT" checkout -q "$BRANCH" 2>/dev/null || return 0
    fi

    # Stash uncommitted work so it's recoverable rather than silently destroyed.
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
        git -C "$WT" stash push -u -m "worktree-setup auto-stash $(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" >/dev/null 2>&1 || true
        echo "worktree-setup: stashed dirty working tree in $WT before reset; recover with 'git -C \"$WT\" stash list'" >&2
    fi

    # Hard reset: drops any commits sitting on the per-instance branch
    # past origin/<default>. Stale prior-bead commits are intentionally
    # discarded — they have either already been merged via the refinery
    # path or were abandoned mid-handoff.
    git -C "$WT" reset --hard "$DEFAULT_REF" >/dev/null 2>&1 || true
}

# Idempotent: refresh and skip if worktree already exists.
if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
    refresh_existing_worktree
    exit 0
fi

mkdir -p "$(dirname "$WT")"

STAGE=""

merge_stage_entry() (
    SRC="$1"
    DST="$2"

    if [ -d "$SRC" ]; then
        mkdir -p "$DST"
        for ENTRY in "$SRC"/.[!.]* "$SRC"/..?* "$SRC"/*; do
            [ -e "$ENTRY" ] || continue
            merge_stage_entry "$ENTRY" "$DST/$(basename "$ENTRY")"
        done
        rmdir "$SRC" 2>/dev/null || true
        exit 0
    fi

    if [ -e "$DST" ]; then
        exit 0
    fi
    mv "$SRC" "$DST"
)

restore_stage() {
    [ -n "$STAGE" ] || return 0
    mkdir -p "$WT"
    for ENTRY in "$STAGE"/.[!.]* "$STAGE"/..?* "$STAGE"/*; do
        [ -e "$ENTRY" ] || continue
        merge_stage_entry "$ENTRY" "$WT/$(basename "$ENTRY")"
    done
    rmdir "$STAGE" 2>/dev/null || true
    STAGE=""
}

if [ -d "$WT" ] && [ "$(find "$WT" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
    STAGE=$(mktemp -d "$(dirname "$WT")/.gascity-worktree-stage.XXXXXX")
    find "$WT" -mindepth 1 -maxdepth 1 -exec mv {} "$STAGE"/ \;
    trap 'restore_stage' EXIT HUP INT TERM
fi

rmdir "$WT" 2>/dev/null || true
# Clear stale metadata from removed worktrees before branch/worktree lookup.
git -C "$RIG_ROOT" worktree prune >/dev/null 2>&1 || true

BRANCH=$(branch_name)

# If a stale per-instance branch already exists at the rig repo (from a
# previous worktree that was deleted), force-reset it to origin/<default>
# so it can't carry forward old commits when we re-attach the worktree.
if git -C "$RIG_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    if [ -n "$DEFAULT_REF" ]; then
        git -C "$RIG_ROOT" branch -f "$BRANCH" "$DEFAULT_REF" >/dev/null 2>&1 || true
    fi
    if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" worktree add "$WT" "$BRANCH"; then
        echo "worktree-setup: failed to create worktree at $WT from $RIG_ROOT (branch $BRANCH)" >&2
        restore_stage
        exit 1
    fi
else
    # Cut the new branch from origin/<default> explicitly (not from
    # whatever happens to be the local HEAD) so multi-bead reuse can't
    # drift the worktree behind origin's actual default.
    if [ -n "$DEFAULT_REF" ]; then
        worktree_add_ok=0
        GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" worktree add "$WT" -b "$BRANCH" "$DEFAULT_REF" && worktree_add_ok=1
    else
        worktree_add_ok=0
        GIT_LFS_SKIP_SMUDGE=1 git -C "$RIG_ROOT" worktree add "$WT" -b "$BRANCH" && worktree_add_ok=1
    fi
    if [ "$worktree_add_ok" != "1" ]; then
        echo "worktree-setup: failed to create worktree at $WT from $RIG_ROOT (branch $BRANCH)" >&2
        restore_stage
        exit 1
    fi
fi

if [ -n "$STAGE" ]; then
    for ENTRY in "$STAGE"/.[!.]* "$STAGE"/..?* "$STAGE"/*; do
        [ -e "$ENTRY" ] || continue
        merge_stage_entry "$ENTRY" "$WT/$(basename "$ENTRY")"
    done
    rm -rf "$STAGE"
    STAGE=""
fi
trap - EXIT HUP INT TERM

# Bead redirect for filesystem beads.
mkdir -p "$WT/.beads"
echo "$RIG_ROOT/.beads" > "$WT/.beads/redirect"

# Submodule init (best-effort).
git -C "$WT" submodule init 2>/dev/null || true

# Keep runtime ignores local to git metadata instead of mutating the tracked
# repository .gitignore. --git-path resolves the exclude file Git actually
# consults for this worktree, including linked-worktree layouts.
EXCLUDE=$(git -C "$WT" rev-parse --git-path info/exclude)
case "$EXCLUDE" in
    /*) ;;
    *) EXCLUDE="$WT/$EXCLUDE" ;;
esac
mkdir -p "$(dirname "$EXCLUDE")"
touch "$EXCLUDE"

MARKER="# Gas City worktree infrastructure (local excludes)"
if ! grep -qF "$MARKER" "$EXCLUDE" 2>/dev/null; then
    if [ -s "$EXCLUDE" ] && [ "$(tail -c 1 "$EXCLUDE" 2>/dev/null || true)" != "" ]; then
        printf '\n' >> "$EXCLUDE"
    fi
    printf '%s\n' "$MARKER" >> "$EXCLUDE"
fi

append_exclude() {
    PATTERN="$1"
    grep -qxF "$PATTERN" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$PATTERN" >> "$EXCLUDE"
}

append_exclude ".beads/redirect"
append_exclude ".beads/hooks/"
append_exclude ".beads/formulas/"
append_exclude ".runtime/"
append_exclude ".logs/"
append_exclude "worktrees/"
append_exclude "__pycache__/"

# AI-tool config dirs: blanket-exclude per-session runtime cruft
# (settings.json, project history, caches) but allow-list the canonical
# committed-content subdirs (skills/, commands/, agents/) that Claude
# Code, Codex, Gemini, and OpenCode all use as the shared-content
# convention. Using `<tool>/*` instead of `<tool>/` is what lets the
# `!<tool>/skills/` negation re-include — a directory exclude would skip
# recursion entirely.
#
# After re-including skills/, re-exclude `core.gc-*` underneath: those
# are Gas City controller-installed skills (mail, dispatch, dashboard,
# rigs, work, etc.) that get auto-stamped into every worktree. They're
# machinery, not project content; they should never be committed.
for tool in .claude .codex .gemini .opencode; do
    append_exclude "$tool/*"
    append_exclude "!$tool/skills/"
    append_exclude "!$tool/commands/"
    append_exclude "!$tool/agents/"
    append_exclude "$tool/skills/core.gc-*"
done

append_exclude ".github/hooks/"
append_exclude ".github/copilot-instructions.md"
append_exclude "state.json"

# Optional sync.
sync_worktree

exit 0
