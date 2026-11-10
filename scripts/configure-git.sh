#!/bin/bash
# shellcheck shell=bash
# scripts/configure-git.sh - Configure git for a litellm-auto-router-suite checkout
#
# Usage:
#   scripts/configure-git.sh [options]
#
# Options:
#   -n, --name NAME       Set git user.name. Default: an existing global
#                         user.name; else the GitHub login from `gh api user`.
#   -e, --email EMAIL     Set git user.email. Default: an existing global
#                         user.email; else the GitHub noreply address
#                         <id>+<login>@users.noreply.github.com.
#   -m, --merge STRATEGY  Set git pull.rebase (default: true). Valid: true, false
#   --no-dco              Do not install the DCO sign-off hooks (default: install)
#   -v, --verbose         Show verbose output
#   -h, --help            Show this help
#
# Identity resolution order (this repo never hardcodes a person's identity):
#   1. -n / -e on the command line
#   2. an existing `git config --global user.name` / `user.email`
#   3. the authenticated gh account: gh api user -q .login and -q .id, giving
#      <id>+<login>@users.noreply.github.com (GitHub's noreply form, so merged
#      commits attribute to the account instead of leaking a private address)
#   4. an interactive prompt - only at a controlling terminal
#
# MERGE STRATEGIES:
#   true  - rebase local commits on top of upstream when pulling (recommended)
#   false - create a merge commit when pulling
#
# CREDENTIAL HELPER (macOS, selected by the origin remote host):
#   SSH remote (git@host: / ssh://)  "" (clears the helper chain; SSH keys auth)
#   github.com                       gh CLI (osxkeychain if gh is missing)
#   GitLab host                      glab CLI (osxkeychain if glab is missing)
#   other HTTPS hosts                osxkeychain fallback
#
# DCO HOOKS:
#   prepare-commit-msg  Adds the Signed-off-by trailer to every commit unless one
#                       is already present, using git config user.name/user.email.
#   commit-msg          Rejects a Signed-off-by trailer whose address is not in
#                       "Name <email>" form, which is how a hand-typed sign-off
#                       loses its angle brackets and fails the DCO bot.
#   DO NOT type "Signed-off-by:" by hand. The hook adds it. A repo where the
#   trailer is typed manually is a repo where someone will type it wrong.
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

# Identity deliberately has no baked-in default: see the resolution order above.
NAME="${GIT_CONFIGURE_NAME:-}"
EMAIL="${GIT_CONFIGURE_EMAIL:-}"
MERGE_STRATEGY="${GIT_CONFIGURE_MERGE:-true}"
INSTALL_DCO="${GIT_CONFIGURE_DCO:-true}"
VERBOSE="${GIT_CONFIGURE_VERBOSE:-0}"
POSITIONAL_SEEN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        -n|--name)
            [ $# -ge 2 ] || { log_error "$1 requires a value"; exit 1; }
            NAME="$2"; shift 2 ;;
        -e|--email)
            [ $# -ge 2 ] || { log_error "$1 requires a value"; exit 1; }
            EMAIL="$2"; shift 2 ;;
        -m|--merge)
            [ $# -ge 2 ] || { log_error "$1 requires a value"; exit 1; }
            MERGE_STRATEGY="$2"; shift 2 ;;
        --no-dco)       INSTALL_DCO="false"; shift ;;
        -v|--verbose)   VERBOSE=1;           shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Compatible with:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            log_error "unknown option: $1"
            printf 'Try: scripts/configure-git.sh --help\n' >&2
            exit 2 ;;
        *)
            [ "${POSITIONAL_SEEN}" = "false" ] || { log_error "unexpected argument: $1"; exit 2; }
            POSITIONAL_SEEN=true
            log_error "unexpected argument: $1 (this script takes no positional arguments)"
            exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The summary report keeps this script's original echo -e style; decisions and
# failures go through the shared logger in scripts/lib/common.sh.
note() {
    if [ "${VERBOSE}" = "1" ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

check_git_repo() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not in a git repository. Run this script from inside the cloned repository."
        exit 1
    fi
    note "Confirmed: running in a git repository ($(git rev-parse --show-toplevel 2>/dev/null))"
}

validate_merge_strategy() {
    local strategy="$1"
    case "${strategy}" in
        true|false) return 0 ;;
        *)
            log_error "Invalid merge strategy: ${strategy}"
            log_error "Valid options: true, false"
            exit 1
            ;;
    esac
}

# resolve_identity
#   Fills NAME and EMAIL using the documented order. Prompts only when there is
#   a controlling terminal; a non-interactive run with no identity fails with the
#   exact flags to pass instead of hanging on a read.
resolve_identity() {
    if [ -z "${NAME}" ]; then
        NAME="$(git config --global user.name 2>/dev/null)" || true
    fi
    if [ -z "${EMAIL}" ]; then
        EMAIL="$(git config --global user.email 2>/dev/null)" || true
    fi
    if [ -n "${NAME}" ] && [ -n "${EMAIL}" ]; then
        note "Identity taken from existing global git config."
        return 0
    fi

    if [ -z "${NAME}" ] || [ -z "${EMAIL}" ]; then
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            local login="" uid=""
            login="$(gh api user -q .login 2>/dev/null)" || true
            uid="$(gh api user -q .id 2>/dev/null)" || true
            if [ -n "${login}" ] && [ -n "${uid}" ]; then
                [ -n "${NAME}" ] || NAME="${login}"
                # GitHub's noreply form keeps attribution without publishing a
                # personal address in every commit.
                [ -n "${EMAIL}" ] || EMAIL="${uid}+${login}@users.noreply.github.com"
                note "Identity derived from the authenticated gh account (${login})."
            fi
        else
            note "gh is unavailable or unauthenticated; cannot derive a GitHub noreply identity."
        fi
    fi

    if [ -z "${NAME}" ] || [ -z "${EMAIL}" ]; then
        if [ ! -t 0 ]; then
            log_error "No git identity available and no controlling terminal to ask for one."
            printf '       Pass it explicitly: scripts/configure-git.sh -n "Full Name" -e "name@example.com"\n' >&2
            exit 1
        fi
        while [ -z "${NAME}" ]; do
            printf 'Git user.name (e.g. "Jane Doe"): ' >&2
            read -r NAME
        done
        while [ -z "${EMAIL}" ]; do
            printf 'Git user.email (name@example.com, or the GitHub noreply form): ' >&2
            read -r EMAIL
        done
    fi

    case "${EMAIL}" in
        *@*.*) return 0 ;;
        *)
            log_error "Refusing to set an unusable user.email: '${EMAIL}'"
            exit 1
            ;;
    esac
}

# configure_credential_helper
#   Host-aware credential.helper selection. Idempotent: every branch clears the
#   existing chain first, so re-running converges instead of stacking helpers.
configure_credential_helper() {
    case "$(uname -s)" in
        Darwin) ;;
        *)
            note "credential.helper selection is macOS-specific; leaving git's default on $(uname -s)."
            return 0
            ;;
    esac

    local remote_url="" transport="" remote_host=""
    remote_url="$(git config --get remote.origin.url 2>/dev/null)" || true

    case "${remote_url}" in
        git@*:*|ssh://*)  transport="ssh" ;;
        http://*|https://*) transport="https" ;;
        *)                transport="" ;;
    esac

    if [ "${transport}" = "ssh" ]; then
        # SSH keys authenticate; an empty helper value clears any inherited chain.
        git config --unset-all credential.helper 2>/dev/null || true
        git config --add credential.helper ""
        log_success "SSH remote - credential helper cleared"
        return 0
    fi

    if [ "${transport}" = "https" ]; then
        local host="${remote_url#*://}"
        host="${host#*@}"
        remote_host="${host%%/*}"
    fi

    git config --unset-all credential.helper 2>/dev/null || true

    case "${remote_host}" in
        *github.com*)
            if command -v gh >/dev/null 2>&1; then
                # Empty value first clears inherited helpers, then gh takes over.
                git config --add credential.helper ""
                git config --add credential.helper "$(command -v gh) auth git-credential"
                log_success "Set credential helper to gh (multi-account support)"
            else
                git config credential.helper osxkeychain
                log_warn "gh CLI not found, using osxkeychain (may have multi-account issues)"
            fi
            ;;
        *gitlab*)
            if command -v glab >/dev/null 2>&1; then
                git config --add credential.helper ""
                git config --add credential.helper "$(command -v glab) auth git-credential"
                log_success "Set credential helper to glab (GitLab remote)"
            else
                git config credential.helper osxkeychain
                log_warn "glab CLI not found, using osxkeychain (may have multi-account issues)"
            fi
            ;;
        "")
            git config credential.helper osxkeychain
            log_warn "Could not determine a remote host, using osxkeychain (may have multi-account issues)"
            ;;
        *)
            git config credential.helper osxkeychain
            log_warn "Unknown HTTPS host '${remote_host}', using osxkeychain (may have multi-account issues)"
            ;;
    esac
}

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

# install_dco_hook
#   Installs the two DCO hooks described in the header. Both are /bin/sh and are
#   written from scratch each run, so a drifted copy is always repaired.
install_dco_hook() {
    local hooks_dir=""
    hooks_dir="$(git rev-parse --git-path hooks)"
    mkdir -p "${hooks_dir}"

    # --- prepare-commit-msg: sign-off injection ---
    local prepare_hook="${hooks_dir}/prepare-commit-msg"
    cat > "${prepare_hook}" <<'HOOK_EOF'
#!/bin/sh
# Installed by scripts/configure-git.sh (litellm-auto-router-suite).
# Auto-adds a Signed-off-by trailer for DCO compliance.
# Idempotent: skips when a Signed-off-by trailer is already present.
COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="$2"

# Skip merge / squash sources; an amended message is already signed.
case "$COMMIT_SOURCE" in
  merge|squash) exit 0 ;;
esac

if grep -qiE '^Signed-off-by:' "$COMMIT_MSG_FILE"; then
  exit 0
fi

NAME="$(git config user.name)"
EMAIL="$(git config user.email)"
if [ -z "$NAME" ] || [ -z "$EMAIL" ]; then
  exit 0
fi

git interpret-trailers --in-place \
  --trailer "Signed-off-by: $NAME <$EMAIL>" \
  "$COMMIT_MSG_FILE"
HOOK_EOF
    chmod +x "${prepare_hook}"
    log_success "Installed DCO prepare-commit-msg hook at: ${prepare_hook}"

    # --- commit-msg: sign-off validation ---
    local msg_hook="${hooks_dir}/commit-msg"
    cat > "${msg_hook}" <<'HOOK_EOF'
#!/bin/sh
# Installed by scripts/configure-git.sh (litellm-auto-router-suite).
# Validates every Signed-off-by trailer uses the correct form:
#   Signed-off-by: Full Name <email@domain>
# Catches manually typed sign-offs that lost their angle brackets.
COMMIT_MSG_FILE="$1"

BAD=$(grep -iE '^Signed-off-by:' "$COMMIT_MSG_FILE" \
  | grep -vE '^Signed-off-by: .+ <[^>]+@[^>]+>$')

if [ -n "$BAD" ]; then
  echo "ERROR: Malformed Signed-off-by trailer (missing <email> angle brackets):" >&2
  echo "$BAD" >&2
  echo "" >&2
  echo "Expected format: Signed-off-by: Full Name <email@domain>" >&2
  echo "Tip: the prepare-commit-msg hook adds this trailer - never type it by hand." >&2
  exit 1
fi
HOOK_EOF
    chmod +x "${msg_hook}"
    log_success "Installed DCO commit-msg validation hook at: ${msg_hook}"
}

show_config() {
    echo
    echo -e "${BLUE}Current Git Configuration:${NC}"
    echo "  user.name:          $(git config user.name 2>/dev/null || printf '(unset)')"
    echo "  user.email:         $(git config user.email 2>/dev/null || printf '(unset)')"
    echo "  pull.rebase:        $(git config pull.rebase 2>/dev/null || printf '(unset)')"
    echo "  push.default:       $(git config push.default 2>/dev/null || printf '(unset)')"
    echo "  push.autoSetupRemote: $(git config push.autoSetupRemote 2>/dev/null || printf '(unset)')"
    echo "  color.ui:           $(git config color.ui 2>/dev/null || printf '(unset)')"
    echo "  remote.origin.tagopt: $(git config --get remote.origin.tagopt 2>/dev/null || printf '(unset)')"
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "  credential.helper:  $(git config --get-all credential.helper 2>/dev/null | tr '\n' ' ')"
    fi

    local hooks_dir=""
    hooks_dir="$(git rev-parse --git-path hooks)"
    if [ -x "${hooks_dir}/prepare-commit-msg" ]; then
        echo "  DCO inject hook:    installed (${hooks_dir}/prepare-commit-msg)"
    else
        echo "  DCO inject hook:    not installed"
    fi
    if [ -x "${hooks_dir}/commit-msg" ]; then
        echo "  DCO validate hook:  installed (${hooks_dir}/commit-msg)"
    else
        echo "  DCO validate hook:  not installed"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo -e "${GREEN}Git configuration - litellm-auto-router-suite${NC}"
    echo "==========================================================="

    check_git_repo
    validate_merge_strategy "${MERGE_STRATEGY}"
    resolve_identity

    echo
    echo "Configuration to apply:"
    echo "  Name:                ${NAME}"
    echo "  Email:               ${EMAIL}"
    echo "  Merge strategy:      ${MERGE_STRATEGY}"
    echo "  DCO sign-off hooks:  ${INSTALL_DCO}"
    echo

    configure_git "${NAME}" "${EMAIL}" "${MERGE_STRATEGY}"

    if [ "${INSTALL_DCO}" = "true" ]; then
        install_dco_hook
        echo -e "${YELLOW}DCO sign-off reminder:${NC} do not type 'Signed-off-by:' yourself."
        echo "The prepare-commit-msg hook adds it; the commit-msg hook rejects a"
        echo "hand-typed trailer that is missing the <email> angle brackets."
    else
        note "Skipped DCO sign-off hooks (--no-dco)"
    fi

    show_config
    echo -e "${GREEN}Git configured successfully.${NC}"
}

main "$@"
