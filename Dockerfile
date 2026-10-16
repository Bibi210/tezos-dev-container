ARG BASE_TAG=latest
FROM ghcr.io/lthms/tezos-dev-base:${BASE_TAG} AS source
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG GIT_COMMIT

# The base must ship the same Cargo layout used by this nightly build.
RUN test -d /root/tezos/_build/.cargo-target/default/evm-runtime/release || \
    { echo 'Rebuild Dockerfile.base with the per-component Cargo cache layout first.' >&2; exit 1; }

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
RUN --mount=type=cache,id=tezos-cargo-rust-deps,target=/root/tezos/_build/.cargo-target/default/rust-deps,sharing=locked \
    --mount=type=cache,id=tezos-cargo-rustzcash,target=/root/tezos/_build/.cargo-target/default/rustzcash,sharing=locked \
    --mount=type=cache,id=tezos-cargo-evm-runtime,target=/root/tezos/_build/.cargo-target/default/evm-runtime,sharing=locked \
    --mount=type=cache,id=tezos-cargo-rollup-node,target=/root/tezos/_build/.cargo-target/default/rollup-node,sharing=locked \
    --mount=type=cache,id=tezos-cargo-libcrux,target=/root/tezos/_build/.cargo-target/default/libcrux,sharing=locked \
    --mount=type=cache,id=tezos-cargo-riscv-kernels,target=/root/tezos/_build/.cargo-target/default/riscv-kernels,sharing=locked \
    --mount=type=cache,id=tezos-cargo-kernel-sdk,target=/root/tezos/src/kernel_sdk/target,sharing=locked \
    --mount=type=cache,id=tezos-cargo-evm-kernel,target=/root/tezos/etherlink/kernel_latest/target,sharing=locked \
    --mount=type=cache,id=tezos-cargo-git,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,id=tezos-cargo-registry,target=/root/.cargo/registry,sharing=locked \
    --mount=type=bind,from=prepared,source=/root/.cargo,target=/mnt/base-cargo \
    --mount=type=bind,from=prepared,source=/root/tezos,target=/mnt/base-tezos \
    build-tezos nightly

FROM prepared AS development
# Keep tools downloaded by the build (for example solc) as well as shell setup.
RUN --mount=type=bind,from=build,source=/root,target=/mnt/build-root \
    rsync -aH --checksum --delete --exclude=/tezos --exclude=/.cargo/git --exclude=/.cargo/registry /mnt/build-root/ /root/
RUN --mount=type=bind,from=build,source=/root/tezos,target=/mnt/build-tezos \
    rsync -aH --checksum --delete --exclude=/_opam --exclude=/_build/.cargo-target \
      --exclude=/src/kernel_sdk/target --exclude=/etherlink/kernel_latest/target \
      /mnt/build-tezos/ /root/tezos/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/rust-deps,target=/mnt/build-cargo \
    mkdir -p /root/tezos/_build/.cargo-target/default/rust-deps && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/_build/.cargo-target/default/rust-deps/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/rustzcash,target=/mnt/build-cargo \
    mkdir -p /root/tezos/_build/.cargo-target/default/rustzcash && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/_build/.cargo-target/default/rustzcash/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/evm-runtime,target=/mnt/build-cargo \
    mkdir -p /root/tezos/_build/.cargo-target/default/evm-runtime && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/_build/.cargo-target/default/evm-runtime/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/rollup-node,target=/mnt/build-cargo \
    mkdir -p /root/tezos/_build/.cargo-target/default/rollup-node && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/_build/.cargo-target/default/rollup-node/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/libcrux,target=/mnt/build-cargo \
    mkdir -p /root/tezos/_build/.cargo-target/default/libcrux && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/_build/.cargo-target/default/libcrux/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/riscv-kernels,target=/mnt/build-cargo \
    mkdir -p /root/tezos/_build/.cargo-target/default/riscv-kernels && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/_build/.cargo-target/default/riscv-kernels/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/kernel-sdk,target=/mnt/build-cargo \
    mkdir -p /root/tezos/src/kernel_sdk/target && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/src/kernel_sdk/target/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/evm-kernel,target=/mnt/build-cargo \
    mkdir -p /root/tezos/etherlink/kernel_latest/target && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/tezos/etherlink/kernel_latest/target/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/cargo-git,target=/mnt/build-cargo \
    mkdir -p /root/.cargo/git && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/.cargo/git/
RUN --mount=type=bind,from=build,source=/opt/cargo-export/cargo-registry,target=/mnt/build-cargo \
    mkdir -p /root/.cargo/registry && \
    rsync -aH --checksum --delete /mnt/build-cargo/ /root/.cargo/registry/

WORKDIR /root/tezos
CMD ["/bin/bash"]
