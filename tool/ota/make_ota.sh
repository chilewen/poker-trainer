#!/bin/zsh
# 把打好的 ipa 做成「手机 Safari 点一下就能装」的 OTA 安装页。
#
#   zsh tool/ota/make_ota.sh <ipa路径> <HTTPS基础地址> [输出目录] [ipa下载地址]
#
# 第 4 个参数用来「两头分开托管」：安装页和 manifest.plist 很小，放 GitHub Pages
# 就够；ipa 有 7MB，国内从 github.io 拉经常慢到失败，就换成国内对象存储或 CDN 的
# 直链（例如 https://cdn.jsdelivr.net/gh/用户名/仓库@main/poker_trainer.ipa）。
#
# 例：
#   zsh tool/ota/make_ota.sh build/ios/ipa/poker_trainer.ipa \
#       https://yourname.github.io/poker-ota build/ota
#   zsh tool/ota/make_ota.sh build/ios/ipa/poker_trainer.ipa \
#       https://yourname.github.io/poker-ota build/ota \
#       https://cdn.jsdelivr.net/gh/yourname/poker-ota@main/poker_trainer.ipa
#
# 生成的目录直接整个传到任意 HTTPS 静态托管（GitHub Pages / Cloudflare Pages /
# 对象存储公共读）就行，手机上用 Safari 打开打印出来的链接即可安装。
#
# 注意：ipa 必须是用「包含你这台设备 UDID 的」描述文件签的（Ad Hoc 或开发包），
# 否则手机上下载完会提示无法安装。
set -e

if [ $# -lt 2 ]; then
  echo "用法: zsh tool/ota/make_ota.sh <ipa路径> <HTTPS基础地址> [输出目录]"
  exit 1
fi

IPA="$1"
BASE="${2%/}"
OUT="${3:-build/ota}"
# ipa 单独的下载地址（默认跟安装页同源）。
IPA_URL="${4:-$BASE/$(basename "$IPA")}"
[ -f "$IPA" ] || { echo "找不到 ipa: $IPA"; exit 1; }
case "$BASE" in
  https://*) ;;
  *) echo "基础地址必须以 https:// 开头（iOS 只认 HTTPS）：$BASE"; exit 1 ;;
esac

IPA_NAME=$(basename "$IPA")
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -name '*.ipa' -delete   # 清掉上一次的包，目录本身（含 .git）保留
cp "$IPA" "$OUT/$IPA_NAME"
touch "$OUT/.nojekyll"  # 别让 GitHub Pages 走 Jekyll 处理

# 从 ipa 里的 Info.plist 读出真实的应用信息，免得手写错。
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unzip -qq "$IPA" -d "$TMP"
APP=$(find "$TMP/Payload" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "ipa 里没有 Payload/*.app，包不对？"; exit 1; }
PLIST="$APP/Info.plist"
BID=$(plutil -extract CFBundleIdentifier raw "$PLIST")
VER=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
TITLE=$(plutil -extract CFBundleDisplayName raw "$PLIST" 2>/dev/null || \
        plutil -extract CFBundleName raw "$PLIST")

cat > "$OUT/manifest.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>$IPA_URL</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>$BID</string>
        <key>bundle-version</key>
        <string>$VER</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>$TITLE</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST_EOF

# 带个时间戳：iOS 会把 manifest 缓存住，同一个地址改内容它照样用旧的，
# 于是「重新发布了但手机上还是老样子」。
MANIFEST_URL="$BASE/manifest.plist?v=$(date +%Y%m%d%H%M%S)"
cat > "$OUT/install.html" <<HTML_EOF
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>安装 $TITLE</title>
<style>
  body{font-family:-apple-system,sans-serif;margin:0;padding:48px 24px;text-align:center;background:#0d1117;color:#e6edf3}
  a{display:inline-block;margin-top:24px;padding:14px 32px;background:#2f81f7;color:#fff;
    border-radius:12px;text-decoration:none;font-size:18px}
  p{color:#8b949e;font-size:14px;line-height:1.6}
</style>
</head>
<body>
  <h1>$TITLE</h1>
  <p>版本 $VER · $BID</p>
  <a href="itms-services://?action=download-manifest&amp;url=$MANIFEST_URL">安装</a>
  <p>点击后如果没反应，用 Safari 打开本页。</p>
  <details style="text-align:left;max-width:420px;margin:32px auto 0">
    <summary style="cursor:pointer;color:#8b949e">点了没反应 / 一直「等待中」？</summary>
    <p>先在 iPhone 的 Safari 里分别打开下面两个链接，确认手机能访问到文件：<br>
       第一个应该显示一段 XML，第二个应该开始下载：</p>
    <p><a href="$BASE/manifest.plist" style="padding:0;background:none;color:#2f81f7;font-size:14px">manifest.plist</a>
       ｜ <a href="$IPA_URL" style="padding:0;background:none;color:#2f81f7;font-size:14px">$IPA_NAME（下载这个）</a></p>
    <p>· 两个都打不开 → 托管没生效（GitHub Pages 没开、地址或仓库名不对）；<br>
       · 两个都能打开、但安装还是卡在「等待中」或报「无法安装」→ 这台 iPhone 的 UDID
       不在描述文件里，去 developer.apple.com → Devices 登记后重新出包。</p>
  </details>
</body>
</html>
HTML_EOF

echo "好了，把 $OUT 整个目录上传到 $BASE 对应的位置，然后在手机上打开："
echo "  $BASE/install.html"
echo "（直接打开 itms-services 链接也可以：）"
echo "  itms-services://?action=download-manifest&url=$MANIFEST_URL"
echo "ipa 下载地址：$IPA_URL"
echo "打包信息：$TITLE $VER ($BID)"
