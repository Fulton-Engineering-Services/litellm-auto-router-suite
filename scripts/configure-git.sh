#!/bin/bash
# shellcheck shell=bash
# scripts/configure-git.sh - Configure git for a litellm-auto-router-suite checkout
#
# Usage:
#   scripts/configure-git.sh [options]
#
# Options:
#   -n, --name NAME       Set git user.name. Default: an existing global
#                         user.name; else the GitHub login from `gh api user`.
#   -e, --email EMAIL     Set git user.email. Default: an existing global
#                         user.email; else the GitHub noreply address
#                         <id>+<login>@users.noreply.github.com.
#   -m, --merge STRATEGY  Set git pull.rebase (default: true). Valid: true, false
#   --no-dco              Do not install the DCO sign-off hooks (default: install)
#   -v, --verbose         Show verbose output
#   -h, --help            Show this help
#
# Identity is resolved in this order, and this repo never hardcodes a person's
# identity: -n/-e, then an existing global git config, then the authenticated gh
# account as <id>+<login>@users.noreply.github.com, then a prompt -- but only at
# a controlling terminal.
#
# credential.helper is chosen per origin host on macOS: an SSH remote clears the
# chain, github.com uses gh, a GitLab host uses glab, anything else falls back to
# osxkeychain. The DCO hooks add the Signed-off-by trailer and then validate it,
# so it is never typed by hand. The full rules, and the reasons for them, are in
# the modules listed below.
#
# Layout - this file is the CLI: defaults, argument parsing, the summary report
# and dispatch. The steps live in scripts/lib/, one responsibility per file:
#
#   lib/git-preflight.sh    repo check, merge-strategy check, identity resolution
#   lib/git-settings.sh     the git configuration this repo asks for
#   lib/git-credentials.sh  host-aware credential.helper selection
#   lib/git-dco-hooks.sh    the two DCO hooks, written fresh on every run
#   lib/common.sh           logging, die, require_command
#
# This repo holds bash to 250 lines per file -- tighter than the 500-line ceiling
# used elsewhere, because bash here accumulates hard-won comments about tooling
# quirks, and a 700-line wall stops being readable long before it stops being
# correct.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"
[ -f "$LIB_DIR/common.sh" ] || { echo "FATAL: missing $LIB_DIR/common.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh disable=SC1091
. "$LIB_DIR/common.sh"

for _lib in git-preflight git-credentials git-settings git-dco-hooks; do
    [ -f "$LIB_DIR/${_lib}.sh" ] || { echo "FATAL: missing $LIB_DIR/${_lib}.sh" >&2; exit 1; }
done
unset _lib
# shellcheck source=lib/git-preflight.sh disable=SC1091
. "$LIB_DIR/git-preflight.sh"
# shellcheck source=lib/git-credentials.sh disable=SC1091
. "$LIB_DIR/git-credentials.sh"
# shellcheck source=lib/git-settings.sh disable=SC1091
. "$LIB_DIR/git-settings.sh"
# shellcheck source=lib/git-dco-hooks.sh disable=SC1091
. "$LIB_DIR/git-dco-hooks.sh"

# ---------------------------------------------------------------------------
# Defaults (env-overridable)
# ---------------------------------------------------------------------------

# Identity deliberately has no baked-in default: see the resolution order above.
NAME="${GIT_CONFIGURE_NAME:-}"
EMAIL="${GIT_CONFIGURE_EMAIL:-}"
MERGE_STRATEGY="${GIT_CONFIGURE_MERGE:-true}"
INSTALL_DCO="${GIT_CONFIGURE_DCO:-true}"
VERBOSE="${GIT_CONFIGURE_VERBOSE:-0}"
POSITIONAL_SEEN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        -n|--name)
            [ $# -ge 2 ] || { log_error "$1 requires a value"; exit 1; }
            NAME="$2"; shift 2 ;;
        -e|--email)
            [ $# -ge 2 ] || { log_error "$1 requires a value"; exit 1; }
            EMAIL="$2"; shift 2 ;;
        -m|--merge)
            [ $# -ge 2 ] || { log_error "$1 requires a value"; exit 1; }
            MERGE_STRATEGY="$2"; shift 2 ;;
        --no-dco)       INSTALL_DCO="false"; shift ;;
        -v|--verbose)   VERBOSE=1;           shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            printf 'Try: scripts/configure-git.sh --help\n' >&2
            exit 2 ;;
        *)
            [ "${POSITIONAL_SEEN}" = "false" ] || { log_error "unexpected argument: $1"; exit 2; }
            POSITIONAL_SEEN=true
            log_error "unexpected argument: $1 (this script takes no positional arguments)"
            exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

# The summary report keeps this script's original echo -e style; decisions and
# failures go through the shared logger in scripts/lib/common.sh.
note() {
    if [ "${VERBOSE}" = "1" ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

show_config() {
    echo
    echo -e "${BLUE}Current Git Configuration:${NC}"
    echo "  user.name:          $(git config user.name 2>/dev/null || printf '(unset)')"
    echo "  user.email:         $(git config user.email 2>/dev/null || printf '(unset)')"
    echo "  pull.rebase:        $(git config pull.rebase 2>/dev/null || printf '(unset)')"
    echo "  push.default:       $(git config push.default 2>/dev/null || printf '(unset)')"
    echo "  push.autoSetupRemote: $(git config push.autoSetupRemote 2>/dev/null || printf '(unset)')"
    echo "  color.ui:           $(git config color.ui 2>/dev/null || printf '(unset)')"
    echo "  remote.origin.tagopt: $(git config --get remote.origin.tagopt 2>/dev/null || printf '(unset)')"
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "  credential.helper:  $(git config --get-all credential.helper 2>/dev/null | tr '\n' ' ')"
    fi

    local hooks_dir=""
    hooks_dir="$(git rev-parse --git-path hooks)"
    if [ -x "${hooks_dir}/prepare-commit-msg" ]; then
        echo "  DCO inject hook:    installed (${hooks_dir}/prepare-commit-msg)"
    else
        echo "  DCO inject hook:    not installed"
    fi
    if [ -x "${hooks_dir}/commit-msg" ]; then
        echo "  DCO validate hook:  installed (${hooks_dir}/commit-msg)"
    else
        echo "  DCO validate hook:  not installed"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo -e "${GREEN}Git configuration - litellm-auto-router-suite${NC}"
    echo "==========================================================="

    check_git_repo
    validate_merge_strategy "${MERGE_STRATEGY}"
    resolve_identity

    echo
    echo "Configuration to apply:"
    echo "  Name:                ${NAME}"
    echo "  Email:               ${EMAIL}"
    echo "  Merge strategy:      ${MERGE_STRATEGY}"
    echo "  DCO sign-off hooks:  ${INSTALL_DCO}"
    echo

    configure_git "${NAME}" "${EMAIL}" "${MERGE_STRATEGY}"

    if [ "${INSTALL_DCO}" = "true" ]; then
        install_dco_hook
        echo -e "${YELLOW}DCO sign-off reminder:${NC} do not type 'Signed-off-by:' yourself."
        echo "The prepare-commit-msg hook adds it; the commit-msg hook rejects a"
        echo "hand-typed trailer that is missing the <email> angle brackets."
    else
        note "Skipped DCO sign-off hooks (--no-dco)"
    fi

    show_config
    echo -e "${GREEN}Git configured successfully.${NC}"
}

main "$@"
