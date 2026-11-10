#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/git-settings.sh - The git configuration this repo asks for.
# Source file; do not execute directly.
#
# Public functions:
#   configure_git <name> <email> <merge_strategy>
#                                 write the identity, pull, push and color
#                                 settings, then delegate helper selection
#
# Reads the launcher's globals: VERBOSE.
#
# MERGE STRATEGIES (the merge_strategy argument, i.e. git pull.rebase):
#   true  - rebase local commits on top of upstream when pulling (recommended)
#   false - create a merge commit when pulling
#
# Every setting here is global except remote.origin.tagopt, which is local on
# purpose -- see the comment at its call site.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_GIT_SETTINGS_LOADED:-}" ]; then
    return 0
fi
_LARS_GIT_SETTINGS_LOADED=1

# Source the foundational libs when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi
if [ "${_LARS_GIT_CREDENTIALS_LOADED:-}" != "1" ]; then
    # shellcheck source=git-credentials.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/git-credentials.sh"
fi

configure_git() {
    local name="$1"
    local email="$2"
    local merge_strategy="$3"

    log_step "Configuring git settings..."

    if git config user.name "${name}"; then
        log_success "Set user.name to: ${name}"
    else
        log_error "Failed to set user.name"
        exit 1
    fi

    if git config user.email "${email}"; then
        log_success "Set user.email to: ${email}"
    else
        log_error "Failed to set user.email"
        exit 1
    fi

    if git config pull.rebase "${merge_strategy}"; then
        log_success "Set pull.rebase to: ${merge_strategy}"
    else
        log_error "Failed to set pull.rebase"
        exit 1
    fi

    log_step "Setting additional git configurations..."

    # Default branch name for any repo created from here on.
    git config init.defaultBranch main 2>/dev/null || true
    note "Set init.defaultBranch to main"

    git config color.ui auto
    log_success "Enabled color output"

    git config push.default simple
    log_success "Set push.default to simple"

    # Create the upstream on first push instead of erroring out.
    git config push.autoSetupRemote true
    log_success "Set push.autoSetupRemote true"

    # Repo-local, unlike the neighbouring push.* settings which are deliberately
    # global. remote.origin.tagopt is keyed on the remote NAME, so a --global copy
    # would disable tag-update protection for every repository on the workstation
    # that happens to have an origin -- silently overwriting a local tag the first
    # time a fetch sees a remote tag of the same name. This repo re-points release
    # tags deliberately; no other repo is being opted in. Re-clones get it by
    # running this script, which is the operators' entry point anyway.
    #
    # Guarded on origin actually having a url, because git config CREATES the
    # [remote "origin"] section it writes into: a url-less stub is worse than no
    # section at all, since `git remote get-url origin` then succeeds and prints
    # the bare word "origin", which reads as a real remote to every downstream
    # probe (it made setup-remote-repository.sh refuse its own first run).
    if [ -n "$(git config --local --get remote.origin.url 2>/dev/null || printf '')" ]; then
        git config --local remote.origin.tagopt --force
        log_success "Set remote.origin.tagopt to --force (local)"
    else
        log_info "No origin url yet; skipping remote.origin.tagopt (re-run once the remote exists)"
    fi

    configure_credential_helper
}
