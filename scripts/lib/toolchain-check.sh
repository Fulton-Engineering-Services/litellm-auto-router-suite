#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/toolchain-check.sh - Read-only toolchain validation and reporting.
# Source file; do not execute directly.
#
# Public functions:
#   toolchain_check_tool <tool>         log one presence line; 0 when found
#   toolchain_rows                      TAB-separated tool/required/found rows
#   toolchain_missing_tools             required tools that are absent
#   toolchain_check_python              validate the python story
#   toolchain_check                     full validation; 0 when ready
#
# Reads the launcher's globals: none.
#
# The check half of the toolchain is portable and never mutates, which is what
# lets CI on Linux run it read-only; only the install half assumes macOS and
# Homebrew (see toolchain-install.sh). Keeping the two apart is what makes that
# guarantee inspectable rather than a promise.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_TOOLCHAIN_CHECK_LOADED:-}" ]; then
    return 0
fi
_LARS_TOOLCHAIN_CHECK_LOADED=1

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
