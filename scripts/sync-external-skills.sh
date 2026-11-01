#!/bin/sh
# Keep the external skills in .claude/skills in step with their GitHub repos.
#
#   sh scripts/sync-external-skills.sh          clone on first run, then update to the latest main
#   sh scripts/sync-external-skills.sh --quiet  same, printing only problems (used by the SessionStart hook)
#
# Each repo is a read-only mirror under .claude/skill-sources/<name> (partial + sparse clone, so it stays small).
# .claude/skills/<skill> is a symlink into it, so a pull is all it takes for Claude to see the new version.
# Local edits inside a mirror are discarded on update: change the skill on GitHub instead.
# Untracked files (node_modules, .venv, demo sources added by the skill) are kept.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/.claude/skill-sources"
SKILLS="$ROOT/.claude/skills"
QUIET=; [ "$1" = "--quiet" ] && QUIET=1
say() { [ -n "$QUIET" ] || echo "$@"; }
mkdir -p "$SRC" "$SKILLS"

# name | repo | branch | sparse mode | sparse patterns | skill dir inside repo | skill name in .claude/skills
REPOS='
stickman-video-director|https://github.com/kaomei/stickman-video-director.git|main|cone|skills|skills/directing-stickman-videos|directing-stickman-videos
lemo-opuscar|https://github.com/lemomo-ai/lemo-opuscar.git|main|no-cone|/* !/styles/*/demo/ !/styleboard/ !/docs/frames/ !/docs/cover.jpg !/docs/opuscar98.jpg !/styles/*/poster.jpg|plugin/skills/lemo-opuscar|lemo-opuscar
'

set_sparse() { # dir mode patterns...
  dir=$1; mode=$2; shift 2
  if [ "$mode" = cone ]; then
    git -C "$dir" sparse-checkout set "$@"
  else
    # keep demo folders that the lemo-opuscar skill added with `setup.sh demo <slug>`
    extra=$(git -C "$dir" sparse-checkout list 2>/dev/null | grep -E '^/styles/[^/*]+/(demo/|poster\.jpg)$' || true)
    # shellcheck disable=SC2086
    git -C "$dir" sparse-checkout set --no-cone "$@" $extra 2>/dev/null || git -C "$dir" sparse-checkout set "$@" $extra
  fi
}

status=0
echo "$REPOS" | while IFS='|' read -r name url branch mode patterns skilldir skill; do
  [ -n "$name" ] || continue
  dir="$SRC/$name"
  set -f  # patterns contain * : don't let the shell expand them
  if [ ! -d "$dir/.git" ]; then
    say "↓ cloning $name"
    rm -rf "$dir"
    if git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$branch" "$url" "$dir"; then
      # shellcheck disable=SC2086
      set_sparse "$dir" "$mode" $patterns
    else
      echo "✗ $name: clone failed (offline?)"; status=1; set +f; continue
    fi
  else
    before=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    git -C "$dir" remote set-url origin "$url"
    if err=$(git -C "$dir" fetch --quiet --depth 1 origin "$branch" 2>&1) && err=$(git -C "$dir" reset --quiet --hard FETCH_HEAD 2>&1); then
      # shellcheck disable=SC2086
      set_sparse "$dir" "$mode" $patterns
      after=$(git -C "$dir" rev-parse --short HEAD)
      if [ "$before" != "$after" ]; then echo "↻ $name updated $before → $after: $(git -C "$dir" log -1 --format=%s)"
      else say "✓ $name up to date ($after)"; fi
    else
      echo "! $name: could not update, using the local copy. $(echo "$err" | head -1)"
    fi
  fi
  set +f
  # the symlink Claude reads the skill through (relative, so it works from any checkout path)
  link="$SKILLS/$skill"
  target="../skill-sources/$name/$skilldir"
  if [ "$(readlink "$link" 2>/dev/null)" != "$target" ]; then
    rm -rf "$link"; ln -s "$target" "$link"; say "→ linked .claude/skills/$skill"
  fi
done
exit $status
