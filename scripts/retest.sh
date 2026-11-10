#!/usr/bin/env bash
# Re-run an app's behaviour tests (Testkube) for the release it runs now, e.g.
# after a flaky or infrastructure failure. The report and its signed evidence
# follow as for any run; for a tier and release the newest result counts.
# Usage: retest.sh [--dry-run] <tier> <app>
set -euo pipefail
cd "$(dirname "$0")/.."
dry=0; [ "${1:-}" = --dry-run ] && { dry=1; shift; }
tier=$1 app=$2
TIER=$tier yq -e '.tiers[] | select(.name == strenv(TIER))' tiers.yaml >/dev/null 2>&1 || { echo "unknown tier: $tier" >&2; exit 1; }
APP=$app yq -e '.apps[] | select(.name == strenv(APP))' apps.yaml >/dev/null 2>&1 || { echo "unknown app: $app" >&2; exit 1; }
manifest=$(APP=$app NAME="$app-behaviour-retest-$(date +%s)" yq -n '
  .apiVersion = "testworkflows.testkube.io/v1" | .kind = "TestWorkflowExecution" |
  .metadata = {"name": strenv(NAME), "namespace": "testkube"} |
  .spec.testWorkflow.name = strenv(APP) + "-behaviour"')
if [ $dry = 1 ]; then echo "$manifest"; else echo "$manifest" | kubectl --context "kind-tier-$tier" apply -f -; fi
