# Repository Guidelines

## Project Overview

`litellm-auto-router-suite` is the LiteLLM auto-router suite: gateway, headroom
compression plane, routers, and their control planes. Today it is the **build
and governance shell** — toolchains, gates, containers, CI — with two seed
packages (one TypeScript, one Python) that carry only identity/version
primitives. Application code lands on top of this shell per the roadmap in
`.design/project-content.md`: eight Docker images (litellm gateway,
headroom-serve, headroom-lb, headroom-lb-tuner, headroom-compress, headroom-mcp,
valkey, postgresql), a `compose.example.yml`, and LiteLLM plugins / inference UI
/ headroom services ported from `fulton-infra-ecosystem`'s home-inference group.

Apache-2.0, org `Fulton-Engineering-Services`. Read [CONTRIBUTING.md](CONTRIBUTING.md)
before your first PR.

## Architecture & Data Flow

- **Bazel is the orchestrator, not a second implementation.** No `rules_js` /
  `rules_python`; `typescript/pnpm-lock.yaml` and `python/uv.lock` are the sole
  dependency truth. Every gate target is a `rules_shell` `sh_binary` (Bazel 9
  removed the native one) delegating to `scripts/bazel/run-pnpm.sh` /
  `run-uv.sh`, which exec the real pnpm/uv toolchains. `.bazelrc` sets
  `--spawn_strategy=local` so targets are never sandboxed away from the
  toolchain they invoke.
- All gate targets are `tags = ["manual"]`: `bazel test //...` matches nothing.
  CI runs `bazel build //...` then `bazel run //:check`.
- `bazel run //:check` (→ `scripts/bazel/check-all.sh`) **is the exact CI
  sequence**: `pnpm --dir typescript install --frozen-lockfile` → `uv sync
--directory python` → TS typecheck/lint/lint:tsdoc/test/build → Python ruff /
  mypy / pytest → `scripts/lint-shell.sh`. Run it before pushing.
- **TypeScript flow:** `packages/<pkg>/src/**/*.ts` → `tsc -b` (composite
  project references) emits `lib/`. `tsconfig.host.json` references both each
  package's src project and its `tsconfig.test.json`, so `pnpm run typecheck`
  typechecks tests; `tsconfig.build.json` references only src, so `build` never
  emits tests. Vitest runs TypeScript sources directly from
  `packages/*/tests/` (never compiled `lib/` / `lib-tests/`).
- **Python flow:** uv _virtual root_ workspace (root `pyproject.toml`
  deliberately has no `[project]` table); members under `python/packages/*` are
  src-layout hatchling distributions installed into `python/.venv` by
  `uv sync`. All ruff/mypy/pytest/coverage config lives only in the root
  `python/pyproject.toml` so every member shares one gate stack.
- **Container-as-gate:** `docker/images/harness/Dockerfile` runs the real gates
  at image build time (`pnpm run build`, `uv run --frozen mypy packages`,
  `uv run --frozen pytest -q`). Production images are deliberately not stubbed.
  `docker-release.yml` drives bake itself, so the bake file stays the source of
  truth: adding an image means editing `docker/docker-bake.hcl`, not the
  workflow.

## Key Directories

| Path                                 | Purpose                                                                                       |
| ------------------------------------ | --------------------------------------------------------------------------------------------- |
| `typescript/`                        | pnpm workspace: routers and control planes (tsc, oxlint, eslint TSDoc gate, vitest, prettier) |
| `typescript/packages/<name>/`        | one package: `src/index.ts` + `tests/<name>.test.ts`; no per-package `BUILD.bazel` needed     |
| `python/`                            | uv workspace: LiteLLM plugins and headroom service clients (ruff, mypy, pytest)               |
| `python/packages/<name>/src/<name>/` | one member (src layout + `py.typed`), tests in `packages/<name>/tests/`                       |
| `scripts/`                           | operators' surface — first-class code, bash 3.2 / BSD-coreutils clean                         |
| `scripts/lib/`                       | sourced-only helper modules (logging, toolchain, git, GitHub API, ruleset reconcile)          |
| `scripts/bazel/`                     | thin `sh_binary` delegates Bazel execs (`check-all.sh`, `run-pnpm.sh`, `run-uv.sh`)           |
| `docker/`                            | `docker-bake.hcl` (single source of truth per image) + per-image build contexts               |
| `.github/`                           | `ci.yml`, `docker-release.yml`, `dependabot.yml`, `dco.yml`, `pull_request_template.md`       |
| root                                 | Bazel workspace files, `lefthook.yml`, Prettier/shellcheck configs, community docs            |

## Development Commands

First-time setup (installs only with your consent; `--check` audits without
installing):

```bash
scripts/setup-project-toolchain.sh   # bootstrap toolchain → pnpm install → lefthook install → uv sync
scripts/configure-git.sh             # repo-local git config, lefthook, DCO hooks
```

Gate commands — every row is a required status check on `main`. There is **no
root-level `pnpm test`**: `--dir typescript` / `--directory python` is mandatory
everywhere, including hooks and CI.

```bash
pnpm --dir typescript run typecheck      # tsc -b tsconfig.host.json (also typechecks tests)
pnpm --dir typescript run lint           # typecheck first, then oxlint (type-aware)
pnpm --dir typescript run lint:tsdoc     # eslint TSDoc/jsdoc gate over packages/*/src
pnpm --dir typescript run test           # vitest run   (CI uses test:coverage)
pnpm --dir typescript run build          # tsc -b tsconfig.build.json
pnpm --dir typescript run format:check   # prettier --check .
uv sync --directory python --frozen      # required before pytest (installs members)
uv run --directory python ruff check .
uv run --directory python ruff format --check .
uv run --directory python mypy packages  # strict
uv run --directory python pytest         # enforces --cov-fail-under=85
scripts/lint-shell.sh                    # shellcheck + 250-line/file gate
scripts/check-hygiene.sh                 # conflict markers / trailing whitespace
```

Bazel (run, not test — targets are `manual`):

```bash
bazel build //...            # every declared target
bazel run //:check           # full gate sequence in CI order — run this before pushing
bazel run //typescript:test  # also :test_coverage :typecheck :lint :lint_tsdoc :build :format_check
bazel run //python:test      # also :ruff :mypy
```

Docker (always through bake; never `docker build` a Dockerfile directly):

```bash
docker buildx bake -f docker/docker-bake.hcl --set harness.platform=linux/amd64 harness
docker buildx bake -f docker/docker-bake.hcl --print harness        # dry-run
docker run --rm ghcr.io/fulton-engineering-services/litellm-auto-router-suite/harness:local info
```

CI required contexts are literal strings in the org ruleset — **never rename a
CI job or matrix `name:`**: `TypeScript`, `Python (3.12)`, `Python (3.13)`,
`Shell`, `Bazel`, `Docker (linux/amd64)`, `Docker (linux/arm64)`, `DCO`. CI
never generates lockfiles: a missing/inconsistent `pnpm-lock.yaml` or
`uv.lock` fails the build; regenerate them in the same PR that changes a
dependency.
All CI jobs use GitHub-hosted runners — the org's one self-hosted runner
(`gx10-9273`) must not be pinned in this repo's workflows.

## Code Conventions & Common Patterns

### TypeScript (`typescript/packages/*`)

- Prettier is authoritative (root `.prettierrc.json`, the repo's only prettier
  config, resolved upward from `typescript/`): **no semicolons, single quotes,
  2-space indent, `printWidth: 140`, `trailingComma: "all"`,
  `arrowParens: "avoid"`**. pre-commit runs `prettier --write` (ts/json/yml/
  yaml/md) + `oxlint --fix` (ts) with `stage_fixed`, so commits rewrite staged
  files; the cheap local loop is `pnpm --dir typescript run lint:fix` then
  `lint:tsdoc:fix`.
- Pure ESM (`"type": "module"`). Relative imports carry the **`.js` extension
  pointing at the compiled name**: `import { VERSION } from '../src/index.js'`
  (enabled by `allowImportingTsExtensions` + `rewriteRelativeImportExtensions`).
  Node builtins use the `node:` prefix.
- Annotate every binding explicitly (convention): `const manifest: Manifest =
manifestJson as Manifest`. Untrusted JSON: parse to `unknown`, then assert to
  a locally declared `interface`.
- oxlint is type-aware; in `src/` (relaxed for `tests/`): no `any`, no `!`, no
  floating promises, `only-throw-error` (throw only `Error`),
  `require-await`, `switch-exhaustiveness-check`, `no-unnecessary-condition`.
- **TSDoc is enforced, not decorative.** `lint:tsdoc` (pre-push + CI) fails
  unless every exported function, class, interface, type alias, module, and
  annotated exported const in `packages/*/src/**` has a description-bearing doc
  block (`tsdoc/syntax` + `jsdoc/require-jsdoc`/`require-param`/
  `require-returns`/`require-description`). Tests are exempt. `@remarks` and
  `@deprecated` are valid; JSDoc-only tags are not.
- Naming: kebab-case packages and files; `SCREAMING_SNAKE_CASE` exported
  constants; PascalCase interfaces. New package names follow
  `@fulton-engineering-services/litellm-auto-router-suite-<name>` with
  `private: true` and `lib/` output (GHCR registry via `typescript/.npmrc`).
- `VERSION`/`PACKAGE_NAME` are **deliberately duplicated** between `src/` and
  the manifest, guarded by a drift test — do not "fix" this by reading
  `package.json` at runtime (bundler cannot).
- tsconfig strictness applies to tests too: `strict`,
  `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`,
  `noUnusedLocals`/`noUnusedParameters`, `noImplicitOverride`,
  `noFallthroughCasesInSwitch`.

### Python (`python/packages/*`)

- src layout + `py.typed`; module docstring is an imperative summary, blank
  line, explanatory paragraph (no Google/numpy style). Strings are
  double-quoted (ruff `quote-style = "double"`); `line-length = 100`;
  target `py312`; mypy `strict = true`.
- Naming: distribution `fes-<slug>`, import package `fes_<slug>` under `src/`
  (see `python/packages/fes_litellm_auto_router_suite/`).
- Test functions: `def test_<name>() -> None:` with bare `assert`, module
  docstring stating the invariant, stdlib-first imports (ruff `PTH` forces
  `pathlib` over `os.path`).
- All tool config lives in the root `python/pyproject.toml`; members declare
  only distribution metadata (no `[tool.*]` sections).
- **Adding a second member requires four registrations in the root
  `pyproject.toml`** or it is silently unlinted/untypechecked/uncovered:
  `[tool.ruff.lint.isort].known-first-party`, `[tool.mypy].mypy_path`,
  `--cov=<module>` in `[tool.pytest.ini_options].addopts`, and
  `[tool.coverage.run].source`.

### Shell (`scripts/**` — first-class code)

- Target: **bash 3.2 + BSD coreutils** (macOS stock `/bin/bash`). No
  `declare -A`, no `${var^^}`, no `mapfile`; use `printf`, never `echo -e`.
- Executables start exactly:

  ```bash
  #!/bin/bash
  # shellcheck shell=bash
  # scripts/<verb>-<noun>.sh - <one-line purpose>
  # Usage: ...
  # Options: ...
  # Layout — lib/x.sh  purpose
  # Compatible with: bash 3.2 + BSD coreutils (macOS stock /bin/bash)
  set -euo pipefail
  ```

  The header **is** the `--help` output (printed via `sed` between the
  `# Usage:` and `# Compatible with:` sentinels) — keep both sentinels.

- Libs (`scripts/lib/*.sh`) are sourced, never executed: no `set -euo
pipefail`, no side effects, a unique double-source guard
  (`_LARS_<NAME>_LOADED=1`), and they self-source dependencies so sourcing order
  doesn't matter. Source with the established pattern:

  ```bash
  [ -f "$LIB_DIR/common.sh" ] || { echo "FATAL: missing $LIB_DIR/common.sh" >&2; exit 1; }
  # shellcheck source=lib/common.sh disable=SC1091
  . "$LIB_DIR/common.sh"
  ```

- Log only through `common.sh` helpers (`log_step`, `log_success`, `log_warn`,
  `log_error`→stderr, `log_info`, `log_config`, `log_header`, `die`,
  `require_command`). Exit codes: `0` ok, `1` via `die`, `2` unknown option.
- Naming: drivers `scripts/<verb>-<noun>.sh`; libs
  `scripts/lib/<domain>[-aspect].sh` with domain-prefixed `snake_case`
  functions (`homebrew_`, `toolchain_`, `ruleset_`, `assert_`, `check_`).
  Every flag mirrors an env override (`${VAR:-default}`).
- Hard limits: **250 lines per shell file** — split into `scripts/lib/`, one
  responsibility per file, instead of widening `.shellcheckrc`. A gate whose
  tool is missing fails, never skips. Software installs require explicit
  consent (`AUTO_INSTALL_DEPS=1` or a typed `y`); `--yes` never authorizes
  installers. To add/rename a bootstrapped tool, edit
  `scripts/lib/toolchain-inventory.sh` — it is the only tool table.

### Git & contribution

- Conventional commit titles (`feat:`, `fix:`, `docs:`, `chore:`). DCO
  `Signed-off-by:` is added by the `prepare-commit-msg` hook from
  `scripts/configure-git.sh` — **never type it by hand** (the `commit-msg`
  hook rejects malformed angle brackets, and GitHub's DCO app is a required
  check).
- PRs: one approving review, fresh approval after the last push, all required
  checks green; only squash/rebase merges; `main` is protected. Fill the PR
  template (`## Summary` + gate checklist).
- Hooks (lefthook config at repo root because lefthook resolves from the git
  root): pre-commit runs prettier/oxlint with `stage_fixed`, whitespace and
  hygiene checks; pre-push runs `typecheck` and `lint:tsdoc`. **No hook runs
  the test suites**, and Python gates have no local hook at all — ruff/mypy/
  pytest failures first surface in CI / `bazel run //:check`. Reinstall hooks
  with `pnpm --dir typescript exec lefthook install`.
- `CHANGELOG.md` follows Keep a Changelog + SemVer and is hand-maintained
  (there is no release-please); add an `## Unreleased` bullet with each change.

## Important Files

| File                                                                          | Why it matters                                                                                    |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `typescript/package.json`                                                     | the whole TS gate stack as scripts; `packageManager` is the single pnpm version truth             |
| `typescript/tsconfig.base.json`                                               | shared strict compiler settings; packages extend it and add only rootDir/outDir/include           |
| `typescript/tsconfig.host.json` / `tsconfig.build.json`                       | solution files: host = typecheck (src + tests), build = src only; new packages must be added here |
| `typescript/.oxlintrc.json`                                                   | type-aware lint rules with src-vs-tests overrides (tests relax `!`, `require-await`, etc.)        |
| `typescript/eslint.config.mjs`                                                | TSDoc/jsdoc gate, scoped to `packages/*/src/**/*.ts`                                              |
| `typescript/vitest.config.ts`                                                 | single root test config; the `include` glob defines where tests may live                          |
| `python/pyproject.toml`                                                       | the one gate stack: ruff, mypy strict, pytest+coverage floor, member registrations                |
| `python/.python-version`                                                      | interpreter truth (3.12); CI additionally gates 3.13                                              |
| `MODULE.bazel`, `BUILD.bazel`, `typescript/BUILD.bazel`, `python/BUILD.bazel` | thin sh_binary orchestrators; gate table lives here                                               |
| `scripts/bazel/check-all.sh`                                                  | the exact CI sequence, locally reproducible via `bazel run //:check`                              |
| `lefthook.yml`                                                                | what fires on commit/push; paths assume `typescript/node_modules/.bin`                            |
| `docker/docker-bake.hcl`                                                      | image definitions + GHA/GHCR dual cache planes                                                    |
| `.github/workflows/ci.yml`                                                    | required check names are load-bearing org-ruleset strings                                         |
| `scripts/lib/common.sh`                                                       | logging/die/require_command helpers every script must use                                         |
| `.prettierrc.json`                                                            | repo-wide format truth (also drives the pre-commit hook)                                          |

## Runtime/Tooling Preferences

- **Node** `^22.19.0 || >=24.0.0` (`engines`, `engine-strict=true`); CI runs
  Node 22. **pnpm 12.18.0** only — version single-sourced from
  `packageManager`; never npm or yarn.
- **Python 3.12** (`python/.python-version`; CI matrix 3.12 + 3.13 via
  `UV_PYTHON`). **uv** only — never pip/poetry; uv-managed CPython is
  authoritative, the pyenv leg is advisory.
- **Bazel 9.3.2** via bazelisk (`.bazelversion`); bzlmod only.
- Locked tool versions live in the lockfiles (never hand-edit): TypeScript
  6.0.3, vitest 5.1.0, oxlint 1.93.0, eslint 10, prettier 3.9; ruff 0.17.4,
  mypy 2.4.1, pytest 9.2.0, pytest-cov 7.1.0.
- Dependabot holds `typescript` back at `>= 7` (`.github/dependabot.yml`):
  typescript-eslint 8.72.2's parser rejects TS 7 and `lint:tsdoc` runs inside
  the required `TypeScript` check, so a TS-7 bump would freeze every PR.
  Dependabot rewrites `package.json` requirements, not just lockfiles.
- Homebrew supplies bootstrappers only; version truth is `packageManager`,
  `typescript/package.json`, the uv `dev` dependency-group, and
  `python/.python-version` — never a brew formula.
- pnpm 12's minimum-release-age policy rejects dependencies newer than its
  window (failing `--frozen-lockfile` and CI); exempt exact versions are listed
  in `typescript/pnpm-workspace.yaml` `minimumReleaseAgeExclude` — extend it
  when pinning a very recent devDep, keeping the policy on for everything else.

## Testing & QA

- **TypeScript:** vitest 5 with a single root config; tests exist only at
  `typescript/packages/*/tests/**/*.test.ts` — `__tests__/`, `*.spec.ts`, and
  anything under `src/`, `lib/`, `lib-tests/` are invisible to the runner.
  No `globals: true`: always `import { describe, expect, it } from 'vitest'`.
  Coverage uses the v8 provider over `packages/*/src/**/*.ts` with **no
  threshold** (the 85% floor is Python-only). CI runs `test:coverage` and
  uploads `typescript/coverage/` with `if-no-files-found: error`.
- **Python:** pytest + pytest-cov via `uv run --directory python pytest`;
  `--cov-fail-under=85` comes from root `addopts`, with html report to
  `python/htmlcov/`. Run `uv sync --directory python` first — imports of a
  member resolve because `uv sync` installs it into the venv.
- **Test philosophy:** assert invariants, not tautologies. The seed tests are
  drift checks (src constants vs manifest, `__version__` vs `pyproject.toml`);
  reproduce that idiom — read the manifest via
  `fileURLToPath(new URL('../package.json', import.meta.url))` (TS) or
  `Path(__file__).resolve().parent.parent / "pyproject.toml"` (Python).
- **Adding a TS package:** create `package.json` (no `scripts`),
  `tsconfig.json` (`rootDir: "src"`, `outDir: "lib"`), `tsconfig.test.json`
  (`rootDir: "tests"`, `outDir: "lib-tests"`, `references: [{path: "./tsconfig.json"}]`),
  add both projects to `tsconfig.host.json` and the src project to
  `tsconfig.build.json`, then `pnpm --dir typescript install` to refresh the
  lockfile. No Bazel file needed under `packages/`.
- **Adding a Python member:** `python/packages/<name>/src/<name>/{__init__.py,py.typed}`
  - `tests/test_*.py` + metadata-only member `pyproject.toml`; register the
    module in the four root-pyproject places; `uv sync --directory python`.
- **Definition of done:** `bazel run //:check` green locally (the exact CI
  sequence), PR template checklist satisfied, lockfiles updated in the same PR.
  Never rename CI jobs/matrix names; reflect any new gate in `CONTRIBUTING.md`
  and the README gate table.
