#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/repo-gate.sh - Guarded mutations, operator confirmation, assertions.
# Source file; do not execute directly.
#
# Public functions:
#   cleanup                       EXIT trap: remove $WORKDIR (KEEP_WORKDIR=1 keeps it)
#   json_escape <string>          JSON string literal, quoted and escaped
#   assert_that <ok> <label> <detail>
#                                 record one --verify assertion outcome
#   write_api <METHOD> <PATH> [BODY_FILE]
#                                 the only mutating gh api call in this script
#   confirm <what>                --yes / TTY gate in front of every mutation
#
# Every write the provisioning path makes goes through write_api, and every write
# stands behind confirm. That is deliberate rather than ceremonial: --dry-run is
# only worth reading if there is exactly one door to the remote, and an operator
# reviewing a plan needs to be able to trust that nothing else touched it.
#
# Reads the launcher's globals: DRY_RUN, ASSUME_YES, WORKDIR, FAILURES.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_REPO_GATE_LOADED:-}" ]; then
    return 0
fi
_LARS_REPO_GATE_LOADED=1

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

# ---------------------------------------------------------------------------
# EXIT cleanup
# ---------------------------------------------------------------------------

cleanup() {
    # The last command of an EXIT trap becomes the script's exit status, so this
    # has to end in success. WORKDIR is only assigned on the provisioning path, so
    # under --verify the bare && chain that used to be here evaluated to false, and
    # a fully green verify -- every assertion PASS -- exited 1, indistinguishable
    # from a real failure.
    #
    # KEEP_WORKDIR=1 leaves the generated documents on disk (create.json,
    # patch.json, ruleset.json, and the ruleset-live.json the containment predicate
    # fetches) and prints where they are. Deleting them unconditionally made "why
    # did the ruleset step decide to write?" unanswerable after the fact, so the
    # only way to find out was to re-run the whole script.
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        if [ -n "${KEEP_WORKDIR:-}" ]; then
            log_info "KEEP_WORKDIR set: generated files left in ${WORKDIR}"
        else
            rm -rf "$WORKDIR"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# JSON and assertions
# ---------------------------------------------------------------------------

# json_escape STRING -> JSON string literal (quoted, escaped)
json_escape() {
    jq -n --arg v "$1" '$v'
}

# assert_that PASS|FAIL LABEL MESSAGE — record an assertion outcome.
assert_that() {
    local ok="$1" label="$2" detail="$3"
    if [ "$ok" = true ]; then
        log_success "PASS  ${label}${detail:+ — }${detail}"
    else
        log_error "FAIL  ${label}${detail:+ — }${detail}"
        FAILURES=$((FAILURES + 1))
    fi
}

# ---------------------------------------------------------------------------
# The write path
# ---------------------------------------------------------------------------

# write_api METHOD PATH BODY_FILE — guarded mutation. Body may be empty ("").
write_api() {
    local method="$1" path="$2" body="${3:-}"
    if [ "$DRY_RUN" = true ]; then
        log_step "[dry-run] gh api -X ${method} ${path}"
        if [ -n "$body" ] && [ -f "$body" ]; then
            printf '%s\n' "----- body -----"
            cat "$body"
            printf '%s\n' "----------------"
        fi
        return 0
    fi
    # Response JSON is swallowed here, not at the call sites. Three callers used to
    # carry their own >/dev/null, which threw away the dry-run plan above as well:
    # the create call and both ruleset mutations printed nothing, so an operator
    # reviewing --dry-run could not see the calls that matter most.
    if [ -n "$body" ] && [ -f "$body" ]; then
        gh_api "$method" "$path" --input "$body" >/dev/null
    else
        gh_api "$method" "$path" >/dev/null
    fi
}

# confirm ACTION — gate a mutation behind --yes or a TTY yes.
confirm() {
    local what="$1"
    [ "$DRY_RUN" = true ] && return 0
    [ "$ASSUME_YES" = true ] && return 0
    if [ -t 0 ]; then
        printf 'Proceed: %s [y/N] ' "$what"
        local reply=""
        read -r reply
        case "$reply" in
            [yY]|[yY][eE][sS]) return 0 ;;
            *) log_info "aborted by operator"; exit 1 ;;
        esac
    fi
    log_error "refusing to mutate without --yes (no TTY for confirmation)"
    exit 1
}
