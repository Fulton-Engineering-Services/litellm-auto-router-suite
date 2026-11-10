#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
root="${BUILD_WORKSPACE_DIRECTORY:?BUILD_WORKSPACE_DIRECTORY unset (run via 'bazel run')}"
cd "$root/python" && exec uv run "$@"
