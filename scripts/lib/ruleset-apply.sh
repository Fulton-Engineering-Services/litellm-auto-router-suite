#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/ruleset-apply.sh - Reconcile the org ruleset and prove DCO coverage.
# Source file; do not execute directly.
#
# Public functions:
#   apply_ruleset         create/update the ruleset, then show what is in force
#   assert_dco_coverage   the DCO app installation must cover every repo
#
# apply_ruleset reads the desired state from ruleset-definition.sh and decides
# between three outcomes -- no write, one PUT, or one POST -- from that alone.
#
# Reads the launcher's globals: ORG, NAME, WORKDIR, DRY_RUN. Expects
# lib/common.sh, lib/github.sh (github_org_admin) and lib/repo-gate.sh (confirm,
# write_api); calls dco_app_id, ruleset_body, ruleset_id, ruleset_matches from
# lib/ruleset-definition.sh, which the launcher loads first.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_RULESET_APPLY_LOADED:-}" ]; then
    return 0
fi
_LARS_RULESET_APPLY_LOADED=1

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
# Step 4: org-level ruleset
# ---------------------------------------------------------------------------

apply_ruleset() {
    log_header "Org ruleset"
    github_org_admin "$ORG"

    local dco_id
    dco_id="$(dco_app_id)"
    log_info "DCO app id resolved from the org installation: ${dco_id}"

    local body="$WORKDIR/ruleset.json"
    ruleset_body "$body" "$dco_id"

    local existing_id
    existing_id="$(ruleset_id)"

    local action
    if [ -z "$existing_id" ]; then
        action="create"
    elif ruleset_matches "$existing_id" "$body"; then
        action="noop"
    else
        action="update"
    fi

    case "$action" in
        noop)
            log_success "ruleset '${NAME} Branch Protection}' (id ${existing_id}) already matches; no write"
            ;;
        update)
            # Update in place. PUT is the verb these endpoints honor: measured 200
            # on /orgs/{org}/rulesets/{id} with the full definition, the id was
            # preserved and the re-read came back byte-identical to the body sent.
            # PATCH 404s for these rulesets ({"message":"Not Found"} for the same
            # token that GETs and POSTs them fine), which is what pushed an earlier
            # revision of this step to delete-then-create -- the wrong cure. Between
            # those two calls the repository has no branch protection at all, and
            # since create has no conditional-write form, every idempotent re-run of
            # this script churned the ruleset id (26910111 -> 26911541 -> 26911762)
            # even when the definition had not changed.
            log_step "ruleset exists (id ${existing_id}); updating it in place"
            confirm "update org ruleset '${NAME} Branch Protection}'"
            if ! write_api PUT "/orgs/${ORG}/rulesets/${existing_id}" "$body"; then
                die "could not update ruleset ${existing_id} — ${NAME} is still running the previous definition. Re-run this script to retry. Unlike the old recreate path, a failure here cannot leave the repository unprotected."
            fi
            ;;
        create)
            confirm "create org ruleset '${NAME} Branch Protection}'"
            write_api POST "/orgs/${ORG}/rulesets" "$body"
            ;;
    esac
    [ "$DRY_RUN" = true ] && return 0

    # Both rulesets together are the enforced reality; print them so the operator
    # is not misled into thinking this one file is the whole picture. Each ruleset
    # is read back with its own GET: the list view returns conditions as null, so
    # filtering the list by scope silently matched nothing -- the first run of this
    # step printed zero rows and still reported success.
    log_step "org rulesets now enforcing this repository"
    local rs_id line matched=0
    while IFS= read -r rs_id; do
        [ -n "$rs_id" ] || continue
        line="$(gh api "/orgs/${ORG}/rulesets/${rs_id}" \
            | jq -r --arg r "$NAME" 'select((.conditions.repository_name.include // [])
                    | (. == ["~ALL"] or index($r) != null))
                    | "  \(.name) (id \(.id), \(.enforcement))"')"
        [ -n "$line" ] || continue
        printf '%s\n' "$line"
        matched=$((matched + 1))
    done < <(gh api "/orgs/${ORG}/rulesets" | jq -r '.[].id')
    if [ "$matched" -eq 0 ]; then
        log_warn "no org ruleset is scoped to ${NAME} or to ~ALL"
    fi
    log_success "ruleset applied (${matched} ruleset(s) in force)"
}

# ---------------------------------------------------------------------------
# Step 5: DCO coverage assertion
# ---------------------------------------------------------------------------

assert_dco_coverage() {
    log_header "DCO coverage"
    local sel id
    sel="$(gh api "/orgs/${ORG}/installations" \
        -q '.installations[] | select(.app_slug=="dco") | .repository_selection' 2>/dev/null | head -1)"
    id="$(gh api "/orgs/${ORG}/installations" \
        -q '.installations[] | select(.app_slug=="dco") | .id' 2>/dev/null | head -1)"
    [ "$sel" = all ] || die "DCO app installation ${id} has repository_selection='${sel}', not 'all' — new repos are not covered. Fix it in the console: https://github.com/organizations/${ORG}/settings/installations/${id}"
    log_success "DCO app installation ${id} covers all repositories"
}
