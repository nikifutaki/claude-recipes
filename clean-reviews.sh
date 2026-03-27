#!/usr/bin/env bash
set -euo pipefail

REVIEWS_DIR="$HOME/.claude/reviews"

if [[ ! -d "$REVIEWS_DIR" ]]; then
  echo "No review artifacts found at $REVIEWS_DIR"
  exit 0
fi

echo "==> Review artifacts in $REVIEWS_DIR:"
echo ""
du -sh "$REVIEWS_DIR"/* 2>/dev/null || true
echo ""

read -rp "Remove all review artifacts? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
  rm -rf "$REVIEWS_DIR"
  echo "  CLEAN   $REVIEWS_DIR"
else
  echo "  SKIP"
fi

echo ""
echo "==> Done!"
