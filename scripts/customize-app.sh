#!/usr/bin/env bash
# Turn a copy of promo-app-template into app <name>: rename `example` to the
# app name in the manifests, chart and mirror config.
# Usage: customize-app.sh <repo-dir> <app-name>
set -euo pipefail
dir=$1 app=$2
grep -rlw example "$dir/base" "$dir/tiers" "$dir/chart" "$dir/mirror" |
  while read -r f; do perl -pi -e "s/\\bexample\\b/$app/g" "$f"; done
