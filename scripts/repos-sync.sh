#!/usr/bin/env bash
# Copy the template-owned files from promo-app-template into app repos and
# customize them; app-owned files (base/, chart/, mirror/, release.yaml,
# tier.yaml, app tests) are never touched. Leaves changes uncommitted.
# Usage: repos-sync.sh [promo-<app>-dir...]   (default: every app in apps.yaml, as siblings)
set -euo pipefail
cd "$(dirname "$0")/.."
# Template-owned paths, relative to the repo root. Globs expand in the template.
OWNED=".github/workflows scripts tests/lib tests/run.sh tests/test_chart.sh tests/test_mirror.sh tests/test_behaviour.sh chart/templates/_behaviour.tpl
  tests/test_tiers.sh tests/test_release.sh tests/test_notify.sh tests/test_gate.sh tiers/*/kustomization.yaml tiers/*/notify.yaml"
template=${TEMPLATE_DIR:-$(cd .. && pwd)/promo-app-template}
dirs="$*"
[ -n "$dirs" ] || for app in $(yq '.apps[].name' apps.yaml); do dirs="$dirs $(cd .. && pwd)/promo-$app"; done
for d in $dirs; do
  app=$(basename "$d"); app=${app#promo-}
  paths=$(cd "$template" && for p in $OWNED; do [ ! -e "$p" ] || echo "$p"; done)
  for p in $paths; do
    rm -rf "${d:?}/$p"; mkdir -p "$(dirname "$d/$p")"; cp -R "$template/$p" "$d/$p"
  done
  # shellcheck disable=SC2086 # one path per word
  scripts/customize-app.sh "$d" "$app" $paths
  echo "== synced $app"
done
