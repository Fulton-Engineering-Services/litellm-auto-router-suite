#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/repo-push.sh - Checkout preflight and publication of main.
# Source file; do not execute directly.
#
# Public functions:
#   preflight        refuse to publish from a checkout that should not publish
#   push_repo        point origin at the target and push main (and tags)
#   pick_transport   echo ssh|https, whichever this host can actually use
#
# preflight is the safety property of the whole script: it is what makes
# "run the setup script" a command an operator can type without first
# remembering what state the checkout is in.
#
# Reads the launcher's globals: ORG, NAME, REPO, DRY_RUN, REPO_ROOT, SSH_REMOTE,
# HTTPS_REMOTE. Expects lib/common.sh, lib/github.sh (github_ensure_gh) and
# lib/repo-gate.sh (confirm).
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_REPO_PUSH_LOADED:-}" ]; then
    return 0
fi
_LARS_REPO_PUSH_LOADED=1

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

    # Not [ -d .git ]: a linked worktree created by `git worktree add` keeps its
    # gitdir in a .git FILE, so the directory test rejected a perfectly good
    # checkout. Ask git instead of guessing from the path.
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
        || die "not a git worktree: $REPO_ROOT"

    local branch
    branch="$(git rev-parse --abbrev-ref HEAD)"
    # Publishing is a main-only operation, but --dry-run pushes nothing, so the
    # refusal bought nothing there while making the script unrunnable from the one
    # place this repo is actually worked: a `git worktree` on a feature branch,
    # before the PR exists. A real publish still refuses any other HEAD.
    if [ "$branch" != main ] && [ "$DRY_RUN" != true ]; then
        die "HEAD is on '${branch}', expected 'main'"
    fi
    [ "$branch" = main ] || log_warn "--dry-run on '${branch}': a real publish requires main"

    # Tracked content compared by bytes, not by git's cached stat info. The
    # pre-commit formatter rewrites files it touches, and a rewrite whose bytes are
    # identical can still leave `git status` reporting " M" until the stat cache is
    # refreshed -- which refused to publish a tree that was provably identical to
    # HEAD (git diff and git diff --cached both empty; the very next git status was
    # clean). What gets published is tracked content, so that is what is checked.
    if ! git diff --quiet HEAD --; then
        git status --short
        die "tracked files differ from HEAD — commit or stash before publishing"
    fi
    local untracked
    untracked="$(git ls-files --others --exclude-standard)"
    if [ -n "$untracked" ]; then
        log_warn "untracked file(s) present, never published: $(printf '%s' "$untracked" | paste -sd, -)"
    fi
    log_success "worktree matches HEAD on main ($(git rev-parse --short HEAD))"

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
