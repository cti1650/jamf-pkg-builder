#!/usr/bin/env bash
# build-and-verify.sh — Download a macOS installer, build a .pkg if needed,
# and verify install / detect / uninstall / EA on the GitHub Actions macOS runner.
#
# Usage: scripts/core/build-and-verify.sh <app_yaml_path>
#
# Exits non-zero only when the download step fails. All other steps are
# recorded in the step summary and the workflow decides whether to fail.

set -euo pipefail

# ---------- arg + env ----------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app_yaml_path>" >&2
  exit 2
fi

APP_YAML="$1"
if [[ ! -f "$APP_YAML" ]]; then
  echo "ERROR: app yaml not found: $APP_YAML" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_ROOT="${RUNNER_TEMP:-/tmp}/jamf-pkg-builder"
ARTIFACT_DIR="$WORK_ROOT/artifacts"
LOG_FILE="$WORK_ROOT/build-and-verify.log"

mkdir -p "$WORK_ROOT" "$ARTIFACT_DIR"
: > "$LOG_FILE"

# Step result tracking (parallel arrays keep ordering deterministic).
STEP_NAMES=()
STEP_STATUSES=()
STEP_NOTES=()

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)]" "$*" | tee -a "$LOG_FILE"; }
section() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG_FILE"; }
record() {
  STEP_NAMES+=("$1"); STEP_STATUSES+=("$2"); STEP_NOTES+=("${3-}")
  log "[$2] $1${3:+ — $3}"
}

require() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "ERROR: required command not found: $c" >&2
      exit 2
    fi
  done
}
require yq curl pkgutil installer

# ---------- parse yaml ----------

y() { yq -r "$1" "$APP_YAML"; }
y_or() { local v; v="$(y "$1")"; [[ "$v" == "null" || -z "$v" ]] && printf '%s' "$2" || printf '%s' "$v"; }

NAME="$(y '.name')"
DL_URL="$(y_or '.download.url' '')"
DL_FILE="$(y_or '.download.file' '')"
INSTALLER_TYPE="$(y '.installer.type')"
APP_BUNDLE_NAME="$(y_or '.installer.app_name' '')"
REPACKAGE="$(y_or '.installer.repackage' 'false')"

DETECT_APP_PATH="$(y_or '.detect.app_path' '')"
DETECT_MIN_VERSION="$(y_or '.detect.min_version' '')"
DETECT_EA_SCRIPT="$(y_or '.detect.ea_script' '')"

UNINSTALL_TYPE="$(y '.uninstall.type')"
UNINSTALL_PKG_ID="$(y_or '.uninstall.pkg_id' '')"
UNINSTALL_SCRIPT="$(y_or '.uninstall.script' '')"

EA_SCRIPT="$(y_or '.extension_attribute.script' '')"

APP_SLUG="$(basename "$APP_YAML" .yml)"
APP_WORK="$WORK_ROOT/$APP_SLUG"
rm -rf "$APP_WORK"
mkdir -p "$APP_WORK"

section "App: $NAME ($APP_SLUG)"
log "yaml         : $APP_YAML"
log "installer    : type=$INSTALLER_TYPE repackage=$REPACKAGE"
log "work dir     : $APP_WORK"
log "artifact dir : $ARTIFACT_DIR"

# script_based mode: skip install/verify, only stage EA + uninstall scripts.
if [[ "$INSTALLER_TYPE" == "script_based" ]]; then
  section "script_based mode — staging EA / uninstall only"
  [[ -n "$EA_SCRIPT"        && -f "$REPO_ROOT/$EA_SCRIPT" ]]        && cp "$REPO_ROOT/$EA_SCRIPT"        "$ARTIFACT_DIR/${APP_SLUG}-ea.sh"
  [[ -n "$UNINSTALL_SCRIPT" && -f "$REPO_ROOT/$UNINSTALL_SCRIPT" ]] && cp "$REPO_ROOT/$UNINSTALL_SCRIPT" "$ARTIFACT_DIR/${APP_SLUG}-uninstall.sh"
  record "script_based stage" "OK" "scripts copied to artifacts"
  exit 0
fi

# ---------- step 1: download ----------

section "Step 1/12 — download"
DL_PATH="$APP_WORK/$DL_FILE"
log "GET $DL_URL"
if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$DL_PATH" "$DL_URL"; then
  record "1. download" "FAIL" "curl failed"
  echo "Download failed — aborting" >&2
  exit 1
fi
SIZE="$(stat -f%z "$DL_PATH" 2>/dev/null || stat -c%s "$DL_PATH")"
log "saved: $DL_PATH ($SIZE bytes)"
record "1. download" "OK" "$SIZE bytes"

# ---------- step 2: static analysis ----------

section "Step 2/12 — static analysis"
file "$DL_PATH" | tee -a "$LOG_FILE" || true
case "$INSTALLER_TYPE" in
  pkg)
    pkgutil --check-signature "$DL_PATH" 2>&1 | tee -a "$LOG_FILE" || true
    record "2. static analysis" "OK" "pkg signature inspected"
    ;;
  dmg)
    if hdiutil imageinfo "$DL_PATH" >/dev/null 2>&1; then
      log "dmg image-info ok"
      record "2. static analysis" "OK" "dmg image-info ok"
    else
      record "2. static analysis" "WARN" "hdiutil imageinfo failed"
    fi
    ;;
  *)
    record "2. static analysis" "WARN" "unknown installer.type=$INSTALLER_TYPE"
    ;;
esac

# ---------- step 3: build pkg if needed ----------

section "Step 3/12 — build pkg"
PKG_PATH=""
case "$INSTALLER_TYPE" in
  pkg)
    PKG_PATH="$DL_PATH"
    record "3. build pkg" "SKIP" "installer is already a pkg"
    ;;
  dmg)
    if [[ "$REPACKAGE" != "true" ]]; then
      cp "$DL_PATH" "$APP_WORK/${APP_SLUG}.dmg"
      record "3. build pkg" "SKIP" "repackage=false, dmg passed through"
    else
      if [[ -z "$APP_BUNDLE_NAME" ]]; then
        record "3. build pkg" "FAIL" "installer.app_name is required when repackage=true"
      else
        MOUNT_POINT="$APP_WORK/mnt"
        mkdir -p "$MOUNT_POINT"
        # hdiutil attach is known to occasionally flake — retry a couple of times.
        attached=false
        for try in 1 2 3; do
          if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DL_PATH" >>"$LOG_FILE" 2>&1; then
            attached=true; break
          fi
          log "hdiutil attach attempt $try failed, retrying..."
          sleep 3
        done
        if ! $attached; then
          record "3. build pkg" "FAIL" "hdiutil attach failed after retries"
        else
          SRC_APP="$MOUNT_POINT/$APP_BUNDLE_NAME"
          if [[ ! -d "$SRC_APP" ]]; then
            hdiutil detach "$MOUNT_POINT" -force >>"$LOG_FILE" 2>&1 || true
            record "3. build pkg" "FAIL" "$APP_BUNDLE_NAME not found at mount root"
          else
            PKG_PATH="$APP_WORK/${APP_SLUG}.pkg"
            # --component is single-bundle mode: forces install at --install-location regardless of
            # BundleIsRelocatable inferred from nested helper .app bundles (Slack Helper.app etc.).
            # We intentionally do NOT sign here (per repo policy; MDM does not require it).
            if pkgbuild --component "$SRC_APP" \
                        --install-location "/Applications" \
                        --identifier "local.jamf-pkg-builder.${APP_SLUG}" \
                        --version "1.0.0" \
                        "$PKG_PATH" >>"$LOG_FILE" 2>&1; then
              record "3. build pkg" "OK" "$(basename "$PKG_PATH")"
            else
              record "3. build pkg" "FAIL" "pkgbuild failed"
              PKG_PATH=""
            fi
            hdiutil detach "$MOUNT_POINT" -force >>"$LOG_FILE" 2>&1 || true
          fi
        fi
      fi
    fi
    ;;
  *)
    record "3. build pkg" "FAIL" "unsupported installer.type=$INSTALLER_TYPE"
    ;;
esac

# Stash the pkg as an artifact regardless of later steps.
[[ -n "$PKG_PATH" && -f "$PKG_PATH" ]] && cp "$PKG_PATH" "$ARTIFACT_DIR/${APP_SLUG}.pkg"

# ---------- step 4: pre-install snapshot ----------

section "Step 4/12 — pre-install snapshot"
SNAP_PRE_APPS="$APP_WORK/pre-applications.txt"
SNAP_PRE_PKGS="$APP_WORK/pre-receipts.txt"
ls -1 /Applications > "$SNAP_PRE_APPS" 2>/dev/null || true
pkgutil --pkgs > "$SNAP_PRE_PKGS" 2>/dev/null || true
record "4. pre-install snapshot" "OK" "$(wc -l <"$SNAP_PRE_APPS") apps / $(wc -l <"$SNAP_PRE_PKGS") receipts"

# ---------- step 5: install ----------

section "Step 5/12 — install"
if [[ -z "$PKG_PATH" || ! -f "$PKG_PATH" ]]; then
  record "5. install" "SKIP" "no pkg to install"
else
  # installer can occasionally hang — wrap with gtimeout (coreutils) when available.
  installer_cmd=(installer -pkg "$PKG_PATH" -target / -verbose)
  if command -v gtimeout >/dev/null 2>&1; then
    installer_cmd=(gtimeout 600 "${installer_cmd[@]}")
  fi
  # shellcheck disable=SC2024  # LOG_FILE is under user-owned $WORK_ROOT; sudo redirect is intentional.
  if sudo "${installer_cmd[@]}" >>"$LOG_FILE" 2>&1; then
    record "5. install" "OK" "installer -pkg ... -target /"
  else
    record "5. install" "FAIL" "installer returned non-zero"
  fi
fi

# ---------- step 6: post-install snapshot + diff ----------

section "Step 6/12 — post-install snapshot + diff"
SNAP_POST_APPS="$APP_WORK/post-applications.txt"
SNAP_POST_PKGS="$APP_WORK/post-receipts.txt"
ls -1 /Applications > "$SNAP_POST_APPS" 2>/dev/null || true
pkgutil --pkgs > "$SNAP_POST_PKGS" 2>/dev/null || true
{
  echo "--- /Applications diff ---"
  diff "$SNAP_PRE_APPS" "$SNAP_POST_APPS" || true
  echo "--- pkgutil --pkgs diff ---"
  diff "$SNAP_PRE_PKGS" "$SNAP_POST_PKGS" || true
} | tee -a "$LOG_FILE" > "$APP_WORK/install-diff.txt"
NEW_APPS=$(diff "$SNAP_PRE_APPS" "$SNAP_POST_APPS" | grep -c '^>' || true)
NEW_PKGS=$(diff "$SNAP_PRE_PKGS" "$SNAP_POST_PKGS" | grep -c '^>' || true)
record "6. post-install diff" "OK" "+${NEW_APPS} apps / +${NEW_PKGS} receipts"

# ---------- step 7: detection ----------

section "Step 7/12 — detection"
DETECTED_VERSION=""
if [[ -n "$DETECT_EA_SCRIPT" && -f "$REPO_ROOT/$DETECT_EA_SCRIPT" ]]; then
  out="$(sudo bash "$REPO_ROOT/$DETECT_EA_SCRIPT" 2>&1 || true)"
  log "detect.sh output: $out"
  if echo "$out" | grep -Eiq 'installed|true|yes|found'; then
    record "7. detect" "OK" "custom detect.sh matched"
  else
    record "7. detect" "FAIL" "custom detect.sh did not indicate installed"
  fi
elif [[ -n "$DETECT_APP_PATH" ]]; then
  if [[ -d "$DETECT_APP_PATH" ]]; then
    PLIST="$DETECT_APP_PATH/Contents/Info.plist"
    if [[ -f "$PLIST" ]]; then
      DETECTED_VERSION="$(/usr/bin/defaults read "$PLIST" CFBundleShortVersionString 2>/dev/null || echo "")"
    fi
    log "detected version: ${DETECTED_VERSION:-<unknown>} (min: ${DETECT_MIN_VERSION:-<none>})"
    if [[ -z "$DETECT_MIN_VERSION" ]]; then
      record "7. detect" "OK" "app path exists (no min_version check)"
    else
      # sort -V handles semver-ish leading components reliably.
      if [[ "$(printf '%s\n%s\n' "$DETECT_MIN_VERSION" "$DETECTED_VERSION" | sort -V | head -1)" == "$DETECT_MIN_VERSION" ]]; then
        record "7. detect" "OK" "version $DETECTED_VERSION >= $DETECT_MIN_VERSION"
      else
        record "7. detect" "FAIL" "version $DETECTED_VERSION < $DETECT_MIN_VERSION"
      fi
    fi
  else
    record "7. detect" "FAIL" "app path missing: $DETECT_APP_PATH"
  fi
else
  record "7. detect" "WARN" "no detect.app_path or detect.ea_script configured"
fi

# ---------- step 8: install location + arch ----------

section "Step 8/12 — install location + architecture"
if [[ -n "$DETECT_APP_PATH" && -d "$DETECT_APP_PATH" ]]; then
  BIN_DIR="$DETECT_APP_PATH/Contents/MacOS"
  if [[ -d "$BIN_DIR" ]]; then
    MAIN_BIN=""
    while IFS= read -r f; do MAIN_BIN="$f"; break; done < <(find "$BIN_DIR" -maxdepth 1 -type f -perm -u+x 2>/dev/null)
    if [[ -n "$MAIN_BIN" ]]; then
      file "$MAIN_BIN" | tee -a "$LOG_FILE" || true
      lipo -info "$MAIN_BIN" 2>/dev/null | tee -a "$LOG_FILE" || true
      ARCH="$(lipo -info "$MAIN_BIN" 2>/dev/null | sed 's/^.*: //')"
      record "8. arch check" "OK" "${ARCH:-unknown}"
    else
      record "8. arch check" "WARN" "no binary found in $BIN_DIR"
    fi
  else
    record "8. arch check" "WARN" "no MacOS dir under $DETECT_APP_PATH"
  fi
else
  record "8. arch check" "SKIP" "app path not present"
fi

# ---------- step 9: uninstall ----------

section "Step 9/12 — uninstall"
case "$UNINSTALL_TYPE" in
  pkg)
    if [[ -z "$UNINSTALL_PKG_ID" ]]; then
      record "9. uninstall" "FAIL" "uninstall.pkg_id required for type=pkg"
    else
      # shellcheck disable=SC2024  # LOG_FILE is user-owned; sudo redirect intentional.
      if sudo pkgutil --forget "$UNINSTALL_PKG_ID" >>"$LOG_FILE" 2>&1; then
        [[ -n "$DETECT_APP_PATH" && -d "$DETECT_APP_PATH" ]] && sudo rm -rf "$DETECT_APP_PATH"
        record "9. uninstall" "OK" "pkgutil --forget $UNINSTALL_PKG_ID"
      else
        record "9. uninstall" "FAIL" "pkgutil --forget $UNINSTALL_PKG_ID failed"
      fi
    fi
    ;;
  script)
    if [[ -z "$UNINSTALL_SCRIPT" || ! -f "$REPO_ROOT/$UNINSTALL_SCRIPT" ]]; then
      record "9. uninstall" "FAIL" "uninstall script missing: $UNINSTALL_SCRIPT"
    else
      # shellcheck disable=SC2024  # LOG_FILE is user-owned; sudo redirect intentional.
      if sudo bash "$REPO_ROOT/$UNINSTALL_SCRIPT" >>"$LOG_FILE" 2>&1; then
        record "9. uninstall" "OK" "$(basename "$UNINSTALL_SCRIPT")"
      else
        record "9. uninstall" "FAIL" "uninstall script returned non-zero"
      fi
    fi
    ;;
  *)
    record "9. uninstall" "FAIL" "unknown uninstall.type=$UNINSTALL_TYPE"
    ;;
esac

# ---------- step 10: post-uninstall snapshot + diff ----------

section "Step 10/12 — post-uninstall snapshot + diff"
SNAP_AFTER_APPS="$APP_WORK/after-applications.txt"
SNAP_AFTER_PKGS="$APP_WORK/after-receipts.txt"
ls -1 /Applications > "$SNAP_AFTER_APPS" 2>/dev/null || true
pkgutil --pkgs > "$SNAP_AFTER_PKGS" 2>/dev/null || true
{
  echo "--- /Applications diff vs pre ---"
  diff "$SNAP_PRE_APPS" "$SNAP_AFTER_APPS" || true
  echo "--- pkgutil --pkgs diff vs pre ---"
  diff "$SNAP_PRE_PKGS" "$SNAP_AFTER_PKGS" || true
} | tee -a "$LOG_FILE" > "$APP_WORK/uninstall-diff.txt"
LEFTOVER_APPS=$(diff "$SNAP_PRE_APPS" "$SNAP_AFTER_APPS" | grep -c '^>' || true)
LEFTOVER_PKGS=$(diff "$SNAP_PRE_PKGS" "$SNAP_AFTER_PKGS" | grep -c '^>' || true)
record "10. post-uninstall diff" "OK" "leftover: ${LEFTOVER_APPS} apps / ${LEFTOVER_PKGS} receipts"

# ---------- step 11: removal verification ----------

section "Step 11/12 — removal verification"
if [[ -n "$DETECT_APP_PATH" ]]; then
  if [[ -d "$DETECT_APP_PATH" ]]; then
    record "11. removed" "FAIL" "$DETECT_APP_PATH still present"
  else
    record "11. removed" "OK" "$DETECT_APP_PATH gone"
  fi
else
  record "11. removed" "SKIP" "no app_path to verify"
fi

# ---------- step 12: EA functional test ----------

section "Step 12/12 — EA functional test"
if [[ -n "$EA_SCRIPT" && -f "$REPO_ROOT/$EA_SCRIPT" ]]; then
  cp "$REPO_ROOT/$EA_SCRIPT" "$ARTIFACT_DIR/${APP_SLUG}-ea.sh"
  ea_out="$(sudo bash "$REPO_ROOT/$EA_SCRIPT" 2>&1 || true)"
  log "EA output: $ea_out"
  if echo "$ea_out" | grep -Eq '<result>.*</result>'; then
    record "12. ea script" "OK" "<result> tag present (post-uninstall)"
  else
    record "12. ea script" "FAIL" "no <result> tag in EA output"
  fi
else
  record "12. ea script" "WARN" "no EA script configured"
fi

# ---------- summary ----------

section "Summary"
fail=0; warn=0
for s in "${STEP_STATUSES[@]}"; do
  case "$s" in FAIL) fail=$((fail+1));; WARN) warn=$((warn+1));; esac
done
{
  printf '\n| # | Step | Status | Note |\n'
  printf '|---|------|--------|------|\n'
  for i in "${!STEP_NAMES[@]}"; do
    printf '| %d | %s | %s | %s |\n' "$((i+1))" "${STEP_NAMES[$i]}" "${STEP_STATUSES[$i]}" "${STEP_NOTES[$i]}"
  done
  printf '\nFAIL=%d WARN=%d total=%d\n' "$fail" "$warn" "${#STEP_NAMES[@]}"
} | tee -a "$LOG_FILE"

# Copy the log into artifacts last so the summary is included.
cp "$LOG_FILE" "$ARTIFACT_DIR/${APP_SLUG}-build-and-verify.log"

# If running under GitHub Actions, also write to the step summary.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## $NAME ($APP_SLUG)"
    echo
    echo "| # | Step | Status | Note |"
    echo "|---|------|--------|------|"
    for i in "${!STEP_NAMES[@]}"; do
      printf '| %d | %s | %s | %s |\n' "$((i+1))" "${STEP_NAMES[$i]}" "${STEP_STATUSES[$i]}" "${STEP_NOTES[$i]}"
    done
    echo
    echo "FAIL=$fail WARN=$warn"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Exit code policy: only fail the job on hard FAIL count. WARN is reported but green.
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
