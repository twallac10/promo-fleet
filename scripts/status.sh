#!/usr/bin/env bash
# Per tier cluster: Flux Kustomizations and HelmReleases with their full
# condition message (never truncated), and pod restart counts.
# Usage: status.sh [tier...]
set -uo pipefail
cd "$(dirname "$0")/.."
tiers="$*"
[ -n "$tiers" ] || tiers=$(yq '.tiers[].name' tiers.yaml)
for t in $tiers; do
  ctx=kind-tier-$t
  echo "=== $t ($ctx)"
  if ! kind get clusters 2>/dev/null | grep -qx "tier-$t"; then echo "  (no cluster)"; continue; fi
  for kind in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
    kubectl --context "$ctx" get "$kind" -A -o json | jq -r '.items[] |
      (.status.conditions // [] | map(select(.type=="Ready")) | .[0]) as $r |
      "  \(.kind)/\(.metadata.namespace)/\(.metadata.name): \($r.status // "Unknown") \($r.reason // "") - \(($r.message // "") | gsub("\n"; " "))"'
  done
  kubectl --context "$ctx" get pods -A -o json | jq -r '
    [.items[] | {p: "\(.metadata.namespace)/\(.metadata.name)", r: ([.status.containerStatuses[]?.restartCount] | add // 0)}] as $ps |
    "  pods: \($ps | length), restarts: \($ps | map(.r) | add // 0)",
    ($ps[] | select(.r > 0) | "    \(.p): \(.r) restarts")'
done
