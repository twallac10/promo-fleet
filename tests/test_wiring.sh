test_generated_clusters_current() {
  tmp=$(mktemp -d)
  OUT_DIR="$tmp" "$ROOT/scripts/gen-clusters.sh"
  tiers=$(tier_names)
  for t in $tiers; do
    diff -u "$ROOT/clusters/$t/apps.yaml" "$tmp/$t/apps.yaml" || fail "clusters/$t/apps.yaml is stale: run scripts/gen-clusters.sh"
  done
}

# Kustomization name -> dependsOn names, for one tier.
deps_of() {
  yq ea "select(.kind==\"Kustomization\" and .metadata.name==\"$2\") | [.spec.dependsOn[]?.name] | sort | join(\",\")" \
    "$ROOT/clusters/$1/apps.yaml" "$ROOT/clusters/$1/platform.yaml" | sed '/^$/d'
}

test_dependson_order() {
  tiers=$(tier_names)
  for t in $tiers; do
    [ "$(deps_of "$t" app-kyverno)" = "" ] || fail "$t: kyverno has deps"
    [ "$(deps_of "$t" app-kyverno-policies)" = "app-kyverno" ] || fail "$t: kyverno-policies deps"
    [ "$(deps_of "$t" guardrails)" = "app-kyverno" ] || fail "$t: guardrails deps"
    [ "$(deps_of "$t" canary)" = "" ] || fail "$t: canary must not depend on anything"
    [ "$(deps_of "$t" app-prometheus)" = "app-kyverno,canary" ] || fail "$t: prometheus deps: $(deps_of "$t" app-prometheus)"
    for a in $(yq '.apps[].name' "$ROOT/apps.yaml"); do
      p=$(yq "select(.kind==\"Kustomization\" and .metadata.name==\"app-$a\") | .spec.path" "$ROOT/clusters/$t/apps.yaml")
      [ "$p" = "./tiers/$t" ] || fail "$t: app-$a path $p"
      [ "$(yq "select(.kind==\"Kustomization\" and .metadata.name==\"app-$a\") | .spec.wait" "$ROOT/clusters/$t/apps.yaml")" = true ] \
        || fail "$t: app-$a must wait for its HelmRelease (dependsOn means Ready + tested)"
    done
  done
}

test_no_helmrepository() {
  ! grep -rl --include='*.yaml' --exclude-dir=fixtures --exclude-dir=.git -E '^kind: HelmRepository' "$ROOT" || fail "HelmRepository found"
  bad=$(find "$ROOT" -name '*.yaml' -not -path '*/fixtures/*' -not -path '*/.git/*' -exec yq 'select(.kind=="OCIRepository") | .spec.url' {} \; |
    grep -v -- '---' | grep -v '^oci://ghcr.io/twallac10/charts/' || true)
  [ -z "$bad" ] || fail "OCIRepository outside our prefix: $bad"
}

test_guardrail_policy_rejects() {
  for f in helmrepository foreign-oci; do
    out=$(kyverno apply "$ROOT/guardrails/" --resource "$ROOT/tests/fixtures/$f.yaml" 2>&1 || true)
    echo "$out" | grep -Eq 'fail: [1-9]' || fail "$f not rejected: $out"
  done
  out=$(kyverno apply "$ROOT/guardrails/" --resource "$ROOT/tests/fixtures/our-oci.yaml" 2>&1 || true)
  echo "$out" | grep -Eq 'fail: 0' && echo "$out" | grep -Eq 'pass: [1-9]' || fail "our OCI rejected: $out"
}

test_guardrails_enforced_natively() {
  names=$(yq 'select(.kind=="ValidatingPolicy") | .metadata.name' "$ROOT"/guardrails/*.yaml | grep -v -- '---')
  [ -n "$names" ] || fail "no guardrail policies"
  for p in $names; do
    pol=$(yq "select(.metadata.name==\"$p\")" "$ROOT"/guardrails/*.yaml)
    [ "$(echo "$pol" | yq '.spec.validationActions | join(",")')" = Deny ] || fail "$p must Deny in every tier"
    [ "$(echo "$pol" | yq '.spec.autogen.validatingAdmissionPolicy.enabled')" = true ] || fail "$p must generate a native VAP"
  done
}

test_canary_digest_pinned() {
  d=$(yq .spec.ref.digest "$ROOT/canary/ocirepository.yaml")
  echo "$d" | grep -Eq '^sha256:[0-9a-f]{64}$' && ! echo "$d" | grep -q '^sha256:0\{64\}$' || fail "canary digest not pinned: $d"
}
