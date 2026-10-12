#!/bin/zsh
# 出一个能直接装到安卓手机上的 APK：
#
#   zsh tool/android/build_apk.sh [--bump] [--split] [--install]
#
#   --bump     先把 pubspec.yaml 的构建号 +1（跟 iOS 那条一样，手机上才分得清
#              装的是不是新包）
#   --split    按 ABI 拆包（arm64 的包小一半左右）。默认出通用包，省得记自己
#              手机是哪种架构
#   --install  出完直接 adb install 到连着的那台机器上（手机要开 USB 调试）
#
# 产物落在 build/android/：poker_trainer-<版本>.apk（用不上的旧包会被删掉）。
# 想传到手机自己装，把这个文件拷过去点一下就行（安卓要允许「安装未知应用」）。
#
# 签名：android/key.properties 存在就用里面的正式签名，不存在就用 debug 签名
# ——自己手机上装足够了。注意 debug 签名的包跟正式签名的包**不能互相覆盖安装**，
# 换签名之前先把手机上的旧 App 卸掉。
set -e

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BUMP=0
SPLIT=0
INSTALL=0
for arg in "$@"; do
  case $arg in
    --bump) BUMP=1 ;;
    --split) SPLIT=1 ;;
    --install) INSTALL=1 ;;
    *) echo "不认识的参数：$arg（只认 --bump / --split / --install）"; exit 1 ;;
  esac
done

if (( BUMP )); then
  zsh tool/ota/bump_version.sh
fi

# 版本号取到 apk 文件名里：手机上一个目录里躺好几个包时，一眼能看出哪个是哪版。
VERSION=$(python3 -c "
import re
print(re.search(r'^version:[ \t]*(\S+)', open('pubspec.yaml', encoding='utf-8').read(), re.M).group(1))
")

OUT=build/android
mkdir -p "$OUT"

if (( SPLIT )); then
  flutter build apk --release --split-per-abi
else
  flutter build apk --release
fi

# 只留这一次出的包：上一版的 apk 躺在同一个目录里，传文件时很容易传错。
rm -f "$OUT"/poker_trainer-*.apk
for apk in build/app/outputs/flutter-apk/app-release*.apk; do
  suffix=${${apk:t}#app-release}
  target="$OUT/poker_trainer-$VERSION$suffix"
  cp "$apk" "$target"
  echo "→ $target（$(du -h "$target" | cut -f1)）"
done

if (( INSTALL )); then
  # 通用包装在手机上没有歧义；拆包时得按手机架构挑，这里只处理通用包。
  apk="$OUT/poker_trainer-$VERSION.apk"
  [ -f "$apk" ] || { echo "拆包模式下请自己 adb install：$OUT/poker_trainer-$VERSION-*.apk"; exit 1; }
  adb install -r "$apk"
fi

echo "装到手机上：把 $OUT/poker_trainer-$VERSION.apk 传到手机（微信/AirDrop 随你），点一下装。"
