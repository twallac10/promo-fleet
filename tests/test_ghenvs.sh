# task gh:envs: Environments from tiers.yaml, branch protection and repo settings per app repo.
ghenvs_plan() { PATH="$ROOT/tests/fixtures/bin:$PATH" PROMO_REVIEWER_ID=42 GH_LOG="${GH_LOG:-/dev/null}" "$ROOT/scripts/gh-envs.sh" --dry-run; }

test_ghenvs_dry_run_plan() {
  GH_LOG=$(mktemp); out=$(ghenvs_plan) || fail "dry run failed: $out"
  apps=$(yq '.apps[].name' "$ROOT/apps.yaml")
  for a in $apps; do
    r=repos/twallac10/promo-$a
    [ "$(echo "$out" | grep -c "^PATCH $r ")" = 1 ] || fail "$a: repo settings"
    echo "$out" | grep "^PATCH $r " | cut -d' ' -f3- | jq -e '.allow_auto_merge and .delete_branch_on_merge and .allow_squash_merge
      and .security_and_analysis.secret_scanning.status == "enabled"
      and .security_and_analysis.secret_scanning_push_protection.status == "enabled"' >/dev/null || fail "$a: settings body"
    for t in dev stg prd; do
      body=$(echo "$out" | grep "^PUT $r/environments/$t " | cut -d' ' -f3-)
      [ -n "$body" ] || fail "$a/$t: no environment"
      want='[]'; [ $t = prd ] && want='[{"type":"User","id":42}]'
      echo "$body" | jq -e --argjson w "$want" '.reviewers == $w and .prevent_self_review == false
        and .deployment_branch_policy == {"protected_branches": false, "custom_branch_policies": true}' >/dev/null || fail "$a/$t: $body"
      for p in main 'refs/pull/*/merge'; do
        echo "$out" | grep "^POST $r/environments/$t/deployment-branch-policies " | cut -d' ' -f3- |
          jq -e --arg p "$p" 'select(.name == $p and .type == "branch")' >/dev/null || fail "$a/$t: branch policy $p"
      done
    done
    prot=$(echo "$out" | grep "^PUT $r/branches/main/protection " | cut -d' ' -f3-)
    echo "$prot" | jq -e '.required_status_checks == {"strict": false, "contexts": ["promotion-gate"]} and .enforce_admins == false
      and .required_pull_request_reviews == null and .restrictions == null' >/dev/null || fail "$a: protection: $prot"
  done
  [ "$(echo "$out" | grep -c .)" = $(( $(echo "$apps" | wc -l) * 11 )) ] || fail "want 11 writes per repo, got: $out"
}

test_ghenvs_follows_tiers_yaml() {
  tmp=$(mktemp); yq '.tiers += [{"name": "qa", "clusters": ["kind-tier-qa"], "requiresApproval": true, "onFailure": "rollback"}]' "$ROOT/tiers.yaml" > "$tmp"
  out=$(PROMO_TIERS="$tmp" ghenvs_plan)
  [ "$(echo "$out" | grep -c '^PUT repos/twallac10/promo-kyverno/environments/')" = 4 ] || fail "want 4 environments per repo"
  echo "$out" | grep '^PUT repos/twallac10/promo-kyverno/environments/qa ' | grep -q '"id":42' || fail "qa requires approval"
}

test_ghenvs_dry_run_makes_no_writes() {
  GH_LOG=$(mktemp); ghenvs_plan >/dev/null
  [ ! -s "$GH_LOG" ] || fail "dry run called gh for writes: $(cat "$GH_LOG")"
}
