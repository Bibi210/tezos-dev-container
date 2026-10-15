#!/usr/bin/env bash
# Run from the Tezos checkout, after provisioning its recommended Rust toolchain.
set -euo pipefail

stamp=_opam/.tezos-dev-container-deps
# Include this helper so changing the installation policy also invalidates it.
fingerprint=$(
  {
    sha256sum "$0" scripts/version.sh scripts/install_build_deps.sh \
      scripts/install_build_deps.rust.sh rust-toolchain &&
    find opam/virtual -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  } | sha256sum | cut -d ' ' -f 1
)
if [[ -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" ]]; then
  echo 'Tezos opam dependencies unchanged; reusing installed switch'
  exit 0
fi

# --dev installs both the build and development dependencies in one invocation.
./scripts/install_build_deps.sh --dev
rm -rf _opam/.opam-switch/build _opam/.opam-switch/sources
printf '%s\n' "$fingerprint" > "$stamp"
