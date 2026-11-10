#!/bin/bash
# shellcheck shell=bash
# scripts/check-hygiene.sh - Reject staged files carrying conflict markers or trailing whitespace
#
# Usage:
#   scripts/check-hygiene.sh [path ...]
#
# Options:
#   --verbose     Also list the files that passed
#   -h, --help    Show this help
#
# Arguments:
#   path          File(s) to scan. With no arguments the staged set is scanned
#                 (git diff --cached --name-only --diff-filter=ACM), which is how
#                 the lefthook pre-commit job invokes it.
#
# Checks:
#   1. Merge-conflict markers. "<<<<<<< " / ">>>>>>> " are fatal on their own; a
#      bare "=======" line counts only when an arrow marker is also present, so
#      a markdown setext underline is not mistaken for a conflict.
#   2. Trailing whitespace on any line.
#
# Binary files are skipped (grep -I). "no newline at end of file" and the
# whitespace policy git itself enforces stay with the lefthook
# "git diff --cached --check" job - this script adds what that job does not see.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"
[ -f "$LIB_DIR/common.sh" ] || { echo "FATAL: missing $LIB_DIR/common.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh disable=SC1091
. "$LIB_DIR/common.sh"

# ---------------------------------------------------------------------------
# Defaults (env-overridable)
# ---------------------------------------------------------------------------

VERBOSE="${CHECK_HYGIENE_VERBOSE:-0}"
FILES=()
POSITIONAL_SEEN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        --verbose) VERBOSE=1; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            printf 'Try: scripts/check-hygiene.sh --help\n' >&2
            exit 2 ;;
        *)
            POSITIONAL_SEEN=true
            FILES+=("$1")
            shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------

if [ "${#FILES[@]}" -eq 0 ]; then
    require_command git "Run this inside the repository checkout."
    staged="$(git diff --cached --name-only --diff-filter=ACM)" || true
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        FILES+=("${f}")
    done <<< "${staged}"
    if [ "${#FILES[@]}" -eq 0 ]; then
        log_success "hygiene: nothing staged."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

ARROW_RE='^(<{7}|>{7})( |$)'
SEP_RE='^={7}$'
WS_RE='[[:space:]]+$'

findings=0
checked=0
for f in "${FILES[@]}"; do
    if [ ! -f "${f}" ]; then
        log_warn "hygiene: skipping absent file: ${f}"
        continue
    fi
    checked=$((checked + 1))
    file_bad=0

    arrows="$(grep -nIE -- "${ARROW_RE}" "${f}" 2>/dev/null)" || true
    if [ -n "${arrows}" ]; then
        log_error "${f}: merge-conflict marker(s):"
        printf '%s\n' "${arrows}" | awk -v F="${f}" '{print "    " F ":" $0}'
        file_bad=1
        # The "=======" divider only matters inside a real conflict hunk.
        sep="$(grep -nIE -- "${SEP_RE}" "${f}" 2>/dev/null)" || true
        if [ -n "${sep}" ]; then
            printf '%s\n' "${sep}" | awk -v F="${f}" '{print "    " F ":" $0}'
        fi
    fi

    ws="$(grep -nIE -- "${WS_RE}" "${f}" 2>/dev/null)" || true
    if [ -n "${ws}" ]; then
        log_error "${f}: trailing whitespace:"
        printf '%s\n' "${ws}" | awk -v F="${f}" '{print "    " F ":" $0}'
        file_bad=1
    fi

    if [ "${file_bad}" -eq 1 ]; then
        findings=$((findings + 1))
    elif [ "${VERBOSE}" = "1" ]; then
        log_info "hygiene: clean - ${f}"
    fi
done

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

if [ "${findings}" -gt 0 ]; then
    log_error "hygiene: ${findings} file(s) failed (conflict markers or trailing whitespace)."
    printf '       Fix them, or stage again after running: pnpm --dir typescript run format\n' >&2
    exit 1
fi

log_success "hygiene: ${checked} file(s) clean."
