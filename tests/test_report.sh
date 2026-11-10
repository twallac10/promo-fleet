# testkube/report.sh: the last step of every behaviour TestWorkflow (template promo-report).
report_env() { # <junit dir> -> runs report.sh with stubs; prints stdout
  PATH="$ROOT/tests/fixtures/bin:$PATH" APP=kyverno TIER=dev EXECUTION=exec-1 JUNIT_DIR="$1" \
    GH_DISPATCH_TOKEN=tok CURL_LOG="$CURL_LOG" sh "$ROOT/testkube/report.sh"
}
case_file() { printf '<testcase name="%s" time="1"%s\n' "$2" "$([ "$3" = pass ] && echo '/>' || echo '><failure message="boom"/></testcase>')" > "$1/$2.xml"; }

test_report_builds_junit() {
  d=$(mktemp -d); CURL_LOG=$(mktemp); case_file "$d" a pass; case_file "$d" b pass
  EXPECTED="a b" report_env "$d" >/dev/null || fail "report failed"
  x="$d/junit.xml"; yq -p xml -o json '.' "$x" >/dev/null || fail "not XML: $(cat "$x")"
  [ "$(yq -p xml '.testsuites.testsuite."+@name"' "$x")" = kyverno ] || fail "suite name"
  [ "$(yq -p xml '.testsuites.testsuite."+@tests"' "$x")" = 2 ] || fail "tests count: $(cat "$x")"
  [ "$(yq -p xml '.testsuites.testsuite."+@failures"' "$x")" = 0 ] || fail "failures count"
}

test_report_marks_missing_checks_as_errors() {
  d=$(mktemp -d); CURL_LOG=$(mktemp); case_file "$d" a pass; case_file "$d" b fail
  EXPECTED="a b c" report_env "$d" >/dev/null || fail "report failed"
  x="$d/junit.xml"
  [ "$(yq -p xml '.testsuites.testsuite."+@tests"' "$x")" = 3 ] || fail "tests count"
  [ "$(yq -p xml '.testsuites.testsuite."+@failures"' "$x")" = 1 ] || fail "failures count"
  [ "$(yq -p xml '.testsuites.testsuite."+@errors"' "$x")" = 1 ] || fail "errors count: $(cat "$x")"
  grep -q 'name="c"' "$x" || fail "missing check not named"
}

test_report_payload() {
  d=$(mktemp -d); CURL_LOG=$(mktemp); case_file "$d" a pass
  EXPECTED=a report_env "$d" >/dev/null || fail "report failed"
  grep -qx 'https://api.github.com/repos/twallac10/promo-kyverno/dispatches' "$CURL_LOG.args" || fail "url: $(cat "$CURL_LOG.args")"
  grep -qx 'Authorization: Bearer tok' "$CURL_LOG.args" || fail "auth header"
  b=$(cat "$CURL_LOG.body")
  echo "$b" | jq -e '.event_type == "TestReport/kyverno.kyverno"
    and .client_payload.app == "kyverno" and .client_payload.tier == "dev" and .client_payload.execution == "exec-1"
    and .client_payload.release_id == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    and .client_payload.digest == "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    and .client_payload.revision == "3"' >/dev/null || fail "payload: $b"
  [ "$(echo "$b" | jq -r .client_payload.junit_b64 | base64 -d)" = "$(cat "$d/junit.xml")" ] || fail "junit_b64 doesn't decode to junit.xml"
}

test_report_fails_loudly_when_dispatch_fails() {
  d=$(mktemp -d); CURL_LOG=$(mktemp); case_file "$d" a pass
  if err=$(EXPECTED=a CURL_FAIL=1 report_env "$d" 2>&1); then fail "dispatch failure must fail the step"; fi
  echo "$err" | grep -q 'promo-kyverno' || fail "error must name the repo: $err"
}

test_report_template_wiring() {
  t="$ROOT/testkube/promo-report.yaml"; [ -f "$t" ] || fail "missing $t"
  [ "$(yq 'select(.kind=="TestWorkflowTemplate") | .metadata.name' "$t")" = promo-report ] || fail "template name"
  [ "$(yq 'select(.kind=="TestWorkflowTemplate") | .spec.steps[0].condition' "$t")" = always ] || fail "report step must run always"
  # Each app chart brings its own test ServiceAccount, scoped to its own HelmRelease.
  [ -z "$(yq 'select(.kind == "ServiceAccount" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind' "$t" | grep -v -- '---')" ] || fail "no shared SA or cluster-wide RBAC in promo-report.yaml"
  yq -o json -I0 '.configMapGenerator[] | select(.name=="promo-report")' "$ROOT/testkube/kustomization.yaml" | grep -q report.sh || fail "report.sh ConfigMap"
}
