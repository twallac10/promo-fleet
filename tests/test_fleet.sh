test_tiers_yaml_shape() {
  n=$(yq '.tiers | length' "$ROOT/tiers.yaml"); [ "$n" -ge 1 ] || fail "no tiers"
  yq -o json -I0 '.tiers[]' "$ROOT/tiers.yaml" | while read -r t; do
    echo "$t" | jq -e '(.name|type=="string") and (.clusters|type=="array" and length>0)
      and (.requiresApproval|type=="boolean") and (.onFailure=="hold" or .onFailure=="rollback")' >/dev/null \
      || fail "bad tier: $t"
  done
  [ "$(yq '.tiers[0].onFailure' "$ROOT/tiers.yaml")" = hold ] || fail "first tier must hold"
  [ "$(yq '[.tiers[] | select(.onFailure=="hold")] | length' "$ROOT/tiers.yaml")" = 1 ] || fail "only first tier holds"
}

test_apps_yaml_shape() {
  yq -o json -I0 '.apps[]' "$ROOT/apps.yaml" | while read -r a; do
    echo "$a" | jq -e '(.name|test("^[a-z][a-z0-9-]*$")) and (.repo == "promo-" + .name) and (.dependsOn|type=="array")' >/dev/null \
      || fail "bad app: $a"
  done
}

test_kind_etcd_tmpfs() {
  tiers=$(tier_names); for t in $tiers; do
    f="$ROOT/kind/$t.yaml"
    [ "$(yq .name "$f")" = "tier-$t" ] || fail "$f: name must be tier-$t"
    [ "$(yq '.tiers[] | select(.name=="'"$t"'") | .clusters[0]' "$ROOT/tiers.yaml")" = "kind-tier-$t" ] || fail "$t: cluster name"
    yq '.nodes[0].image' "$f" | grep -q '^kindest/node:v[0-9.]*@sha256:' || fail "$f: node image not pinned by digest"
    # kind node containers mount /tmp as tmpfs; etcd there avoids fsync stalls on the Docker disk.
    yq '.nodes[0].kubeadmConfigPatches[]' "$f" | yq '.etcd.local.dataDir' | grep -q '^/tmp/' || fail "$f: etcd not on tmpfs"
  done
}

test_cluster_paths() {
  tiers=$(tier_names); for t in $tiers; do
    p=$(yq 'select(.kind=="Kustomization" and .metadata.name=="flux-system") | .spec.path' "$ROOT/clusters/$t/flux-sync.yaml")
    [ "$p" = "./clusters/$t" ] || fail "$t: sync path is '$p'"
    u=$(yq 'select(.kind=="GitRepository") | .spec.url' "$ROOT/clusters/$t/flux-sync.yaml")
    [ "$u" = "https://github.com/twallac10/promo-fleet" ] || fail "$t: url $u"
  done
}

test_customize_renames_app() {
  tmp=$(mktemp -d); cp -R "$TEMPLATE_DIR"/. "$tmp/"; rm -rf "$tmp/.git"
  "$ROOT/scripts/customize-app.sh" "$tmp" kyverno
  ! grep -rqw example "$tmp/base" "$tmp/tiers" "$tmp/chart" "$tmp/mirror" || fail "example left: $(grep -rlw example "$tmp/base" "$tmp/tiers" "$tmp/chart" "$tmp/mirror")"
  [ "$(yq .name "$tmp/chart/Chart.yaml")" = promo-kyverno ] || fail "chart name"
  [ "$(yq .wrapper.name "$tmp/mirror/chart.yaml")" = promo-kyverno ] || fail "wrapper name"
  [ "$(yq .spec.url "$tmp/base/ocirepository.yaml")" = oci://ghcr.io/twallac10/charts/promo-kyverno ] || fail "oci url"
  (cd "$tmp" && ROOT="$tmp" tests/run.sh >/dev/null) || fail "customized repo tests fail"
}

test_up_down_idempotent() {
  [ "${LIVE:-0}" = 1 ] || { echo "skip (LIVE=1 to run)"; return 0; }
  cd "$ROOT"
  task up -- dev && task up -- dev || fail "up not idempotent"
  task down -- dev && task down -- dev || fail "down not idempotent"
}

test_repos_sync_copies_template_owned_only() {
  tmp=$(mktemp -d); d="$tmp/promo-kyverno"
  mkdir "$d"; cp -R "$TEMPLATE_DIR"/. "$d/"; rm -rf "$d/.git"
  "$ROOT/scripts/customize-app.sh" "$d" kyverno
  echo "# sentinel-values" >> "$d/chart/values.yaml"
  echo "# sentinel-tier" >> "$d/tiers/dev/tier.yaml"
  echo "stale" > "$d/tests/lib/lib.sh"
  "$ROOT/scripts/repos-sync.sh" "$d"
  grep -q sentinel-values "$d/chart/values.yaml" || fail "app-owned chart/values.yaml overwritten"
  grep -q sentinel-tier "$d/tiers/dev/tier.yaml" || fail "app-owned tier.yaml overwritten"
  diff -q "$TEMPLATE_DIR/tests/lib/lib.sh" "$d/tests/lib/lib.sh" >/dev/null || fail "tests/lib/lib.sh not synced"
  ! grep -rlw example "$d/.github" "$d/scripts" "$d/tests" "$d/tiers" || fail "example left after sync"
  (cd "$d" && ROOT="$d" tests/run.sh >/dev/null) || fail "synced repo tests fail"
}

test_dispatch_secret_manifests() {
  dir=$(mktemp -d); printf 'tok-123\n' > "$dir/dispatch-dev.token"
  out=$(PROMO_DISPATCH_DIR="$dir" "$ROOT/scripts/dispatch-secret.sh" dev)
  for a in $(yq '.apps[].name' "$ROOT/apps.yaml"); do
    echo "$out" | yq -e "select(.kind==\"Namespace\" and .metadata.name==\"$a\")" >/dev/null || fail "no Namespace $a"
    [ "$(echo "$out" | yq "select(.kind==\"Secret\" and .metadata.namespace==\"$a\" and .metadata.name==\"promo-dispatch\") | .stringData.token")" = tok-123 ] \
      || fail "Secret promo-dispatch in $a missing or wrong token"
  done
  [ "$(echo "$out" | yq 'select(.kind=="Secret" and .metadata.namespace=="testkube") | .stringData.token')" = tok-123 ] || fail "Secret promo-dispatch in testkube (the behaviour-test reporter) missing"
  [ "$(echo "$out" | yq 'select(.kind=="Secret") | .metadata.name' | grep -vc -- '---')" = "$(( $(yq '.apps | length' "$ROOT/apps.yaml") + 1 ))" ] || fail "want one Secret per app plus testkube"
  if err=$(PROMO_DISPATCH_DIR="$dir" "$ROOT/scripts/dispatch-secret.sh" stg 2>&1 >/dev/null); then fail "missing token file must fail"; fi
  echo "$err" | grep -q "$dir/dispatch-stg.token" || fail "error must name the token path: $err"
}
