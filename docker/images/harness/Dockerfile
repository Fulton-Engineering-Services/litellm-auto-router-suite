# syntax=docker/dockerfile:1
# harness — toolchain proof image for litellm-auto-router-suite.
#
# Builds the real TypeScript and Python workspaces (pnpm build, mypy, pytest)
# with the exact pinned toolchain the repo's gates use, then ships a minimal
# non-root runtime carrying node_modules, the uv-managed 3.12 interpreter,
# the project venv, pnpm, and uv. `docker run --rm <tag> info` prints the four
# tool versions.
#
# Deviations from the plan sketch, both required to make the image real:
# - No apt python3 / no `python3.12` symlink: bookworm ships 3.11, so the
#   symlink target never exists. uv is authoritative for the interpreter
#   (`uv python install`), installed as its own pinned standalone binary
#   because bookworm's system pip is PEP 668 externally-managed and cannot
#   `pip install uv` anyway.
# - The runtime stage installs tini and copies the corepack/pnpm surface;
#   otherwise `info` has no pnpm or PID-1 init at runtime.

ARG NODE_VERSION=24.15.0
ARG PYTHON_VERSION=3.12
ARG UV_VERSION=0.10.10
ARG PNPM_VERSION=12.18.0

FROM node:${NODE_VERSION}-bookworm-slim AS base
ARG PYTHON_VERSION
ARG UV_VERSION
ARG PNPM_VERSION
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_LINK_MODE=copy \
    COREPACK_HOME=/opt/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# 1. stable: system packages (ca-certificates/curl for the uv download, git
#    for git-sourced deps, tini for PID 1). No python3 from apt — see header.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git tini

# 2. stable: package managers. uv from its pinned upstream release tarball
#    (standalone static binary; no system python needed to bootstrap it).
RUN case "${TARGETARCH}" in \
      amd64) uv_arch=x86_64 ;; \
      arm64) uv_arch=aarch64 ;; \
      *) printf 'unsupported TARGETARCH: %s\n' "${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/uv.tar.gz \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}-unknown-linux-gnu.tar.gz" && \
    tar -xzf /tmp/uv.tar.gz -C /tmp && \
    install -m 0755 "/tmp/uv-${uv_arch}-unknown-linux-gnu/uv" /usr/local/bin/uv && \
    install -m 0755 "/tmp/uv-${uv_arch}-unknown-linux-gnu/uvx" /usr/local/bin/uvx && \
    rm -rf /tmp/uv.tar.gz "/tmp/uv-${uv_arch}-unknown-linux-gnu"

# The project interpreter, installed by uv and carried into the runtime
# stage at the same absolute path so the venv's interpreter symlink resolves.
RUN uv python install "${PYTHON_VERSION}"

# PNPM_VERSION must match the packageManager field in typescript/package.json.
RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate

# 3. volatile-ish: dependency manifests copied before source, so dependency
#    layers survive source edits. Workspace manifests must all be present or
#    the frozen installs cannot resolve the two importers.
COPY typescript/package.json typescript/pnpm-lock.yaml typescript/pnpm-workspace.yaml /build/typescript/
COPY typescript/packages/core/package.json /build/typescript/packages/core/package.json
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    cd /build/typescript && pnpm install --frozen-lockfile

COPY python/pyproject.toml python/uv.lock python/.python-version /build/python/
COPY python/packages/fes_litellm_auto_router_suite/pyproject.toml \
     python/packages/fes_litellm_auto_router_suite/README.md \
     /build/python/packages/fes_litellm_auto_router_suite/
RUN --mount=type=cache,target=/root/.cache/uv \
    cd /build/python && uv sync --frozen --no-install-workspace

# 4. volatile: source, then the real gates (these are the same commands
#    scripts/bazel/check-all.sh and CI run).
COPY typescript/ /build/typescript/
COPY python/ /build/python/
RUN cd /build/typescript && pnpm run build
RUN --mount=type=cache,target=/root/.cache/uv \
    cd /build/python && uv run --frozen mypy packages && uv run --frozen pytest -q

# 5. runtime: non-root, minimal, tini as PID 1.
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ENV COREPACK_HOME=/opt/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/app/python/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends tini && \
    groupadd -g 10001 appuser && \
    useradd -u 10001 -g appuser -m -s /usr/sbin/nologin appuser
COPY --from=base /usr/local/bin/uv /usr/local/bin/
COPY --from=base /opt/uv-python /opt/uv-python
COPY --from=base /opt/corepack /opt/corepack
COPY --from=base /usr/local/lib/node_modules/corepack /usr/local/lib/node_modules/corepack
# The node image ships corepack (and `corepack enable`'s pnpm shim) as
# symlinks into node_modules/corepack/dist, whose launcher requires
# ./lib/corepack.cjs relatively; COPY would dereference them into broken
# copies, so recreate the symlinks here.
RUN ln -sf ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack && \
    ln -sf ../lib/node_modules/corepack/dist/pnpm.js /usr/local/bin/pnpm
COPY --from=base /build/typescript/node_modules /app/typescript/node_modules
COPY --from=base /build/python/.venv /app/python/.venv
COPY --chmod=0755 docker/images/harness/entrypoint.sh /usr/local/bin/entrypoint.sh
WORKDIR /app
USER appuser
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
CMD ["info"]
