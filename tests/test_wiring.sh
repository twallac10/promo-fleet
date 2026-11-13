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
    [ "$(deps_of "$t" app-kyverno)" = "testkube-report" ] || fail "$t: kyverno deps: $(deps_of "$t" app-kyverno)"
    [ "$(deps_of "$t" app-kyverno-policies)" = "app-kyverno,testkube-report" ] || fail "$t: kyverno-policies deps"
    [ "$(deps_of "$t" testkube)" = "" ] || fail "$t: testkube must not depend on anything"
    # The report template is a Testkube kind: it can only be applied (dry-run) once
    # the testkube HelmRelease has installed the CRDs, so it is a separate step.
    [ "$(deps_of "$t" testkube-report)" = "testkube" ] || fail "$t: testkube-report must depend on testkube"
    [ "$(deps_of "$t" guardrails)" = "app-kyverno" ] || fail "$t: guardrails deps"
    [ "$(deps_of "$t" canary)" = "" ] || fail "$t: canary must not depend on anything"
    [ "$(deps_of "$t" app-prometheus)" = "app-kyverno,canary,testkube-report" ] || fail "$t: prometheus deps: $(deps_of "$t" app-prometheus)"
    for a in $(yq '.apps[].name' "$ROOT/apps.yaml"); do
      p=$(yq "select(.kind==\"Kustomization\" and .metadata.name==\"app-$a\") | .spec.path" "$ROOT/clusters/$t/apps.yaml")
      [ "$p" = "./tiers/$t" ] || fail "$t: app-$a path $p"
      [ "$(yq "select(.kind==\"Kustomization\" and .metadata.name==\"app-$a\") | .spec.wait" "$ROOT/clusters/$t/apps.yaml")" = true ] \
        || fail "$t: app-$a must wait for its HelmRelease (dependsOn means Ready + tested)"
    done
  done
}

test_no_helmrepository() {
  # Only files this repo tracks: CI checks other repos out inside the workspace.
  files=$(cd "$ROOT" && git ls-files '*.yaml' | grep -v '^tests/fixtures/')
  ! (cd "$ROOT" && grep -l -E '^kind: HelmRepository' $files) || fail "HelmRepository found"
  bad=$(cd "$ROOT" && for f in $files; do yq 'select(.kind=="OCIRepository") | .spec.url' "$f"; done |
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

test_testkube_values() {
  # Behaviour tests (the signed evidence) run in Testkube; installed like the canary, chart from our GHCR.
  hr=$(yq -o json -I0 'select(.kind=="HelmRelease")' "$ROOT/testkube/helmrelease.yaml")
  echo "$hr" | jq -e '.metadata.namespace == "testkube" and .spec.values["testkube-api"].nats.enabled == false
    and .spec.values["testkube-api"].nats.embedded == true' >/dev/null || fail "testkube values: $hr"
  u=$(yq '.spec.url' "$ROOT/testkube/ocirepository.yaml"); d=$(yq '.spec.ref.digest' "$ROOT/testkube/ocirepository.yaml")
  [ "$u" = oci://ghcr.io/twallac10/charts/testkube ] || fail "testkube OCIRepository url: $u"
  echo "$d" | grep -Eq '^sha256:[0-9a-f]{64}$' && ! echo "$d" | grep -q '^sha256:0\{64\}$' || fail "testkube digest not pinned: $d"
  [ "$(yq '.version' "$ROOT/testkube/source.yaml")" = 2.15.0 ] || fail "testkube version"
  tiers=$(tier_names); for t in $tiers; do
    yq 'select(.kind=="Kustomization" and .metadata.name=="testkube") | .spec.path' "$ROOT/clusters/$t/platform.yaml" | grep -qx './testkube' || fail "$t: no testkube Kustomization"
  done
}

test_testkube_install_has_no_testkube_kinds() {
  # On an empty cluster the Testkube CRDs come from the HelmRelease; a Testkube
  # object in the same Kustomization fails its dry-run and nothing installs.
  out=$(kubectl kustomize "$ROOT/testkube") || fail "kustomize testkube"
  [ -z "$(echo "$out" | yq 'select(.apiVersion | test("testkube\.io")) | .kind' | grep -v -- '---')" ] || fail "testkube/ must not contain Testkube kinds"
  out=$(kubectl kustomize "$ROOT/testkube/report") || fail "kustomize testkube/report"
  echo "$out" | yq -e 'select(.kind=="TestWorkflowTemplate") | .metadata.name == "promo-report"' >/dev/null || fail "testkube/report: no promo-report template"
  for t in $(tier_names); do
    yq 'select(.kind=="Kustomization" and .metadata.name=="testkube-report") | .spec.path' "$ROOT/clusters/$t/platform.yaml" | grep -qx './testkube/report' || fail "$t: no testkube-report Kustomization"
  done
}
