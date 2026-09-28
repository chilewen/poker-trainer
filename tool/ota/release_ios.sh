#!/bin/zsh
# 出包 + 发布到 GitHub Pages，一条命令跑完。
#
#   zsh tool/ota/release_ios.sh [--bump] [--skip-build] [--dry-run]
#                              [用户名] [仓库名] [ipa单独地址]
#
#   --bump        发布前把 pubspec.yaml 的构建号 +1（0.1.0+1 → 0.1.0+2），
#                 这样手机上能看出装的是不是新包
#   --skip-build  不重新出包，直接拿 build/ios/ipa/poker_trainer.ipa 发布
#                 （只改了安装页、或者上次出包其实没问题想重推时用）
#                 ⚠ 它不会重新编译：改了 Dart 代码却用它发布，推上去的还是旧包。
#                 make_ota.sh 会拿 ipa 构建号跟 pubspec 对一下来兜底，但别指望它。
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

# 读 ipa 里的构建号（CFBundleVersion）。读不到就返回空串。
ipa_build_number() {
  [[ -f "$IPA" ]] || return 0
  local tmp plist
  tmp=$(mktemp -d)
  unzip -qq -o "$IPA" "Payload/*/Info.plist" -d "$tmp" 2>/dev/null
  plist=$(find "$tmp/Payload" -maxdepth 2 -name Info.plist 2>/dev/null | head -1)
  [[ -n "$plist" ]] && plutil -extract CFBundleVersion raw "$plist" 2>/dev/null
  rm -rf "$tmp"
}

# pubspec.yaml 里 `version: x.y.z+N` 的那个 N。
pubspec_build_number() {
  sed -n 's/^version:[[:space:]]*[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*+\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
    "$ROOT/pubspec.yaml" | head -1
}

# 出包失败时光看 flutter 那几十行日志很难定位。这里把 flutter 的输出和 Xcode 自己
# 写的那套导出日志一起翻一遍——真正的失败原因（尤其签名）基本只在后者里——翻译成人话。
explain_build_failure() {
  local -a logs
  local d
  [[ -f "$BUILD_LOG" ]] && logs+=("$BUILD_LOG")
  d=$(ls -dt "${TMPDIR:-/tmp}"/Runner_*.xcdistributionlogs 2>/dev/null | head -1)
  [[ -n "$d" ]] && logs+=("$d"/*.log)
  (( ${#logs} )) || return 0

  if grep -qE 'No Accounts|No "iOS Distribution" signing certificate|No signing certificate' \
       "${logs[@]}" 2>/dev/null; then
    echo ""
    echo "✗ 导出这一步签名挂了：Xcode 找不到可用的 Apple Distribution 证书。"
    echo "  常见原因：Xcode 里没有登录 Apple ID（Settings → Accounts），或者登录状态"
    echo "  过期了——证书、描述文件就同步不下来。去 Xcode → Settings → Accounts 看一眼"
    echo "  那个 Apple ID 是不是有黄色警告，有就重新登录；也可以先开 Xcode → Window →"
    echo "  Organizer 手动 Distribute App 导一遍，能过再回来跑本脚本。"
    echo "  ⚠ 这个报错在 Codex 沙箱里是假的：沙箱读不到钥匙串，xcodebuild 必然说没账号。"
    echo "     要判断真伪，请在自己的终端里重跑一遍。"
    echo "  ⚠ 在这一步修好之前，build/ios/ipa/ 里躺的一直是上一次的旧包，"
    echo "     千万别 --skip-build 发布、也别手动跑 make_ota.sh，发出去手机装的还是旧 App。"
  elif grep -qE 'missing the required UUID|Failed to load profile' "${logs[@]}" 2>/dev/null; then
    echo ""
    echo "✗ 描述文件读不出来（Profile is missing the required UUID property）。"
    echo "  先在 ~/Library/Developer/Xcode/UserData/Provisioning Profiles 里确认没有"
    echo "  0 字节或半截的残留文件，再到 Xcode → Settings → Accounts 重新下载描述文件。"
    echo "  （同样地：沙箱里读不到钥匙串，这个错也不可信。）"
  elif grep -qE 'EXPORT FAILED|exportArchive' "${logs[@]}" 2>/dev/null; then
    echo ""
    echo "✗ 归档成功但导出 ipa 失败（exportArchive 挂了）。"
    echo "  完整原因在 $d 里，重点看 IDEDistributionProvisioning.log 和"
    echo "  IDEDistribution.critical.log 这两份。"
  fi
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
  # App 里显示的版本号常量跟 pubspec 同步一次再出包，省得装上去还是旧版号。
  zsh "$ROOT/tool/gen_app_version.sh" >/dev/null
  clean_swiftpm_packages
  if ! build_ipa; then
    if grep -q 'Unable to delete file or directory' "$BUILD_LOG" &&
       grep -q 'ephemeral/Packages' "$BUILD_LOG"; then
      echo ""
      echo "撞上 ephemeral/Packages 的删除竞态了，清干净重试一次…"
      clean_swiftpm_packages
      build_ipa || { explain_build_failure; echo "重试还是失败，日志在上面。"; exit 1; }
    else
      explain_build_failure
      echo "出包失败，日志在上面。"
      exit 1
    fi
  fi

  # flutter build ipa 在「归档成功、导出失败」时退出码有时仍是 0，错误只打在某几行日志里。
  # 脚本要是信了退出码，就会继续拿 build/ios/ipa 里上一次的旧包去发布，线上只会看到
  # 「ipa 跟上次一样」。所以这里不看出厂状态，直接核 ipa 的构建号是不是这一版。
  PUB_BUILD=$(pubspec_build_number)
  IPA_BUILD=$(ipa_build_number)
  if [[ -n "$PUB_BUILD" && "$IPA_BUILD" != "$PUB_BUILD" ]]; then
    echo ""
    echo "✗ 出包过程没报错，但 ipa 没更新：build/ios/ipa 里是 build ${IPA_BUILD:-读不到}，"
    echo "  pubspec.yaml 已经是 +$PUB_BUILD。多半是「归档成功、导出失败」，而 flutter 的"
    echo "  退出码还是 0。"
    explain_build_failure
    exit 1
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
echo "（ipa / manifest 每发一次都换带时间戳的新文件名，CDN 缓存会自动绕开；"
      "安装页上的「包指纹」就是这份 ipa 的 sha256 前 12 位，装完对不上说明下的是旧包）"
