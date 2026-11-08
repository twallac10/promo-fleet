#!/usr/bin/env bash
# Create every app repo in apps.yaml from promo-app-template (if missing),
# rename the template app to the app, and push. Checkouts go next to this repo.
set -euo pipefail
cd "$(dirname "$0")/.."
owner=twallac10
parent=$(cd .. && pwd)
for app in $(yq '.apps[].name' apps.yaml); do
  repo=promo-$app
  if gh repo view "$owner/$repo" >/dev/null 2>&1; then
    echo "== $repo exists"; continue
  fi
  echo "== creating $repo"
  gh repo create "$owner/$repo" --public --template "$owner/promo-app-template"
  sleep 3 # template copy is asynchronous
  [ -d "$parent/$repo" ] || gh repo clone "$owner/$repo" "$parent/$repo"
  scripts/customize-app.sh "$parent/$repo" "$app"
  git -C "$parent/$repo" add -A
  git -C "$parent/$repo" commit -qm "chore: customize template for $app"
  git -C "$parent/$repo" push -q origin main
done
