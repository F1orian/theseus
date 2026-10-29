#!/usr/bin/env bash
# Runs every local check: `swift test` for Modules/ and `xcodebuild test` for the app on an iOS 26+
# simulator, then prints a short summary. Full logs land in build/test-logs/.
#
# Usage: scripts/test.sh [--skip-app]
# Env:   THESEUS_SIMULATOR=<udid or name>  pick a simulator (default: newest iOS 26+ iPhone)
#        THESEUS_INTEGRATION=1             also run the live-Server tests (needs a filled-in .env)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGS="$ROOT/build/test-logs"
mkdir -p "$LOGS"

SKIP_APP=0
[[ "${1:-}" == "--skip-app" ]] && SKIP_APP=1

PACKAGE_STATUS="skipped"
APP_STATUS="skipped"
PACKAGE_DETAIL=""
APP_DETAIL=""

# ---------------------------------------------------------------------------
echo "==> swift test (Modules/)"
swift test --package-path Modules >"$LOGS/swift-test.log" 2>&1
PACKAGE_EXIT=$?
# Swift Testing prints one "Test run with N tests …" line per test bundle.
PACKAGE_DETAIL="$(python3 - "$LOGS/swift-test.log" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
text = re.sub(r"\x1b\[[0-9;]*m", "", text)
runs = re.findall(r"Test run with (\d+) tests? in \d+ suites? (passed|failed)", text)
total = sum(int(n) for n, _ in runs)
failed_runs = sum(1 for _, s in runs if s == "failed")
skipped = len(re.findall(r"Test \S+ skipped", text))
issues = sum(int(n) for n in re.findall(r"with (\d+) issues?", text))
print(f"{total} tests in {len(runs)} bundles, {skipped} skipped, {issues} issues")
PY
)"
if [[ $PACKAGE_EXIT -eq 0 ]]; then PACKAGE_STATUS="passed"; else PACKAGE_STATUS="FAILED"; fi
echo "    $PACKAGE_STATUS: $PACKAGE_DETAIL"

# ---------------------------------------------------------------------------
read -r -d '' SUMMARIZE_XCRESULT <<'PY'
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("no result bundle (build failure?)")
    sys.exit()
dev = (s.get("devicesAndConfigurations") or [{}])[0].get("device", {})
print(f"{s.get('totalTestCount', 0)} tests: {s.get('passedTests', 0)} passed, "
      f"{s.get('failedTests', 0)} failed, {s.get('skippedTests', 0)} skipped "
      f"on {dev.get('deviceName', '?')} (iOS {dev.get('osVersion', '?')})")
PY

if [[ $SKIP_APP -eq 0 ]]; then
  echo "==> xcodebuild test (app)"
  [[ -d Theseus.xcodeproj ]] || xcodegen generate --quiet

  DESTINATION_ID="$(python3 - "${THESEUS_SIMULATOR:-}" <<'PY'
import json, subprocess, sys
wanted = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
candidates = []
for runtime, devices in data["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.rsplit(".iOS-", 1)[1].split("-"))
    if version < (26,):
        continue
    for d in devices:
        if wanted and wanted not in (d["udid"], d["name"]):
            continue
        if not wanted and not d["name"].startswith("iPhone"):
            continue
        candidates.append((d["state"] == "Booted", version, d["name"], d["udid"]))
if candidates:
    print(sorted(candidates)[-1][3])
PY
)"
  if [[ -z "$DESTINATION_ID" ]]; then
    APP_STATUS="FAILED"
    APP_DETAIL="no iOS 26+ simulator found (set THESEUS_SIMULATOR)"
  else
    # Live UI test credentials reach the test runner via the TEST_RUNNER_ prefix.
    if [[ "${THESEUS_INTEGRATION:-}" == "1" && -f .env ]]; then
      set -a; source .env; set +a
      export TEST_RUNNER_THESEUS_OWUI_URL="${THESEUS_OWUI_URL:-}"
      export TEST_RUNNER_THESEUS_OWUI_EMAIL="${THESEUS_OWUI_EMAIL:-}"
      export TEST_RUNNER_THESEUS_OWUI_PASSWORD="${THESEUS_OWUI_PASSWORD:-}"
      # ComposerUITests attaches a library photo and a Files document: seed them once per simulator.
      MARKER="$ROOT/build/.composer-prepared-$DESTINATION_ID"
      if [[ ! -f "$MARKER" ]]; then
        xcrun simctl bootstatus "$DESTINATION_ID" -b >/dev/null 2>&1
        scripts/prepare-composer-simulator "$DESTINATION_ID" >"$LOGS/prepare-composer.log" 2>&1 && touch "$MARKER"
      fi
    fi
    RESULT="$ROOT/build/TestResults.xcresult"
    rm -rf "$RESULT"
    APP_STARTED=$(date +%s)
    xcodebuild test \
      -project Theseus.xcodeproj \
      -scheme Theseus \
      -destination "id=$DESTINATION_ID" \
      -derivedDataPath build/DerivedData \
      -resultBundlePath "$RESULT" \
      >"$LOGS/xcodebuild-test.log" 2>&1
    APP_EXIT=$?
    APP_DETAIL="$(xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null \
      | python3 -c "$SUMMARIZE_XCRESULT")"
    if [[ $APP_EXIT -eq 0 ]]; then APP_STATUS="passed"; else APP_STATUS="FAILED"; fi
    # Whatever a failed walkthrough left behind ([theseus-test] Chats with Attachments, uploads),
    # limited to this run so parallel runs on the same Account keep theirs.
    if [[ "${THESEUS_INTEGRATION:-}" == "1" && -f .env ]]; then
      HOURS=$(python3 -c "import time; print(round((time.time() - $APP_STARTED) / 3600 + 0.05, 3))")
      scripts/prepare-composer-simulator --cleanup "$HOURS" >>"$LOGS/prepare-composer.log" 2>&1
    fi
  fi
  echo "    $APP_STATUS: $APP_DETAIL"
fi

# ---------------------------------------------------------------------------
echo
echo "Summary"
echo "  Modules (swift test):   $PACKAGE_STATUS — $PACKAGE_DETAIL"
echo "  App (xcodebuild test):  $APP_STATUS${APP_DETAIL:+ — $APP_DETAIL}"
echo "  Logs: ${LOGS#"$ROOT/"}/"

[[ "$PACKAGE_STATUS" != "FAILED" && "$APP_STATUS" != "FAILED" ]]
