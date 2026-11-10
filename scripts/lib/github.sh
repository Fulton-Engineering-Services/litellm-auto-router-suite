#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/github.sh - gh CLI bootstrap and GitHub API helpers.
# Source file; do not execute directly.
#
# Public functions:
#   github_ensure_gh              gh present (brew install on consent) and authenticated
#   github_org_admin <org>        fail fast when the token cannot administer the org
#   gh_api <METHOD> <PATH> [extra gh-api args...]
#                                 logged wrapper around `gh api -X METHOD PATH "$@"`
#
# gh_api passes every trailing argument straight through, so callers append
# --jq/-q, --input -, --paginate, --field, etc. after the path:
#   gh_api GET /repos/acme/widget -q .default_branch
#
# Transports: this file never assumes an SSH remote or a GitHub SSH key. gh
# authenticates over HTTPS; git transport is the caller's concern.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LOG_GITHUB_LOADED:-}" ]; then
    return 0
fi
_LOG_GITHUB_LOADED=1

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

# ---------------------------------------------------------------------------
# github_ensure_gh
#
# Ensures the gh CLI is installed and authenticated. Installing gh goes through
# homebrew_install_formulae so it inherits that file's consent rule (never a
# --yes flag). Authentication cannot be automated here: without it the caller
# gets the exact remediation string instead of a later, cryptic 401.
# ---------------------------------------------------------------------------
github_ensure_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        log_step "The gh CLI is not installed."
        if command -v homebrew_install_formulae >/dev/null 2>&1; then
            homebrew_install_formulae gh \
                || die "gh is required and was not installed. Install it (brew install gh), then re-run."
        else
            die "gh is not installed. Install it first: brew install gh (or scripts/setup-project-toolchain.sh --install)"
        fi
        require_command gh "Install gh: brew install gh"
    fi
    log_info "gh: $(command -v gh)"

    if ! gh auth status >/dev/null 2>&1; then
        die "gh is not authenticated for any GitHub host. Remediation: run: gh auth login"
    fi
    log_success "gh is authenticated as $(gh api user -q .login 2>/dev/null || printf 'unknown user')."
}

# ---------------------------------------------------------------------------
# github_org_admin <org>
#
# Fails fast when the current token cannot manage organization settings, which
# is what the org-level ruleset call needs. Two layers:
#   1. A classic PAT reports its scopes in the x-oauth-scopes response header;
#      a fine-grained token does not, so the header check is advisory only.
#   2. The authoritative probe is an admin-only read (org rulesets), which
#      returns 403 for a non-admin regardless of token type.
# ---------------------------------------------------------------------------
github_org_admin() {
    local org="${1:-}"
    [ -n "${org}" ] || die "github_org_admin requires an org name"
    github_ensure_gh

    local scopes=""
    scopes="$(gh api -i user 2>/dev/null \
        | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-oauth-scopes"{gsub(/ /,"",$2); print $2}')" || true

    if [ -n "${scopes}" ]; then
        case ",${scopes}," in
            *",admin:org,"*)
                log_info "token scopes include admin:org"
                ;;
            *)
                die "the gh token lacks the admin:org scope (scopes: ${scopes}). Remediation: run: gh auth refresh-scopes -s admin:org, then run: gh auth login"
                ;;
        esac
    else
        log_info "no x-oauth-scopes header (fine-grained token?); probing admin access directly."
    fi

    if ! gh api "orgs/${org}/rulesets" >/dev/null 2>&1; then
        die "the gh token cannot read org rulesets for '${org}', so it cannot manage org settings. Needs the admin:org scope; see github.com/organizations/${org}/settings/admin"
    fi
    log_success "token can administer org '${org}'."
}

# ---------------------------------------------------------------------------
# gh_api <METHOD> <PATH> [extra gh-api args...]
#
# Thin, logged wrapper around `gh api -X`. Extra arguments are passed through
# verbatim after the path (--jq/-q, --input -, --paginate, --field, --raw-field,
# --method overrides, ...), which is what makes PATCH bodies and jq filters
# work without a second wrapper per shape.
# ---------------------------------------------------------------------------
gh_api() {
    [ $# -ge 2 ] || die "gh_api requires <METHOD> <PATH> [extra gh api args...]"
    local method="$1"
    local path="$2"
    shift 2
    log_step "gh api -X ${method} ${path}"
    gh api -X "${method}" "${path}" "$@"
}
