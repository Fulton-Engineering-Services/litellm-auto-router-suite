// docker-bake.hcl — single-source dependency graph for `docker buildx bake`.
//
// This plan ships exactly one buildable target, `harness`, which proves the
// bake file, both cache planes, and the toolchain layers end to end. The
// production images (gateway, headroom compression plane, the three routers,
// and their control planes) land with the content plan as sibling targets;
// they are deliberately NOT stubbed here.
//
// Two cache planes (see docker/README.md):
// - GHA Actions build cache: `cache-from type=gha`, enabled per build by
//   GHA_CACHE_SCOPE (CI sets a matrix-safe scope; local builds leave it "").
//   The `GHA_CACHE_SCOPE == "" ? [] : [...]` guard is load-bearing: an HCL
//   ternary mixing `[]` and `list(string)` fails type inference, so the
//   empty-scope sentinel is the known-good way to make the plane conditional.
//   Do not "simplify" it.
// - GHCR registry cache: `cache-to type=registry`, written only by the
//   main-branch release build, which sets REGISTRY_CACHE to this image's
//   repo. Local builds leave it "" and get no registry export.

variable "REGISTRY" {
  default = "ghcr.io/fulton-engineering-services/litellm-auto-router-suite"
}

variable "TAG" {
  default = "local"
}

variable "PLATFORM" {
  default = "linux/amd64,linux/arm64"
}

// Per-arch / per-build GHA cache scope suffix. CI sets this matrix suffix
// (e.g. "amd64", "arm64"); local builds leave it empty for no GHA caching.
variable "GHA_CACHE_SCOPE" {
  default = ""
}

// Set to the image repo on main builds (by the release workflow) to publish
// a shared registry buildcache; empty locally.
variable "REGISTRY_CACHE" {
  default = ""
}

variable "NODE_VERSION" {
  default = "24.15.0"
}

variable "PYTHON_VERSION" {
  default = "3.12"
}

variable "BUILDX_EXPERIMENTAL" {
  default = "1"
}

// Tag helpers, copied verbatim from the codekeeper bake file
// ($FIE/infra/codekeeper/docker/docker-bake.hcl): a registry-less "name:tag"
// for local builds, fully-qualified "REGISTRY/name:tag" when REGISTRY is
// set. The plan named a `layer_ref()` function; it does not exist in the
// codekeeper source (which defines ref, tag_for, image, base_ref, node_ref,
// tree_sitter_ref, base_repo) — nothing was invented to fill that gap.
// The four per-layer helpers are not carried over: they resolve the layered
// image set's REPO/BASE_TAG/NODE_TAG/TREE_SITTER_TAG variables, which this
// single-target bake does not declare. The content plan restores them from
// the codekeeper file when layered images land.
function "ref" {
  params = [name]
  result = equal("", REGISTRY) ? name : "${REGISTRY}/${name}"
}

function "tag_for" {
  params = [override]
  result = equal("", override) ? TAG : override
}

// Fully-qualified image ref with tag.
function "image" {
  params = [name, tag_override]
  result = "${ref(name)}:${tag_for(tag_override)}"
}

group "default" {
  targets = ["harness"]
}

target "harness" {
  context    = "."
  dockerfile = "docker/images/harness/Dockerfile"
  // split(",", PLATFORM): PLATFORM is the comma-joined pair; a single list
  // element "linux/amd64,linux/arm64" is not two platforms.
  platforms  = split(",", PLATFORM)
  tags       = [image("harness", ""), image("harness", "latest")]
  labels = {
    "org.opencontainers.image.source" = "https://github.com/Fulton-Engineering-Services/litellm-auto-router-suite"
  }
  cache-from = GHA_CACHE_SCOPE == "" ? [] : ["type=gha,scope=${GHA_CACHE_SCOPE}-harness"]
  cache-to   = REGISTRY_CACHE == "" ? [] : ["type=registry,ref=${REGISTRY_CACHE}:buildcache-harness,mode=max,ignore-error=true"]
}
