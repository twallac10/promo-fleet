#!/bin/sh
# Last step of every behaviour TestWorkflow (template promo-report), run even
# when tests failed: build one junit.xml from the checks' <testcase> files, read
# which release was tested from the app's HelmRelease, and send it all to the
# app repo as a repository_dispatch (TestReport/<app>.<app>). There the promote
# workflow checks it against main, stores it in GHCR and signs it.
# POSIX sh: runs in alpine/kubectl (no bash, no jq).
# Env: APP, TIER, EXPECTED (check names), EXECUTION, GH_DISPATCH_TOKEN, JUNIT_DIR (/data/junit)
set -eu
dir=${JUNIT_DIR:-/data/junit}
repo=twallac10/promo-$APP

# One <testcase> per expected check; a check that never wrote one is an error.
tests=0 failures=0 errors=0 cases=
for c in $EXPECTED; do
  tests=$((tests + 1))
  if [ -s "$dir/$c.xml" ]; then
    case=$(cat "$dir/$c.xml")
    if grep -q '<failure' "$dir/$c.xml"; then failures=$((failures + 1)); fi
  else
    case="<testcase name=\"$c\"><error message=\"check did not report (aborted or timed out)\"/></testcase>"
    errors=$((errors + 1))
  fi
  cases="$cases$case
"
done
printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n<testsuite name="%s" tests="%s" failures="%s" errors="%s">\n%s</testsuite>\n</testsuites>\n' \
  "$APP" "$tests" "$failures" "$errors" "$cases" > "$dir/junit.xml"
echo "junit: $tests tests, $failures failures, $errors errors"

# The release these tests ran against, as the cluster has it.
hr="kubectl get helmrelease $APP -n $APP -o"
release_id=$($hr "jsonpath={.metadata.annotations.event\.toolkit\.fluxcd\.io/release-id}")
digest=$($hr "jsonpath={.status.history[0].ociDigest}")
revision=$($hr "jsonpath={.status.history[0].version}")

body=$(mktemp)
printf '{"event_type":"TestReport/%s.%s","client_payload":{"app":"%s","tier":"%s","release_id":"%s","digest":"%s","revision":"%s","execution":"%s","junit_b64":"%s"}}' \
  "$APP" "$APP" "$APP" "$TIER" "$release_id" "$digest" "$revision" "$EXECUTION" "$(base64 < "$dir/junit.xml" | tr -d '\n')" > "$body"
if ! curl -fsS --retry 3 -X POST "https://api.github.com/repos/$repo/dispatches" \
    -H "Authorization: Bearer $GH_DISPATCH_TOKEN" -H "Accept: application/vnd.github+json" \
    --data-binary "@$body"; then
  echo "report: could not send the test report to $repo; no evidence for this run (task retest -- $TIER $APP)" >&2
  exit 1
fi
echo "report: sent TestReport for $APP $TIER release $release_id"
