#!/bin/zsh
# OTA 发布目录里的 pre-commit 钩子：提交前自动重新生成安装页。
#
# 为什么需要它：常见的手动发布是「把新打的 ipa 拷进 build/ota → git add . →
# git commit → git push」。这条路上 make_ota.sh 根本没跑，install.html 和
# manifest.plist 还是上一次发布时生成的，于是页面上永远是旧版本号，看着像
# 「版本号一直没变化」。这个钩子会在真正生成提交对象之前重跑一次 make_ota.sh，
# 把 install.html / manifest.plist 按目录里现有的 ipa 重新写一遍并加入暂存区，
# 所以随便哪条路发布，页面上的版本都是当前这个包的。
#
# 由 publish_gh_pages.sh 自动安装到 build/ota/.git/hooks/pre-commit，
# 配置放在 build/ota/.ota.conf（那个文件是本机的，已被 .gitignore 忽略）。
set -e

OUT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
CONF="$OUT/.ota.conf"
[ -f "$CONF" ] || exit 0

OTA_TOOL=""
OTA_BASE=""
OTA_IPA_URL=""
source "$CONF"
[ -n "$OTA_TOOL" ] && [ -n "$OTA_BASE" ] || exit 0
[ -f "$OTA_TOOL/make_ota.sh" ] || exit 0

# 目录里可能压根没有 ipa（比如只改了说明文字），那就别动页面。
IPA=$(ls "$OUT"/*.ipa 2>/dev/null | head -1)
[ -n "$IPA" ] || exit 0

zsh "$OTA_TOOL/make_ota.sh" "$IPA" "$OTA_BASE" "$OUT" "$OTA_IPA_URL" >/dev/null
# add -A：make_ota.sh 会给 ipa / manifest 换带时间戳的新文件名并删掉旧的，
# 只 add 两个固定名字的话，重命名后的包根本进不了这次提交。
git -C "$OUT" add -A .
echo "[ota] 已按当前 ipa 重新生成安装页（$(grep -o '版本 [^<]*' "$OUT/install.html" | head -1)）"
