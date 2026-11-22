#!/usr/bin/env bash
# usage: changelog.sh TAG — commit subjects between the previous v* tag (or root) and TAG
set -euo pipefail
tag="${1:?usage: changelog.sh TAG}"
prev=$(git describe --tags --abbrev=0 --match 'v*' "${tag}^" 2>/dev/null || true)
range="${prev:+$prev..}$tag"
git log --no-merges --format='- %s' "$range" |
  grep -Ev '^- (docs|test|chore)(\(.*\))?:|^- Merge (pull request|branch)' || true
