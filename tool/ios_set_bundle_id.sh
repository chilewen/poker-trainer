#!/usr/bin/env bash
# 修改 iOS 的 Bundle ID 与开发团队，然后本地校验工程文件。
#
# 用法：
#   tool/ios_set_bundle_id.sh <新BundleId> [TeamId]
# 例：
#   tool/ios_set_bundle_id.sh com.tcgroup.pokertrainer LQG3344N2G
#
# 说明：
#   - 主 target 与 RunnerTests 一起改（RunnerTests 自动变成 <新BundleId>.RunnerTests）
#   - DEVELOPMENT_TEAM 省略时保留原值
#   - 改完请务必重新出包：flutter build ipa --release --export-method ad-hoc
#   - 换包名后 Xcode 会自动创建新的 App ID；Ad Hoc 描述文件需要用新 App ID 重新
#     生成一次（设备 UDID 不变），否则安装会失败。
set -euo pipefail

PBX="$(cd "$(dirname "$0")/.." && pwd)/ios/Runner.xcodeproj/project.pbxproj"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "用法: $0 <新BundleId> [TeamId]" >&2
  exit 2
fi

NEW_ID="$1"
NEW_TEAM="${2:-}"

if [[ ! "$NEW_ID" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "❌ Bundle ID 格式不对：$NEW_ID（例：com.tcgroup.pokertrainer）" >&2
  exit 2
fi

[[ -f "$PBX" ]] || { echo "❌ 找不到 $PBX" >&2; exit 1; }

OLD_ID="$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' "$PBX" | sed -E 's/.*= ([^;]+);.*/\1/' | sed -E 's/\.RunnerTests$//')"
OLD_TEAM="$(grep -m1 'DEVELOPMENT_TEAM = ' "$PBX" | sed -E 's/.*= ([^;]+);.*/\1/')"

echo "原 Bundle ID : $OLD_ID"
echo "新 Bundle ID : $NEW_ID"
echo "原 Team      : $OLD_TEAM"
[[ -n "$NEW_TEAM" ]] && echo "新 Team      : $NEW_TEAM"

python3 - "$PBX" "$OLD_ID" "$NEW_ID" "$NEW_TEAM" <<'PY'
import re, sys

path, old_id, new_id, new_team = sys.argv[1:5]
src = open(path, encoding='utf-8').read()

# 纯子串替换：com.x.y 会被替换，com.x.y.RunnerTests 同时变成 <新>.RunnerTests
changed_id = src.count(old_id)
src = src.replace(old_id, new_id)

changed_team = 0
if new_team:
    new_src, n = re.subn(r'(DEVELOPMENT_TEAM = )[^;]+(;)', r'\g<1>' + new_team + r'\g<2>', src)
    changed_team = n
    src = new_src

open(path, 'w', encoding='utf-8').write(src)
print(f"替换 Bundle ID 出现次数: {changed_id}")
if new_team:
    print(f"替换 DEVELOPMENT_TEAM 出现次数: {changed_team}")
PY

plutil -lint "$PBX"

echo "✅ 完成。现在的值："
grep -n 'PRODUCT_BUNDLE_IDENTIFIER = \|DEVELOPMENT_TEAM = ' "$PBX" | sed 's/^/   /'
echo
echo "下一步：flutter build ipa --release --export-method ad-hoc"
