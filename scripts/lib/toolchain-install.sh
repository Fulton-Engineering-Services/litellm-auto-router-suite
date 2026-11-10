#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/toolchain-install.sh - Installing what is missing (macOS + Homebrew).
# Source file; do not execute directly.
#
# Public functions:
#   toolchain_is_macos                  0 on Darwin
#   toolchain_install_tools               brew-install every absent bootstrapper
#   toolchain_install_uv_python           uv-install the pinned interpreter
#   toolchain_install_python              pyenv-install it (advisory)
#   toolchain_install                     full install path
#
# Reads globals: TOOLCHAIN_PYTHON_VERSION (see toolchain-python.sh).
#
# The install half assumes macOS + Homebrew and honors the consent rule owned by
# scripts/lib/homebrew.sh: nothing is installed without AUTO_INSTALL_DEPS or an
# explicit yes at a terminal. A --yes on a calling script never authorizes an
# install -- that flag governs operational prompts, not software. The check half
# (toolchain-check.sh) has no such assumption and stays portable.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_TOOLCHAIN_INSTALL_LOADED:-}" ]; then
    return 0
fi
_LARS_TOOLCHAIN_INSTALL_LOADED=1

# Source the foundational libs when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi
if [ "${_LARS_TOOLCHAIN_PYTHON_LOADED:-}" != "1" ]; then
    # shellcheck source=toolchain-python.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/toolchain-python.sh"
fi
if [ "${_LARS_TOOLCHAIN_INVENTORY_LOADED:-}" != "1" ]; then
    # shellcheck source=toolchain-inventory.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/toolchain-inventory.sh"
fi

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
