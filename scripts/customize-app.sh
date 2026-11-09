#!/usr/bin/env bash
# Turn a copy of promo-app-template into app <name>: rename `example` to the
# app name in the given paths (default: manifests, chart, mirror config and
# workflows), then refresh each tier's release id (the rename changes it).
# Usage: customize-app.sh <repo-dir> <app-name> [path...]
set -euo pipefail
dir=$1 app=$2; shift 2
[ $# -gt 0 ] || set -- base tiers chart mirror .github
for p in "$@"; do
  [ -e "$dir/$p" ] || continue
  { grep -rlw example "$dir/$p" || true; } | while read -r f; do perl -pi -e "s/\\bexample\\b/$app/g" "$f"; done
done
if [ -x "$dir/scripts/release-id.sh" ]; then
  for f in "$dir"/tiers/*/release.yaml; do "$dir/scripts/release-id.sh" --write "$f"; done
fi
