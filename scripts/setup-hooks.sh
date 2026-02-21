#!/bin/sh
# Enables the repository's git hooks (leak guard). Run once after cloning.
set -e
root=$(git rev-parse --show-toplevel)
git -C "$root" config core.hooksPath .githooks
chmod +x "$root"/.githooks/*
echo "Git hooks enabled (core.hooksPath=.githooks)."
if ! command -v node >/dev/null 2>&1; then
  echo "Warning: Node.js not found. Commits and pushes will be refused until it is installed." >&2
fi
