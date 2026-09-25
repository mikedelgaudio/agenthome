#!/usr/bin/env bash
# Links each agent's global instructions file to global/AGENTS.md in this repo.
# Safe to re-run. Existing real files are backed up, never overwritten.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/global/AGENTS.md"
STAMP="$(date +%Y%m%d%H%M%S)"

TARGETS=(
  "$HOME/.codex/AGENTS.md"
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.copilot/copilot-instructions.md"
)

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

for t in "${TARGETS[@]}"; do
  mkdir -p "$(dirname "$t")"
  if [ -L "$t" ] && [ "$(readlink "$t")" = "$SRC" ]; then
    echo "ok       $t"
    continue
  fi
  if [ -e "$t" ] || [ -L "$t" ]; then
    mv "$t" "$t.bak.$STAMP"
    echo "backup   $t -> $t.bak.$STAMP"
  fi
  ln -s "$SRC" "$t"
  echo "linked   $t -> $SRC"
done
