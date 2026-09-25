#!/bin/zsh
# 一轮回归门禁：zsh tool/regression.sh [--fast] [--probes]
#
# 门禁跑三件事：静态分析 + 引擎用例 + 引擎校验。诊断探针（--probes）另外算。
# 拆到进程级并行：每个部件一个进程，最重的 engine_test.dart 再按用例拆成几片。
# 以前串行 40 秒以上、单文件 15 秒，现在 5~7 秒上下。
#
# 用例默认交给 tool/sharded_test.sh（编译一次 + 按用例拆片）跑，而不是
# flutter test——后者只按**文件**并行，engine_test.dart 那 75 条用例它拆不开。
# 想跟 CI 完全一致地用官方命令，就设 TEST_RUNNER=flutter。
#
# 为什么快不了更多：AI 的每个决策内部都要模拟对手的牌，比例类结论只能靠
# 成千上万手重放抽出来，这些手数是实打实的 CPU 时间，没法靠少跑来省
# （门禁部分约 25 秒 CPU，10 核，墙钟下限 3 秒，实际 5~7 秒里最大一块还是那条
# 单文件用例：它要先编译再跑，编译本身就要 2.5 秒，源码没动时会被 dill 缓存省掉）。
# 再快只能 --fast 少跑用例，或者只跑你改到的那条线。
#
#   --fast            只跑结构性冒烟用例（发牌 / 牌型评估 / 存档 / 标题那十几
#                     条），要重放牌局的 AI 用例全部报成 skipped。用途是快速确认
#                     「有没有跑不起来 / 结构性错」——AI 行为有没有被改坏，它看
#                     不出来。配合 --probes 时探针样本仍会砍到 1/4。
#                     （早先这个档是「样本砍一半」，结果比例类断言稳定假失败几条，
#                      报红报得毫无参考价值，所以换成了「少跑用例」而不是「少抽样」。）
#   --probes          额外跑 6 个诊断探针（ai_probe / ai_sim 那一族）。它们只打印
#                     比例、不会让回归失败，却占掉整套里最大一块 CPU（约 50s），
#                     所以默认不跑。改完 AI 要看数字（改前 vs 改后）时再加。
#   TEST_RUNNER=...   换一个跑用例的命令（每调一次传一个测试文件）。设成
#                     flutter 就是官方的 flutter test 跑全部用例。
#   DART=...          改 dart 可执行文件
#   改哪条试哪条        TEST_ONLY=河牌 zsh tool/sharded_test.sh test/engine_test.dart

#                     只跑名字含这个子串的用例，不分片。它不是回归门禁（只证明那

#                     一条过得去），但编辑循环里用它最省时间：全量回归的墙钟下限

#                     是「编译 2.5 秒 + 重放 5 秒」，单条基本只花编译那 2.5 秒，

#                     源码没动再跑一遍是 1 秒以内。全量那遍还是得跑。

#   TEST_SHARDS=n     单个用例文件内部拆 n 片并行（默认 5，设 1 关掉）。只对
#                     导入了 test/support/test_shard.dart 的文件生效，别的文件
#                     没有 TEST_SHARD 开关，拆片只会让几片把同一批用例各跑一遍。
#                     实测 5 片最省墙钟，再多就只剩 flutter_tester 的启动开销了。
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
PROBES=0
for arg in "$@"; do
  case $arg in
    --fast) FAST=1 ;;
    --probes) PROBES=1 ;;
    --help|-h) sed -n '2,/^set -u/p' $0 | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "未知参数：$arg（只认 --fast / --probes）"; exit 2 ;;
  esac
done

if (( FAST )); then
  export TEST_FAST=1
  (( PROBES )) && export PROBE_SEEDS_SCALE=0.25
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

# 用例按文件拆进程并行，文件内部再按用例拆片（见 tool/sharded_test.sh）。
# engine_test.dart 是 75 条用例的单体（占整套回归一半以上的墙钟），而
# flutter test 只按**文件**并行、拆不开它，所以默认不用 flutter test。
# 用例之间没有共享状态，分片只改谁跑哪条，跑到的用例跟整跑逐条一致
# （对拍过 75 条：无丢失无重复），且任意一片失败整体就失败。
export TEST_SHARDS=${TEST_SHARDS:-5}
if [[ ${TEST_RUNNER:-} == flutter ]]; then
  start engine "引擎用例 test/*.dart（官方 flutter test）"
  job engine flutter test
else
  TEST_RUNNER=${TEST_RUNNER:-$ROOT/tool/sharded_test.sh}
  for f in $ROOT/test/*.dart; do
    b=$(basename $f .dart)
    start engine_$b "用例 $b"
    job engine_$b zsh $TEST_RUNNER $f
  done
fi

start verify "引擎校验 verify_engine"
job verify $DART tool/verify_engine.dart

# 诊断探针——**不是门禁**：它们只把比例打印出来，从不设失败码（只有
# verify_engine 会失败）。它们加起来约 50 秒 CPU，是全套里最贵的一块，所以
# 默认不跑：改完 AI 想快速知道自己有没有破坏行为，看这一节的门禁就够了。
#
# 要看数字（改 AI 的策略、要拿「改前 vs 改后」的比例）时加 --probes 再跑一遍。
if (( PROBES )); then
  for p in ai_vs_raise_probe ai_multi_probe ai_draw_probe ai_preflop3bet_probe \
      ai_reraise_probe ai_river_defense_probe; do
    start $p "探针 $p"
    job $p $DART tool/$p.dart
  done

  # ai_probe 是全套里最重的一个（96 格 × 300 手），拆 4 片并行：每格只由一个
  # 进程跑、样本量不变，所以逐例的数字跟整跑完全一致，只是输出顺序按片重排
  # （段标题固定由第 0 片打，拼起来还是按段落读得下去）。
  SHARDS=${AI_PROBE_SHARDS:-4}
  for i in $(seq 0 $((SHARDS - 1))); do
    start ai_probe_$i "探针 ai_probe 第 $((i + 1))/$SHARDS 片"
    job ai_probe_$i env PROBE_SHARD=$i/$SHARDS $DART tool/ai_probe.dart
  done
fi

wait

# 拼回成一份：分片只重排顺序，逐例的数字跟整跑一致（见 probe_scale.dart）。
if (( PROBES )); then
  for i in $(seq 0 $((SHARDS - 1))); do cat $LOG/ai_probe_$i.log; done > $LOG/ai_probe.log
fi

FAILED=0
printf '\n%-28s %-24s %6s  %s\n' 部件 说明 用时 结果
for name in $NAMES; do
  code=$(cat $LOG/$name.status 2>/dev/null || print 1)
  mark="通过"
  if [[ $code != 0 ]]; then mark="失败（见 $LOG/$name.log）"; FAILED=1; fi
  printf '%-28s %-24s %5ss  %s\n' $name $TITLE[$name] $(cat $LOG/$name.time 2>/dev/null || print 0) $mark
done
print ''
if (( ! PROBES )); then
  print "（诊断探针没跑——它们只打印数字、没有失败码，不算门禁。要看比例：zsh tool/regression.sh --probes）"
fi
if (( ! FAST )); then
  print "（这一遍是门禁全量。迭代时想省时间：TEST_ONLY=关键字 zsh tool/sharded_test.sh test/engine_test.dart 只跑改到的那条；"
  print " 只想确认没跑不起来：zsh tool/regression.sh --fast）"
fi
if (( FAILED )); then
  if (( FAST )); then
    print "（--fast 档只跑了结构性冒烟用例，AI 用例整条被跳过——行为类回归要用全量）"
  fi
  print "回归失败：日志在 $LOG"
  exit 1
fi
print "回归全部通过（用时 ${SECONDS}s）"
