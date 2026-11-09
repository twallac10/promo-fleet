#!/usr/bin/env bash
# Print, for every app in apps.yaml, its Namespace and the Secret its Flux
# githubdispatch Provider reads (promo-dispatch, key token). The token is this
# tier's fine-grained PAT (Contents: write on the app repos), kept outside Git.
# Usage: dispatch-secret.sh <tier> | kubectl apply -f -
set -euo pipefail
cd "$(dirname "$0")/.."
tier=$1
f=${PROMO_DISPATCH_DIR:-$HOME/.config/promo}/dispatch-$tier.token
if [ ! -s "$f" ]; then
  echo "missing $f: create a fine-grained PAT for tier $tier (repos: the app repos," >&2
  echo "permission Contents: write), save it there and chmod 600 it. See promo-fleet NOTES.md." >&2
  exit 1
fi
token=$(tr -d '[:space:]' < "$f")
for app in $(yq '.apps[].name' apps.yaml); do
  APP=$app yq -n '.apiVersion = "v1" | .kind = "Namespace" | .metadata.name = strenv(APP)'
  echo ---
  APP=$app TOKEN=$token yq -n '.apiVersion = "v1" | .kind = "Secret" | .type = "Opaque" |
    .metadata = {"name": "promo-dispatch", "namespace": strenv(APP)} | .stringData.token = strenv(TOKEN)'
  echo ---
done
