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

FROM source AS prepared

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

# The compile stage commits cache snapshots alongside its build outputs. Final
# layers import each artifact group separately, including on a fresh builder.
FROM prepared AS build
COPY scripts/build-tezos.sh /usr/local/bin/build-tezos
RUN --mount=type=cache,target=/tmp/cargo-target \
    --mount=type=cache,target=/tmp/cargo-rollup \
    --mount=type=bind,from=prepared,source=/tmp,target=/tmp/base-cache \
    build-tezos nightly

FROM prepared AS development
# Keep tools downloaded by the build (for example solc) as well as shell setup.
RUN --mount=type=bind,from=build,source=/root,target=/mnt/build-root \
    rsync -aH --checksum --delete --exclude=/tezos /mnt/build-root/ /root/
RUN --mount=type=bind,from=build,source=/root/tezos,target=/mnt/build-tezos \
    rsync -aH --checksum --delete --exclude=/_opam /mnt/build-tezos/ /root/tezos/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/cargo-target,target=/mnt/build-native \
    mkdir -p /tmp/cargo-target && \
    rsync -aH --checksum --delete /mnt/build-native/ /tmp/cargo-target/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/cargo-rollup,target=/mnt/build-rollup \
    mkdir -p /tmp/cargo-rollup && \
    rsync -aH --checksum --delete /mnt/build-rollup/ /tmp/cargo-rollup/

WORKDIR /root/tezos
CMD ["/bin/bash"]
