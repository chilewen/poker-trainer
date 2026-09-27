#!/bin/zsh
# 清掉回归跑剩的临时目录：`$TMPDIR` 里的 `poker_*` / `pt_*` 空壳（外加可选的历史遗留）。
#
#   zsh tool/clean_temp.sh          # 只删残留空壳，保留 dill 缓存和回归日志
#   zsh tool/clean_temp.sh --all    # 连 dill 缓存（$TMPDIR/poker_test_runner，约 280MB）
#                                   # 和回归日志（/tmp/poker_regression）一起删；下次回归
#                                   # 要重新编译，多花 2~3 秒
#
# 为什么会有残留：用例靠 test/support/temp_session_dir.dart 在 teardown 里「先刷盘
# 再删目录」收尾，但 teardown 只在用例正常跑完时执行——Ctrl-C 掐断、进程被 kill、
# 或者跑的是没收尾逻辑的老版本，就会在 $TMPDIR 里留下 poker_session_* / pt_* 空目录
# （实测攒到过 1970 个）。它们是空的，删掉不影响任何东西。
#
# 所以正常跑完一遍 `zsh tool/regression.sh` 本来就该一个残留不留；留了就说明有
# teardown 没收干净，这个脚本只是兜底，别拿它当日常清理。
set -u
unsetopt nomatch

TMP=${${TMPDIR:-/tmp}%/}
CACHE=$TMP/poker_test_runner
LOG=${POKER_LOG_DIR:-/tmp/poker_regression}

removed=0
for d in "$TMP"/poker_* "$TMP"/pt_*(N); do
  [[ $d == $CACHE ]] && continue
  rm -rf -- $d
  (( removed++ ))
done
print "已删 $TMP 下的 poker_*/pt_* 残留：$removed 个"

if [[ ${1:-} == --all ]]; then
  if [[ -d $CACHE ]]; then
    rm -rf -- $CACHE
    print "已删 dill 缓存 $CACHE（下次回归要重新编译）"
  fi
  if [[ -d $LOG ]]; then
    rm -rf -- $LOG
    print "已删回归日志 $LOG"
  fi
else
  print "（保留了 $CACHE 这个 dill 缓存——它是提速用的，不是残留；要一起删加 --all）"
fi
