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
#   normalize_ruleset DOC REF     projection of DOC, judged against REF
#   ruleset_matches ID WANT_FILE  0 when the live ruleset already says WANT_FILE
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

# normalize_ruleset DOC REFERENCE — projection of DOC, judged against REFERENCE.
#
# Both sides of ruleset_matches call this: the live document against the body, and
# the body against itself. Passing every input as an argument rather than one as
# stdin and one as a slurpfile is deliberate -- jq would then be handed the same
# path twice with no way for a reader (or shellcheck) to tell which one it might
# write.
#
# A whole-document comparison can never report equality, which is the bug this
# function exists to kill. GET /orgs/{org}/rulesets/{id} returns 2137 bytes for a
# definition this script sends as 1934, and the whole difference is three keys
# GitHub fills in for itself inside the pull_request rule:
#   allowed_merge_methods: ["merge","squash","rebase"]
#   require_extra_approval_for_unattributed_changes: true
#   required_reviewers: []
# Compare documents as they arrive and an already-correct ruleset still reads as
# drift -- the apply step logged "updating it in place" on a ruleset that was
# already exactly right, and issued a PUT to prove it.
#
# So the projection is derived FROM THE BODY WE INTEND TO SEND rather than from a
# list of server fields to excuse. The body is the single source of truth for which
# keys are significant, and a future server-injected default cannot resurrect the
# bug because nothing here names server fields at all.
normalize_ruleset() {
    local doc="$1" reference="$2"
    jq -S --slurpfile doc "$doc" --slurpfile want "$reference" '
        # Keep only the parameters this rule type is defined to set. A key the body
        # does not mention is GitHub-owned, so its value is not evidence of drift.
        def keep_params($w):
            .parameters as $live
            | .parameters = ($w.parameters // {}
                | with_entries(.value = ($live[.key] // null)));
        # Rules are walked in body order and matched by type, so a rule the server
        # dropped makes this array shorter than the body -- drift -- instead of
        # vanishing the way a select-both-sides filter would hide it.
        $doc[0]
        | { name,
            target,
            enforcement,
            conditions: (.conditions | {ref_name, repository_name}),
            bypass_actors: (.bypass_actors // []),
            rules: [ $want[0].rules[] as $w
                     | (.rules[] | select(.type == $w.type)
                        | keep_params($w)
                        | {type, parameters}) ] }
    '
}

# ruleset_matches ID BODY — is the live ruleset already exactly what BODY says?
#
# This is what makes the ruleset step cheap and quiet on a re-run: without it the
# script writes on every invocation. Both sides are reduced through
# normalize_ruleset first, and both are left in $WORKDIR so KEEP_WORKDIR=1 can
# answer "why did this decide to write?" after the fact.
ruleset_matches() {
    local id="$1" body="$2"
    local raw="$WORKDIR/ruleset-get.json" live="$WORKDIR/ruleset-live.json" want="$WORKDIR/ruleset-want.json"
    gh api "/orgs/${ORG}/rulesets/${id}" > "$raw" || return 1
    normalize_ruleset "$raw" "$body" > "$live" || return 1
    normalize_ruleset "$body" "$body" > "$want" || return 1
    cmp -s "$live" "$want"
}
