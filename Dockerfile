ARG BASE_TAG=latest
FROM ghcr.io/lthms/tezos-dev-base:${BASE_TAG} AS source
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG GIT_COMMIT

# ---------------------------------------------------------------------------
# Update the repository
# ---------------------------------------------------------------------------
RUN if [[ ! "${GIT_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then \
      echo 'GIT_COMMIT must be a full commit SHA; use scripts/resolve-tezos-commit.sh' >&2; \
      exit 1; \
    fi && \
    cd /root/tezos && \
    git fetch --depth 1 origin "$GIT_COMMIT" && \
    git checkout --detach FETCH_HEAD && \
    test "$(git rev-parse HEAD)" = "$GIT_COMMIT"
LABEL org.tezos.revision=$GIT_COMMIT

FROM source AS development

# ---------------------------------------------------------------------------
# Version drift detection + update
# ---------------------------------------------------------------------------
RUN cd /root/tezos && . scripts/version.sh && \
    # Always provision the pinned toolchain and targets: rustc may auto-install
    # the toolchain from rust-toolchain before a version comparison runs.
    rustup toolchain install "$recommended_rust_version" && \
    rustup default "$recommended_rust_version" && \
    rustup target add --toolchain "$recommended_rust_version" \
      wasm32-unknown-unknown \
      riscv64gc-unknown-none-elf \
      riscv64gc-unknown-linux-gnu \
      riscv64gc-unknown-linux-musl \
      x86_64-unknown-linux-musl && \
    # Node drift
    . "$NVM_DIR/nvm.sh" && \
    current_node="$(node --version | sed 's/^v//')" && \
    if [ "$current_node" != "$recommended_node_version" ]; then \
      echo "Node drift: $current_node -> $recommended_node_version" && \
      nvm install "$recommended_node_version"; \
    fi

# Update Node.js symlink in case of version drift
RUN . "$NVM_DIR/nvm.sh" && ln -sf "$(dirname "$(which node)")" "$NVM_DIR/current"

# Reconcile the switch when upstream changes its dependency inputs. The base
# records their fingerprint, so ordinary source-only updates skip opam entirely.
COPY scripts/install-opam-deps.sh /usr/local/bin/install-opam-deps
RUN --mount=type=cache,target=/root/.opam/download-cache \
    install-opam-deps && \
    make -f kernels.mk build-deps && \
    make -f etherlink.mk build-deps

# ---------------------------------------------------------------------------
# Incremental rebuild
# Dune only recompiles what changed since the base image's build.
# Docker layer = filesystem diff, so only modified files in _build/ are stored.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/tmp/cargo-target \
    cd /root/tezos && \
    make && \
    make -f etherlink.mk evm_kernel.wasm && \
    make -f kernels.mk kernel_sdk && \
    dune build tezt/tests/main.exe && \
    dune build etherlink/tezt/tests/main.exe && \
    { find . -name Cargo.toml -execdir rm -rf target \; 2>/dev/null || true; }

WORKDIR /root/tezos
CMD ["/bin/bash"]
