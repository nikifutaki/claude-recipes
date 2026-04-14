#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$REPO_DIR/config"
TARGET_DIR="$HOME/.claude"

if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "ERROR: Config directory not found: $CONFIG_DIR" >&2
  exit 1
fi

echo "==> Removing claude-recipes symlinks"
echo "    Source: $CONFIG_DIR"
echo "    Target: $TARGET_DIR"
echo ""

removed=0
while IFS= read -r -d '' src; do
  rel_path="${src#"$CONFIG_DIR"/}"
  dest="$TARGET_DIR/$rel_path"

  if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$src" ]]; then
    rm "$dest"
    echo "  REMOVE  $rel_path"
    removed=$((removed + 1))
  elif [[ -L "$dest" ]]; then
    echo "  SKIP    $rel_path (symlink points elsewhere)"
  elif [[ -e "$dest" ]]; then
    echo "  SKIP    $rel_path (not a symlink)"
  else
    echo "  SKIP    $rel_path (not found)"
  fi
done < <(find "$CONFIG_DIR" -type f ! -name '.gitkeep' -print0)

echo ""
echo "  Removed $removed symlink(s)."

# グローバル gitignore から .claude/reviews/ を除去
GITIGNORE_ENTRY=".claude/reviews/"
GLOBAL_IGNORE="$(git config --global core.excludesFile 2>/dev/null || true)"
GLOBAL_IGNORE="${GLOBAL_IGNORE:-$HOME/.config/git/ignore}"

echo ""
echo "==> Cleaning global gitignore"
echo "    File: $GLOBAL_IGNORE"

if [[ -f "$GLOBAL_IGNORE" ]] && grep -qFx "$GITIGNORE_ENTRY" "$GLOBAL_IGNORE"; then
  grep -vFx "$GITIGNORE_ENTRY" "$GLOBAL_IGNORE" > "$GLOBAL_IGNORE.tmp"
  mv "$GLOBAL_IGNORE.tmp" "$GLOBAL_IGNORE"
  echo "  REMOVE  $GITIGNORE_ENTRY"
else
  echo "  OK      $GITIGNORE_ENTRY (not present)"
fi
