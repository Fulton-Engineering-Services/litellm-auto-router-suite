#!/bin/bash
# shellcheck shell=bash
#
# scripts/lib/git-dco-hooks.sh - The two DCO sign-off hooks this repo requires.
# Source file; do not execute directly.
#
# Public functions:
#   install_dco_hook                write and chmod both hooks under git-path hooks
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
# Both hooks are /bin/sh and are written from scratch on every run, so a drifted
# or hand-edited copy is always repaired rather than skipped -- the reason this
# lives in its own file is that the hook bodies are quoted heredocs, which is
# exactly the bash syntax most easily broken by an unrelated edit elsewhere.
#
# Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)

# Guard against double-sourcing
if [ -n "${_LARS_GIT_DCO_HOOKS_LOADED:-}" ]; then
    return 0
fi
_LARS_GIT_DCO_HOOKS_LOADED=1

# Source common.sh (log_*/die) when not already loaded.
if [ "${_LOG_COMMON_LOADED:-}" != "1" ]; then
    # shellcheck source=common.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"
fi

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
