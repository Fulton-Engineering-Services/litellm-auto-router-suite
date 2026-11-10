#!/bin/bash
# shellcheck shell=bash
# setup-remote-repository.sh — create and enforce the GitHub repository for this project.
#
# Usage:
#   scripts/setup-remote-repository.sh [--org ORG] [--name NAME] [--description TEXT]
#                                      [--dry-run] [--yes] [--verify] [--verbose]
#
# Options:
#   --org           Organization that owns the repo (default: Fulton-Engineering-Services)
#   --name          Repository name (default: litellm-auto-router-suite)
#   --description   Repo description sent on create
#   --dry-run       Print every gh api call and JSON body it WOULD make; mutate nothing
#   --yes           Skip the interactive confirmation before mutating
#                   (never authorizes software installs — see scripts/lib/homebrew.sh)
#   --verify        Re-read the enforced reality and print PASS/FAIL per assertion
#   --verbose       Extra progress detail
#   -h, --help      This help
#
# Environment:
#   KEEP_WORKDIR=1    Leave the generated JSON bodies in place and print the path
#                     instead of deleting them on exit (see lib/repo-gate.sh).
#
# Layout — this file is a launcher; the steps live in scripts/lib/, one
# responsibility per file. This repo holds bash to 250 lines per file, tighter
# than the 500-line ceiling elsewhere, because bash accumulates hard-won
# comments about API quirks and a 700-line wall of them stops being readable
# long before it stops being correct.
#
#   lib/common.sh              logging, die, require_command
#   lib/github.sh              gh bootstrap, gh_api, github_org_admin
#   lib/repo-gate.sh           the single write path: write_api, confirm, cleanup
#   lib/repo-create.sh         repository create, then settings reconcile
#   lib/repo-push.sh           preflight (the safety gate) and the push of main
#   lib/ruleset-definition.sh  the desired ruleset, and live-vs-desired comparison
#   lib/ruleset-apply.sh       create/update the ruleset, DCO coverage assertion
#   lib/repo-verify.sh         --verify assertions and the operator UI to-do
#   lib/homebrew.sh, lib/toolchain.sh   shared with the toolchain setup scripts
#
# Idempotent: every mutation is preceded by a GET and is a no-op when the remote
# state already matches, so re-running after a partial failure is safe.
#
# Preflight refuses to run on a dirty worktree, off `main`, or against an `origin`
# that points somewhere other than the target. (--dry-run pushes nothing, so it is
# exempt from the `main` requirement and can be run from a feature branch.)
#
# Requirements:
#   - gh (authenticated, with admin:org on the target org for the ruleset step)
#   - git, jq
#   - The DCO GitHub App installed on the org with repository_selection "all"
#
# Three Settings→General toggles have no REST or GraphQL field and are therefore
# printed as deep links at the end rather than attempted through gh.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"

# ---------------------------------------------------------------------------
# Modules, in load order. The first two are foundational and self-source their
# own dependencies; the step modules may be sourced in any order because every
# call happens inside main(), long after all of them are loaded.
# ---------------------------------------------------------------------------

for _module in common github repo-gate repo-create repo-push \
               ruleset-definition ruleset-apply repo-verify; do
    [ -f "$LIB_DIR/${_module}.sh" ] || { echo "FATAL: missing $LIB_DIR/${_module}.sh" >&2; exit 1; }
    # shellcheck source=/dev/null disable=SC1091
    . "$LIB_DIR/${_module}.sh"
done
unset _module

# Registered before any step can fail, so a die() partway through still cleans up.
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Defaults (env-overridable)
# ---------------------------------------------------------------------------

ORG="${ORG:-Fulton-Engineering-Services}"
NAME="${NAME:-litellm-auto-router-suite}"
DESCRIPTION="${DESCRIPTION:-LiteLLM auto-router suite: gateway, headroom compression plane, routers, and control planes.}"
HOMEPAGE="${HOMEPAGE:-}"
DRY_RUN=false
ASSUME_YES=false
VERIFY_ONLY=false
VERBOSE=false
POSITIONAL_SEEN=false
# GitHub Actions' integration id; stable across every org ruleset in this org.
ACTIONS_INTEGRATION_ID=15368
WORKDIR=""
FAILURES=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        --org)
            [ $# -ge 2 ] || { log_error "--org requires a value"; exit 1; }
            ORG="$2"; shift 2 ;;
        --name)
            [ $# -ge 2 ] || { log_error "--name requires a value"; exit 1; }
            NAME="$2"; shift 2 ;;
        --description)
            [ $# -ge 2 ] || { log_error "--description requires a value"; exit 1; }
            DESCRIPTION="$2"; shift 2 ;;
        --homepage)
            [ $# -ge 2 ] || { log_error "--homepage requires a value"; exit 1; }
            HOMEPAGE="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --yes)
            ASSUME_YES=true; shift ;;
        --verify)
            VERIFY_ONLY=true; shift ;;
        --verbose)
            VERBOSE=true; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            exit 2 ;;
        *)
            [ "$POSITIONAL_SEEN" = false ] || { log_error "unexpected argument: $1"; exit 2; }
            POSITIONAL_SEEN=true
            log_warn "ignoring unexpected argument: $1"
            shift ;;
    esac
done

REPO="$ORG/$NAME"
SSH_REMOTE="git@github.com:${ORG}/${NAME}.git"
HTTPS_REMOTE="https://github.com/${ORG}/${NAME}.git"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    require_command git
    require_command jq
    require_command gh

    if [ "$VERIFY_ONLY" = true ]; then
        github_ensure_gh
        verify
        [ "$FAILURES" -eq 0 ] || die "${FAILURES} assertion(s) failed"
        log_success "all assertions passed"
        return 0
    fi

    WORKDIR="$(mktemp -d)"
    preflight
    create_repo
    sync_repo_settings
    push_repo
    apply_ruleset
    assert_dco_coverage

    if [ "$DRY_RUN" = true ]; then
        log_warn "dry run: nothing was created or changed"
        return 0
    fi

    print_ui_todo
    log_success "${REPO} is provisioned"
}

main "$@"
