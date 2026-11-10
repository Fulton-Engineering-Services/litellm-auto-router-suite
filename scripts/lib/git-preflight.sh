#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/git-preflight.sh - Preconditions and identity for configure-git.
# Source file; do not execute directly.
#
# Public functions:
#   check_git_repo                    refuse to run outside a git repository
#   validate_merge_strategy <value>   accept only true/false for pull.rebase
#   resolve_identity                  fill NAME and EMAIL from the documented
#                                     order: flags, git config, gh, prompt
#
# Reads the launcher's globals: NAME, EMAIL, VERBOSE.
#
# Identity resolution order (this repo never hardcodes a person's identity):
#   1. -n / -e on the command line
#   2. an existing `git config --global user.name` / `user.email`
#   3. the authenticated gh account: gh api user -q .login and -q .id, giving
#      <id>+<login>@users.noreply.github.com (GitHub's noreply form, so merged
#      commits attribute to the account instead of leaking a private address)
#   4. an interactive prompt - only at a controlling terminal
#
# This is the part of configure-git.sh an operator most often has to reason
# about, which is why it is the part kept separate: the order above is a privacy
# decision, not a convenience one.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_GIT_PREFLIGHT_LOADED:-}" ]; then
    return 0
fi
_LARS_GIT_PREFLIGHT_LOADED=1

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

check_git_repo() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not in a git repository. Run this script from inside the cloned repository."
        exit 1
    fi
    note "Confirmed: running in a git repository ($(git rev-parse --show-toplevel 2>/dev/null))"
}

validate_merge_strategy() {
    local strategy="$1"
    case "${strategy}" in
        true|false) return 0 ;;
        *)
            log_error "Invalid merge strategy: ${strategy}"
            log_error "Valid options: true, false"
            exit 1
            ;;
    esac
}

# resolve_identity
#   Fills NAME and EMAIL using the documented order. Prompts only when there is
#   a controlling terminal; a non-interactive run with no identity fails with the
#   exact flags to pass instead of hanging on a read.
resolve_identity() {
    if [ -z "${NAME}" ]; then
        NAME="$(git config --global user.name 2>/dev/null)" || true
    fi
    if [ -z "${EMAIL}" ]; then
        EMAIL="$(git config --global user.email 2>/dev/null)" || true
    fi
    if [ -n "${NAME}" ] && [ -n "${EMAIL}" ]; then
        note "Identity taken from existing global git config."
        return 0
    fi

    if [ -z "${NAME}" ] || [ -z "${EMAIL}" ]; then
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            local login="" uid=""
            login="$(gh api user -q .login 2>/dev/null)" || true
            uid="$(gh api user -q .id 2>/dev/null)" || true
            if [ -n "${login}" ] && [ -n "${uid}" ]; then
                [ -n "${NAME}" ] || NAME="${login}"
                # GitHub's noreply form keeps attribution without publishing a
                # personal address in every commit.
                [ -n "${EMAIL}" ] || EMAIL="${uid}+${login}@users.noreply.github.com"
                note "Identity derived from the authenticated gh account (${login})."
            fi
        else
            note "gh is unavailable or unauthenticated; cannot derive a GitHub noreply identity."
        fi
    fi

    if [ -z "${NAME}" ] || [ -z "${EMAIL}" ]; then
        if [ ! -t 0 ]; then
            log_error "No git identity available and no controlling terminal to ask for one."
            printf '       Pass it explicitly: scripts/configure-git.sh -n "Full Name" -e "name@example.com"\n' >&2
            exit 1
        fi
        while [ -z "${NAME}" ]; do
            printf 'Git user.name (e.g. "Jane Doe"): ' >&2
            read -r NAME
        done
        while [ -z "${EMAIL}" ]; do
            printf 'Git user.email (name@example.com, or the GitHub noreply form): ' >&2
            read -r EMAIL
        done
    fi

    case "${EMAIL}" in
        *@*.*) return 0 ;;
        *)
            log_error "Refusing to set an unusable user.email: '${EMAIL}'"
            exit 1
            ;;
    esac
}
