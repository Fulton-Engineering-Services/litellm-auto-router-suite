#!/bin/bash
# shellcheck shell=bash
# scripts/lint-shell.sh - shellcheck gate for every shell script in this repo
#
# Usage:
#   scripts/lint-shell.sh [--verbose] [--version]
#
# Options:
#   --verbose     Print the shellcheck version and the file list before checking
#   --version     Print the shellcheck version and exit
#   -h, --help    Show this help
#
# Scope:
#   Every *.sh under scripts/ and docker/, checked with -x so
#   "# shellcheck source=" directives are followed. Repo-root .shellcheckrc
#   carries the house disable list, so this script must run from the repo root
#   (it cds there itself).
#
# Gate semantics:
#   A missing shellcheck is a FAILURE, never a skip. A green run that checked
#   nothing is worse than a red one, so an empty file set also fails.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"
[ -f "$LIB_DIR/common.sh" ] || { echo "FATAL: missing $LIB_DIR/common.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh disable=SC1091
. "$LIB_DIR/common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

# ---------------------------------------------------------------------------
# Defaults (env-overridable)
# ---------------------------------------------------------------------------

VERBOSE="${LINT_SHELL_VERBOSE:-0}"
SHOW_VERSION="${LINT_SHELL_VERSION:-0}"
# Directories scanned for shell sources, relative to the repo root.
SCAN_DIRS="${LINT_SHELL_DIRS:-scripts docker}"
POSITIONAL_SEEN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        --verbose)   VERBOSE=1;      shift ;;
        --version)   SHOW_VERSION=1; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            printf 'Try: scripts/lint-shell.sh --help\n' >&2
            exit 2 ;;
        *)
            [ "${POSITIONAL_SEEN}" = "false" ] || { log_error "unexpected argument: $1"; exit 2; }
            log_error "unexpected argument: $1 (this script takes no positional arguments)"
            exit 2 ;;
    esac
done

SHELLCHECK_HINT="Install it: brew install shellcheck (or scripts/setup-project-toolchain.sh --install)"

# --version reports the pinned-by-package-manager analyzer version; it still
# requires shellcheck to exist, because a version of nothing is not information.
if [ "${SHOW_VERSION}" = "1" ]; then
    require_command shellcheck "${SHELLCHECK_HINT}"
    shellcheck --version
    exit 0
fi

require_command shellcheck "${SHELLCHECK_HINT}"

cd "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Collect targets
# ---------------------------------------------------------------------------

TARGETS=()
for d in ${SCAN_DIRS}; do
    if [ -d "${REPO_ROOT}/${d}" ]; then
        TARGETS+=("${d}")
    else
        log_warn "skipping absent directory: ${d}/"
    fi
done
[ "${#TARGETS[@]}" -gt 0 ] || die "no shell source directories present (expected: ${SCAN_DIRS})"

file_count="$(find "${TARGETS[@]}" -type f -name '*.sh' | wc -l | tr -d ' ')"
[ "${file_count}" -gt 0 ] || die "no *.sh files found under: ${TARGETS[*]} (a gate that checks nothing is not a gate)"

SC_ARGS=(-x)
if [ "${VERBOSE}" = "1" ]; then
    sc_ver="$(shellcheck --version | awk '/^version:/{print $2}')"
    log_step "shellcheck ${sc_ver:-?} over ${file_count} file(s): ${TARGETS[*]}"
    find "${TARGETS[@]}" -type f -name '*.sh' | sort | awk '{print "    " $0}'
    SC_ARGS=(-x -f tty)
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

status=0
# -print0 / xargs -0 so paths with spaces survive. xargs exits 123 when any of
# the analyzer invocations it spawns failed, and that is the status propagated.
find "${TARGETS[@]}" -type f -name '*.sh' -print0 \
    | xargs -0 shellcheck "${SC_ARGS[@]}" || status=$?

if [ "${status}" -eq 0 ]; then
    log_success "shellcheck: ${file_count} file(s) clean."
else
    log_error "shellcheck failed (exit ${status}). Fix the findings above; do not add a file to .shellcheckrc to hide one."
fi
exit "${status}"
