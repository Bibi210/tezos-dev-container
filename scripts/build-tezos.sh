#!/usr/bin/env bash
set -euo pipefail

# A fresh builder has empty cache mounts even when it pulled a compiled base.
# Import the base image's artifacts before building at the same absolute paths.
for cache in cargo-target cargo-rollup; do
  if [ -d "/tmp/base-cache/$cache" ] &&
     [ -z "$(find "/tmp/$cache" -mindepth 1 -print -quit)" ]; then
    cp -a "/tmp/base-cache/$cache/." "/tmp/$cache/"
  fi
done

# Enumerate first: deleting a sibling target while find is traversing its parent
# can otherwise produce ENOENT before find reaches the prune expression.
remove_source_targets() {
  local targets_file
  targets_file=$(mktemp)
  find "$@" -name target -prune -o -name Cargo.toml -printf '%h/target\0' > "$targets_file"
  xargs -0 -r rm -rf -- < "$targets_file"
  rm -f "$targets_file"
}

cd /root/tezos
if [ "${1:-}" = base ]; then
  scripts/slim-mode.sh on
fi
make -f etherlink.mk evm_kernel.wasm
# Dune's source_tree dependencies include ignored files. These Cargo outputs
# are disposable, and must not become inputs to the native Rust builds.
remove_source_targets src etherlink
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
remove_source_targets .

# Commit snapshots in this same RUN: a restored build layer must contain its
# artifacts even when the builder's mutable cache mounts have not been restored.
mkdir -p /opt/cargo-export
cp -a /tmp/cargo-target /tmp/cargo-rollup /opt/cargo-export/
