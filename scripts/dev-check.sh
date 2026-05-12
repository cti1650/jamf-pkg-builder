#!/usr/bin/env bash
# Local convenience: run the same checks CI runs (shellcheck + schema + choice list).
set -euo pipefail

cd "$(dirname "$0")/.."

ok=0; fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "OK    $name"; ok=$((ok+1))
  else
    echo "FAIL  $name"; fail=$((fail+1))
  fi
}

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck" bash -c "find scripts -type f -name '*.sh' -print0 | xargs -0 shellcheck -x -e SC1091,SC2155"
else
  echo "SKIP  shellcheck (not installed; brew install shellcheck)"
fi

check "apps schema" bash scripts/check-apps-schema.sh
check "choice list" bash scripts/check-choice-list.sh

echo
echo "ok=$ok fail=$fail"
[[ $fail -eq 0 ]]
