#!/bin/zsh
# 一轮回归门禁：zsh tool/regression.sh [--fast]
#
# 跑四件事：静态分析 + 引擎用例 + 引擎校验 + AI 探针。
# 这几件事互不依赖，所以并行跑——以前串行要 40 秒以上，现在 20 秒上下。
#
#   --fast            样本砍到 1/4。只看「有没有跑不起来 / 结构性错误」，
#                     比例类数字会抖（几百手抽到 ±6% 很正常），别拿它下结论。
#   TEST_RUNNER=...   用离线编译档跑用例，例如 zsh 里没有 flutter 的沙箱：
#                       TEST_RUNNER=/tmp/probe/run.sh zsh tool/regression.sh
#   DART=...          改 dart 可执行文件
#
# 注意：探针用 `dart <file>` 而不是 `dart run <file>`。dart run 每次都
# 重新打包 native assets（改写 .dart_tool/lib/*.dylib），几个探针并行会互相
# 踩坏签名；这几个探针没有原生依赖，直接跑脚本文件既快又安全。
#
# 每个部件的完整输出在 $POKER_LOG_DIR（默认 /tmp/poker_regression）下。
set -u
unsetopt bgnice   # 后台任务别 nice，沙箱里会刷一屏 operation not permitted
ROOT=${0:A:h:h}
LOG=${POKER_LOG_DIR:-/tmp/poker_regression}
DART=${DART:-dart}

FAST=0
for arg in "$@"; do
  case $arg in
    --fast) FAST=1 ;;
    --help|-h) sed -n '2,/^set -u/p' $0 | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "未知参数：$arg（只认 --fast）"; exit 2 ;;
  esac
done

if (( FAST )); then
  export PROBE_SEEDS_SCALE=0.25
  export TEST_SEEDS_SCALE=0.5
fi

mkdir -p $LOG   # 每个部件的日志都是覆盖写，不用先清目录

typeset -a NAMES
typeset -A TITLE

start() {  # start <短名> <说明>
  NAMES+=($1); TITLE[$1]=$2
}
# 每个部件在后台跑：正文进 .log，退出码进 .status，自己那段的用时进 .time。
# 用时必须在子任务里记——在主 shell 里减就成了「从开始到全部结束」。
job() {    # job <短名> <命令...>
  local name=$1; shift
  (
    cd $ROOT
    local t0=$SECONDS
    "$@" > $LOG/$name.log 2>&1
    print $? > $LOG/$name.status
    print $((SECONDS - t0)) > $LOG/$name.time
  ) &
}

start analyze "静态分析 lib test tool"
job analyze $DART analyze lib test tool

start engine "引擎用例 test/*.dart"
if [[ -n ${TEST_RUNNER:-} ]]; then
  job engine zsh -c "for f in $ROOT/test/*.dart; do zsh $TEST_RUNNER \$f || exit 1; done"
else
  job engine flutter test
fi

start verify "引擎校验 verify_engine"
job verify $DART tool/verify_engine.dart

for p in ai_probe ai_vs_raise_probe ai_multi_probe ai_draw_probe ai_preflop3bet_probe; do
  start $p "探针 $p"
  job $p $DART tool/$p.dart
done

wait

FAILED=0
printf '\n%-20s %-24s %6s  %s\n' 部件 说明 用时 结果
for name in $NAMES; do
  code=$(cat $LOG/$name.status 2>/dev/null || print 1)
  mark="通过"
  if [[ $code != 0 ]]; then mark="失败（见 $LOG/$name.log）"; FAILED=1; fi
  printf '%-20s %-24s %5ss  %s\n' $name $TITLE[$name] $(cat $LOG/$name.time 2>/dev/null || print 0) $mark
done
print ''
if (( FAILED )); then
  if (( FAST )); then
    print "（--fast 档下用例缩到 1/2，比例类断言偶发假失败，先看是不是改了行为）"
  fi
  print "回归失败：日志在 $LOG"
  exit 1
fi
print "回归全部通过（用时 ${SECONDS}s）"
