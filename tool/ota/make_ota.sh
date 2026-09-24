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
STAMP=$(date +%Y%m%d%H%M%S)
# 换文件名来绕 CDN 缓存（jsDelivr 这类是按完整 URL 缓存的，文件名不变就会一直
# 发旧包）。以前是在地址后面挂 ?v=时间戳，结果 iOS 的 itms-services 直接罢工：
# 点「安装」毫无反应、不弹窗也不报错。所以缓存刷新全靠「换文件名」，地址里
# 一个问号都不留——这才是 23:30 那版能装成功时的地址形态。
# 名字里已经有时间戳的（对发布目录里的包重跑时）先脱掉，别叠成两个。
IPA_BASE="${IPA_NAME%.ipa}"
IPA_BASE="${IPA_BASE%-<->}"
IPA_STAMPED="$IPA_BASE-$STAMP.ipa"
MANIFEST_NAME="manifest-$STAMP.plist"
# ipa 单独的下载地址（默认跟安装页同源）；不管调用方传的是哪个名字，都换成
# 带时间戳的文件名。
IPA_URL="${4:-$BASE/$IPA_NAME}"
case "$IPA_URL" in *\?*) IPA_URL="${IPA_URL%%\?*}" ;; esac      # 丢掉历史遗留的 query
IPA_URL="${IPA_URL%/*}/$IPA_STAMPED"
mkdir -p "$OUT"
# 先把新包拷进来再清旧的：有一种常见用法是「直接对 build/ota 里这个 ipa 重跑
# make_ota」（发布目录里的 pre-commit 钩子就是这么干的），先删就会把源文件删掉。
cp "$IPA" "$OUT/$IPA_STAMPED.new"
find "$OUT" -maxdepth 1 -name '*.ipa' -delete   # 清掉上一次的包，目录本身（含 .git）保留
mv "$OUT/$IPA_STAMPED.new" "$OUT/$IPA_STAMPED"
find "$OUT" -maxdepth 1 -name 'manifest*.plist' -delete  # 旧 manifest 一并清掉
touch "$OUT/.nojekyll"  # 别让 GitHub Pages 走 Jekyll 处理

# 从 ipa 里的 Info.plist 读出真实的应用信息，免得手写错。
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# 从复制进来的那份解压：源 ipa 本身就是发布目录里的文件时（重跑/钩子场景），
# 上面已经把它改名了，原来的路径已经不存在。
unzip -qq "$OUT/$IPA_STAMPED" -d "$TMP"
APP=$(find "$TMP/Payload" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "ipa 里没有 Payload/*.app，包不对？"; exit 1; }
PLIST="$APP/Info.plist"
BID=$(plutil -extract CFBundleIdentifier raw "$PLIST")
VER=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
# 构建号也要读出来：pubspec 里 +N 那一位（bump_version.sh 加的就是它）只进
# CFBundleVersion，苹果的「短版本」永远停在 0.1.0。只看短版本的话，装了新版
# 手机上和安装页上都是 0.1.0——「版本号一直没变化」就是这么来的。
BVER=$(plutil -extract CFBundleVersion raw "$PLIST" 2>/dev/null || echo '')
VER_TEXT="$VER"
case "$BVER" in
  ''|*[!0-9]*) ;;                       # 读不到或是非数字（比如 1.0.3）就只显示短版本
  *) VER_TEXT="$VER（build $BVER）" ;;
esac
# manifest 里的 bundle-version 是 iOS 判断「有没有新版本」的依据：它跟手机上已装的
# 版本一样（或不更高）时，点「安装」会**毫无反应**——不弹窗、不报错、啥也不发生。
# 短版本永远是 0.1.0，所以把构建号拼上，变成 0.1.0.3 → 0.1.0.4 这样每次递增。
MVERSION="$VER"
case "$BVER" in
  ''|*[!0-9]*) ;;
  *) MVERSION="$VER.$BVER" ;;
esac
TITLE=$(plutil -extract CFBundleDisplayName raw "$PLIST" 2>/dev/null || \
        plutil -extract CFBundleName raw "$PLIST")

PUBLISHED=$(date '+%Y-%m-%d %H:%M')

cat > "$OUT/$MANIFEST_NAME" <<PLIST_EOF
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
        <string>$MVERSION</string>
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

# manifest 也是「一次发布一个新文件名」：iOS 会把 manifest 按地址缓存住，
# 同一个地址改了内容它照样用旧的，于是「重新发布了手机上还是老样子」。
MANIFEST_URL="$BASE/$MANIFEST_NAME"
cat > "$OUT/install.html" <<HTML_EOF
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Cache-Control" content="no-cache,no-store,must-revalidate">
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
  <p>版本 $VER_TEXT · $BID</p>
  <p>发布于 $PUBLISHED</p>
  <a href="itms-services://?action=download-manifest&amp;url=$MANIFEST_URL">安装</a>
  <p>点击后如果没反应，用 Safari 打开本页。</p>
  <details style="text-align:left;max-width:420px;margin:32px auto 0">
    <summary style="cursor:pointer;color:#8b949e">点了没反应 / 一直「等待中」？</summary>
    <p>先在 iPhone 的 Safari 里分别打开下面两个链接，确认手机能访问到文件：<br>
       第一个应该显示一段 XML，第二个应该开始下载：</p>
    <p><a href="$MANIFEST_URL" style="padding:0;background:none;color:#2f81f7;font-size:14px">$MANIFEST_NAME</a>
       ｜ <a href="$IPA_URL" style="padding:0;background:none;color:#2f81f7;font-size:14px">$IPA_STAMPED（下载这个）</a></p>
    <p>· 两个都打不开 → 托管没生效（GitHub Pages 没开、地址或仓库名不对）；<br>
       · 点「安装」完全没反应、不弹窗 → 手机上装的已经是同一个版本（iOS 认为
       没新包可装就什么都不做），把构建号 +1 重新出包再来；<br>
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
echo "打包信息：$TITLE $VER_TEXT ($BID)"
