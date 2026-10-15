ARG BASE_TAG=latest
FROM ghcr.io/lthms/tezos-dev-base:${BASE_TAG}
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG GIT_BRANCH=master

# ---------------------------------------------------------------------------
# Update the repository
# ---------------------------------------------------------------------------
RUN cd /root/tezos && \
    git fetch origin "$GIT_BRANCH" && \
    git checkout FETCH_HEAD

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
