#!/usr/bin/env bash
# Create and sync tier clusters one at a time, waiting for each to be Ready
# before starting the next (LESSONS: parallel bootstraps starve each other).
# Usage: up.sh [tier...]   (default: every tier in tiers.yaml, in order)
set -euo pipefail
cd "$(dirname "$0")/.."
tiers="$*"
[ -n "$tiers" ] || tiers=$(yq '.tiers[].name' tiers.yaml)
for t in $tiers; do
  yq -e ".tiers[] | select(.name==\"$t\")" tiers.yaml >/dev/null || { echo "unknown tier: $t" >&2; exit 1; }
  ctx=kind-tier-$t
  scripts/dispatch-secret.sh "$t" >/dev/null # fail before creating anything if the token is missing
  if kind get clusters | grep -qx "tier-$t"; then
    echo "== $t: cluster exists"
  else
    echo "== $t: creating cluster"
    kind create cluster --config "kind/$t.yaml"
  fi
  flux install --context "$ctx"
  scripts/dispatch-secret.sh "$t" | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" apply -f "clusters/$t/flux-sync.yaml"
  flux --context "$ctx" reconcile source git flux-system
  echo "== $t: waiting for Kustomizations to be Ready"
  kubectl --context "$ctx" -n flux-system wait kustomizations --all --for=condition=Ready --timeout=20m
  if [ -n "$(kubectl --context "$ctx" get helmreleases -A -o name)" ]; then
    kubectl --context "$ctx" wait helmreleases -A --all --for=condition=Ready --timeout=20m
  fi
done
