#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/repo-create.sh - Repository creation and settings reconciliation.
# Source file; do not execute directly.
#
# Public functions:
#   create_repo         create the org repository, or report it already exists
#   sync_repo_settings  PATCH whatever create could not set, or what drifted
#
# create and reconcile are separate because they have different failure modes.
# Create is all-or-nothing and its body has to omit fields the API rejects
# outright; reconcile is a per-field diff that must be able to notice a single
# drifted toggle and fix exactly that.
#
# Reads the launcher's globals: ORG, NAME, REPO, DESCRIPTION, HOMEPAGE, WORKDIR,
# DRY_RUN. Expects lib/common.sh, lib/github.sh (gh_api) and lib/repo-gate.sh
# (json_escape, confirm, write_api).
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_REPO_CREATE_LOADED:-}" ]; then
    return 0
fi
_LARS_REPO_CREATE_LOADED=1

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
# Step 2: create the repository
# ---------------------------------------------------------------------------

create_repo() {
    log_header "Repository"
    if gh api "repos/${REPO}" -q .full_name >/dev/null 2>&1; then
        log_success "repository already exists: ${REPO} (create skipped)"
        return 0
    fi

    local body="$WORKDIR/create.json"
    # Two fields the first draft carried were rejected by the API itself:
    #   homepage ""              -> not a valid URL
    #   merge_commit_title/message together with allow_merge_commit:false ->
    #     "Sorry, you need to allow the merge commit strategy in order to set the
    #      default merge commit message title and message. (no_merge_strategy)"
    # This repo deliberately disables merge commits (squash and rebase only), so
    # the merge-commit message defaults describe a strategy that cannot run and are
    # simply absent; the squash counterparts are kept because squash is enabled.
    # HOMEPAGE is dropped rather than sent blank or null.
    jq -n \
        --arg name "$NAME" \
        --arg description "$DESCRIPTION" \
        --arg homepage "$HOMEPAGE" \
        '{
            name: $name,
            description: $description,
            private: false,
            has_issues: true,
            has_projects: false,
            has_wiki: false,
            has_discussions: false,
            auto_init: false,
            allow_merge_commit: false,
            allow_squash_merge: true,
            allow_rebase_merge: true,
            allow_auto_merge: false,
            allow_update_branch: true,
            delete_branch_on_merge: true,
            squash_merge_commit_title: "PR_TITLE",
            squash_merge_commit_message: "COMMIT_MESSAGES"
        }
        | if $homepage == "" then del(.homepage) else . end' > "$body"

    confirm "create public org repository ${REPO}"
    write_api POST "/orgs/${ORG}/repos" "$body"
    [ "$DRY_RUN" = true ] && return 0

    gh api "repos/${REPO}" -q .full_name >/dev/null 2>&1 \
        || die "create returned but the repository is not readable"
    log_success "created ${REPO}"
}

# sync_repo_settings — PATCH anything create could not set or that drifted.
# web_commit_signoff_required has no GraphQL UpdateRepositoryInput field, so it
# is set here over REST and never through graphql.
sync_repo_settings() {
    log_header "Repository settings"
    [ "$DRY_RUN" = true ] && { log_step "[dry-run] would reconcile repo settings via PATCH /repos/${REPO}"; return 0; }

    local want current patch_needed body
    body="$WORKDIR/patch.json"

    # field:desired pairs. `true`/`false` stay unquoted via jq's boolean literals.
    # No merge_commit_title/merge_commit_message: the API refuses them while
    # allow_merge_commit is false (see create_repo), so reconciling them here would
    # fail the same way. No homepage either -- an empty one is rejected as an
    # invalid URL, so it is only ever added when the operator supplied one.
    want='{"has_issues":true,"has_projects":false,"has_wiki":false,"has_discussions":false,"allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":true,"allow_auto_merge":false,"allow_update_branch":true,"delete_branch_on_merge":true,"web_commit_signoff_required":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES","description":'"$(json_escape "$DESCRIPTION")"'}'
    if [ -n "$HOMEPAGE" ]; then
        want="$(jq -c --arg h "$HOMEPAGE" '. + {homepage: $h}' <<<"$want")"
    fi

    current="$(gh api "repos/${REPO}" | jq -c '.')"
    patch_needed="$(jq -n --argjson want "$want" --argjson have "$current" '
        $want
        | with_entries(select(.value != $have[.key]))
    ')"

    if [ "$(jq -r 'length' <<<"$patch_needed")" = "0" ]; then
        log_success "repository settings already match"
        return 0
    fi

    jq -n --argjson patch "$patch_needed" '$patch' > "$body"
    log_step "reconciling $(jq -r 'keys | join(", ")' <<<"$patch_needed")"
    gh_api PATCH "/repos/${REPO}" --input "$body" >/dev/null
    log_success "repository settings applied"
}
