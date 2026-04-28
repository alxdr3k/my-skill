#!/usr/bin/env bash
# Verify that embedded dev-cycle direct-push repo lists match direct-push-repos.txt.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$repo_root/direct-push-repos.txt"

files=(
  "$repo_root/commands/dev-cycle.md"
  "$repo_root/codex/skills/dev-cycle/SKILL.md"
)

expected_list() {
  sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$source_file" | sort
}

embedded_list() {
  local file="$1"
  awk '
    /\*\*Direct-push 리포/ { in_block = 1; next }
    in_block && /^- / { sub(/^- /, ""); print; seen = 1; next }
    in_block && seen && !/^- / { exit }
  ' "$file" | sort
}

case_pattern() {
  local file="$1"
  awk '
    /case "\$REPO_NAME" in/ {
      getline
      gsub(/^[[:space:]]+/, "")
      gsub(/\)$/, "")
      print
      exit
    }
  ' "$file"
}

expected="$(expected_list | paste -sd '|' -)"

if [[ -z "$expected" ]]; then
  echo "direct-push-repos.txt is empty" >&2
  exit 1
fi

for file in "${files[@]}"; do
  actual="$(embedded_list "$file" | paste -sd '|' -)"
  if [[ "$actual" != "$expected" ]]; then
    echo "direct-push list drift in ${file#$repo_root/}" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi

  pattern="$(case_pattern "$file" | tr '|' '\n' | sort | paste -sd '|' -)"
  if [[ "$pattern" != "$expected" ]]; then
    echo "direct-push case pattern drift in ${file#$repo_root/}" >&2
    echo "expected: $expected)" >&2
    echo "actual:   $pattern)" >&2
    exit 1
  fi
done
