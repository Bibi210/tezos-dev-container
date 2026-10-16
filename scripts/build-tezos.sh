#!/usr/bin/env bash
set -euo pipefail

cargo_root=/root/tezos/_build/.cargo-target/default
components=(rust-deps rustzcash evm-runtime rollup-node libcrux riscv-kernels kernel-sdk evm-kernel cargo-git cargo-registry)
cache_dirs=(
  "$cargo_root/rust-deps"
  "$cargo_root/rustzcash"
  "$cargo_root/evm-runtime"
  "$cargo_root/rollup-node"
  "$cargo_root/libcrux"
  "$cargo_root/riscv-kernels"
  /root/tezos/src/kernel_sdk/target
  /root/tezos/etherlink/kernel_latest/target
  /root/.cargo/git
  /root/.cargo/registry
)

# A fresh builder seeds empty mounts from the compiled base, at the same paths
# used by Dune and Make. Keep each cache independent for image assembly.
for index in "${!components[@]}"; do
  cache=${cache_dirs[$index]}
  case "$cache" in
    /root/tezos/*) seed="/mnt/base-tezos/${cache#/root/tezos/}" ;;
    /root/.cargo/*) seed="/mnt/base-cargo/${cache#/root/.cargo/}" ;;
  esac
  mkdir -p "$cache"
  if [ -d "$seed" ] && [ -z "$(find "$cache" -mindepth 1 -print -quit)" ]; then
    cp -a "$seed/." "$cache/"
  fi
done

cd /root/tezos
if [ "${1:-}" = base ]; then
  scripts/slim-mode.sh on
fi
make -f etherlink.mk evm_kernel.wasm
make BUILD_EXTRA='tezt/tests/main.exe etherlink/tezt/tests/main.exe'

# Make copies installed executables into the checkout. Small launchers retain
# those entry points without duplicating binaries. Unlike symlinks, they can be
# overwritten by make's subsequent cp -f without a same-file error.
for binary in _build/install/default/bin/*; do
  name=${binary##*/}
  if [ -f "$name" ] && [ ! -L "$name" ] && cmp -s "$name" "$binary"; then
    # Expand the launcher's arguments at execution time.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nexec "$(dirname -- "$0")/%s" "$@"\n' "$binary" > "$name"
    chmod +x "$name"
  fi
done

# Commit snapshots in this same RUN: a restored build layer must contain its
# artifacts even when the builder's mutable cache mounts have not been restored.
mkdir -p /opt/cargo-export
for index in "${!components[@]}"; do
  destination="/opt/cargo-export/${components[$index]}"
  mkdir -p "$destination"
  cp -a "${cache_dirs[$index]}/." "$destination/"
done
