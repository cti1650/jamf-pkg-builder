#!/usr/bin/env bash
# Verify that the workflow_dispatch choice options in build-and-verify-pkg.yml
# exactly match the set of apps/*.yml basenames (sorted, no extras).
set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required" >&2
  exit 2
fi

WF=".github/workflows/build-and-verify-pkg.yml"
[[ -f "$WF" ]] || { echo "ERROR: $WF not found" >&2; exit 2; }

apps_from_disk=$(for f in apps/*.yml; do basename "$f" .yml; done | sort -u)
apps_from_wf=$(yq -r '.on.workflow_dispatch.inputs.app.options[]' "$WF" | sort -u)

diff_out=$(diff <(printf '%s\n' "$apps_from_disk") <(printf '%s\n' "$apps_from_wf") || true)
if [[ -n "$diff_out" ]]; then
  echo "ERROR: workflow choice options do not match apps/*.yml" >&2
  echo "--- expected (apps/*.yml) vs actual (workflow) ---" >&2
  echo "$diff_out" >&2
  exit 1
fi
echo "choice options match apps/*.yml: OK"
