#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/git-credentials.sh - Host-aware credential.helper selection.
# Source file; do not execute directly.
#
# Public functions:
#   configure_credential_helper   pick and write credential.helper for this repo
#
# Reads the launcher's globals: VERBOSE.
#
# CREDENTIAL HELPER (macOS, selected by the origin remote host):
#   SSH remote (git@host: / ssh://)  "" (clears the helper chain; SSH keys auth)
#   github.com                       gh CLI (osxkeychain if gh is missing)
#   GitLab host                      glab CLI (osxkeychain if glab is missing)
#   other HTTPS hosts                osxkeychain fallback
#
# Kept apart from the plain settings in git-settings.sh because the rules here
# are host-dependent and platform-dependent, and getting them wrong leaks
# credentials into the wrong helper -- whereas a wrong push.default is merely
# annoying.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_GIT_CREDENTIALS_LOADED:-}" ]; then
    return 0
fi
_LARS_GIT_CREDENTIALS_LOADED=1

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

# configure_credential_helper
#   Host-aware credential.helper selection. Idempotent: every branch clears the
#   existing chain first, so re-running converges instead of stacking helpers.
configure_credential_helper() {
    case "$(uname -s)" in
        Darwin) ;;
        *)
            note "credential.helper selection is macOS-specific; leaving git's default on $(uname -s)."
            return 0
            ;;
    esac

    local remote_url="" transport="" remote_host=""
    remote_url="$(git config --get remote.origin.url 2>/dev/null)" || true

    case "${remote_url}" in
        git@*:*|ssh://*)  transport="ssh" ;;
        http://*|https://*) transport="https" ;;
        *)                transport="" ;;
    esac

    if [ "${transport}" = "ssh" ]; then
        # SSH keys authenticate; an empty helper value clears any inherited chain.
        git config --unset-all credential.helper 2>/dev/null || true
        git config --add credential.helper ""
        log_success "SSH remote - credential helper cleared"
        return 0
    fi

    if [ "${transport}" = "https" ]; then
        local host="${remote_url#*://}"
        host="${host#*@}"
        remote_host="${host%%/*}"
    fi

    git config --unset-all credential.helper 2>/dev/null || true

    case "${remote_host}" in
        *github.com*)
            if command -v gh >/dev/null 2>&1; then
                # Empty value first clears inherited helpers, then gh takes over.
                git config --add credential.helper ""
                git config --add credential.helper "$(command -v gh) auth git-credential"
                log_success "Set credential helper to gh (multi-account support)"
            else
                git config credential.helper osxkeychain
                log_warn "gh CLI not found, using osxkeychain (may have multi-account issues)"
            fi
            ;;
        *gitlab*)
            if command -v glab >/dev/null 2>&1; then
                git config --add credential.helper ""
                git config --add credential.helper "$(command -v glab) auth git-credential"
                log_success "Set credential helper to glab (GitLab remote)"
            else
                git config credential.helper osxkeychain
                log_warn "glab CLI not found, using osxkeychain (may have multi-account issues)"
            fi
            ;;
        "")
            git config credential.helper osxkeychain
            log_warn "Could not determine a remote host, using osxkeychain (may have multi-account issues)"
            ;;
        *)
            git config credential.helper osxkeychain
            log_warn "Unknown HTTPS host '${remote_host}', using osxkeychain (may have multi-account issues)"
            ;;
    esac
}
