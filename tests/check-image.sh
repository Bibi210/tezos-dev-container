#!/usr/bin/env bash
# Run with: docker run --rm -i IMAGE bash < tests/check-image.sh
set -euo pipefail

test "$(id -u)" = 1000
test "$(id -g)" = 1000
test "$HOME" = /home/dev
for directory in "$HOME" "$HOME/tezos" "$CARGO_HOME" "$RUSTUP_HOME" "$NVM_DIR" /opt/cargo-export; do
  test -w "$directory"
  test "$(stat -c %u "$directory")" = 1000
done
sudo -n true

python3 --version
python3 -m pip --version
for tool in pre-commit shellcheck shfmt jsonnet jsonnetfmt jsonnet-lint hadolint; do
  "$tool" --version
done

scratch=$(mktemp -d "$HOME/tezos/.image-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
python3 -m venv "$scratch/venv"
"$scratch/venv/bin/python" -m pip --version
printf '{ answer: 42 }\n' > "$scratch/check.jsonnet"
jsonnet "$scratch/check.jsonnet" | jq -e '.answer == 42'
jsonnetfmt --test "$scratch/check.jsonnet"
jsonnet-lint "$scratch/check.jsonnet"
