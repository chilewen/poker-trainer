#!/bin/zsh
# 一轮回归门禁：zsh tool/regression.sh [--fast]
#
# 跑四件事：静态分析 + 引擎用例 + 引擎校验 + AI 探针。
# 拆到进程级并行：每个部件一个进程，最重的两个（用例、ai_probe）再按文件 /
# 按用例拆开。以前串行 40 秒以上，现在 14 秒上下（机器有别的负载时 16 秒）
# ——瓶颈是最长的单个用例文件 engine_test.dart，它自己就要 11~14 秒。
#
# 为什么快不了更多：AI 的每个决策内部都要模拟对手的牌，比例类结论只能靠
# 成千上万手重放抽出来，这些手数是实打实的 CPU 时间，没法靠少跑来省。
# 想再快就上 --fast 档（缩样本，只保证「跑得起来」，不保证比例稳定）。
#
#   --fast            探针样本砍到 1/4、用例砍到 1/2（全量 14s → 9s）。只看
#                     「有没有跑不起来 / 结构性错误」：比例类数字会抖（几百手
#                     抽到 ±6% 很正常），断言也可能假失败，别拿它下结论。
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

if [[ -n ${TEST_RUNNER:-} ]]; then
  # 三个用例文件互不依赖，各开一个进程：串行约 19 秒、并行约 11 秒。
  # 注意拆不到用例级——flutter test 只按文件并行，engine_test.dart 是单体。
  for f in $ROOT/test/*.dart; do
    b=$(basename $f .dart)
    start engine_$b "用例 $b"
    job engine_$b zsh $TEST_RUNNER $f
  done
else
  start engine "引擎用例 test/*.dart"
  job engine flutter test
fi

start verify "引擎校验 verify_engine"
job verify $DART tool/verify_engine.dart

for p in ai_vs_raise_probe ai_multi_probe ai_draw_probe ai_preflop3bet_probe; do
  start $p "探针 $p"
  job $p $DART tool/$p.dart
done

# ai_probe 是全套里最重的一个（68 格 × 300 手 ≈ 1.5 秒/片），拆 4 片并行：
# 每格只由一个进程跑、样本量不变，所以逐例的数字跟整跑完全一致，只是输出
# 顺序按片重排（段标题固定由第 0 片打，拼起来还是按段落读得下去）。
SHARDS=${AI_PROBE_SHARDS:-4}
for i in $(seq 0 $((SHARDS - 1))); do
  start ai_probe_$i "探针 ai_probe 第 $((i + 1))/$SHARDS 片"
  job ai_probe_$i env PROBE_SHARD=$i/$SHARDS $DART tool/ai_probe.dart
done

wait

# 拼回成一份：分片只重排顺序，逐例的数字跟整跑一致（见 probe_scale.dart）。
for i in $(seq 0 $((SHARDS - 1))); do cat $LOG/ai_probe_$i.log; done > $LOG/ai_probe.log

FAILED=0
printf '\n%-28s %-24s %6s  %s\n' 部件 说明 用时 结果
for name in $NAMES; do
  code=$(cat $LOG/$name.status 2>/dev/null || print 1)
  mark="通过"
  if [[ $code != 0 ]]; then mark="失败（见 $LOG/$name.log）"; FAILED=1; fi
  printf '%-28s %-24s %5ss  %s\n' $name $TITLE[$name] $(cat $LOG/$name.time 2>/dev/null || print 0) $mark
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
