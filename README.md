# tezos-dev

Self-contained Docker images for [tezos/tezos](https://gitlab.com/tezos/tezos)
development. The **base image** is rebuilt weekly. The **nightly image** updates
the checkout and dependencies, then rebuilds incrementally on top of the base.

## Quick start

```bash
# Resolve master once so both images build the same Tezos revision.
TEZOS_COMMIT=$(./scripts/resolve-tezos-commit.sh master)

# Build the base image (weekly)
docker build -f Dockerfile.base --build-arg GIT_COMMIT="$TEZOS_COMMIT" \
  -t ghcr.io/lthms/tezos-dev-base:latest .

# Build the nightly image on top of it
docker build --build-arg GIT_COMMIT="$TEZOS_COMMIT" -t tezos-dev-nightly .

# Build for a specific branch
TEZOS_COMMIT=$(./scripts/resolve-tezos-commit.sh my-feature-branch)
docker build --build-arg GIT_COMMIT="$TEZOS_COMMIT" -t tezos-dev-nightly .

# Start a shell
docker run -it tezos-dev-nightly
```

## Design

### Two-image strategy

| Image | Rebuild frequency | Purpose |
|-------|-------------------|---------|
| `Dockerfile.base` | Weekly | Full toolchain + compiled `_build` tree |
| `Dockerfile` | Nightly | Exact checkout + dependency reconciliation + incremental rebuild |

Nightly images share the base image's layers. Pulling an updated nightly image
only downloads layers not already present locally; the size depends on what
changed and which build artifacts were reused.

### Layer caching (base image)

Tool versions are hardcoded as `ARG`s in early layers (opam, Node.js,
Foundry), which change rarely and stay cached across rebuilds. Each workflow
resolves the requested Tezos branch before starting Docker and passes the full
SHA as `GIT_COMMIT`. A new commit invalidates the checkout layer; an unchanged
commit can reuse it. Docker cannot detect remote branch updates on its own,
and pulling the base image does not force a cached `git fetch` to run.

Both Dockerfiles require `GIT_COMMIT`, fetch that exact commit, verify `HEAD`,
and record it in the `org.tezos.revision` image label. The same argument can be
used to rebuild an older revision without resolving a branch again.

A separate `dependencies` stage copies only `scripts/version.sh`, the upstream
opam installer scripts, `rust-toolchain`, and `opam/virtual/` from the checkout.
It provisions Rust and Node.js, then runs upstream's dependency installer with
`--dev` to install both build and development dependencies. The full source tree
is copied in afterwards. A new Tezos revision therefore reuses these layers
when the dependency inputs are unchanged.

Nightly builds compare those inputs with the fingerprint recorded in the base's
opam switch. They skip opam for source-only changes and run the upstream installer
when dependencies change. A failed install does not update the fingerprint.
Kernel toolchain setup is also rerun against the nightly checkout. The installer
uses upstream's OCaml version, pinned opam repository, and dependency manifests;
its opam depext step installs required system packages.

```
Stable tool arguments  System packages, opam, rustup + sccache, Node.js, Foundry
Dependency inputs      Rust/Node version setup + opam build/dev dependencies
New Tezos commit       Full checkout + kernel toolchain setup
                       make (slim mode) + tezt builds
```

### Size optimizations

- **Slim mode** (`scripts/slim-mode.sh on`): excludes old protocols from the
  default build
- **BuildKit cache mounts**: the shared Cargo target directory and opam download
  cache stay in the builder. Their contents are not included in the images or
  exported by the workflows' GHA layer cache.
- **sccache**: its local cache is retained in the image, alongside the compiled
  Dune `_build` tree. Cargo target directories are removed from the image.
- **Shared Rust target dir**: `OCTEZ_RUST_DEPS_TARGET_DIR`,
  `OCTEZ_RUSTZCASH_DEPS_TARGET_DIR`, and
  `OCTEZ_ETHERLINK_WASM_RUNTIME_TARGET_DIR` all point to the same directory,
  allowing compatible artifacts to be shared, but serializing those Cargo builds
- **Cleanup in the base image**: opam build/sources dirs, nvm cache, and generated
  root binaries are removed in the same `RUN` step that creates them, so they
  never appear in its Docker layers

## Build args

### `Dockerfile.base`

| Arg | Default | Description |
|-----|---------|-------------|
| `NODE_VERSION` | `18.18.2` | Node.js version (via nvm) |
| `OPAM_VERSION` | `2.3.0` | opam package manager version |
| `FORGE_VERSION` | `1.5.0` | Foundry forge version |
| `SCCACHE_VERSION` | `0.10.0` | sccache version |
| `GIT_COMMIT` | Required | Full Tezos commit SHA; resolve a branch with `scripts/resolve-tezos-commit.sh` |

### `Dockerfile`

| Arg | Default | Description |
|-----|---------|-------------|
| `BASE_TAG` | `latest` | Tag of the base image to build on |
| `GIT_COMMIT` | Required | Full Tezos commit SHA to fetch and check out |

## Validation

`python3 -m unittest discover -s tests` checks branch resolution and both
Dockerfiles' checkout commands against a temporary local Git repository. It
includes an advancing branch and a branch moving after its SHA was resolved.
It also tests dependency fingerprint invalidation, failed-install retries, and
reuse across source-only edits. These tests do not compile Tezos.

`docker build -f Dockerfile.base --target dependencies --build-arg
GIT_COMMIT=... .` can check dependency installation separately from compilation.

Both Dockerfiles expose a `source` stage for checking the actual Docker checkout
and revision label without compiling Tezos. For example:

```bash
docker build -f Dockerfile.base --target source \
  --build-arg GIT_COMMIT="$TEZOS_COMMIT" -t tezos-base-source .
docker build --target source --build-arg GIT_COMMIT="$TEZOS_COMMIT" \
  -t tezos-nightly-source .
docker image inspect tezos-nightly-source \
  --format '{{ index .Config.Labels "org.tezos.revision" }}'
```
