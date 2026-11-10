#!/bin/bash
# shellcheck shell=bash
# setup-remote-repository.sh — create and enforce the GitHub repository for this project.
#
# Usage:
#   scripts/setup-remote-repository.sh [--org ORG] [--name NAME] [--description TEXT]
#                                      [--dry-run] [--yes] [--verify] [--verbose]
#
# Options:
#   --org           Organization that owns the repo (default: Fulton-Engineering-Services)
#   --name          Repository name (default: litellm-auto-router-suite)
#   --description   Repo description sent on create
#   --dry-run       Print every gh api call and JSON body it WOULD make; mutate nothing
#   --yes           Skip the interactive confirmation before mutating
#                   (never authorizes software installs — see scripts/lib/homebrew.sh)
#   --verify        Re-read the enforced reality and print PASS/FAIL per assertion
#   --verbose       Extra progress detail
#   -h, --help      This help
#
# Idempotent: every mutation is preceded by a GET and is a no-op when the remote
# state already matches, so re-running after a partial failure is safe.
#
# Preflight refuses to run on a dirty worktree, off `main`, or against an `origin`
# that points somewhere other than the target.
#
# Requirements:
#   - gh (authenticated, with admin:org on the target org for the ruleset step)
#   - git, jq
#   - The DCO GitHub App installed on the org with repository_selection "all"
#
# Three Settings→General toggles have no REST or GraphQL field and are therefore
# printed as deep links at the end rather than attempted through gh.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"
[ -f "$LIB_DIR/common.sh" ] || { echo "FATAL: missing $LIB_DIR/common.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh disable=SC1091
. "$LIB_DIR/common.sh"
[ -f "$LIB_DIR/github.sh" ] || { echo "FATAL: missing $LIB_DIR/github.sh" >&2; exit 1; }
# shellcheck source=lib/github.sh disable=SC1091
. "$LIB_DIR/github.sh"

# ---------------------------------------------------------------------------
# Defaults (env-overridable)
# ---------------------------------------------------------------------------

ORG="${ORG:-Fulton-Engineering-Services}"
NAME="${NAME:-litellm-auto-router-suite}"
DESCRIPTION="${DESCRIPTION:-LiteLLM auto-router suite: gateway, headroom compression plane, routers, and control planes.}"
HOMEPAGE="${HOMEPAGE:-}"
DRY_RUN=false
ASSUME_YES=false
VERIFY_ONLY=false
VERBOSE=false
POSITIONAL_SEEN=false
# GitHub Actions' integration id; stable across every org ruleset in this org.
ACTIONS_INTEGRATION_ID=15368
WORKDIR=""
FAILURES=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        --org)
            [ $# -ge 2 ] || { log_error "--org requires a value"; exit 1; }
            ORG="$2"; shift 2 ;;
        --name)
            [ $# -ge 2 ] || { log_error "--name requires a value"; exit 1; }
            NAME="$2"; shift 2 ;;
        --description)
            [ $# -ge 2 ] || { log_error "--description requires a value"; exit 1; }
            DESCRIPTION="$2"; shift 2 ;;
        --homepage)
            [ $# -ge 2 ] || { log_error "--homepage requires a value"; exit 1; }
            HOMEPAGE="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --yes)
            ASSUME_YES=true; shift ;;
        --verify)
            VERIFY_ONLY=true; shift ;;
        --verbose)
            VERBOSE=true; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            exit 2 ;;
        *)
            [ "$POSITIONAL_SEEN" = false ] || { log_error "unexpected argument: $1"; exit 2; }
            POSITIONAL_SEEN=true
            log_warn "ignoring unexpected argument: $1"
            shift ;;
    esac
done

REPO="$ORG/$NAME"
SSH_REMOTE="git@github.com:${ORG}/${NAME}.git"
HTTPS_REMOTE="https://github.com/${ORG}/${NAME}.git"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

cleanup() {
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# json_escape STRING -> JSON string literal (quoted, escaped)
json_escape() {
    jq -n --arg v "$1" '$v'
}

# assert PASS|FAIL LABEL MESSAGE — record an assertion outcome.
assert_that() {
    local ok="$1" label="$2" detail="$3"
    if [ "$ok" = true ]; then
        log_success "PASS  ${label}${detail:+ — }${detail}"
    else
        log_error "FAIL  ${label}${detail:+ — }${detail}"
        FAILURES=$((FAILURES + 1))
    fi
}

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    log_header "Preflight"
    cd "$REPO_ROOT"
    github_ensure_gh

    local who
    who="$(gh api user -q .login)" || die "gh is not authenticated — run: gh auth login"
    log_info "authenticated as ${who}"

    gh api "orgs/${ORG}" -q .login >/dev/null 2>&1 \
        || die "token cannot see org '${ORG}' — check 'gh auth status' scopes (needs read:org, and admin:org for the ruleset)"
    log_success "org reachable: ${ORG}"

    [ -d .git ] || die "not a git worktree: $REPO_ROOT"

    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = main ] || die "HEAD is on '${branch}', expected 'main'"

    if [ -n "$(git status --porcelain)" ]; then
        git status --short
        die "worktree is not clean — commit or stash before publishing"
    fi
    log_success "worktree clean on main ($(git rev-parse --short HEAD))"

    # The configured url is the only honest existence probe. `git remote get-url
    # origin` succeeds and prints the bare word "origin" for a [remote "origin"]
    # section that has no url -- which is exactly what `git config
    # remote.origin.tagopt --force` leaves behind in a clone whose remote has not
    # been created yet -- and this preflight would then refuse its own first run.
    local existing
    existing="$(git config --local --get remote.origin.url 2>/dev/null || true)"
    if [ -n "${existing}" ]; then
        case "$existing" in
            *":${ORG}/${NAME}.git"|*"${ORG}/${NAME}"*)
                log_info "origin already points at the target: ${existing}" ;;
            *)
                die "origin points at '${existing}', not ${REPO} — refusing to silently repoint it" ;;
        esac
    fi
}

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

# ---------------------------------------------------------------------------
# Step 3: push
# ---------------------------------------------------------------------------

push_repo() {
    log_header "Push"
    local url transport
    transport="$(pick_transport)"
    # Validated rather than trusted. The probe runs inside $(...), so anything it
    # logs lands in the variable: a contaminated value failed the equality test and
    # left url on the SSH remote while reporting https transport -- a push over a
    # transport this host has no key for, after the repo was already created.
    case "$transport" in
        ssh)   url="$SSH_REMOTE" ;;
        https) url="$HTTPS_REMOTE" ;;
        *)     die "transport probe returned '${transport}', expected ssh or https" ;;
    esac

    # Nothing below this point executes under --dry-run. `git remote add` and
    # `git remote set-url` are real mutations of this checkout: they used to sit
    # ahead of the dry-run bail-out, so a run that promised to report only left
    # origin pointing at the SSH URL behind it.
    if [ "$DRY_RUN" = true ]; then
        log_step "[dry-run] would point origin at ${url} (${transport} transport) and push main"
        return 0
    fi

    local existing
    existing="$(git config --local --get remote.origin.url 2>/dev/null || true)"
    if [ -n "${existing}" ]; then
        [ "${existing}" = "$url" ] || {
            log_step "repointing origin from ${existing} to ${url}"
            git remote set-url origin "$url"
        }
    elif git config --local --get-regexp '^remote\.origin\.' >/dev/null 2>&1; then
        # A url-less stub: the section exists (per-remote config written before the
        # remote did), so `git remote add` would fail with "remote origin already
        # exists" and set-url is the operation that actually fills it in.
        confirm "set the url of the existing url-less origin to ${url} and push main"
        log_step "origin exists without a url; setting it"
        git remote set-url origin "$url"
    else
        confirm "add origin ${url} and push main"
        git remote add origin "$url"
    fi
    log_info "remote origin: ${url} (${transport} transport)"

    git push -u origin main
    if [ -n "$(git tag --list)" ]; then
        git push --follow-tags
        log_success "pushed main and tags"
    else
        log_success "pushed main (no tags)"
    fi

    local actual
    actual="$(gh api "repos/${REPO}" -q .default_branch)"
    [ "$actual" = main ] || die "default branch is '${actual}', expected 'main'"
    log_success "default branch is main"
}

# pick_transport — echo ssh|https. GitHub over SSH is only usable when an SSH key
# is actually authorized; this host may authenticate gh over HTTPS only, in which
# case configure-git.sh's gh credential helper carries the HTTPS push.
pick_transport() {
    # Output is tested, not exit status. `ssh -T git@github.com` exits 1 even on
    # success -- GitHub prints the authenticated banner and then fails the shell --
    # so under `set -o pipefail` piping it into grep makes the pipeline status the
    # ssh exit and the ssh branch unreachable for everyone, valid key or not.
    local probe
    probe="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        -T git@github.com 2>&1 || true)"
    case "$probe" in
        *[Ss]uccessfully\ authenticated*)
            printf 'ssh' ;;
        *)
            # >&2 because stdout is the return channel of this function.
            log_warn "ssh to github.com is not authorized on this host; falling back to HTTPS + gh credential helper" >&2
            printf 'https' ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 4: org-level ruleset
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
                { type: "pull_request", parameters: {
                    required_approving_review_count: 1,
                    require_last_push_approval: true,
                    dismiss_stale_reviews_on_push: true,
                    require_code_owner_review: false,
                    require_review_on_push: false,
                    required_review_thread_resolution: false,
                    automatic_access_check: true,
                    do_not_enforce_on_create: false } },
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
            bypass_actors: [
                { actor_type: "OrganizationAdminTeam", actor_id: 1, bypass_mode: "always" } ]
        }' > "$out"
}

apply_ruleset() {
    log_header "Org ruleset"
    github_org_admin "$ORG"

    local dco_id
    dco_id="$(dco_app_id)"
    log_info "DCO app id resolved from the org installation: ${dco_id}"

    local body="$WORKDIR/ruleset.json"
    ruleset_body "$body" "$dco_id"

    local existing_id
    existing_id="$(gh api "/orgs/${ORG}/rulesets" \
        | jq -r --arg n "${NAME} Branch Protection" '.[] | select(.name==$n) | .id' 2>/dev/null | head -1)"

    if [ -n "$existing_id" ]; then
        log_step "ruleset exists (id ${existing_id}); PATCH replaces its definition"
        write_api PATCH "/orgs/${ORG}/rulesets/${existing_id}" "$body"
    else
        confirm "create org ruleset '${NAME} Branch Protection}'"
        write_api POST "/orgs/${ORG}/rulesets" "$body"
    fi
    [ "$DRY_RUN" = true ] && return 0

    # Both rulesets together are the enforced reality; print them so the operator
    # is not misled into thinking this one file is the whole picture.
    log_step "org rulesets now matching this repository"
    gh api "/orgs/${ORG}/rulesets" \
        | jq -r --arg r "$NAME" '.[] | select((.conditions.repository_name.include // []) | (. == ["~ALL"] or (index($r) != null))) | "  \(.name) (id \(.id), \(.enforcement))"'
    log_success "ruleset applied"
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

    actual="$(gh api "/repos/${REPO}/rulesets" \
        | jq -r --arg n "${NAME} Branch Protection" '[.[] | select(.name==$n)] | length')"
    if [ "$actual" = "1" ]; then
        assert_that true "ruleset present" "${NAME} Branch Protection"
    else
        assert_that false "ruleset present" "found ${actual} rulesets with that name"
    fi

    local contexts
    contexts="$(gh api "/repos/${REPO}/rulesets" \
        | jq -r --arg n "${NAME} Branch Protection" '
            [.[] | select(.name==$n) | .rules[]
             | select(.type=="required_status_checks")
             | .parameters.required_status_checks[].context] | sort | join(",")')"
    local expected
    expected="$(printf '%s\n' "Bazel" "DCO" "Docker (linux/amd64)" "Docker (linux/arm64)" \
        "Python (3.12)" "Python (3.13)" "Shell" "TypeScript" | sort | paste -sd, -)"
    if [ "$contexts" = "$expected" ]; then
        assert_that true "required status checks" "8 contexts"
    else
        assert_that false "required status checks" "expected ${expected}, got ${contexts:-<none>}"
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    require_command git
    require_command jq
    require_command gh

    if [ "$VERIFY_ONLY" = true ]; then
        github_ensure_gh
        verify
        [ "$FAILURES" -eq 0 ] || die "${FAILURES} assertion(s) failed"
        log_success "all assertions passed"
        return 0
    fi

    WORKDIR="$(mktemp -d)"
    preflight
    create_repo
    sync_repo_settings
    push_repo
    apply_ruleset
    assert_dco_coverage

    if [ "$DRY_RUN" = true ]; then
        log_warn "dry run: nothing was created or changed"
        return 0
    fi

    print_ui_todo
    log_success "${REPO} is provisioned"
}

main "$@"
