#!/usr/bin/env bash
# Fail if any image an app renders (any tier) or the canary uses lacks a
# linux/amd64 or linux/arm64 build (LESSONS #12). App repos are siblings.
set -euo pipefail
cd "$(dirname "$0")/.."
parent=$(cd .. && pwd)
images=$(
  for app in $(yq '.apps[].name' apps.yaml); do
    ( cd "$parent/promo-$app" && ROOT=$PWD && export ROOT && source tests/lib/lib.sh &&
      for t in $TIERS; do render "$t"; done )
  done | yq '.. | select(has("image") and (.image | type) == "!!str") | .image' | grep -v -- '---'
  for f in canary/images.txt testkube/images.txt; do [ ! -f "$f" ] || cat "$f"; done
)
bad=0
for img in $(echo "$images" | sort -u); do
  archs=$(docker buildx imagetools inspect --raw "$img" |
    jq -r '[.manifests[]?.platform | select(.os=="linux") | .architecture] | unique | join(",")')
  case ",$archs," in
    *,amd64,*arm64,*|*,arm64,*amd64,*) echo "ok   $img ($archs)";;
    *) echo "FAIL $img (${archs:-single-arch manifest})"; bad=1;;
  esac
done
exit $bad
