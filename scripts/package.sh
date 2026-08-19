#!/bin/bash
#
# 打包 + 签名 + 公证 MacOSMonitorApp
#
# 用法：
#   export APPLE_ID="你的 Apple ID 邮箱"
#   export NOTARY_PASSWORD="你的 App 专用密码"
#   ./scripts/package.sh
#
# （密码通过环境变量传入，不会写进脚本/历史记录）

set -euo pipefail

# ==== 配置（按需修改）====
APP_NAME="MacOSMonitorApp"
BUNDLE_ID="com.zhangenyang.macosmonitor"
VERSION="1.1.0"
# ========================

# 透传给 swift build 的额外参数（如沙箱受限环境下需要 --disable-sandbox）
SWIFT_BUILD_FLAGS="${SWIFT_BUILD_FLAGS:-}"

APPLE_ID="${APPLE_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

# 签名身份：优先用环境变量，否则自动从钥匙串检测（不硬编码姓名/Team ID）
DEVELOPER_ID="${DEVELOPER_ID:-}"
TEAM_ID="${TEAM_ID:-}"

if [[ -z "$DEVELOPER_ID" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"Developer ID Application: [^"]+"' | head -1 | sed 's/^"//; s/"$//')
fi
if [[ -z "$TEAM_ID" && -n "$DEVELOPER_ID" ]]; then
    TEAM_ID=$(echo "$DEVELOPER_ID" | grep -oE '\([^)]*\)' | tail -1 | tr -d '()')
fi

if [[ -z "$DEVELOPER_ID" ]]; then
    echo "错误：找不到 Developer ID 证书。" >&2
    echo "请先安装证书，或用环境变量指定：" >&2
    echo "  export DEVELOPER_ID='Developer ID Application: 你的名字 (TEAMID)'" >&2
    echo "  export TEAM_ID='TEAMID'" >&2
    exit 1
fi
echo "签名身份：$DEVELOPER_ID"

cd "$(dirname "$0")/.."

echo "==> 1/6 构建 release"
swift build -c release $SWIFT_BUILD_FLAGS

echo "==> 2/6 打包 .app"
APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Mac 能耗监控</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 3/6 签名（hardened runtime + 时间戳）"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -z "$APPLE_ID" || -z "$NOTARY_PASSWORD" ]]; then
    echo ""
    echo "已完成签名（未公证）。要继续公证，请先："
    echo "  export APPLE_ID=\"你的邮箱\""
    echo "  export NOTARY_PASSWORD=\"你的 App 专用密码\""
    echo "再重跑本脚本。"
    exit 0
fi

echo "==> 4/6 提交公证（zip 后提交）"
ZIP="build/${APP_NAME}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

echo "==> 5/6 钉票（把公证票据钉进 .app）"
xcrun stapler staple "$APP"

echo "==> 6/6 重新打包分发 zip（含票据）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "完成 ✅"
echo "  可分发文件：${ZIP}"
echo "  验证："
spctl -a -vv "$APP"
