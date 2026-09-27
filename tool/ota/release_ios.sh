#!/bin/zsh
# 出包 + 发布到 GitHub Pages，一条命令跑完。
#
#   zsh tool/ota/release_ios.sh [--bump] [--skip-build] [--dry-run]
#                              [用户名] [仓库名] [ipa单独地址]
#
#   --bump        发布前把 pubspec.yaml 的构建号 +1（0.1.0+1 → 0.1.0+2），
#                 这样手机上能看出装的是不是新包
#   --skip-build  不重新出包，直接拿 build/ios/ipa/poker_trainer.ipa 发布
#                 （只改了安装页、或者上一次出包失败后想重推时用）
#   --dry-run     只打印「会出什么包、会推到哪儿」，不真的出包/提交/推送
#
# 例：
#   zsh tool/ota/release_ios.sh --bump          # 平时就用这一条
#   zsh tool/ota/release_ios.sh chilewen poker-ota
#
# 出包用的是 Ad Hoc（付费开发者证书 + 含设备 UDID 的描述文件）；
# 想换成 development 就设 EXPORT_METHOD=development。
set -e

BUMP=0
SKIP_BUILD=0
DRY=0
POS=()
for a in "$@"; do
  case "$a" in
    --bump) BUMP=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "未知参数：$a（-h 看用法）"; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

USER_NAME="${POS[1]:-chilewen}"
REPO="${POS[2]:-poker-ota}"
IPA_URL="${POS[3]:-https://cdn.jsdelivr.net/gh/$USER_NAME/$REPO@main/poker_trainer.ipa}"
METHOD="${EXPORT_METHOD:-ad-hoc}"
IPA="build/ios/ipa/poker_trainer.ipa"

echo "仓库     $ROOT"
echo "发布到   https://$USER_NAME.github.io/$REPO/install.html"
echo "ipa 直链 $IPA_URL"
echo "签名方式 $METHOD"
echo ""

# Flutter 每次 build 都会把 ios/Flutter/ephemeral/Packages 整个删掉重建；目录里
# 有上一轮 / Xcode 留下的残留（或半删状态）时，递归删除会撞上「删到一半某个条目
# 没了」的竞态，报
#   Unable to delete file or directory at …/ephemeral/Packages/.packages
# 那句「read-only volume」是误导——判定码其实是 ENOENT（找不到文件），不是权限。
# 出包前先best-effort清干净，撞上了再清一次重试，基本就不再见了。
clean_swiftpm_packages() {
  local dir="$ROOT/ios/Flutter/ephemeral/Packages"
  [[ -e "$dir" ]] || return 0
  rm -rf "$dir" 2>/dev/null || true
}

BUILD_LOG="${TMPDIR:-/tmp}/poker_build_$$.log"
trap 'rm -f "$BUILD_LOG"' EXIT

# 构建输出照旧实时打到屏幕上，同时存一份到 $BUILD_LOG 供失败时判断原因。
# 退出码取管道里 flutter 那一截（$pipestatus[1]），别被 tee 的 0 盖掉。
build_ipa() {
  setopt local_options pipefail
  flutter build ipa --release --export-method "$METHOD" 2>&1 | tee "$BUILD_LOG"
  return ${pipestatus[1]}
}

if (( BUMP )); then
  if (( DRY )); then
    echo "（试运行）会把 pubspec.yaml 的构建号 +1"
  else
    zsh tool/ota/bump_version.sh
  fi
fi

if (( SKIP_BUILD )); then
  echo "跳过出包，直接用现有 ipa：$IPA"
elif (( DRY )); then
  echo "（试运行）会执行：flutter build ipa --release --export-method $METHOD"
else
  clean_swiftpm_packages
  if ! build_ipa; then
    if grep -q 'Unable to delete file or directory' "$BUILD_LOG" &&
       grep -q 'ephemeral/Packages' "$BUILD_LOG"; then
      echo ""
      echo "撞上 ephemeral/Packages 的删除竞态了，清干净重试一次…"
      clean_swiftpm_packages
      build_ipa || { echo "重试还是失败，日志在上面。"; exit 1; }
    else
      echo "出包失败，日志在上面。"
      exit 1
    fi
  fi
fi

if (( DRY )); then
  echo ""
  echo "（试运行）接下来会：把上面的 ipa 拷进 build/ota、重新生成安装页、"
  echo "            git commit 并 push 到 git@github.com:$USER_NAME/$REPO.git"
  exit 0
fi

[ -f "$IPA" ] || { echo "找不到 $IPA，出包没成功？"; exit 1; }

zsh tool/ota/publish_gh_pages.sh "$IPA" "$USER_NAME" "$REPO" "$IPA_URL"

echo ""
echo "手机上打开：https://$USER_NAME.github.io/$REPO/install.html"
echo "（ipa 地址已带 ?v=时间戳，CDN 缓存会自动绕开，不用再手动 purge）"
