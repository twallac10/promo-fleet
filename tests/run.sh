#!/usr/bin/env bash
# Runs every tests/test_*.sh. Each file defines test_* functions; each runs in
# a subshell and passes when it exits 0. Prints PASS/FAIL <name>.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export ROOT
fails=0
for f in tests/test_*.sh; do
  [ -e "$f" ] || continue
  for t in $(bash -c "source $f; declare -F" | awk '{print $3}' | grep '^test_'); do
    if out=$(bash -c "set -euo pipefail; source tests/lib/lib.sh; source $f; $t" 2>&1); then
      echo "PASS $t"
    else
      echo "FAIL $t"; echo "$out" | sed 's/^/    /'
      fails=$((fails + 1))
    fi
  done
done
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
