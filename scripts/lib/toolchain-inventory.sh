#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/toolchain-inventory.sh - The bootstrapper table and its lookups.
# Source file; do not execute directly.
#
# Public functions:
#   toolchain_tool_names                one tool per line, in report order
#   toolchain_is_required <tool>        0 when the tool gates a build
#   toolchain_formula_for <tool>        Homebrew formula providing the tool
#   toolchain_bin <tool>                resolved path, or nothing when absent
#
# Every tool this repo needs is available as a Homebrew formula, so check and
# install are one generic pair driven by the tables below. brew never sets a
# version this repo depends on: pnpm comes from "packageManager" in
# typescript/package.json, ruff/mypy/pytest from the uv dev group in
# python/pyproject.toml, and oxlint/vitest/typescript from package.json. brew
# supplies bootstrappers only.
#
# This is the file to edit when a tool is added or renamed: the check and install
# paths both read these tables and contain no tool list of their own.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_TOOLCHAIN_INVENTORY_LOADED:-}" ]; then
    return 0
fi
_LARS_TOOLCHAIN_INVENTORY_LOADED=1

# Source common.sh (log_*) when not already loaded (e.g. standalone runs).
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

# toolchain_tool_names
#   Prints one tool name per line, in report order (required first).
toolchain_tool_names() {
    printf '%s\n' git jq shellcheck bazelisk uv node pnpm pyenv
}

# toolchain_is_required <tool>
#   Returns 0 when the tool gates a build, 1 when it is recommended only.
toolchain_is_required() {
    case "$1" in
        pyenv) return 1 ;;
        *) return 0 ;;
    esac
}

# toolchain_formula_for <tool>
#   Prints the Homebrew formula that provides <tool>. The names coincide today;
#   the indirection exists so a formula rename is a one-line change.
toolchain_formula_for() {
    case "$1" in
        git) printf 'git\n' ;;
        jq) printf 'jq\n' ;;
        shellcheck) printf 'shellcheck\n' ;;
        bazelisk) printf 'bazelisk\n' ;;
        uv) printf 'uv\n' ;;
        node) printf 'node\n' ;;
        pnpm) printf 'pnpm\n' ;;
        pyenv) printf 'pyenv\n' ;;
        *) return 1 ;;
    esac
}

# toolchain_bin <tool>
#   Prints the resolved path for <tool>, or nothing when it is absent.
#   bazelisk also counts as satisfied by a `bazel` on PATH: bazelisk installs a
#   `bazel` shim, and either binary satisfies `bazel run //:check`.
toolchain_bin() {
    local tool="$1"
    if command -v "${tool}" >/dev/null 2>&1; then
        command -v "${tool}"
        return 0
    fi
    if [ "${tool}" = "bazelisk" ] && command -v bazel >/dev/null 2>&1; then
        command -v bazel
        return 0
    fi
    return 1
}
