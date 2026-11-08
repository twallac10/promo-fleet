#!/usr/bin/env bash
# Delete tier clusters. Usage: down.sh [tier...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."
tiers="$*"
[ -n "$tiers" ] || tiers=$(yq '.tiers[].name' tiers.yaml)
for t in $tiers; do
  kind delete cluster --name "tier-$t"
done
