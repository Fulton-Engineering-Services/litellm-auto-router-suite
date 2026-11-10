# Docker

`docker/docker-bake.hcl` is the single source of truth for every image in this
repo; build through `docker buildx bake`, never by invoking `docker build` on a
Dockerfile directly.

## Images

Today the bake file defines exactly one target, `harness`: the toolchain proof
image. It installs the repo's pinned toolchain (node, pnpm via corepack, uv
with its own managed CPython 3.12), runs the real gates inside the build
(`pnpm run build`, `uv run mypy packages`, `uv run pytest`), and ships a
minimal non-root runtime with `tini` as PID 1. `docker run --rm <tag> info`
prints the four tool versions (node, python, pnpm, uv).

The content plan (see `.design/project-content.md`) will add the production
images as sibling bake targets: the LiteLLM **gateway**, the **headroom**
compression plane, the three **routers**, and their **control planes**
(eight images total). They are deliberately not stubbed here — a bake file
with no buildable target proves nothing, and empty targets are worse.

## Image naming convention

All images are published as:

```text
ghcr.io/fulton-engineering-services/litellm-auto-router-suite/<name>:<tag>
```

`REGISTRY` in the bake file defaults to that repository; `TAG` defaults to
`local` (the release workflow sets it from the git ref).

## The two cache planes

The design doc splits layer caching across two planes, and the bake file
implements each with a `""`-sentinel ternary (`GHA_CACHE_SCOPE == "" ? [] :
[...]`) because an HCL ternary mixing `[]` and `list(string)` breaks type
inference — do not simplify those guards.

1. **GHA Actions build cache** (`type=gha`) — active on every CI build.
   `GHA_CACHE_SCOPE` carries the per-target/per-arch scope (e.g.
   `docker-linux/arm64`), so each matrix leg gets `scope=<scope>-harness`.
   Local builds leave it `""` and get no GHA plane (there are no Actions
   credentials off-runner).
2. **GHCR registry cache** (`type=registry`) — written only by the main-branch
   release build, which sets `REGISTRY_CACHE` to the image's repo; the export
   lands on `<REGISTRY_CACHE>:buildcache-harness` with `mode=max` and
   `ignore-error=true`. PR builds never see registry credentials, so they
   leave it `""`.

## Local commands

```sh
# Native arch (Apple Silicon) build of the harness image
docker buildx bake -f docker/docker-bake.hcl --set harness.platform=linux/arm64 harness

# amd64 build
docker buildx bake -f docker/docker-bake.hcl --set harness.platform=linux/amd64 harness

# Exercise the GHA-scope plumbing locally (cache-from only; the runner-side
# registry export stays off unless REGISTRY_CACHE is set)
GHA_CACHE_SCOPE=local docker buildx bake -f docker/docker-bake.hcl --set harness.platform=linux/arm64 harness

# Inspect the resolved configuration without building
docker buildx bake -f docker/docker-bake.hcl --print harness
```

Then:

```sh
docker run --rm ghcr.io/fulton-engineering-services/litellm-auto-router-suite/harness:local info
```
