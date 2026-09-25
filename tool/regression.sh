#!/bin/zsh
# 一轮回归门禁：zsh tool/regression.sh [--fast] [--probes]
#
# 门禁跑三件事：静态分析 + 引擎用例 + 引擎校验。诊断探针（--probes）另外算。
# 拆到进程级并行：每个部件一个进程，最重的 engine_test.dart 再按用例拆成几片，
# 探针内部再按格子并行。以前串行 40 秒以上、单文件 15 秒，现在 6~7 秒（改了 lib
# 要重编那一遍 9 秒）；加 --probes 是 20 秒（探针约 120 秒 CPU，靠并行摊平）。
#
# 用例默认交给 tool/sharded_test.sh（编译一次 + 按用例拆片）跑，而不是
# flutter test——后者只按**文件**并行，engine_test.dart 那 96 条用例它拆不开。
# 想跟 CI 完全一致地用官方命令，就设 TEST_RUNNER=flutter。
#
# 为什么快不了更多：AI 的每个决策内部都要模拟对手的牌，比例类结论只能靠
# 成千上万手重放抽出来，这些手数是实打实的 CPU 时间，没法靠少跑来省
# （门禁部分约 26 秒 CPU，10 核，墙钟下限 3 秒；实测那 26 秒里约一半是 engine_test
# 那条单文件用例：96 条里有 30 多条要重放几百手完整牌局。它还要先编译再跑，编译本身
# 就要 2.5 秒，源码没动时会被 dill 缓存省掉）。
# 再快只能 --fast 少跑用例，或者只跑你改到的那条线。
#
#   --fast            只跑结构性冒烟用例（发牌 / 牌型评估 / 存档 / 标题那十几
#                     条），要重放牌局的 AI 用例全部报成 skipped。用途是快速确认
#                     「有没有跑不起来 / 结构性错」——AI 行为有没有被改坏，它看
#                     不出来。配合 --probes 时探针样本仍会砍到 1/4。
#                     （早先这个档是「样本砍一半」，结果比例类断言稳定假失败几条，
#                      报红报得毫无参考价值，所以换成了「少跑用例」而不是「少抽样」。）
#   --probes          额外跑 6 个诊断探针（ai_probe / ai_sim 那一族）。它们只打印
#                     比例、不会让回归失败，却占掉整套里最大一块 CPU（约 110s），
#                     所以默认不跑。改完 AI 要看数字（改前 vs 改后）时再加。
#
#   PROBE_ONLY=名字    只跑名字含这个子串的探针，例如 PROBE_ONLY=ai_probe。
#                     配合下面的 AI_PROBE_SECTION 用，改完一处 AI 只要几百毫秒
#                     就能看上那一节的数字（整跑探针 42 秒，只看一节不到 1 秒）。
#                     只影响跑哪些探针，不影响用例门禁——它该跑的照跑。
#
#   AI_PROBE_SECTION=关键字
#                     ai_probe 只跑标题含这个子串的段落（其余段落连模拟都不跑）。
#                     例：AI_PROBE_SECTION=强牌的加注率 zsh tool/regression.sh --probes
#                     设了它之后 ai_probe 自动按 1 片跑（都只剩几百毫秒了，
#                     再拆片只是白付几个进程的启动开销）。
#   TEST_RUNNER=...   换一个跑用例的命令（每调一次传一个测试文件）。设成
#                     flutter 就是官方的 flutter test 跑全部用例。
#   DART=...          改 dart 可执行文件
#   改哪条试哪条        TEST_ONLY=河牌 zsh tool/sharded_test.sh test/engine_test.dart

#                     只跑名字含这个子串的用例，不分片。它不是回归门禁（只证明那

#                     一条过得去），但编辑循环里用它最省时间：全量回归的墙钟下限

#                     是「编译 2.5 秒 + 重放 5 秒」，单条基本只花编译那 2.5 秒，

#                     源码没动再跑一遍是 1 秒以内。全量那遍还是得跑。

#   TEST_SHARDS=n     单个用例文件内部拆 n 片并行（默认 8，设 1 关掉）。只对
#                     导入了 test/support/test_shard.dart 的文件生效，别的文件
#                     没有 TEST_SHARD 开关，拆片只会让几片把同一批用例各跑一遍。
#                     用例从 60 条长到 96 条之后，8 片比 5 片省 1 秒；再多就只剩
#                     flutter_tester 的启动开销了。
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
# engine_test.dart 是 96 条用例的单体（占整套回归一半以上的墙钟），而
# flutter test 只按**文件**并行、拆不开它，所以默认不用 flutter test。
# 用例之间没有共享状态，分片只改谁跑哪条，跑到的用例跟整跑逐条一致
# （对拍过 96 条：无丢失无重复），且任意一片失败整体就失败。
export TEST_SHARDS=${TEST_SHARDS:-8}
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
# verify_engine 会失败）。它们加起来约 120 秒 CPU，是全套里最贵的一块，所以
# 默认不跑：改完 AI 想快速知道自己有没有破坏行为，看这一节的门禁就够了。
#
# 要看数字（改 AI 的策略、要拿「改前 vs 改后」的比例）时加 --probes 再跑一遍。
if (( PROBES )); then
  # PROBE_ONLY 只筛「跑哪几个探针文件」，用例门禁不受它影响。改一处 AI 时
  # 常只需要看一个探针，这里省下的是另外五个探针的 CPU。
  for p in ai_vs_raise_probe ai_multi_probe ai_draw_probe ai_preflop3bet_probe \
      ai_reraise_probe ai_river_defense_probe; do
    [[ -n ${PROBE_ONLY:-} && $p != *${PROBE_ONLY}* ]] && continue
    start $p "探针 $p"
    job $p $DART tool/$p.dart
  done

  # ai_probe 是全套里最重的一个（111 格、每格 200~300 手），拆 4 片并行：每格只由一个
  # 进程跑、样本量不变，所以逐例的数字跟整跑完全一致，只是输出顺序按片重排
  # （段标题固定由第 0 片打，拼起来还是按段落读得下去）。
  #
  # AI_PROBE_SECTION 只看一节时自动退回 1 片：那一节本身几百毫秒就完了，
  # 再拆片只是多付几个 flutter/dart 进程的启动开销。
  SHARDS=${AI_PROBE_SHARDS:-4}
  [[ -n ${AI_PROBE_SECTION:-} ]] && SHARDS=1
  if [[ -z ${PROBE_ONLY:-} || ai_probe == *${PROBE_ONLY}* ]]; then
    for i in $(seq 0 $((SHARDS - 1))); do
      start ai_probe_$i "探针 ai_probe 第 $((i + 1))/$SHARDS 片"
      job ai_probe_$i env PROBE_SHARD=$i/$SHARDS $DART tool/ai_probe.dart
    done
  else
    SHARDS=0
  fi
fi

wait

# 拼回成一份：分片只换「这一格谁来跑」，逐例的数字跟整跑一致（见 probe_scale.dart）。
# 每行前面带的是「源码里的第几次输出」（见 tool/ai_probe.dart 里的 out()），按它
# 排回去，段标题才会重新贴回自己那一节——拼出来跟整跑逐字一样。直接 cat 的话段
# 标题会全挤在第 0 片那一段、行散在后面几片里，读的人根本对不上号（这些数字本来
# 就是拿来跟人对拍 AI 行为的，错位比没有还糟）。
if (( PROBES && ${SHARDS:-0} > 0 )); then
  for i in $(seq 0 $((SHARDS - 1))); do cat $LOG/ai_probe_$i.log; done \
    | grep -E '^[0-9]{6}' | LC_ALL=C sort | cut -f2- > $LOG/ai_probe.log
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
