# tezos-dev

Self-contained Docker images for [tezos/tezos](https://gitlab.com/tezos/tezos)
development. A two-image strategy keeps nightly pulls fast: a heavy **base
image** (rebuilt weekly) and a thin **nightly image** that only adds an
incremental `dune` rebuild on top.

## Quick start

```bash
# Build the base image (weekly, ~45 min)
docker build -f Dockerfile.base -t ghcr.io/lthms/tezos-dev-base:latest .

# Build the nightly image on top of it (~15 min)
docker build -t tezos-dev-nightly .

# Build for a specific branch
docker build --build-arg GIT_BRANCH=my-feature-branch -t tezos-dev-nightly .

# Start a shell
docker run -it tezos-dev-nightly
```

## Design

### Two-image strategy

| Image | Rebuild frequency | Size | Purpose |
|-------|-------------------|------|---------|
| `Dockerfile.base` | Weekly | ~20 GB | Full toolchain + compiled `_build` tree |
| `Dockerfile` | Nightly | ~4 GB layer on top of base | `git fetch` + incremental `dune` rebuild |

Subsequent nightly Docker pulls only download the ~4 GB diff layer instead of
the full 20+ GB base, making daily updates practical.

### Layer caching (base image)

Tool versions are hardcoded as `ARG`s in early layers (opam, Node.js,
Foundry), which change rarely and stay cached across rebuilds. The `git clone`
layer is what invalidates on rebuild, and a version drift detection step
re-installs tools only if the repo's `scripts/version.sh` disagrees with what
was pre-installed. Rust and its cross-compilation targets are installed once,
using `recommended_rust_version` from the checkout's `scripts/version.sh`.

```
Cached (stable)        Tool installs (system packages, opam,
                       rustup + sccache, Node.js, Foundry)
                       ────────────────────────────────────────────────
Invalidates on         git clone --depth 1
rebuild                version drift check (fast if no drift)
                       make build-deps / build-dev-deps
                       make -f kernels.mk / etherlink.mk build-deps
                       make (slim mode) + tezt builds
```

### Size optimizations

- **Slim mode** (`scripts/slim-mode.sh on`): drops old protocols (~30% faster
  builds, fewer binaries)
- **BuildKit cache mounts**: sccache and cargo target dirs live in BuildKit
  caches, not in the image
- **Shared Rust target dir**: `OCTEZ_RUST_DEPS_TARGET_DIR`,
  `OCTEZ_RUSTZCASH_DEPS_TARGET_DIR`, and
  `OCTEZ_ETHERLINK_WASM_RUNTIME_TARGET_DIR` all point to the same directory,
  deduplicating Rust dependencies across the three sub-builds
- **Cleanup in same RUN steps**: opam build/sources dirs, nvm cache, and root
  binaries are removed in the same `RUN` step that creates them, so they never
  appear in Docker layers

## Build args

### `Dockerfile.base`

| Arg | Default | Description |
|-----|---------|-------------|
| `OCAML_VERSION` | `5.3.0` | OCaml compiler version |
| `NODE_VERSION` | `18.18.2` | Node.js version (via nvm) |
| `OPAM_VERSION` | `2.3.0` | opam package manager version |
| `FORGE_VERSION` | `1.5.0` | Foundry forge version |
| `SCCACHE_VERSION` | `0.10.0` | sccache version |
| `GIT_BRANCH` | `master` | Branch to clone from tezos/tezos |

### `Dockerfile`

| Arg | Default | Description |
|-----|---------|-------------|
| `BASE_TAG` | `latest` | Tag of the base image to build on |
| `GIT_BRANCH` | `master` | Branch to fetch and checkout |
