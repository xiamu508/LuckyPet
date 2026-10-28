#!/bin/bash
# 构建 LuckyPet.app（原生 macOS 桌宠 + 久坐提醒）
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/LuckyPet.app"
BIN="LuckyPet"
SRC="src"
CACHE="$PWD/.cache/swift"
mkdir -p "$CACHE"
export CLANG_MODULE_CACHE_PATH="$CACHE"

python3 scripts/verify_assets.py

echo "== 1/6 编译 =="
swiftc -swift-version 5 -O -module-cache-path "$CACHE" -o "$BIN" "$SRC"/*.swift \
    -framework Cocoa -framework AVFoundation \
    -framework UserNotifications -framework ServiceManagement

echo "== 2/6 准备图标 =="
# 复用项目内的原版图标；只有图标缺失时才重新生成。
if [ ! -f icon_work/AppIcon.icns ]; then
    if [ ! -f icon_work/icon_1024.png ]; then
        swiftc -O -module-cache-path "$CACHE" icon_work/gen_icon.swift -o icon_work/gen_icon
        ./icon_work/gen_icon
    fi
    ICONSET="icon_work/LuckyPet.iconset"
    mkdir -p "$ICONSET"
    for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" \
                "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
        size="${spec%% *}"; name="${spec##* }"
        sips -z "$size" "$size" icon_work/icon_1024.png --out "$ICONSET/icon_$name.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o icon_work/AppIcon.icns
fi

echo "== 3/6 组装 .app =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LuckyPet"
cp Info.plist "$APP/Contents/Info.plist"
cp icon_work/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp NOTICE.md LICENSE "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/THIRD_PARTY"
cp THIRD_PARTY/Real-ESRGAN-LICENSE "$APP/Contents/Resources/THIRD_PARTY/"
cp Assets/hd_manifest.json "$APP/Contents/Resources/hd_manifest.json"

echo "== 4/6 复制动画素材 =="
rsync -a Assets/clips/ "$APP/Contents/Resources/clips/"

echo "== 5/6 ad-hoc 签名 =="
codesign --force --deep --sign - "$APP" 2>&1 | tail -2

echo "== 6/6 完成 =="
du -sh "$APP"
echo "产物: $(pwd)/$APP"
