# Shared helpers for tests/test_*.sh. bash 3.2 compatible.
fail() { echo "$*" >&2; exit 1; }
# Use as `tiers=$(tier_names)` so a missing or empty tiers.yaml fails the test.
tier_names() { yq -e '.tiers[].name' "$ROOT/tiers.yaml"; }
TEMPLATE_DIR=${TEMPLATE_DIR:-$ROOT/../promo-app-template}
