#!/usr/bin/env bash
# Daily section, share sheet and Spotlight acceptance on one disposable simulator.
# Usage: test-integrations-ios.sh <project> <derived-data> <simulator-udid> <results-dir> [time-zone]
set -euo pipefail
project="$1"
derived="$2"
simulator="$3"
results="$4"
export TEST_RUNNER_LIFE_UI_TEST_WIDGET_SIMULATOR="$simulator"
export TEST_RUNNER_LIFE_UI_TEST_WIDGET_TIME_ZONE="${5:-UTC}"
for selected in \
  'LifeUITests/WidgetRolloverUIFixtureTests/prepareWidgetRolloverFixture()' \
  'LifeUIUITests/NativeIntegrationsUITests/testDailySectionSitsAboveTablesAndOpensItsRow' \
  'LifeUIUITests/NativeIntegrationsUITests/testShareSheetPreparesADraftThatOpensUnsaved' \
  'LifeUITests/WidgetRolloverUIFixtureTests/spotlightIndexHoldsEnabledTitles()' \
  'LifeUIUITests/NativeIntegrationsUITests/testSpotlightTitleOpensItsRowThroughTheLinkBanner'; do
  name="$(basename "$selected" | tr -cd '[:alnum:]')"
  result="$results/integrations-$name.xcresult"
  xcodebuild -project "$project" -scheme LifeUI -derivedDataPath "$derived" \
    -destination "platform=iOS Simulator,id=$simulator" -parallel-testing-enabled NO \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    -resultBundlePath "$result" "-only-testing:$selected" \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 240 \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
    test-without-building > "$results/integrations-$name.log" 2>&1 || true
  xcrun xcresulttool get test-results summary --path "$result" > "$result.json"
  python3 - "$result.json" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if (result.get("passedTests"), result.get("failedTests"), result.get("skippedTests")) != (1, 0, 0):
    raise SystemExit(f"Expected exactly one passing case: {sys.argv[1]}")
PY
done
