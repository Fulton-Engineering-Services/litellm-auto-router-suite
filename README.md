# litellm-auto-router-suite

LiteLLM auto-router suite: the gateway, the headroom compression plane, the routers, and
their control planes. This repository is currently the build and governance shell — the
toolchains, gates, containers, and CI that everything else lands on top of.

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Directory map

| Path          | Concern                                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| `docker/`     | `docker-bake.hcl` plus per-image build contexts; two cache planes (GHA + GHCR)                                    |
| `python/`     | uv workspace: LiteLLM plugins and headroom service clients (ruff, mypy, pytest)                                   |
| `scripts/`    | Operators' surface. Bash 3.2 / BSD-coreutils clean; helpers in `scripts/lib/`, Bazel wrappers in `scripts/bazel/` |
| `typescript/` | pnpm workspace: routers and control planes (tsc, oxlint, eslint TSDoc, vitest)                                    |
| root          | License and community docs, Prettier config, lefthook, shellcheck config, Bazel workspace files                   |

## Prerequisites

macOS with [Homebrew](https://brew.sh), or any environment where you can install `git`,
`jq`, `shellcheck`, `bazelisk`, `pyenv`, `uv`, `node`, and `pnpm`. You do not need to
install any of them by hand — the setup script does, and asks before it installs anything.

## Quick start

```bash
scripts/setup-project-toolchain.sh    # bootstrap toolchain, then pnpm install + uv sync
scripts/configure-git.sh             # repo-local git config, lefthook, DCO hooks
scripts/setup-remote-repository.sh   # create + enforce the GitHub repo (maintainers only)
```

Use `scripts/setup-project-toolchain.sh --check` to see what is missing without changing
anything; it exits non-zero when something is absent, so it works as a CI probe.

## Gates

Every row is a required status check on `main`.

| Gate         | Command                                        |
| ------------ | ---------------------------------------------- |
| Type-check   | `pnpm --dir typescript run typecheck`          |
| Lint         | `pnpm --dir typescript run lint`               |
| TSDoc        | `pnpm --dir typescript run lint:tsdoc`         |
| Test         | `pnpm --dir typescript run test`               |
| Build        | `pnpm --dir typescript run build`              |
| Python lint  | `uv run --directory python ruff check .`       |
| Python types | `uv run --directory python mypy packages`      |
| Python test  | `uv run --directory python pytest`             |
| Shell        | `scripts/lint-shell.sh`                        |
| Containers   | `docker buildx bake -f docker/docker-bake.hcl` |

## Bazel

Bazel is the orchestrator, not a second implementation: its targets exec the real `pnpm`
and `uv` toolchains, so there is exactly one source of dependency truth.

```bash
bazel build //...              # every declared target
bazel run //:check             # the whole gate table, in CI order
bazel run //typescript:test    # vitest, via pnpm
bazel run //python:test        # pytest, via uv
```

## GitHub governance

`scripts/setup-remote-repository.sh` creates the repository and applies an org-level
ruleset. Enforced:

- PRs required, 1 approving review, re-approval after the last push, stale reviews dismissed
- only squash and rebase merges; merge commits disabled
- `main` protected against deletion, creation, and force-push
- 8 required status checks, with strict (must-be-up-to-date) policy: `TypeScript`,
  `Python (3.12)`, `Python (3.13)`, `Shell`, `Bazel`, `Docker (linux/amd64)`,
  `Docker (linux/arm64)`, `DCO`
- DCO sign-off required, both by the GitHub app and by a local `commit-msg` hook
- branch deleted on merge; auto-merge disabled

Three settings have no API and are left to the operator; the script prints the deep links
at the end:

- Settings → General → Issues → _Auto-close issues with merged linked pull requests_
- Settings → General → Commits → _Allow comments on individual commits_ (should stay on)
- Settings → General → Features → _Preserve this repository_

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities per [SECURITY.md](SECURITY.md).
