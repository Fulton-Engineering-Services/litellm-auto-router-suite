#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/repo-verify.sh - Read-only assertions on the enforced state.
# Source file; do not execute directly.
#
# Public functions:
#   verify          re-read everything the script installs; PASS/FAIL each item
#   print_ui_todo   the three Settings toggles no API can reach
#
# verify() deliberately shares no code with the apply path: it re-reads the remote
# and compares against literals, so a bug in the code that writes cannot also
# explain away the check that reads. It exits through FAILURES, never by dying on
# the first mismatch -- a partial answer is more useful than the first answer.
#
# Reads the launcher's globals: ORG, NAME, REPO. Expects lib/common.sh,
# lib/github.sh, lib/repo-gate.sh (assert_that); calls ruleset_id and dco_app_id
# from lib/ruleset-definition.sh, which the launcher loads first.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_REPO_VERIFY_LOADED:-}" ]; then
    return 0
fi
_LARS_REPO_VERIFY_LOADED=1

# Source the foundational libs when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi
if [ "${_LOG_GITHUB_LOADED:-}" != "1" ]; then
    # shellcheck source=github.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/github.sh"
fi

# ---------------------------------------------------------------------------
# Step 6: --verify
# ---------------------------------------------------------------------------

verify() {
    log_header "Verifying enforced state"

    local actual
    for pair in "private:false" "allow_merge_commit:false" "allow_squash_merge:true" \
                "allow_rebase_merge:true" "delete_branch_on_merge:true" \
                "web_commit_signoff_required:true" "default_branch:main"; do
        local field="${pair%%:*}" want="${pair##*:}"
        actual="$(gh api "repos/${REPO}" -q ".${field}")"
        if [ "$actual" = "$want" ]; then
            assert_that true "$field" "$actual"
        else
            assert_that false "$field" "expected ${want}, got ${actual}"
        fi
    done

    # One lookup path, and every rule read from the single-ruleset GET. The list
    # view returns rules as null, so the previous filter crashed with
    # "Cannot iterate over: null" one line after reporting the ruleset present --
    # a green presence check next to a crashed content check is worse than a plain
    # failure, because it reads as protection that is not being asserted.
    local rs_id
    rs_id="$(ruleset_id)"
    if [ -z "$rs_id" ]; then
        assert_that false "ruleset present" "no ruleset named ${NAME} Branch Protection"
        return 1
    fi
    assert_that true "ruleset present" "${NAME} Branch Protection (id ${rs_id})"

    local contexts
    contexts="$(gh api "/orgs/${ORG}/rulesets/${rs_id}" \
        | jq -r '[.rules[] | select(.type=="required_status_checks")
                  | .parameters.required_status_checks[].context] | sort | join(",")')"
    local expected
    expected="$(printf '%s\n' "Bazel" "DCO" "Docker (linux/amd64)" "Docker (linux/arm64)" \
        "Python (3.12)" "Python (3.13)" "Shell" "TypeScript" | sort | paste -sd, -)"
    if [ "$contexts" = "$expected" ]; then
        assert_that true "required status checks" "8 contexts"
    else
        assert_that false "required status checks" "expected ${expected}, got ${contexts:-<none>}"
    fi

    # Review policy and the strict-status flag are asserted, not assumed: a ruleset
    # that exists but approves on zero reviews, or tolerates a check that never
    # reports, is not the protection this script claims to install.
    local policy
    policy="$(gh api "/orgs/${ORG}/rulesets/${rs_id}" \
        | jq -r '[
            (.rules[] | select(.type=="pull_request")
              | [(.parameters.required_approving_review_count | tostring),
                 (.parameters.require_last_push_approval | tostring)] | join(":")),
            (.rules[] | select(.type=="required_status_checks")
              | (.parameters.strict_required_status_checks_policy | tostring))
          ] | join(" ")')"
    if [ "$policy" = "1:true true" ]; then
        assert_that true "review policy" "1 approval, last-push approval, strict status checks"
    else
        assert_that false "review policy" "expected 1:true true, got ${policy:-<none>}"
    fi

    local dco_id
    dco_id="$(dco_app_id)"
    assert_that true "DCO app id" "$dco_id"

    local sha checks
    sha="$(git rev-parse HEAD)"
    checks="$(gh api "repos/${REPO}/commits/${sha}/check-runs" \
        -q '.check_runs[].name' 2>/dev/null | sort | paste -sd, - || true)"
    if [ -n "$checks" ]; then
        log_info "check runs on ${sha:0:7}: ${checks}"
        log_info "(checks appear once the first Actions run completes)"
    else
        log_warn "no check runs yet on ${sha:0:7} — wait for the first Actions run, then re-run --verify"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Step 7: operator UI to-do (no API for these)
# ---------------------------------------------------------------------------

print_ui_todo() {
    log_header "Operator UI to-do (no API exists for these)"
    printf '%s\n' \
        "  1. Settings -> General -> Issues -> Auto-close issues with merged linked pull requests" \
        "       https://github.com/${REPO}/settings" \
        "  2. Settings -> General -> Commits -> Allow comments on individual commits (default ON; verify it stayed on)" \
        "       https://github.com/${REPO}/settings" \
        "  3. Settings -> General -> Features -> Preserve this repository (GitHub Archive Program opt-in)" \
        "       https://github.com/${REPO}/settings" \
        ""
}
