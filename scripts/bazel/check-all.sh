#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
root="${BUILD_WORKSPACE_DIRECTORY:?BUILD_WORKSPACE_DIRECTORY unset (run via 'bazel run')}"
cd "$root"
pnpm --dir typescript install --frozen-lockfile
uv sync --directory python
pnpm --dir typescript run typecheck
pnpm --dir typescript run lint
pnpm --dir typescript run lint:tsdoc
pnpm --dir typescript run test
pnpm --dir typescript run build
uv run --directory python ruff check .
uv run --directory python mypy packages
uv run --directory python pytest
./scripts/lint-shell.sh
