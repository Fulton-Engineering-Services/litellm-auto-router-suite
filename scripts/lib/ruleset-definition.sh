#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/ruleset-definition.sh - The ruleset this repo is supposed to have.
# Source file; do not execute directly.
#
# Public functions:
#   dco_app_id                    DCO GitHub App id from the org installation
#   ruleset_body OUT_FILE DCO_ID  write the desired ruleset document
#   ruleset_id                    id of this repo's org ruleset, or empty string
#   ruleset_matches ID BODY       0 when the stored ruleset already satisfies BODY
#
# This module is the desired state; ruleset-apply.sh is the reconciliation. The
# split is what lets a reviewer read the protection policy without also reading
# the PUT/create branching, and it is what lets verify() and apply() agree on one
# definition instead of each holding its own copy.
#
# Reads the launcher's globals: ORG, NAME, WORKDIR, ACTIONS_INTEGRATION_ID.
# Expects lib/common.sh, lib/github.sh (gh_api) and lib/repo-gate.sh.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_RULESET_DEF_LOADED:-}" ]; then
    return 0
fi
_LARS_RULESET_DEF_LOADED=1

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
# Required-check identities
# ---------------------------------------------------------------------------

dco_app_id() {
    local id
    id="$(gh api "/orgs/${ORG}/installations" \
        -q '.installations[] | select(.app_slug=="dco") | .app_id' 2>/dev/null | head -1)"
    [ -n "$id" ] || die "the DCO GitHub App is not installed on ${ORG}; install it before applying a required DCO check"
    printf '%s' "$id"
}

ruleset_body() {
    local out="$1" dco_id="$2"
    jq -n \
        --arg name "${NAME} Branch Protection" \
        --arg repo "$NAME" \
        --argjson dco "$dco_id" \
        --argjson actions "$ACTIONS_INTEGRATION_ID" \
        '{
            name: $name,
            target: "branch",
            source_type: "Organization",
            enforcement: "active",
            conditions: {
                ref_name: { include: ["refs/heads/main"], exclude: [] },
                repository_name: { include: [$repo], exclude: [] }
            },
            rules: [
                { type: "deletion" },
                { type: "creation" },
                { type: "non_fast_forward" },
                # Only the five parameters the org ruleset API accepts. An earlier
                # draft also carried require_review_on_push, automatic_access_check
                # and do_not_enforce_on_create here; the POST answered
                # "Invalid rule pull_request: Unexpected parameter ..." for each --
                # those three belong to branch protection, not to rulesets.
                # do_not_enforce_on_create stays legal under required_status_checks
                # below, which is why only this block loses it.
                { type: "pull_request", parameters: {
                    required_approving_review_count: 1,
                    require_last_push_approval: true,
                    dismiss_stale_reviews_on_push: true,
                    require_code_owner_review: false,
                    required_review_thread_resolution: false } },
                { type: "required_status_checks", parameters: {
                    strict_required_status_checks_policy: true,
                    do_not_enforce_on_create: false,
                    required_status_checks: [
                        { context: "TypeScript",           integration_id: $actions },
                        { context: "Python (3.12)",        integration_id: $actions },
                        { context: "Python (3.13)",        integration_id: $actions },
                        { context: "Shell",                integration_id: $actions },
                        { context: "Bazel",                integration_id: $actions },
                        { context: "Docker (linux/amd64)", integration_id: $actions },
                        { context: "Docker (linux/arm64)", integration_id: $actions },
                        { context: "DCO",                  integration_id: $dco } ] } }
            ],
            # "OrganizationAdminTeam" is not a ruleset actor type -- the API answered
            # "OrganizationAdminTeam is not a valid actor type (Validation Failed)".
            # Rulesets accept RepositoryRole / Team / Integration / DeployKey; the
            # org itself (Main Branch Protection, id 12798225) bypasses as
            # {actor_type: "RepositoryRole", actor_id: 5, bypass_mode: "always"},
            # which is the Admin role, so this repo follows the same convention and
            # an operator can still hotfix instead of being locked out by their own
            # required checks.
            # No apostrophes in these comments: they live inside a single-quoted jq
            # program, where one closes the shell string.
            bypass_actors: [
                { actor_type: "RepositoryRole", actor_id: 5, bypass_mode: "always" } ]
        }' > "$out"
}

# ruleset_id — id of this repository's org ruleset, or the empty string.
#
# GET /orgs/{org}/rulesets is a SUMMARY view: name, id, enforcement and target are
# populated but conditions and rules both come back null. Anything that needs
# rules or conditions must GET the single ruleset by id -- which is why every
# caller here resolves an id first and then GETs it.
ruleset_id() {
    gh api "/orgs/${ORG}/rulesets" \
        | jq -r --arg n "${NAME} Branch Protection" '[.[] | select(.name==$n)] | (.[0].id // "")'
}

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

# ruleset_matches ID BODY — does the stored ruleset already satisfy BODY?
#
# Equality cannot answer this, and the first version of this check assumed it
# could: GitHub stores defaults the generated body never mentions
# (allowed_merge_methods, required_reviewers,
# require_extra_approval_for_unattributed_changes ...), so a live ruleset is never
# byte-equal to the document that produced it. Comparing normalized copies of both
# therefore never matched, and the step wrote on every single run.
#
# Containment is the honest relation. Project the live document down to exactly the
# keys BODY declares, then compare: everything this script asserts must be present
# and equal, and whatever the server added on its own is not drift. Arrays match
# positionally and must have equal length, so a rules list the server reordered
# costs one redundant PUT -- the safe direction, because a false "already matches"
# would be the dangerous failure.
#
# Harness-verified against the live ruleset on seven cases: a server-default-only
# difference matches, while a changed review count, a dropped required context, a
# changed enforcement mode, dropped bypass actors, a live document missing a
# declared value, and an extra live rule each force a write.
#
# The fetched document stays at $WORKDIR/ruleset-live.json, so KEEP_WORKDIR=1
# leaves behind exactly what the predicate saw.
ruleset_matches() {
    local id="$1" body="$2" raw="$WORKDIR/ruleset-live.json" rc=0
    gh api "/orgs/${ORG}/rulesets/${id}" > "$raw" || return 1
    jq -e --slurpfile spec "$body" '
        def project:
            {name, target, enforcement, conditions, rules,
             bypass_actors: (.bypass_actors // [])};
        def restrict($s):
            if ($s | type) == "object" and (type == "object") then
                # . inside reduce is the accumulator, not the document being read,
                # so the input has to be bound before it can be indexed.
                . as $in
                | reduce ($s | keys_unsorted[]) as $k
                      ({}; .[$k] = ($in | getpath([$k]) | restrict($s[$k])))
            elif ($s | type) == "array" and (type == "array") then
                if length != ($s | length) then
                    [{"omp-length-mismatch": true}]
                else
                    [range(0; length) as $i | .[$i] | restrict($s[$i])]
                end
            else
                .
            end;
        ($spec[0] | project) as $want
        | (restrict($want) == $want)
    ' "$raw" > /dev/null || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        # A broken predicate must not quietly degrade into "always write", which is
        # precisely how the equality bug above hid for so long.
        *) die "could not compare ruleset ${id} against the desired definition (jq exit ${rc}); refusing to guess whether a write is needed" ;;
    esac
}
