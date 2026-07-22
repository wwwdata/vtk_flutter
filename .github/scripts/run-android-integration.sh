#!/usr/bin/env bash

set -u

log_path="$RUNNER_TEMP/vtk-flutter-android-logcat.txt"
adb logcat -c
adb logcat -v threadtime > "$log_path" &
logcat_pid=$!

cleanup() {
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
}
trap cleanup EXIT

set +e
(
  cd example
  flutter drive \
    -d emulator-5554 \
    --driver test_driver/integration_test.dart \
    --target integration_test/renderer_lab_test.dart
)
test_status=$?
set -e

if [[ "$test_status" -ne 0 ]]; then
  tail -n 2000 "$log_path"
fi

exit "$test_status"
