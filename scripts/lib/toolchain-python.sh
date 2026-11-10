#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/toolchain-python.sh - Which python this repo runs, and its pin.
# Source file; do not execute directly.
#
# Public functions:
#   toolchain_repo_root                 print the repository root, or fail
#   toolchain_pinned_python_version     print python/.python-version's value
#   toolchain_python_bin                print a usable python3 interpreter path
#
# Sets: TOOLCHAIN_PYTHON_VERSION (env-overridable; the uv/pyenv version slot).
#
# uv is authoritative for the interpreter and python/.python-version is the truth
# about which version is wanted; pyenv is advisory only, and the gates consult
# uv first. That ordering is the whole content of this file, so it is kept away
# from the bootstrapper tables, which change for unrelated reasons.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_TOOLCHAIN_PYTHON_LOADED:-}" ]; then
    return 0
fi
_LARS_TOOLCHAIN_PYTHON_LOADED=1

# Source common.sh (log_*) when not already loaded (e.g. standalone runs).
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

# ---------------------------------------------------------------------------
# Python version pin
# ---------------------------------------------------------------------------

# toolchain_repo_root
#   Prints the repository root (two levels above this lib directory). Returns 1
#   when this lib has been copied outside a checkout.
toolchain_repo_root() {
    local d=""
    d="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)" || return 1
    printf '%s' "${d}"
}

# toolchain_pinned_python_version
#   Prints the python version the project pins, read from python/.python-version.
#   uv is authoritative for the interpreter and that file is the truth; returns 1
#   when the file is absent (standalone lib copy, or a checkout predating it).
toolchain_pinned_python_version() {
    local root="" file=""
    root="$(toolchain_repo_root)" || return 1
    file="${root}/python/.python-version"
    [ -f "${file}" ] || return 1
    # tr strips whitespace and CR so a CRLF-authored file still yields "3.12".
    tr -d ' \t\r\n' < "${file}"
}

# pyenv/uv version slot used by toolchain_install_python. Overridable from the
# environment (scripts/setup-project-toolchain.sh --python-version sets it).
TOOLCHAIN_PYTHON_VERSION="${TOOLCHAIN_PYTHON_VERSION:-$(toolchain_pinned_python_version 2>/dev/null || true)}"
if [ -z "${TOOLCHAIN_PYTHON_VERSION}" ]; then
    TOOLCHAIN_PYTHON_VERSION="3.12"
fi

# ---------------------------------------------------------------------------
# Python interpreter selection
# ---------------------------------------------------------------------------

# toolchain_python_bin
#   Prints a usable python3 interpreter path, preferring the uv-managed
#   interpreter (authoritative), then a pyenv-managed python, then system
#   python3. Returns 1 (prints nothing) if none exists. Probe stderr is
#   suppressed so callers can capture stdout cleanly.
toolchain_python_bin() {
    local p=""
    if command -v uv >/dev/null 2>&1; then
        p="$(uv python find "${TOOLCHAIN_PYTHON_VERSION}" 2>/dev/null)" || true
        if [ -n "${p}" ] && [ -x "${p}" ]; then
            printf '%s' "${p}"
            return 0
        fi
    fi
    if command -v pyenv >/dev/null 2>&1; then
        p="$(pyenv which python3 2>/dev/null)" || true
        if [ -n "${p}" ] && [ -x "${p}" ]; then
            printf '%s' "${p}"
            return 0
        fi
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$(command -v python3)"
        return 0
    fi
    return 1
}
