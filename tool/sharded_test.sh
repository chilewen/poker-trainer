#!/bin/zsh
# 用例分片 runner：编译一次 + 按用例拆片并行，等价于 `flutter test`，但快一倍以上。
#
#   zsh tool/sharded_test.sh                        # 跑 test/*.dart
#   zsh tool/sharded_test.sh test/engine_test.dart  # 只跑一个文件
#   TEST_SHARDS=8 zsh tool/sharded_test.sh          # 拆几片（默认 8，1 = 不分片）
#   TEST_ONLY=河牌 zsh tool/sharded_test.sh        # 只跑名字含「河牌」的用例（改哪条试哪条；
#                                                 # 不分片，也不代表回归通过，只是这一条过得去）
#   zsh tool/sharded_test.sh --verbose              # 连每片的完整输出一起打
#
# 为什么不直接用 flutter test：它只按**文件**并行。test/engine_test.dart 把 121 条
# 用例塞在一个文件里，其中 30 多条要重放几百手完整的 AI 牌局，占掉整套回归一半以
# 上的墙钟，而 flutter test 对这个文件完全用不上并行。这里改用 Flutter SDK 自带的
# frontend_server + flutter_tester 直接跑：
#
#   1. 只编译一次；源码没动就连编译都省了（dill 缓存在 $TMPDIR/poker_test_runner，
#      多个测试文件也会复用同一份缓存，所以「没改代码再跑一遍」几乎零成本）；
#   2. 按用例拆片（靠 test/support/test_shard.dart 里的 TEST_SHARD=k/n）。用例之间
#      没有任何共享状态，分片只换「谁跑哪条」，跑到的用例跟整跑逐条一致（对拍过
#      121 条：无丢失无重复），任意一片失败整体就失败；
#   3. 结果以「All tests passed!」汇总行为准——flutter_tester 有用例失败时自己也
#      返回 0，照抄它的退出码等于把门禁废掉。
#
# 找不到 Flutter SDK 时回退 `flutter test`（慢，但行为跟以前完全一样）。
set -u
unsetopt bgnice   # 后台任务别 nice：沙箱里会刷一屏 operation not permitted

ROOT=${0:A:h:h}
SHARDS=${TEST_SHARDS:-8}
CACHE=${POKER_TEST_CACHE:-${TMPDIR:-/tmp}/poker_test_runner}
VERBOSE=0

typeset -a FILES
for arg in "$@"; do
  case $arg in
    --verbose|-v) VERBOSE=1 ;;
    --help|-h) sed -n '2,/^set -u/p' $0 | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) print -u2 "未知参数：$arg（只认 --verbose）"; exit 2 ;;
    *) FILES+=($arg) ;;
  esac
done
(( ${#FILES} )) || FILES=($ROOT/test/*.dart)

# ---- 定位 Flutter SDK --------------------------------------------------------
SDK=${FLUTTER_ROOT:-}
if [[ -z $SDK ]]; then
  command -v flutter >/dev/null 2>&1 || {
    print -u2 "找不到 flutter，无法跑用例"
    exit 1
  }
  SDK=$(command -v flutter)
  SDK=${SDK:A:h:h}
fi
DART_BIN=$SDK/bin/cache/dart-sdk/bin
FRONTEND=$DART_BIN/snapshots/frontend_server_aot.dart.snapshot
ENGINE=$SDK/bin/cache/artifacts/engine
SDK_ROOT=$ENGINE/common/flutter_patched_sdk
case $(uname -sm) in
  "Darwin arm64")  PLAT=darwin-arm64 ;;
  "Darwin x86_64") PLAT=darwin-x64 ;;
  "Linux aarch64") PLAT=linux-arm64 ;;
  "Linux x86_64")  PLAT=linux-x64 ;;
  *)               PLAT= ;;
esac
TESTER=$ENGINE/$PLAT/flutter_tester
if [[ ! -x $TESTER ]]; then
  typeset -a found
  found=($ENGINE/*/flutter_tester(N))
  TESTER=${found[1]:-}
fi

for need in $DART_BIN/dartaotruntime $FRONTEND $SDK_ROOT $TESTER; do
  if [[ -z $need || ! -e $need ]]; then
    print -u2 "Flutter SDK 缺件（$need），回退 flutter test"
    exec flutter test $FILES
  fi
done

# ---- 编译（带缓存）-----------------------------------------------------------
dill_of() { print $CACHE/$(basename $1 .dart).dill }

needs_compile() {
  local dill=$1
  [[ -f $dill ]] || return 0
  # -type f：只看文件。目录的 mtime 会因为「目录里增删过任何东西」而变（哪怕是
  # 一个无关的临时文件），那不说明源码变了，不值得为它重编 2.5 秒。
  [[ -n $(find $ROOT/lib $ROOT/test -type f -name '*.dart' -newer $dill 2>/dev/null | head -1) ]] ||
    [[ -n $(find $ROOT/pubspec.yaml $ROOT/.dart_tool/package_config.json \
        -type f -newer $dill 2>/dev/null | head -1) ]]
}

compile_one() {   # compile_one <源文件> <dill>
  $DART_BIN/dartaotruntime $FRONTEND \
    --sdk-root $SDK_ROOT/ --target=flutter \
    --packages $ROOT/.dart_tool/package_config.json \
    --output-dill $2 $1 > $2.compile.log 2>&1
}

# TEST_ONLY 打错字时别白等一次编译：先在源码里搜一遍这个子串。
if [[ -n ${TEST_ONLY:-} ]]; then
  hit=0
  for f in $FILES; do grep -qF -- "$TEST_ONLY" $f && hit=1; done
  if (( ! hit )); then
    print -u2 "TEST_ONLY=「$TEST_ONLY」在这些文件里根本找不到——检查一下关键字（用例名是中文全角标点）。"
    exit 1
  fi
fi

mkdir -p $CACHE
RUN=$CACHE/run.$$
mkdir -p $RUN

typeset -a NEED_COMPILE
for f in $FILES; do
  local_dill=$(dill_of $f)
  if needs_compile $local_dill; then
    NEED_COMPILE+=($f)
    ( compile_one $f $local_dill ) &
  fi
done
if (( ${#NEED_COMPILE} )); then
  print "编译 ${#NEED_COMPILE} 个测试文件…"
  wait
  for f in $NEED_COMPILE; do
    d=$(dill_of $f)
    if [[ ! -f $d ]]; then
      print -u2 "编译失败：$f"; tail -30 $d.compile.log; exit 1
    fi
  done
fi

# ---- 拆片调度 ----------------------------------------------------------------
# 一个 flutter_tester 可以挂很久（超大机器上跑满一片要几秒到几十秒），跑完还会
# 因为用例里留了定时器而不肯退出，所以不能干等：轮询日志里的汇总行，出现后只留
# 0.4 秒的收尾窗口就收掉。实测汇总行一出现，断言就已经全部打完了，多等的每一秒都是
# 白等——并行时这 2 秒是整套回归关键路径上最大的一块非计算开销（约占 6 秒里的 2 秒）。
# 真机上它自己会退，这段只是兜底。
run_tester() {   # run_tester <dill> <日志>
  FLUTTER_TEST=true $TESTER --use-test-fonts --disable-observatory $1 > $2 2>&1 &
  local pid=$! grace=0
  while (( grace < 3600 )); do
    grep -qE "All tests passed!|Some tests failed|All tests skipped|No tests ran" $2 2>/dev/null && break
    kill -0 $pid 2>/dev/null || break
    sleep 0.3
    (( grace += 0.3 ))
  done
  local hold=0
  while (( hold < 0.4 )) && kill -0 $pid 2>/dev/null; do
    sleep 0.1
    (( hold += 0.1 ))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -TERM $pid 2>/dev/null
    sleep 0.3
    kill -KILL $pid 2>/dev/null
  fi
  wait $pid 2>/dev/null
  return 0
}

typeset -a TAGS
typeset -A TAG_LOG TAG_SRC

for f in $FILES; do
  name=$(basename $f .dart)
  d=$(dill_of $f)
  # 只对「声明支持分片」的文件拆片（导入了 test/support/test_shard.dart）；别的
  # 文件没有实现 TEST_SHARD，拆片只会让几片把同一批用例各跑一遍。
  n=$SHARDS
  grep -q "support/test_shard.dart" $f || n=1
  # TEST_ONLY 已经把用例筛到个位数了，再拆片就是几片把同样那几条各跑一遍。
  [[ -n ${TEST_ONLY:-} ]] && n=1
  if (( n <= 1 )); then
    tag=$name
    TAGS+=($tag); TAG_SRC[$tag]=$f; TAG_LOG[$tag]=$RUN/$tag.log
    ( run_tester $d $RUN/$tag.log ) &
  else
    for i in $(seq 0 $((n - 1))); do
      tag=$name.$i
      TAGS+=($tag); TAG_SRC[$tag]=$f; TAG_LOG[$tag]=$RUN/$tag.log
      ( TEST_SHARD=$i/$n run_tester $d $RUN/$tag.log ) &
    done
  fi
done
wait

# ---- 汇总 --------------------------------------------------------------------
FAILED=0
for tag in $TAGS; do
  log=$TAG_LOG[$tag]
  if ! grep -qE "All tests passed!|All tests skipped|No tests ran" $log 2>/dev/null; then
    FAILED=1
    print -u2 -- "---- 片 $tag 失败（$(basename $TAG_SRC[$tag])）----"
    cat $log
  elif (( VERBOSE )); then
    print -- "---- 片 $tag ----"
    cat $log
  fi
done
if (( FAILED )); then
  print -u2 "用例失败：日志在 $RUN"
  exit 1
fi

# 每片的「通过条数」加起来就是整套跑掉的用例数，顺手打出来，省得怀疑分片漏跑。
# 跳过数取各片的**最大值**：TEST_FAST 下每条被跳过的用例在每个片里都会报一次
# skipped，加起来会翻 n 倍。
total=0
skipped=0
for tag in $TAGS; do
  got=$(grep -aoE "\+[0-9]+" $TAG_LOG[$tag] 2>/dev/null | tail -1 | tr -d "+")
  total=$((total + ${got:-0}))
  sk=$(grep -aoE "~[0-9]+" $TAG_LOG[$tag] 2>/dev/null | tail -1 | tr -d "~")
  (( ${sk:-0} > skipped )) && skipped=${sk:-0}
done
if (( total == 0 )); then
  print -u2 "注意：一条用例都没跑到（TEST_ONLY=${TEST_ONLY:-} 没命中任何用例名）——这不算回归通过。"
  exit 1
fi
if (( skipped )); then
  print "全部通过（${#TAGS} 片，共 $total 条用例，跳过 $skipped 条，用时 ${SECONDS}s）"
else
  print "全部通过（${#TAGS} 片，共 $total 条用例，用时 ${SECONDS}s）"
fi
# 跑完把这一轮的日志目录收掉：它只能放十几 KB，但一次回归一个目录，攒久了
# $TMPDIR 里会躺几百个（实测 126 个 / 224MB）。失败那条路故意不删——报错时
# 上面刚让用户去看 $RUN 里的日志。
rm -rf $RUN 2>/dev/null
exit 0
