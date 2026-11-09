#!/usr/bin/env bash
# GitHub setup for every app repo in apps.yaml, from tiers.yaml (idempotent):
# - repo settings: squash auto-merge, delete merged branches, secret scanning + push protection
# - one Environment per tier; tiers with requiresApproval get you as reviewer
#   (prevent self-review off); branch policy: main only (the gate runs on main's
#   ref via pull_request_target)
# - branch protection on main: required check promotion-gate
# Usage: gh-envs.sh [--dry-run]   (--dry-run prints "<METHOD> <path> <json>" per write)
set -euo pipefail
cd "$(dirname "$0")/.."
dry=0; [ "${1:-}" = --dry-run ] && dry=1
tiers=${PROMO_TIERS:-tiers.yaml}
owner=twallac10
reviewer=${PROMO_REVIEWER_ID:-$(gh api user --jq .id)}

write() { # <METHOD> <path> <json>
  if [ $dry = 1 ]; then echo "$1 $2 $(echo "$3" | jq -c .)"; else echo "$3" | gh api -X "$1" "$2" --input - >/dev/null; echo "ok   $1 $2"; fi
}

for app in $(yq '.apps[].name' apps.yaml); do
  r=repos/$owner/promo-$app
  write PATCH "$r" '{"allow_auto_merge": true, "delete_branch_on_merge": true, "allow_squash_merge": true,
    "security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}'
  for t in $(yq '.tiers[].name' "$tiers"); do
    approval=$(T=$t yq '.tiers[] | select(.name == strenv(T)) | .requiresApproval' "$tiers")
    reviewers='[]'; [ "$approval" = true ] && reviewers="[{\"type\": \"User\", \"id\": $reviewer}]"
    write PUT "$r/environments/$t" "{\"reviewers\": $reviewers, \"prevent_self_review\": false,
      \"deployment_branch_policy\": {\"protected_branches\": false, \"custom_branch_policies\": true}}"
    have=$(gh api "$r/environments/$t/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null || true)
    echo "$have" | grep -qxF main || write POST "$r/environments/$t/deployment-branch-policies" '{"name": "main", "type": "branch"}'
  done
  write PUT "$r/branches/main/protection" '{"required_status_checks": {"strict": false, "contexts": ["promotion-gate"]},
    "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null}'
done
