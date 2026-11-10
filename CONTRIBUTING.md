# Contributing to litellm-auto-router-suite

`litellm-auto-router-suite` is open source under the Apache License 2.0.
Contributions are welcome — bug reports, fixes, and new features alike.

By submitting a pull request you agree that your contribution is made under
the same Apache 2.0 license as the project (inbound = outbound).

---

## Development environment

macOS (Homebrew) or any machine where you can install `git`, `jq`, `shellcheck`,
`bazelisk`, `pyenv`, `uv`, `node`, and `pnpm`. One command sets all of it up:

```bash
git clone git@github.com:Fulton-Engineering-Services/litellm-auto-router-suite.git
cd litellm-auto-router-suite

scripts/setup-project-toolchain.sh      # installs what is missing, then syncs deps
scripts/configure-git.sh                # repo-local git config + commit hooks
scripts/setup-remote-repository.sh      # only when creating the GitHub repo
```

`scripts/setup-project-toolchain.sh --check` reports what is present without
installing anything and exits non-zero when something is missing.

---

## Running the checks

Every command below is a merge gate. Run them all locally, or run them all at
once with `bazel run //:check`.

### TypeScript (`typescript/`)

```bash
pnpm --dir typescript run typecheck      # tsc -b tsconfig.host.json
pnpm --dir typescript run lint           # typecheck + oxlint
pnpm --dir typescript run lint:tsdoc     # eslint TSDoc contract on src/
pnpm --dir typescript run test           # vitest
pnpm --dir typescript run build          # tsc -b tsconfig.build.json
```

### Python (`python/`)

```bash
uv run --directory python ruff check .
uv run --directory python mypy packages
uv run --directory python pytest
```

### Shell

```bash
scripts/lint-shell.sh            # shellcheck over scripts/ and docker/
scripts/check-hygiene.sh         # merge-conflict markers, trailing whitespace
```

### Containers

```bash
docker buildx bake -f docker/docker-bake.hcl --set harness.platform=linux/amd64 harness
```

### Bazel

```bash
bazel build //...                # every declared target
bazel run //:check               # the full gate sequence, in CI order
```

---

## Git hooks

`scripts/configure-git.sh` installs lefthook plus the DCO hooks. Run
`pnpm --dir typescript exec lefthook install` (the setup script does this for
you) to (re)install them after a fresh clone.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by:` trailer. It is added for you by the
`prepare-commit-msg` hook installed by `scripts/configure-git.sh` — **never type
it by hand**, because the companion `commit-msg` hook rejects a sign-off line
whose e-mail lacks the `<…>` angle brackets, and a hand-typed line is the usual
way to hit that. GitHub also enforces the DCO app as a required status check, so
an unsigned commit cannot merge regardless.

---

## Project layout

```
docker/       docker-bake.hcl + per-image build contexts
python/       uv workspace: LiteLLM plugins, headroom service clients
scripts/      first-class operators' surface (bash 3.2 / BSD coreutils clean)
typescript/   pnpm workspace: routers and control planes
```

`scripts/lib/` holds the shell helpers the drivers source; `scripts/bazel/`
holds the thin wrappers Bazel delegates to.

---

## Commits and pull requests

Use conventional commit titles (`feat:`, `fix:`, `docs:`, `chore:`). PRs require
one approving review, a fresh approval after the last push, and every required
status check green before merge. Only squash and rebase merges are enabled.
