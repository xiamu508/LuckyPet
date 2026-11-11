#!/bin/bash
# 原生鼠标电量模块自检；所有产物、配置与预览保留在项目 inspection 中。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$PWD/inspection/mouse-battery"
CACHE="$PWD/.cache/swift"
mkdir -p "$OUT" "$CACHE"
COMMON=(src/MouseBattery.swift src/HIDReportDescriptor.swift)

swiftc -swift-version 5 -module-cache-path "$CACHE" "${COMMON[@]}" \
    src/Preferences.swift src/MouseBatteryMonitor.swift src/PetStatusIcon.swift \
    tests/MouseBatteryTests.swift -framework Cocoa -framework IOKit -o "$OUT/unit-tests"
"$OUT/unit-tests" "$OUT"

SOURCES=()
for source in src/*.swift; do
    if [[ "$source" != src/main.swift ]]; then SOURCES+=("$source"); fi
done
swiftc -swift-version 5 -module-cache-path "$CACHE" "${SOURCES[@]}" \
    tests/MouseBatteryIntegrationTests.swift -framework Cocoa -framework AVFoundation \
    -framework UserNotifications -framework ServiceManagement -framework IOKit \
    -framework CoreBluetooth -framework IOBluetooth -framework GameController -o "$OUT/integration-tests"
LUCKY_PET_CONFIG_DIR="$OUT/integration-config" LUCKY_PET_RESOURCES="$PWD/Assets/clips" \
    "$OUT/integration-tests" "$OUT"

swiftc -swift-version 5 -module-cache-path "$CACHE" "${COMMON[@]}" \
    tests/MouseBatteryProbe.swift -framework IOKit -o "$OUT/device-probe"
"$OUT/device-probe"
