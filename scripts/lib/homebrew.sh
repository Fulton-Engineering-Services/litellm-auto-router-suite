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
#   homebrew_detect_os                   print "macos", "linux" or "unknown"
#   homebrew_detect_package_manager      print the first package manager found
#   homebrew_consented                   0 when the environment authorizes installs
#   homebrew_confirm <prompt...>         [y/N] on stderr, only at a controlling TTY
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
# Layout - this file is the public surface other scripts source; it holds no
# logic, and every function above is re-exported from one of the two modules
# beside it, so existing `source lib/homebrew.sh` callers are unaffected:
#
#   lib/homebrew-platform.sh  OS probe plus the consent/confirm primitives
#   lib/homebrew-install.sh   Homebrew bootstrap, formulae, update and upgrade
#   lib/common.sh             logging, die, require_command
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LOG_HOMEBREW_LOADED:-}" ]; then
    return 0
fi
_LOG_HOMEBREW_LOADED=1

# This file and its modules live side by side in scripts/lib/.
_LARS_HOMEBREW_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1090,SC1091
    source "${_LARS_HOMEBREW_DIR}/common.sh"
fi

# Both modules are hard requirements. Checked before sourcing rather than
# discovered mid-run: this file is sourced, so a failed source would not
# necessarily abort the caller, and a homebrew.sh that had quietly lost its
# install half would still look healthy until the first real install.
for _lib in homebrew-platform homebrew-install; do
    [ -f "${_LARS_HOMEBREW_DIR}/${_lib}.sh" ] \
        || { echo "FATAL: missing ${_LARS_HOMEBREW_DIR}/${_lib}.sh" >&2; exit 1; }
done
unset _lib
# shellcheck source=homebrew-platform.sh disable=SC1090,SC1091
. "${_LARS_HOMEBREW_DIR}/homebrew-platform.sh"
# shellcheck source=homebrew-install.sh disable=SC1090,SC1091
. "${_LARS_HOMEBREW_DIR}/homebrew-install.sh"
unset _LARS_HOMEBREW_DIR
