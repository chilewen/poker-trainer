#!/bin/zsh
# 从 pubspec.yaml 生成 lib/app_version.dart（App 里显示的版本号来源）。
#
#   zsh tool/gen_app_version.sh [pubspec路径] [输出路径]
#
# 为什么要生成一个常量文件：Flutter 运行时读不到原生版本号（要么加
# package_info_plus 插件 + pod install，要么自己写 MethodChannel），而
# 「版本号显示错了」正是我们刚踩过的坑——页面上写着新版本、装上去还是旧的。
# 生成 + 一条用例（test/app_version_test.dart）盯住它跟 pubspec 一致，
# 既不用引依赖，也不会悄悄走散。
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PUBSPEC="${1:-$ROOT/pubspec.yaml}"
OUT="${2:-$ROOT/lib/app_version.dart}"
[ -f "$PUBSPEC" ] || { echo "找不到 $PUBSPEC"; exit 1; }

RAW=$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' "$PUBSPEC" | head -1)
[ -n "$RAW" ] || { echo "pubspec.yaml 里没读到 version:（x.y.z 或 x.y.z+N）"; exit 1; }

SHORT="${RAW%%+*}"
case "$RAW" in
  *+*) BUILD="${RAW#*+}" ;;
  *)   BUILD="" ;;
esac
case "$BUILD" in
  ''|*[!0-9]*) BUILD="" ;;   # 非数字的构建号（如 1.0.3）不进 build 文字
esac

if [ -n "$BUILD" ]; then
  TEXT="$SHORT（build $BUILD）"
else
  TEXT="$SHORT"
fi

cat > "$OUT" <<DART_EOF
// 由 tool/gen_app_version.sh 从 pubspec.yaml 生成，别手改。
//
// 改版本号：用 zsh tool/ota/bump_version.sh（改完会自动重跑这个生成器），
// 或者手改 pubspec 后再跑一次 zsh tool/gen_app_version.sh。
// test/app_version_test.dart 会拿 pubspec.yaml 对一遍，走散了用例会红。

/// 完整版本，跟 pubspec 的 \`version:\` 一字不差，如 \`0.1.0+12\`。
const appVersion = '$RAW';

/// 短版本，如 \`0.1.0\`。
const appVersionShort = '$SHORT';

/// 构建号（pubspec 里 \`+\` 后面那一位），如 \`12\`；没有就是空串。
const appBuildNumber = '$BUILD';

/// 给人看的版本文字：\`0.1.0（build 12）\`。
const appVersionText = '$TEXT';
DART_EOF

echo "已生成 $OUT：$TEXT"
