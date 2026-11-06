#!/usr/bin/env bash
# 현재 리포지토리를 public으로 전환합니다.
set -euo pipefail

command -v gh >/dev/null || { echo "gh CLI가 필요합니다."; exit 1; }
cd "$(dirname "$0")"

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
current=$(gh repo view --json visibility -q .visibility)

if [[ "$current" == "PUBLIC" ]]; then
  echo "$repo 는 이미 public 입니다."
  exit 0
fi

gh repo edit "$repo" --visibility public --accept-visibility-change-consequences
echo "$repo 를 public으로 전환했습니다."
