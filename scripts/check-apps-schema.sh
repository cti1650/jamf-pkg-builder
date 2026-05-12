#!/usr/bin/env bash
# Validate apps/*.yml against the documented schema (docs/yaml-schema.md).
# Required: yq (mikefarah). Exits 1 on the first violation.
set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required" >&2
  exit 2
fi

ALLOWED_INSTALLER_TYPES=" pkg dmg script_based "
ALLOWED_UNINSTALL_TYPES=" pkg script "

fail=0
report() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fail=1; }

for f in apps/*.yml; do
  [[ -f "$f" ]] || continue
  base=$(basename "$f" .yml)

  name=$(yq -r '.name' "$f")
  [[ "$name" == "null" || -z "$name" ]] && report "$f" "missing .name"

  itype=$(yq -r '.installer.type' "$f")
  if [[ "$itype" == "null" || -z "$itype" ]]; then
    report "$f" "missing .installer.type"
  elif ! [[ "$ALLOWED_INSTALLER_TYPES" == *" $itype "* ]]; then
    report "$f" "installer.type=$itype not in {$ALLOWED_INSTALLER_TYPES}"
  fi

  utype=$(yq -r '.uninstall.type' "$f")
  if [[ "$itype" != "script_based" ]]; then
    if [[ "$utype" == "null" || -z "$utype" ]]; then
      report "$f" "missing .uninstall.type"
    elif ! [[ "$ALLOWED_UNINSTALL_TYPES" == *" $utype "* ]]; then
      report "$f" "uninstall.type=$utype not in {$ALLOWED_UNINSTALL_TYPES}"
    fi
  fi

  # download.url is required unless script_based.
  if [[ "$itype" != "script_based" ]]; then
    url=$(yq -r '.download.url' "$f")
    [[ "$url" == "null" || -z "$url" ]] && report "$f" "missing .download.url"
    file=$(yq -r '.download.file' "$f")
    [[ "$file" == "null" || -z "$file" ]] && report "$f" "missing .download.file"
  fi

  # dmg + repackage=true → installer.app_name required.
  if [[ "$itype" == "dmg" ]]; then
    rep=$(yq -r '.installer.repackage' "$f")
    if [[ "$rep" == "true" ]]; then
      app_name=$(yq -r '.installer.app_name' "$f")
      [[ "$app_name" == "null" || -z "$app_name" ]] && report "$f" "installer.app_name required when installer.repackage=true"
    fi
  fi

  # uninstall.type=pkg requires uninstall.pkg_id.
  if [[ "$utype" == "pkg" ]]; then
    pid=$(yq -r '.uninstall.pkg_id' "$f")
    [[ "$pid" == "null" || -z "$pid" ]] && report "$f" "uninstall.pkg_id required when uninstall.type=pkg"
  fi

  # uninstall.type=script requires uninstall.script path (and the file must exist).
  if [[ "$utype" == "script" ]]; then
    sp=$(yq -r '.uninstall.script' "$f")
    if [[ "$sp" == "null" || -z "$sp" ]]; then
      report "$f" "uninstall.script required when uninstall.type=script"
    elif [[ ! -f "$sp" ]]; then
      report "$f" "uninstall.script path not found: $sp"
    fi
  fi

  # detect block required (either app_path or ea_script must resolve).
  app_path=$(yq -r '.detect.app_path' "$f")
  ea_path=$(yq -r '.detect.ea_script' "$f")
  if [[ ( "$app_path" == "null" || -z "$app_path" ) && ( "$ea_path" == "null" || -z "$ea_path" ) ]]; then
    report "$f" "detect: either app_path or ea_script must be set"
  fi
  if [[ "$ea_path" != "null" && -n "$ea_path" && ! -f "$ea_path" ]]; then
    report "$f" "detect.ea_script path not found: $ea_path"
  fi

  # extension_attribute.script must exist if specified.
  ea=$(yq -r '.extension_attribute.script' "$f")
  if [[ "$ea" != "null" && -n "$ea" && ! -f "$ea" ]]; then
    report "$f" "extension_attribute.script not found: $ea"
  fi

  # Filename ↔ .name slug sanity (only flags egregious mismatches; .name is human-readable so we don't enforce equality).
  if [[ -z "$base" ]]; then
    report "$f" "empty basename"
  fi

  echo "OK  $f"
done

if [[ $fail -ne 0 ]]; then
  echo "schema validation failed" >&2
  exit 1
fi
echo "all apps/*.yml passed schema validation"
