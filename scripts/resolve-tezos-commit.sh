#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [branch]" >&2
  exit 2
fi

branch=${1:-master}
ref="refs/heads/$branch"
git check-ref-format "$ref"
remote=$(git ls-remote --exit-code https://gitlab.com/tezos/tezos.git "$ref")
read -r commit resolved_ref <<< "$remote"
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ || "$resolved_ref" != "$ref" ]]; then
  echo "Could not resolve Tezos branch: $branch" >&2
  exit 1
fi
printf '%s\n' "$commit"
