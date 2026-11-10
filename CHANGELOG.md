# Changelog

All notable changes to `litellm-auto-router-suite` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## Unreleased

## 0.1.0 (2026-11-09)

### Features

- project shell: pnpm TypeScript workspace and uv Python workspace, each with one
  seed package, on the Fulton gold-standard strict toolchain.
- Bazel top-level orchestrator delegating to `pnpm` and `uv` for every gate.
- `scripts/` operators' surface: `setup-project-toolchain.sh`, `configure-git.sh`,
  `lint-shell.sh`, `check-hygiene.sh`, `setup-remote-repository.sh`, all clean
  under bash 3.2 and shellcheck.
- docker bake harness with GHA Actions cache and GHCR registry cache planes, plus
  the `harness` proof image.
- GitHub Actions CI (TypeScript, Python 3.12/3.13, Shell, Bazel, Docker amd64/arm64)
  and Docker release workflow, all actions pinned by commit SHA.
