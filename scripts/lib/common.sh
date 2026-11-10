#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/common.sh - Shared logging, dependency, and utility helpers
# for the home-infrastructure scripts.
#
# Source this file from other scripts:
#   LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" >/dev/null 2>&1 && pwd -P)"
#   source "${LIB_DIR}/common.sh"
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)
# Target environments: local macOS dev, CI (GitHub Actions ubuntu/macos)
#

# Guard against double-sourcing
if [ -n "${_LOG_COMMON_LOADED:-}" ]; then
    return 0
fi
_LOG_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Color codes (printf-safe ANSI escapes, no echo -e)
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Output helpers
# Uses printf throughout; no echo -e (not POSIX, differs across BSD/GNU).
# ---------------------------------------------------------------------------

log_hr() {
    # 60-char horizontal rule; portable: printf blank + BSD/GNU tr.
    printf '%60s\n' '' | tr ' ' '='
}

log_header() {
    local hr
    hr="$(log_hr)"
    printf '\n%b%s%b\n' "${BLUE}" "${hr}" "${NC}"
    printf '%b%s%b\n' "${BLUE}${BOLD}" "$1" "${NC}"
    printf '%b%s%b\n' "${BLUE}" "${hr}" "${NC}"
}

log_step() {
    printf '\n%b[>]%b %s\n' "${BLUE}" "${NC}" "$1"
}

log_success() {
    printf '%b[+]%b %s\n' "${GREEN}" "${NC}" "$1"
}

log_warn() {
    printf '%b[!]%b %s\n' "${YELLOW}" "${NC}" "$1"
}

log_error() {
    printf '%b[x]%b %s\n' "${RED}" "${NC}" "$1" >&2
}

log_info() {
    printf '%b[i]%b %s\n' "${BLUE}" "${NC}" "$1"
}

log_config() {
    printf '    %-18s %s\n' "${1}:" "$2"
}

# ---------------------------------------------------------------------------
# Control flow
# ---------------------------------------------------------------------------

die() {
    # log_error + exit 1. Usage: die "message" [exit_code]
    local code="${2:-1}"
    log_error "$1"
    exit "${code}"
}

# ---------------------------------------------------------------------------
# Dependency probing
# ---------------------------------------------------------------------------

# require_command <cmd> [install_hint]
# Exits non-zero (and prints an actionable hint) if <cmd> is not on PATH.
require_command() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "Missing required command: ${cmd}"
        if [ -n "${install_hint}" ]; then
            printf '       Install: %s\n' "${install_hint}" >&2
        fi
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Repo root resolution
#
# log_repo_root
#   Walks up from the current directory until `git rev-parse` succeeds and
#   prints the top-level path. Returns 1 if not inside a git work tree.
# ---------------------------------------------------------------------------

log_repo_root() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    printf '%s' "${root}"
}