#!/usr/bin/env bash
# Activates the versioned git hooks in .githooks/ for this clone.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "Hooks active (core.hooksPath=.githooks)."
[[ -f .githooks/forbidden-patterns.local ]] || echo "Hint: create .githooks/forbidden-patterns.local with internal patterns (one regex per line)."
