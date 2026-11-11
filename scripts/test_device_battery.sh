#!/bin/bash
# 使用确定的系统电量样例与隔离的配置，测试时不配对、不连接真实蓝牙设备。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/inspection/device-battery"
CACHE="$PWD/.cache/swift"
mkdir -p "$OUT" "$CACHE"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
    src/MouseBattery.swift src/HIDReportDescriptor.swift src/MouseBatteryMonitor.swift \
    src/BatteryDevice.swift src/BluetoothBatteryService.swift src/DeviceBatteryMonitor.swift \
    src/BatteryDevicesWindow.swift src/Preferences.swift tests/DeviceBatteryTests.swift \
    -framework Cocoa -framework IOKit -framework CoreBluetooth -framework IOBluetooth \
    -framework GameController -o "$OUT/device-tests"
LUCKY_PET_CONFIG_DIR="$OUT/test-config" "$OUT/device-tests" "$OUT"
