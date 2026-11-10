#!/bin/bash
# shellcheck shell=bash
# scripts/setup-project-toolchain.sh - Bootstrap every toolchain this repo gates on
#
# Usage:
#   scripts/setup-project-toolchain.sh [--check|--install] [options]
#
# Options:
#   --check             Report only: print the status table, exit non-zero when a
#                       required tool is missing. Installs nothing; CI-usable.
#   --install           Run the install path (the default when no mode is given).
#   --yes               Answer operational prompts yes. NEVER authorizes software
#                       installs - see CONSENT below.
#   --skip-brew-upgrade Do not offer `brew upgrade`. `brew update` still runs.
#   --python-version X  Override the pinned python version (default: the value in
#                       python/.python-version, else 3.12).
#   --skip-node         Skip the node/pnpm formulae, pnpm install, and lefthook.
#   --skip-python       Skip uv python install, the pyenv leg, and uv sync.
#   -h, --help          Show this help
#
# Sequence (install path):
#   homebrew_ensure -> brew update -> brew formulae (git jq shellcheck bazelisk
#   pyenv uv node pnpm) -> offer brew upgrade -> uv python install (authoritative)
#   -> pyenv advisory (uv, not pyenv, is what the gates use) -> pnpm install ->
#   uv sync -> lefthook install -> status table.
#
# CONSENT:
#   Software installation requires AUTO_INSTALL_DEPS=1 in the environment or an
#   explicit "y" at a controlling terminal (scripts/lib/homebrew.sh owns the
#   rule). --yes governs operational prompts only, so no flag combination can
#   pipe an installer to bash without the operator seeing it first.
#
# Idempotency:
#   Every step checks before acting: brew list, uv python find, pyenv versions,
#   and the package managers' own frozen-lockfile installs. Re-running is safe.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"
[ -f "$LIB_DIR/common.sh" ] || { echo "FATAL: missing $LIB_DIR/common.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh disable=SC1091
. "$LIB_DIR/common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

for _lib in homebrew.sh toolchain.sh; do
    [ -f "${LIB_DIR}/${_lib}" ] || { echo "FATAL: missing ${LIB_DIR}/${_lib}" >&2; exit 1; }
done
unset _lib
# shellcheck source=lib/homebrew.sh disable=SC1091
. "${LIB_DIR}/homebrew.sh"
# shellcheck source=lib/toolchain.sh disable=SC1091
. "${LIB_DIR}/toolchain.sh"

# ---------------------------------------------------------------------------
# Defaults (env-overridable)
# ---------------------------------------------------------------------------

CHECK="${SETUP_CHECK:-0}"
INSTALL="${SETUP_INSTALL:-0}"
YES="${SETUP_YES:-0}"
SKIP_BREW_UPGRADE="${SETUP_SKIP_BREW_UPGRADE:-0}"
SKIP_NODE="${SETUP_SKIP_NODE:-0}"
SKIP_PYTHON="${SETUP_SKIP_PYTHON:-0}"
PY_VERSION_REQUESTED="${TOOLCHAIN_PYTHON_VERSION:-}"
POSITIONAL_SEEN=false

# Formulae this repo bootstraps from. Version truth lives in packageManager /
# the uv dev group / package.json, never in brew.
BOOTSTRAP_FORMULAE="git jq shellcheck bazelisk pyenv uv node pnpm"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        --check)              CHECK=1;                        shift ;;
        --install)            INSTALL=1;                      shift ;;
        --yes)                YES=1;                          shift ;;
        --skip-brew-upgrade)  SKIP_BREW_UPGRADE=1;            shift ;;
        --python-version)
            [ $# -ge 2 ] || { log_error "--python-version requires a value"; exit 1; }
            PY_VERSION_REQUESTED="$2"; shift 2 ;;
        --skip-node)          SKIP_NODE=1;                    shift ;;
        --skip-python)        SKIP_PYTHON=1;                  shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            printf 'Try: scripts/setup-project-toolchain.sh --help\n' >&2
            exit 2 ;;
        *)
            [ "${POSITIONAL_SEEN}" = "false" ] || { log_error "unexpected argument: $1"; exit 2; }
            log_error "unexpected argument: $1 (this script takes no positional arguments)"
            exit 2 ;;
    esac
done

if [ "${CHECK}" = "1" ] && [ "${INSTALL}" = "1" ]; then
    log_error "--check and --install are mutually exclusive"
    exit 2
fi

if [ -n "${PY_VERSION_REQUESTED}" ]; then
    case "${PY_VERSION_REQUESTED}" in
        ""|*[!0-9.]*)
            log_error "--python-version must be digits and dots (e.g. 3.12); got '${PY_VERSION_REQUESTED}'"
            exit 2 ;;
    esac
    TOOLCHAIN_PYTHON_VERSION="${PY_VERSION_REQUESTED}"
    export TOOLCHAIN_PYTHON_VERSION
fi

# ---------------------------------------------------------------------------
# Status table
# ---------------------------------------------------------------------------

print_summary_table() {
    local c_name="" c_req="" c_found="" c_ok="" c_stripped=""
    log_header "Toolchain status"
    printf '%-12s %-9s %-46s %s\n' "name" "required" "found" "ok"
    printf '%s\n' "------------------------------------------------------------------------------------------------"
    while IFS=$'\t' read -r c_name c_req c_found; do
        [ -n "${c_name}" ] || continue
        if [ "${c_found}" = "-" ] || [ -z "${c_found}" ]; then
            c_found="-"
            c_ok="MISSING"
        else
            c_ok="ok"
            # Collapse $HOME and clip long paths so the table stays a table.
            c_stripped="${c_found#"$HOME"}"
            if [ "${c_stripped}" != "${c_found}" ]; then
                c_found="~${c_stripped}"
            fi
            if [ "${#c_found}" -gt 42 ]; then
                c_found="${c_found:0:39}..."
            fi
        fi
        printf '%-12s %-9s %-46s %s\n' "${c_name}" "${c_req}" "${c_found}" "${c_ok}"
    done <<< "$(toolchain_rows)"
    printf '\n'
    log_config "python pin" "${TOOLCHAIN_PYTHON_VERSION} (uv is authoritative; pyenv is advisory)"
    log_config "repo root" "${REPO_ROOT}"
}

missing_list() {
    toolchain_missing_tools || true
}

# ---------------------------------------------------------------------------
# Install path steps (each checks before acting)
# ---------------------------------------------------------------------------

confirm_operational() {
    # --yes answers this; a non-TTY run proceeds (real installs are consented
    # separately inside homebrew.sh).
    [ "${YES}" = "1" ] && return 0
    [ -t 0 ] || return 0
    if homebrew_confirm "Proceed with the install path?"; then
        return 0
    fi
    die "aborted by operator"
}

step_node() {
    if [ "${SKIP_NODE}" = "1" ]; then
        log_info "Skipping node/pnpm steps (--skip-node)."
        return 0
    fi
    log_step "Installing TypeScript workspace dependencies..."
    [ -f "${REPO_ROOT}/typescript/package.json" ] \
        || die "typescript/package.json is missing - the pnpm workspace root is not in this checkout."
    pnpm --dir "${REPO_ROOT}/typescript" install
    log_step "Installing git hooks (lefthook)..."
    # Lefthook resolves its config from the git root, which is why lefthook.yml
    # lives at the repo root rather than next to the workspace.
    pnpm --dir "${REPO_ROOT}/typescript" exec lefthook install
    log_success "pnpm dependencies and git hooks installed."
}

step_python() {
    if [ "${SKIP_PYTHON}" = "1" ]; then
        log_info "Skipping python steps (--skip-python)."
        return 0
    fi
    log_step "Ensuring uv-managed python ${TOOLCHAIN_PYTHON_VERSION} (authoritative)..."
    toolchain_install_uv_python
    log_step "pyenv advisory leg (the gates never consult pyenv)..."
    toolchain_install_python
    log_step "Syncing the python workspace..."
    [ -f "${REPO_ROOT}/python/pyproject.toml" ] \
        || die "python/pyproject.toml is missing - the uv workspace root is not in this checkout."
    uv sync --directory "${REPO_ROOT}/python"
    log_success "python workspace synced."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log_header "litellm-auto-router-suite toolchain setup"
log_config "mode" "$([ "${CHECK}" = "1" ] && printf 'check (report only)' || printf 'install')"
log_config "consent" "AUTO_INSTALL_DEPS=${AUTO_INSTALL_DEPS:-0} (installs need this or a TTY yes; --yes does not grant it)"

if [ "${CHECK}" = "1" ]; then
    print_summary_table
    missing="$(missing_list)"
    if [ -n "${missing}" ]; then
        log_error "Toolchain incomplete. Missing required tools: $(printf '%s' "${missing}" | tr '\n' ' ')"
        printf '       Install them with: scripts/setup-project-toolchain.sh --install\n' >&2
        exit 1
    fi
    log_success "Toolchain complete - nothing installed (check only)."
    exit 0
fi

confirm_operational

if [ "${SKIP_NODE}" != "1" ] || [ "${SKIP_PYTHON}" != "1" ] || [ "${SKIP_BREW_UPGRADE}" != "1" ]; then
    homebrew_ensure || log_warn "Homebrew unavailable - continuing; steps below will report what they cannot do."
    homebrew_update
    # shellcheck disable=SC2086  # space-separated formula list, intentionally split
    homebrew_install_formulae ${BOOTSTRAP_FORMULAE} \
        || log_warn "Some formulae were not installed (no consent or brew failure)."
    if [ "${SKIP_BREW_UPGRADE}" = "1" ]; then
        log_info "Skipping the brew upgrade offer (--skip-brew-upgrade); brew update already ran."
    else
        homebrew_offer_upgrade
    fi
fi

step_python
step_node

print_summary_table
missing="$(missing_list)"
if [ -n "${missing}" ]; then
    log_error "Setup finished but required tools are still missing: $(printf '%s' "${missing}" | tr '\n' ' ')"
    exit 1
fi
log_success "Toolchain ready. Next: scripts/configure-git.sh"
