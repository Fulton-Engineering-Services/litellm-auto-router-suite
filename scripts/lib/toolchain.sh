#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/toolchain.sh - Validates and installs supporting toolchains
# for the litellm-auto-router-suite scripts:
#
#   git, jq, shellcheck  - required by the scripts/ harness itself (shellcheck
#                          is the gate behind scripts/lint-shell.sh)
#   bazelisk             - required by `bazel build //...` / `bazel run //:check`
#   uv                   - authoritative python interpreter + workspace resolver
#   node, pnpm           - required by the TypeScript workspace gates
#   pyenv                - supported python version selection; ADVISORY only.
#                          The gates consult uv, never pyenv, so a machine with
#                          pyenv and no uv still cannot build (that is intended).
#
# Source from other scripts:
#   LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
#   source "${LIB_DIR}/common.sh"
#   source "${LIB_DIR}/toolchain.sh"
#
# Or run standalone:
#   scripts/lib/toolchain.sh check        # validate presence, exit non-zero if incomplete
#   scripts/lib/toolchain.sh install      # install what's missing (macOS + Homebrew)
#   scripts/lib/toolchain.sh python-bin   # print the chosen python3 interpreter path
#
# The install path assumes macOS + Homebrew (see toolchain_install) and honors
# the consent rule owned by scripts/lib/homebrew.sh: nothing is installed
# without AUTO_INSTALL_DEPS or an explicit yes at a terminal. The check path is
# portable and only reports, so CI (Linux) can run it read-only.
#
# Layout - this file is the public surface and the standalone CLI; it holds no
# logic of its own. The implementation lives in scripts/lib/, one responsibility
# per file, and is re-exported here so every existing `source` of
# lib/toolchain.sh keeps working unchanged:
#
#   lib/toolchain-python.sh     interpreter selection + the python/.python-version pin
#   lib/toolchain-inventory.sh  the bootstrapper table (edit this to add a tool)
#   lib/toolchain-check.sh      read-only validation and reporting
#   lib/toolchain-install.sh    the macOS + Homebrew install path
#   lib/common.sh               logging, die, require_command
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LOG_TOOLCHAIN_LOADED:-}" ]; then
    return 0
fi
_LOG_TOOLCHAIN_LOADED=1

# This file and its modules live side by side in scripts/lib/.
_LARS_TC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# Source common.sh (log_*) when not already loaded (e.g. standalone runs).
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1090,SC1091
    source "${_LARS_TC_DIR}/common.sh"
fi

# Every module is a hard requirement. Checking each one before sourcing is not
# ceremony: this file is sourced, so a failed source does not necessarily abort
# the caller, and a toolchain that silently lost its install half would still
# "work" until the first --install.
for _lib in toolchain-python toolchain-inventory toolchain-check toolchain-install; do
    [ -f "${_LARS_TC_DIR}/${_lib}.sh" ] \
        || { echo "FATAL: missing ${_LARS_TC_DIR}/${_lib}.sh" >&2; exit 1; }
done
unset _lib
# shellcheck source=toolchain-python.sh disable=SC1090,SC1091
. "${_LARS_TC_DIR}/toolchain-python.sh"
# shellcheck source=toolchain-inventory.sh disable=SC1090,SC1091
. "${_LARS_TC_DIR}/toolchain-inventory.sh"
# shellcheck source=toolchain-check.sh disable=SC1090,SC1091
. "${_LARS_TC_DIR}/toolchain-check.sh"
# shellcheck source=toolchain-install.sh disable=SC1090,SC1091
. "${_LARS_TC_DIR}/toolchain-install.sh"
unset _LARS_TC_DIR

# ---------------------------------------------------------------------------
# Standalone entrypoint (only when executed directly)
# ---------------------------------------------------------------------------

if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-check}" in
        check)      toolchain_check ;;
        install)    toolchain_install ;;
        python-bin) toolchain_python_bin ;;
        *)
            printf 'Usage: %s {check|install|python-bin}\n' "$0" >&2
            exit 1
            ;;
    esac
fi
