#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/homebrew-platform.sh - OS probe and install-consent primitives.
# Source file; do not execute directly.
#
# Public functions:
#   homebrew_detect_os                  print "macos", "linux" or "unknown"
#   homebrew_detect_package_manager     print the first package manager found
#   homebrew_consented                  0 when the environment authorizes installs
#   homebrew_confirm <prompt...>        [y/N] on stderr, only at a controlling TTY
#
# Reads globals: AUTO_INSTALL_DEPS (from the environment).
#
# The consent rule, stated in full here because these two functions are the only
# place it is evaluated:
#
#   Consent comes from AUTO_INSTALL_DEPS (default 0) or an explicit "y" typed at
#   a controlling terminal. It NEVER comes from a --yes flag on a calling script:
#   --yes governs operational prompts, and must never silently trigger a
#   curl-pipe-bash installer or a package-manager command.
#
# Both primitives fail closed -- no TTY means no consent -- so a caller can never
# be blocked or surprised by a "yes" it did not ask for. The install path lives
# in homebrew-install.sh.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_HOMEBREW_PLATFORM_LOADED:-}" ]; then
    return 0
fi
_LARS_HOMEBREW_PLATFORM_LOADED=1

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

# The literal Homebrew installer command, printed verbatim before any prompt so
# the operator always sees exactly what would be piped to bash.
HOMEBREW_INSTALL_COMMAND='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# ---------------------------------------------------------------------------
# homebrew_detect_os
#
# Prints "macos", "linux", or "unknown". Never exits: callers decide whether an
# unsupported platform is fatal.
# ---------------------------------------------------------------------------
homebrew_detect_os() {
    case "$(uname -s)" in
        Darwin) printf 'macos\n' ;;
        Linux)  printf 'linux\n' ;;
        *)
            log_warn "Unsupported OS '$(uname -s)'. Auto-install is not available."
            printf 'unknown\n'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# homebrew_detect_package_manager
#
# Probes package managers and prints the first one found. Prints nothing and
# returns 1 when none is detected.
# ---------------------------------------------------------------------------
homebrew_detect_package_manager() {
    local mgr=""
    for mgr in brew apt-get dnf yum apk pacman; do
        if command -v "${mgr}" >/dev/null 2>&1; then
            printf '%s' "${mgr}"
            return 0
        fi
    done
    printf ''
    return 1
}

# ---------------------------------------------------------------------------
# homebrew_consented
#
# Returns 0 when the environment authorizes installs (AUTO_INSTALL_DEPS in
# {1,true,yes,y}, case-insensitive). Deliberately insensitive to any --yes flag.
# ---------------------------------------------------------------------------
homebrew_consented() {
    local v=""
    v="$(printf '%s' "${AUTO_INSTALL_DEPS:-0}" | tr '[:upper:]' '[:lower:]')"
    case "${v}" in
        1|true|yes|y) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# homebrew_confirm <prompt...>
#
# Asks a [y/N] question on stderr and reads from stdin. Returns 1 without
# prompting when there is no controlling terminal, so a non-interactive run can
# never be blocked or surprised by a "yes".
# ---------------------------------------------------------------------------
homebrew_confirm() {
    [ -t 0 ] || return 1
    local ans=""
    printf '%s [y/N] ' "$*" >&2
    read -r ans
    case "${ans}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}
