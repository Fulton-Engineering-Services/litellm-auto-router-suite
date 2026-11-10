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
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LOG_TOOLCHAIN_LOADED:-}" ]; then
    return 0
fi
_LOG_TOOLCHAIN_LOADED=1

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

# ---------------------------------------------------------------------------
# Bootstrapper inventory
#
# Every tool this repo needs is available as a Homebrew formula, so check and
# install are one generic pair driven by the tables below. brew never sets a
# version this repo depends on: pnpm comes from "packageManager" in
# typescript/package.json, ruff/mypy/pytest from the uv dev group in
# python/pyproject.toml, and oxlint/vitest/typescript from package.json. brew
# supplies bootstrappers only.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# toolchain_check_tool <tool>
#   Logs one presence line and returns 0 when the tool was found.
toolchain_check_tool() {
    local tool="$1" found=""
    local label=""
    label="$(printf '%-9s' "${tool}:")"
    found="$(toolchain_bin "${tool}" 2>/dev/null)" || true
    if [ -n "${found}" ]; then
        log_info "  ${label} present (${found})"
        return 0
    fi
    if toolchain_is_required "${tool}"; then
        log_warn "  ${label} MISSING (required)"
    else
        log_warn "  ${label} missing (recommended)"
    fi
    return 1
}

# toolchain_rows
#   Emits one TAB-separated "<tool>\t<required>\t<found>" line per tool so a
#   driver can render its own status table (see scripts/setup-project-toolchain.sh).
toolchain_rows() {
    local tool="" found="" req=""
    for tool in $(toolchain_tool_names); do
        found="$(toolchain_bin "${tool}" 2>/dev/null)" || true
        if toolchain_is_required "${tool}"; then
            req="yes"
        else
            req="no"
        fi
        [ -n "${found}" ] || found="-"
        printf '%s\t%s\t%s\n' "${tool}" "${req}" "${found}"
    done
    found="$(toolchain_python_bin 2>/dev/null)" || true
    [ -n "${found}" ] || found="-"
    printf '%s\t%s\t%s\n' "python3" "yes" "${found}"
}

# toolchain_missing_tools
#   Prints the REQUIRED tools that are absent, one per line. Recommended tools
#   never appear here, so they can never fail a gate.
toolchain_missing_tools() {
    local tool=""
    for tool in $(toolchain_tool_names); do
        toolchain_bin "${tool}" >/dev/null 2>&1 && continue
        toolchain_is_required "${tool}" || continue
        printf '%s\n' "${tool}"
    done
    toolchain_python_bin >/dev/null 2>&1 && return 0
    printf '%s\n' "python3"
}

# toolchain_check_python
#   Validates the python story: a usable interpreter (uv-managed preferred),
#   the pinned version slot, and pyenv presence (reported, never consulted by
#   the gates). Returns 0 when a python3 interpreter exists, 1 otherwise.
toolchain_check_python() {
    local ok=true p="" pyenv_name=""
    p="$(toolchain_python_bin 2>/dev/null)" || true
    if [ -n "${p}" ]; then
        log_info "  python3:  present (${p} - $("${p}" --version 2>&1))"
    else
        log_warn "  python3:  MISSING (required for the python gates)"
        ok=false
    fi
    if command -v uv >/dev/null 2>&1; then
        log_info "  uv:       pinned python slot ${TOOLCHAIN_PYTHON_VERSION} (authoritative)"
    fi
    if command -v pyenv >/dev/null 2>&1; then
        pyenv_name="$(pyenv version-name 2>/dev/null)" || true
        [ -n "${pyenv_name}" ] || pyenv_name="no version set"
        log_info "  pyenv:    present (${pyenv_name}; advisory)"
    else
        log_warn "  pyenv:    missing (recommended for python version selection/install)"
    fi
    [ "${ok}" = "true" ]
}

# toolchain_check
#   Full toolchain validation. Returns 0 when every required piece (bootstrappers
#   + python) is present, 1 otherwise.
toolchain_check() {
    log_header "Supporting toolchain check"
    local ok=true tool=""
    for tool in $(toolchain_tool_names); do
        if ! toolchain_check_tool "${tool}"; then
            toolchain_is_required "${tool}" || continue
            ok=false
        fi
    done
    toolchain_check_python || ok=false
    if [ "${ok}" = "true" ]; then
        log_success "Toolchain ready."
        return 0
    fi
    log_error "Toolchain incomplete. Install path (macOS + Homebrew):"
    printf '       scripts/setup-project-toolchain.sh --install\n' >&2
    printf '   or  scripts/lib/toolchain.sh install\n' >&2
    return 1
}

# ---------------------------------------------------------------------------
# Installation (macOS + Homebrew)
# ---------------------------------------------------------------------------

toolchain_is_macos() {
    [ "$(uname -s)" = "Darwin" ]
}

# toolchain_install_tools
#   Installs every absent bootstrapper through homebrew_install_formulae
#   (scripts/lib/homebrew.sh), which owns the consent rule: installs happen only
#   under AUTO_INSTALL_DEPS or an explicit yes at a TTY, never because --yes was
#   passed. Falls back to a direct `brew install` when homebrew.sh is not loaded.
toolchain_install_tools() {
    log_step "Ensuring bootstrappers (git jq shellcheck bazelisk uv node pnpm pyenv)..."
    local -a missing
    missing=()
    local tool=""
    for tool in $(toolchain_tool_names); do
        toolchain_bin "${tool}" >/dev/null 2>&1 && continue
        missing+=("${tool}")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        log_success "All bootstrappers already present."
        return 0
    fi
    local formula=""
    for tool in "${missing[@]}"; do
        formula="$(toolchain_formula_for "${tool}" 2>/dev/null)" || formula="${tool}"
        if command -v homebrew_install_formulae >/dev/null 2>&1; then
            homebrew_install_formulae "${formula}" \
                || die "could not install ${formula} (needed for ${tool})"
        else
            require_command brew "Install Homebrew first: https://brew.sh"
            log_info "brew install ${formula}"
            brew install "${formula}" || die "brew install ${formula} failed (needed for ${tool})"
        fi
    done
    log_success "Bootstrappers installed: ${missing[*]}"
}

# toolchain_install_uv_python
#   Installs the pinned interpreter under uv, which is authoritative for python.
#   Idempotent: `uv python find` short-circuits when the slot already exists.
toolchain_install_uv_python() {
    log_step "Ensuring uv-managed python ${TOOLCHAIN_PYTHON_VERSION}..."
    require_command uv "Install uv: brew install uv (or scripts/setup-project-toolchain.sh --install)"
    local found=""
    found="$(uv python find "${TOOLCHAIN_PYTHON_VERSION}" 2>/dev/null)" || true
    if [ -n "${found}" ]; then
        log_info "uv python ${TOOLCHAIN_PYTHON_VERSION} already installed (${found})."
        return 0
    fi
    uv python install "${TOOLCHAIN_PYTHON_VERSION}" \
        || die "uv python install ${TOOLCHAIN_PYTHON_VERSION} failed"
    log_success "uv python: $(uv python find "${TOOLCHAIN_PYTHON_VERSION}" 2>/dev/null)"
}

# toolchain_install_python
#   Installs pyenv via Homebrew, then installs TOOLCHAIN_PYTHON_VERSION with
#   `pyenv install -s` (advisory: the gates use uv). Avoids clobbering an
#   existing pyenv global: it only takes over the global when none is set;
#   otherwise it reports how to select the version per-project (pyenv local).
toolchain_install_python() {
    log_step "Ensuring pyenv python ${TOOLCHAIN_PYTHON_VERSION} (advisory)..."
    if ! command -v pyenv >/dev/null 2>&1; then
        if command -v homebrew_install_formulae >/dev/null 2>&1; then
            homebrew_install_formulae pyenv || {
                log_warn "pyenv not installed; skipping the pyenv leg."
                return 0
            }
        else
            require_command brew "Install Homebrew first: https://brew.sh"
            brew install pyenv || die "brew install pyenv failed"
        fi
    fi
    if ! pyenv versions --bare 2>/dev/null | grep -E "^${TOOLCHAIN_PYTHON_VERSION}(\.|$)" >/dev/null; then
        log_info "Installing python ${TOOLCHAIN_PYTHON_VERSION} via pyenv (this can take a while)..."
        pyenv install -s "${TOOLCHAIN_PYTHON_VERSION}" || die "pyenv install ${TOOLCHAIN_PYTHON_VERSION} failed"
    fi
    local current=""
    current="$(pyenv global 2>/dev/null)" || true
    if [ -z "${current}" ] || [ "${current}" = "system" ]; then
        pyenv global "${TOOLCHAIN_PYTHON_VERSION}" 2>/dev/null || true
        log_info "pyenv global set to ${TOOLCHAIN_PYTHON_VERSION}."
    else
        log_info "pyenv global is already '${current}' - leaving it. To select ${TOOLCHAIN_PYTHON_VERSION} per-project: pyenv local ${TOOLCHAIN_PYTHON_VERSION}"
    fi
    log_success "pyenv versions: $(pyenv versions --bare 2>/dev/null | tr '\n' ' ')"
}

# toolchain_install
#   Full install path: bootstrappers (brew) + python (uv authoritative, pyenv
#   advisory). macOS + Homebrew.
toolchain_install() {
    log_header "Supporting toolchain install"
    if ! toolchain_is_macos; then
        die "toolchain_install targets macOS + Homebrew (current system: $(uname -s))"
    fi
    if command -v homebrew_ensure >/dev/null 2>&1; then
        homebrew_ensure || die "Homebrew is required for the install path."
    else
        require_command brew "Install Homebrew first: https://brew.sh"
    fi
    toolchain_install_tools
    toolchain_install_uv_python
    toolchain_install_python
    log_success "Toolchain installed."
}

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
