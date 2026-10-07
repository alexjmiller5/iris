#!/usr/bin/env bash
set -euo pipefail
project="$1"
derived="$2"
simulator="$3"
results="$4"
export TEST_RUNNER_LIFE_UI_TEST_QUICK_ADD_SIMULATOR="$simulator"
for selected in \
  'LifeUITests/QuickAddUIFixtureTests/prepareQuickAddUIFixture()' \
  'LifeUIUITests/QuickAddUITests/testPendingIntentSurvivesRelaunchAndSavesOnlyOnExplicitAction' \
  'LifeUITests/QuickAddUIFixtureTests/verifyQuickAddUIReadback()'; do
  name="$(basename "$selected" | tr -cd '[:alnum:]')"
  result="$results/quick-add-$name.xcresult"
  xcodebuild -project "$project" -scheme LifeUI -derivedDataPath "$derived" \
    -destination "platform=iOS Simulator,id=$simulator" -parallel-testing-enabled NO \
    -resultBundlePath "$result" "-only-testing:$selected" \
    -collect-test-diagnostics never -test-timeouts-enabled YES \
    -maximum-test-execution-time-allowance 120 \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
    test-without-building 2>&1 | tee "$results/quick-add-$name.log"
  xcrun xcresulttool get test-results summary --path "$result" > "$result.json"
  python3 - "$result.json" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if (result.get("passedTests"), result.get("failedTests"), result.get("skippedTests")) != (1, 0, 0):
    raise SystemExit(f"Expected exactly one executed Quick Add case: {result}")
PY
done
