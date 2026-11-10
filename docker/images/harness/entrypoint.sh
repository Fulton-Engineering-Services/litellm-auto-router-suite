#!/bin/sh
# harness entrypoint — prints the pinned toolchain versions, or execs the
# given command. Runs under tini as PID 1's child, as the unprivileged
# appuser; covered by scripts/lint-shell.sh (which globs docker/).
set -eu

command_name="${1:-info}"

case "$command_name" in
  info)
    echo "node $(node --version)"
    echo "python $(python3 --version)"
    echo "pnpm $(pnpm --version)"
    echo "uv $(uv --version | sed 's/^uv //')"
    ;;
  *)
    exec "$@"
    ;;
esac
