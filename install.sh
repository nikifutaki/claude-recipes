#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$REPO_DIR/config"
TARGET_DIR="$HOME/.claude"

# settings.json はデプロイ対象外
SKIP_FILES=("settings.json")

should_skip() {
  local rel_path="$1"
  for skip in "${SKIP_FILES[@]}"; do
    if [[ "$rel_path" == "$skip" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "ERROR: Config directory not found: $CONFIG_DIR" >&2
  exit 1
fi

echo "==> Deploying claude-recipes config"
echo "    Source: $CONFIG_DIR"
echo "    Target: $TARGET_DIR"
echo ""

mkdir -p "$TARGET_DIR"

file_count=0
while IFS= read -r -d '' src; do
  file_count=$((file_count + 1))
  rel_path="${src#"$CONFIG_DIR"/}"

  if should_skip "$rel_path"; then
    echo "  SKIP  $rel_path"
    continue
  fi

  dest="$TARGET_DIR/$rel_path"
  dest_dir="$(dirname "$dest")"

  mkdir -p "$dest_dir"

  # 既にシンボリックリンクが同じ先を指していればスキップ
  if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$src" ]]; then
    echo "  OK    $rel_path (already linked)"
    continue
  fi

  # 既存ファイルがあればバックアップ
  if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
    backup="$dest.backup.$(date +%Y%m%d%H%M%S)"
    echo "  BAK   $rel_path -> $(basename "$backup")"
    mv "$dest" "$backup"
  fi

  ln -s "$src" "$dest"
  echo "  LINK  $rel_path"
done < <(find "$CONFIG_DIR" -type f ! -name '.gitkeep' -print0)

if [[ "$file_count" -eq 0 ]]; then
  echo "  No config files found in $CONFIG_DIR"
fi

echo ""
echo "==> Done!"
