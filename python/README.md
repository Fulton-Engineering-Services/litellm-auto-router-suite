# python/ — uv workspace

This directory is the Python half of the litellm-auto-router-suite: a uv workspace whose
members live under `packages/`. Content packages (LiteLLM plugins, headroom service clients)
land as sibling members; `packages/fes_litellm_auto_router_suite` is the shared-primitives
seed that holds package identity and will hold the code they all import. All tool
configuration (ruff, mypy, pytest, coverage) lives in the root `pyproject.toml` so every
member shares one gate stack — the root itself is a virtual project with no `[project]`
table, and each member owns its own distribution metadata.

Run the gates from the repository root. `uv sync --directory python` materializes
`python/.venv` from `python/uv.lock`; `uv run --directory python ruff check .` lints and
`uv run --directory python ruff format --check .` verifies formatting; `uv run --directory
python mypy packages` enforces strict typing; `uv run --directory python pytest` runs the
test suite with a coverage floor of 85%. Interpreter version truth is
`python/.python-version` (3.12), and CI additionally runs every gate on 3.13.

Git hooks are managed by lefthook at the repository root (`lefthook.yml`), not by
pre-commit — there is exactly one hook manager for both languages. The ruff, mypy, pytest,
and pytest-cov versions are pinned through the `dev` dependency group in the root
`pyproject.toml`, so a fresh clone reproduces the same gates as CI; `scripts/setup-project-toolchain.sh`
bootstraps `uv` itself.
