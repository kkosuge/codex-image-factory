#!/bin/bash
# appcast.xml と配布ページを gh-pages ブランチに置いて push する（GitHub Pages で公開する）。
#
#   publish_pages.sh <appcast.xml> <版>
#
# gh-pages ブランチが無ければ作る。リポジトリの Settings → Pages で
# 「Deploy from a branch: gh-pages / (root)」を選んでおくこと。
set -euo pipefail

APPCAST="${1:?appcast.xml のパスを指定してください}"
VERSION="${2:?版を指定してください}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)/gh-pages"

cd "$ROOT"
git config user.name >/dev/null || git config user.name "github-actions[bot]"
git config user.email >/dev/null || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git fetch origin gh-pages:refs/remotes/origin/gh-pages 2>/dev/null; then
  git worktree add -B gh-pages "$WORK" origin/gh-pages
else
  # 初回: 履歴を持たない gh-pages ブランチを作る。
  git worktree add --detach "$WORK"
  git -C "$WORK" checkout --orphan gh-pages
  git -C "$WORK" rm -rf --quiet . || true
fi

cp "$APPCAST" "$WORK/appcast.xml"
cp "$ROOT/scripts/release/pages-index.html" "$WORK/index.html"
touch "$WORK/.nojekyll"

git -C "$WORK" add appcast.xml index.html .nojekyll
if git -C "$WORK" diff --cached --quiet; then
  echo "変更が無いので push しません"
else
  git -C "$WORK" commit --quiet -m "Codex Image Factory $VERSION の appcast"
  git -C "$WORK" push origin gh-pages
fi
git worktree remove --force "$WORK"
