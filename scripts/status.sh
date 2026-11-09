#!/usr/bin/env bash
# Per tier cluster: Flux Kustomizations and HelmReleases with their full
# condition message (never truncated), pod restart counts, and each app's latest
# GitHub Deployment in that tier (the promotion evidence).
# Usage: status.sh [tier...]
set -uo pipefail
cd "$(dirname "$0")/.."
tiers="$*"
[ -n "$tiers" ] || tiers=$(yq '.tiers[].name' tiers.yaml)
for t in $tiers; do
  ctx=kind-tier-$t
  echo "=== $t ($ctx)"
  for app in $(yq '.apps[].name' apps.yaml); do
    repo=twallac10/promo-$app
    dep=$(gh api "repos/$repo/deployments?environment=$t&task=promote&per_page=1" --jq '.[0] // empty | "\(.id) \(.payload.digest // "-" | .[7:19]) \(.created_at)"' 2>/dev/null)
    if [ -z "$dep" ]; then echo "  deployment $app: none"; continue; fi
    set -- $dep
    state=$(gh api "repos/$repo/deployments/$1/statuses?per_page=1" --jq '.[0].state // "unknown"' 2>/dev/null)
    echo "  deployment $app: $state digest $2 at $3"
  done
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
