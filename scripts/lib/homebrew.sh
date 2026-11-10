#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/homebrew.sh - Platform detection and Homebrew bootstrap.
# Source file; do not execute directly.
#
# Public functions:
#   homebrew_ensure                      install Homebrew itself when consented
#   homebrew_install_formulae <name>...  install named formulae when consented
#   homebrew_update                      refresh the formula index (always runs)
#   homebrew_offer_upgrade               offer `brew upgrade` (interactive only)
#
# AUTO-INSTALL CONSENT (the rule this file owns):
#   Consent comes from AUTO_INSTALL_DEPS (default 0) or an explicit "y" typed at
#   a controlling terminal. It NEVER comes from a --yes flag on a calling
#   script: --yes governs operational prompts, and must never silently trigger
#   a curl-pipe-bash installer or a package-manager command.
#
#   Set AUTO_INSTALL_DEPS=1 for a non-interactive install:
#     AUTO_INSTALL_DEPS=1 scripts/setup-project-toolchain.sh --install
#
# UPGRADE POLICY:
#   `brew update` always runs (index refresh only). `brew upgrade` runs only
#   when the operator answers yes at a TTY; neither --yes nor AUTO_INSTALL_DEPS
#   implies it. Tool versions are otherwise project-pinned (pnpm via
#   "packageManager", ruff/mypy/pytest via the uv dev group, oxlint/vitest/
#   typescript via package.json), so brew supplies bootstrappers only and no
#   version this repo depends on is ever set by `brew upgrade`.
#
# Reads globals: AUTO_INSTALL_DEPS (from environment)
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LOG_HOMEBREW_LOADED:-}" ]; then
    return 0
fi
_LOG_HOMEBREW_LOADED=1

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

# ---------------------------------------------------------------------------
# homebrew_ensure
#
# Makes `brew` available in the current shell, installing Homebrew first when it
# is missing and consented. macOS only. Returns 1 (without failing the caller)
# when Homebrew is unavailable and not consented to.
# ---------------------------------------------------------------------------
homebrew_ensure() {
    if command -v brew >/dev/null 2>&1; then
        return 0
    fi

    if [ "$(homebrew_detect_os)" != "macos" ]; then
        log_warn "Homebrew is not available on $(uname -s); install packages with your system package manager."
        return 1
    fi

    log_step "Homebrew is not installed."
    log_info "Homebrew installs software from the internet. The exact command is:"
    printf '    %s\n' "${HOMEBREW_INSTALL_COMMAND}" >&2
    log_info "Consent comes from AUTO_INSTALL_DEPS=1 or answering yes below - never from --yes."

    local do_install=false
    if homebrew_consented; then
        do_install=true
        log_warn "AUTO_INSTALL_DEPS is set - installing Homebrew without prompting."
    elif [ -t 0 ]; then
        if homebrew_confirm "Install Homebrew now?"; then
            do_install=true
        fi
    else
        log_warn "No controlling terminal and AUTO_INSTALL_DEPS is unset - not installing."
    fi

    if [ "${do_install}" != "true" ]; then
        log_warn "Skipping Homebrew installation."
        return 1
    fi

    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew installation failed"

    # Make brew visible to the current shell (Apple Silicon vs Intel prefixes).
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! command -v brew >/dev/null 2>&1; then
        log_warn "Homebrew install completed but 'brew' is not on PATH."
        return 1
    fi

    log_success "Homebrew installed."
    return 0
}

# ---------------------------------------------------------------------------
# homebrew_install_formulae <name>...
#
# Installs the named formulae, skipping any already present (idempotent). Every
# install is consent-gated by the rule above; a declined or non-interactive run
# returns 1 so the caller decides whether that is fatal.
# ---------------------------------------------------------------------------
homebrew_install_formulae() {
    [ $# -gt 0 ] || return 0

    if ! command -v brew >/dev/null 2>&1; then
        homebrew_ensure || return 1
    fi

    local -a missing
    missing=()
    local formula=""
    for formula in "$@"; do
        if brew list --versions "${formula}" >/dev/null 2>&1; then
            log_info "  brew: ${formula} already installed"
        else
            missing+=("${formula}")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    log_step "Homebrew would install: ${missing[*]}"
    if ! homebrew_consented && ! homebrew_confirm "Install these packages with Homebrew?"; then
        log_warn "Not installing (no consent): ${missing[*]}"
        log_warn "Re-run from a terminal to answer yes, or set AUTO_INSTALL_DEPS=1."
        return 1
    fi

    for formula in "${missing[@]}"; do
        log_info "brew install ${formula}"
        if ! brew install "${formula}"; then
            log_error "brew install ${formula} failed"
            return 1
        fi
    done
    log_success "Installed via Homebrew: ${missing[*]}"
    return 0
}

# ---------------------------------------------------------------------------
# homebrew_update
#
# Refreshes the formula index. Runs unconditionally when brew exists: an up to
# date index is what makes the version check below meaningful, and `brew update`
# changes no installed software.
# ---------------------------------------------------------------------------
homebrew_update() {
    if ! command -v brew >/dev/null 2>&1; then
        log_info "brew update skipped: brew is not installed."
        return 0
    fi
    log_step "brew update (formula index only; always runs)..."
    if brew update; then
        log_success "brew index updated."
    else
        log_warn "brew update failed; continuing with the existing index."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# homebrew_offer_upgrade
#
# Offers `brew upgrade`. Interactive only: no TTY means no upgrade, and neither
# --yes nor AUTO_INSTALL_DEPS may substitute for the operator's answer, because
# upgrading bootstrappers is a workstation decision this repo never depends on.
# ---------------------------------------------------------------------------
homebrew_offer_upgrade() {
    if ! command -v brew >/dev/null 2>&1; then
        return 0
    fi
    if [ ! -t 0 ]; then
        log_info "brew upgrade skipped: no controlling terminal (upgrade is an operator decision)."
        return 0
    fi
    log_info "brew upgrade is deliberately NOT implied by --yes or AUTO_INSTALL_DEPS:"
    log_info "every version this repo depends on is pinned (packageManager, the uv dev group, package.json)."
    if homebrew_confirm "Run 'brew upgrade' for every outdated formula?"; then
        log_step "brew upgrade..."
        if brew upgrade; then
            log_success "brew upgrade complete."
        else
            log_warn "brew upgrade reported failures; continuing."
        fi
    else
        log_info "brew upgrade skipped."
    fi
    return 0
}
