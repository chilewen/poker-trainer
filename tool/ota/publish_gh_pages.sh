#!/bin/zsh
# 一条命令把 ipa 发布到 GitHub Pages（OTA 安装页）。
#
#   zsh tool/ota/publish_gh_pages.sh <ipa路径> <github用户名> <仓库名> [ipa下载地址]
#
# 第 4 个参数可选：ipa 单独放到国内更快的地址（对象存储/CDN）时用，格式跟
# make_ota.sh 一致。github.io 在国内下载 7MB 的 ipa 经常慢到失败，就用它把
# 大文件挪走，安装页和 manifest 留在 Pages 上。
# 例：
#   zsh tool/ota/publish_gh_pages.sh build/ios/ipa/poker_trainer.ipa chilewen poker-ota
#
# 前提：这个仓库已经在 GitHub 上建好了（空的 public 仓库，不要带 README），
#       并且这台机器的 SSH key 能推代码（和 app 仓库用同一把就行）。
# 发布完去仓库 Settings → Pages 选 main / (root)，等一分钟就有网址了。
set -e

if [ $# -lt 3 ]; then
  echo "用法: zsh tool/ota/publish_gh_pages.sh <ipa路径> <github用户名> <仓库名>"
  exit 1
fi

IPA="$1"
USER="$2"
REPO="$3"
IPA_URL="$4"
BASE="https://$USER.github.io/$REPO"
OUT="${OTA_OUT:-build/ota}"
REMOTE="${OTA_REMOTE:-git@github.com:$USER/$REPO.git}"

if [ -n "$IPA_URL" ]; then
  zsh "$(dirname "$0")/make_ota.sh" "$IPA" "$BASE" "$OUT" "$IPA_URL"
else
  zsh "$(dirname "$0")/make_ota.sh" "$IPA" "$BASE" "$OUT"
fi

cd "$OUT"
if [ ! -d .git ]; then
  git init -q -b main
fi
git add -A
git commit -q -m "Poker Trainer OTA $(date '+%Y-%m-%d %H:%M')" || echo "（内容没变，跳过提交）"

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi

if ! git push -u origin main; then
  # 仓库里已经有内容（比如上次发布过）：合并一次再推，别让本地历史把远端顶掉。
  echo "推送被拒，先把远端已有内容合并进来…"
  git fetch origin main
  git merge --allow-unrelated-histories -X ours -m "merge remote" origin/main
  git push -u origin main
fi

echo ""
echo "推完了。接下来："
echo "  1) 打开 https://github.com/$USER/$REPO/settings/pages"
echo "  2) Source 选 Deploy from a branch → main → / (root) → Save"
echo "  3) 等一分钟，手机上用 Safari 打开：$BASE/install.html → 点「安装」"
