// 定向试探 AI 的单点决策：dart tool/ai_probe.dart
// 用固定底牌 / 公共牌 + 英雄脚本，跑很多个随机种子，
// 看电脑玩家在各种局面的动作分布是否合理。
//
// 只跑其中一节（改完一处 AI 时最常用）：
//   AI_PROBE_SECTION=强牌的加注率 dart tool/ai_probe.dart
// 段落名就是源码里 `sec('== xx ==')` 的 xx，grep "== " tool/ai_probe.dart 可列全。
// 单价取决于这一节有多少格：轻的一节几十毫秒，河牌防守那一族单进程要 7~15 秒，
// 所以走 zsh tool/regression.sh --probes 时它会照样按格子拆 8 片并行。
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';

import 'probe_scale.dart';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();

/// 只跑标题含这个子串的段落（`AI_PROBE_SECTION=关键字`）。
///
/// 用途是改完 AI 之后只看相关的那几格：整跑要重放全部格子（42 秒上下，
/// 回归里会按格子拆片并行），只看一节就是这一节的格数那么多。没命中的段落
/// 连模拟都不跑——在 [_sample] 里直接短路返回 skipped，省的是实打实的 CPU，
/// 不是只把打印关掉。正因为它是在 [_sample] 里短路的，带着过滤**也可以拆片**：
/// 不归本片、或不合关键字的格子同样走这条短路，拼回来跟整跑逐字一致。
///
/// 段落 = 最近一个以 `==` 开头的标题行（`sec('')` 的空行分隔、`-- xx --`
/// 这种子标题都不改变当前段落），标题含这个子串就算命中。不设这个变量时
/// 输出跟以前逐字一致。
final String _sectionFilter =
    Platform.environment['AI_PROBE_SECTION'] ?? '';
String _section = '';

/// 过滤关键字有没有命中过任何段落标题——一个字都没命中时给个提示，
/// 免得看到空输出还以为探针坏了。
bool _sectionMatched = false;

bool get _sectionActive =>
    _sectionFilter.isEmpty || _section.contains(_sectionFilter);

class _Result {
  final Map<String, int> counts = {};
  int total = 0;

  /// 并行分片时「这一格不归本片跑」——注意跟 total==0（真收不到样本，
  /// 比如 AI 翻前就弃掉的格子）不是一回事，分片时两者都不能当对方用。
  bool skipped = false;

  /// [requireSelfFire] 的格子专用：有多少个种子真的走到了那个记录点。
  /// 那些种子里的其余部分被「AI 自己没连开两枪」滤掉了——分母缩了多少
  /// 必须让看数字的人知道。不设这个开关时它恒等于 [total]，[_reachNote]
  /// 是空串，输出逐字不变。
  int reached = 0;

  String get _reachNote => reached > total
      ? '  [${(100 * total / reached).toStringAsFixed(0)}% 的种子触发，'
          '共 $reached 手走到这一街]'
      : '';

  /// [pot] = 决策时的底池，[ref] = 加注前的最高注（下注时为 0），
  /// [allIn] = 这一手把剩下的筹码全放进去了。
  /// 下注/加注不按绝对筹码分类，而是按「相对底池的档位」（5% 一档）——
  /// 尺度混合之后同一个局面会有好几档尺寸，绝对数字看着就是一团乱麻。
  ///
  /// 加注记的是**比跟注多投进去的那一份**（`amountTo - ref`），不是加注总额。
  /// 全下必须单独标出来：筹码浅的时候 [_raise]/[_bet] 想要的额度会被引擎夹到
  /// 「全部筹码」，那时比跟注多投的那一份可能只剩底池的 5~10%，读起来像
  /// 「他加了个零头」，其实是推了。不标的话会得出「AI 在造一个比对方下注
  /// 还小的加注」这种不存在的结论（实测：河牌面对连开三枪的那几格，
  /// 标着 `~5%池` / `~10%池` 的加注全是全下，`amountTo == maxTo == stack`）。
  void add(AiDecision d, {required int pot, required int ref, bool allIn = false}) {
    total++;
    var key = d.type.label;
    if ((d.type == ActionType.bet || d.type == ActionType.raise) && pot > 0) {
      final frac = ((d.amountTo ?? 0) - ref) / pot;
      final bucket = (frac * 20).round() / 20;
      key = '${d.type.label} ~${(100 * bucket).toStringAsFixed(0)}%池'
          '${allIn ? '(全下)' : ''}';
    }
    counts[key] = (counts[key] ?? 0) + 1;
  }

  @override
  String toString() {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .map((e) =>
            '${e.key} ${(100 * e.value / total).toStringAsFixed(0)}%')
        .join('  |  ');
  }
}

/// 单挑牌桌：player0 = AI（按钮/小盲），player1 = 英雄（大盲）。
/// [heroFirst] 指定英雄在每条街的第一次行动，其余时候一律跟注。
/// 记录 AI 在 [target] 街的第一次决策。
///
/// [oop] = true 时把按钮换给英雄，AI 坐大盲（没位置），翻牌得先过牌——
/// 用来对比同一个局面下有/没位置的差别。
/// [facingOnly] = true 时只记录「面对下注/加注」的那次决策，不然没位置
/// 这一侧记录到的都是「先说话时怎么打」，比不出面对下注的应对。
///
/// [preflopScript] 是「开场脚本」：在 AI 开始决策之前按顺序替双方把翻前
/// 动作走完。翻前的线是**读盘的前提**（谁开的池、AI 是不是翻前主动方），
/// 有位置/没位置两张桌子如果连翻前线都不一样，后面所有的对比都被污染了。
///
/// [aiScript] 是同一套东西的翻后版：把 AI 在 **target 街之前**的动作也钉死。
/// 不钉的话「转牌/河牌面对下注」这类格子量的其实是**一堆不同局面的平均**——
/// 有些手牌 AI 在翻牌就反加了，底池和 SPR 跟着全变，同一个「面对 1/2 池」
/// 在不同种子里根本不是一个场景（实测河牌那一格：200 手里有十几种底池）。
/// 只写 target 街之前的街；给 target 街写会被跳过、那格就没有样本。
///
/// [requireSelfFire] 是这套脚本的反面：target 街之前**不钉**，让 AI 自己打，
/// 但只统计「AI 自己把前面每条街都开火（下注/加注）过」的那些种子。用来量
/// 依赖 AI 自身状态的线——最关键的是诈唬线的跨街延续：脚本钉死的开火走的是
/// 引擎 `apply`，不经过 [AiPlayer.decide]，AI 也就没登记跨街计划，量出来的
/// 河牌第三枪是「没有这条线」的版本（实测同一手破花 A 高：19% vs 真实路径
/// 40%）。代价是样本被 AI 自己的前置决策筛过、每手触发率不同（跟着打印在
/// 行尾），所以只适合「同一手牌、改前 vs 改后」自比，别横向比两手不同牌。
typedef _Step = ({String who, ActionType type, int? amount});
typedef _AiStep = ({Street street, ActionType type, int? amount});

_Result _sample({
  required String hole,
  required String heroHole,
  required String board,
  required Street target,
  Map<Street, ({ActionType type, double frac})> heroFirst = const {},
  List<_Step> preflopScript = const [],
  List<_AiStep> aiScript = const [],
  int seeds = 300,
  AiStyle style = AiStyle.tightAggressive,
  int stack = 10000,
  int bb = 100,
  bool oop = false,
  bool facingOnly = false,
  bool requireSelfFire = false,
}) {
  // 分片键只由「这是哪个局面」组成，故意不含 oop / preflopScript：
  // pos() 的有/没位置是同一格的两条线，必须落在同一片，不然两条线会被
  // 拆到不同进程、拼回来的对照就不成对了。
  final shardKey = '$hole|$heroHole|$board|$target|$style|'
      '${heroFirst.entries.map((e) => '${e.key}:${e.value.type}:${e.value.frac}').join(',')}'
      '|${aiScript.map((e) => '${e.street}:${e.type}:${e.amount}').join(',')}';
  if (!probeShardMine(shardKey)) return _Result()..skipped = true;
  // 段落过滤（AI_PROBE_SECTION）没命中的格子直接不跑：这是「只重放相关
  // 那几格」的关键，光过滤打印省不下模拟的 CPU。
  if (!_sectionActive) return _Result()..skipped = true;

  final res = _Result();
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: GameConfig(startingStack: stack, smallBlind: bb ~/ 2, bigBlind: bb),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    final ai = AiPlayer(style, random: rnd);
    final boardCards = cs(board);
    if (oop) g.buttonIndex = 0; // startHand 里 +1 → 英雄坐按钮
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs(heroHole)},
      boardOverride: boardCards,
    );

    // 开场脚本：替双方把翻前动作走完，把「翻前线」这个变量固定住。
    for (final st in preflopScript) {
      g.apply(st.who, st.type, amount: st.amount);
    }

    // AI 脚本：target 街之前按配置走，走完（或者没配到这条街）才轮到它自己决策。
    final aiSteps = <Street, List<_AiStep>>{};
    for (final st in aiScript) {
      (aiSteps[st.street] ??= []).add(st);
    }
    final aiUsed = <Street, int>{};

    // 英雄脚本：每条街第一次行动按配置，之后跟注。
    final acted = <Street, int>{};
    if (preflopScript.isNotEmpty) acted[Street.preflop] = 99;
    var guard = 0;
    var recorded = false;
    var targetReached = false; // 这个种子有没有走到记录点（[requireSelfFire] 要看分母）
    var selfFired = true; // AI 在 target 街之前有没有自己把每条街都开火过
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      if (p.player.id == 'ai') {
        // 钉住的动作先走：类型不合法就退化成过牌/跟注，跟英雄脚本一个规矩。
        final forced = aiSteps[g.street];
        final used = aiUsed[g.street] ?? 0;
        if (forced != null && used < forced.length) {
          aiUsed[g.street] = used + 1;
          final f = forced[used];
          var type = f.type;
          if (!legal.any((a) => a.type == type)) {
            type = legal.any((a) => a.type == ActionType.check)
                ? ActionType.check
                : (legal.any((a) => a.type == ActionType.call)
                    ? ActionType.call
                    : legal.first.type);
          }
          final la = legal.firstWhere((a) => a.type == type);
          // [amount] 是「到本街的总额」（引擎语义）。留空时默认 2/3 池：
          // 脚本要能写「AI 在翻牌/转牌自己开一枪」，而脚本是接在翻前之后
          // 跑的，底池得顺着前面的动作算，没法在字面量里写死一个绝对数。
          // 以前留空取 la.minAmount，等于只能写「最小注」——正常的开火线
          // 一格都量不出来，而「听牌转诈唬」整条线全在开火上。
          int? target;
          if (la.type == ActionType.bet || la.type == ActionType.raise) {
            final base =
                la.type == ActionType.raise ? g.currentBet : p.player.streetBet;
            target = f.amount ?? base + (g.potTotal() * 2 / 3).round();
          }
          final sized = target?.clamp(la.minAmount, la.maxAmount);
          g.apply('ai', la.type, amount: sized);
          continue;
        }
        final d = ai.decide(g, p.player);
        final facing = g.currentBet > p.player.streetBet;
        final atTarget = g.street == target && (!facingOnly || facing);
        if (requireSelfFire &&
            g.street.index < target.index &&
            d.type != ActionType.bet &&
            d.type != ActionType.raise) {
          selfFired = false; // 前面有一条街是过牌/跟注，这条诈唬线没连起来
        }
        if (atTarget && !targetReached) {
          targetReached = true;
          res.reached++;
        }
        if (!recorded && atTarget && (!requireSelfFire || selfFired)) {
          recorded = true;
          // 这一手是不是把筹码全放进去（引擎把额度夹到 maxAmount）。用来给
          // 「加注 ~5%池」那种读数加个 `(全下)` 标记，见 [_Result.add]。
          final amountCap = legal
              .where((a) => a.type == d.type)
              .firstOrNull
              ?.maxAmount;
          final allIn = d.amountTo != null &&
              amountCap != null &&
              d.amountTo! >= amountCap;
          res.add(
            d,
            pot: g.potTotal(),
            ref: d.type == ActionType.bet ? p.player.streetBet : g.currentBet,
            allIn: allIn,
          );
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final n = acted[g.street] ?? 0;
      acted[g.street] = n + 1;
      final cfg = n == 0 ? heroFirst[g.street] : null;
      var type = cfg?.type ?? ActionType.check;
      var amount = 0;
      if (type == ActionType.check && !legal.any((a) => a.type == type)) {
        type = ActionType.call;
      }
      if (type == ActionType.bet || type == ActionType.raise) {
        final frac = cfg?.frac ?? 0.5;
        final pot = g.potTotal();
        final target = type == ActionType.bet
            ? p.player.streetBet + (pot * frac).round()
            : g.currentBet + (pot * frac).round();
        amount = target;
      }
      final la = legal.firstWhere((a) => a.type == type,
          orElse: () => legal.firstWhere((a) => a.type == ActionType.check,
              orElse: () =>
                  legal.firstWhere((a) => a.type == ActionType.call,
                      orElse: () => legal.first)));
      final sized = la.type == ActionType.bet || la.type == ActionType.raise
          ? amount.clamp(la.minAmount, la.maxAmount)
          : null;
      g.apply(p.player.id, la.type, amount: sized);
    }
  }
  return res;
}

void main() {
  // 并行分片（PROBE_SHARD=k/n）下：段标题只有第 0 片打，免得四份 log 拼起来
  // 每个标题重复四遍；每条用例只由「分到它的那一片」打印。整跑时这里全部
  // 走默认分支，输出跟以前一模一样。
  //
  // 但光这样拼不回去：每个进程都按同一份 main() 顺序走了一遍，所以「这是第
  // 几次输出」跨进程是一致的。分片时每行带上这个序号，tool/regression.sh 按
  // 序号排回去——段标题和它的行才能重新贴到一起。不带序号直接 cat 的话，段
  // 标题会全挤在第 0 片那一段、行散在后面几片里，读的人根本对不上号（这些
  // 数字本来就是拿来跟人对拍 AI 行为的，错位比没有还糟）。
  final sharded = probeShardTotal > 1;
  var seq = 0;
  void out(String? line) {
    if (line != null) {
      print(sharded ? '${seq.toString().padLeft(6, '0')}\t$line' : line);
    }
    seq++; // 这一行归不归本片打都要计数，序号才跟别的片对得上
  }
  if (sharded) {
    print('# ai_probe 分片 $probeShardIndex/$probeShardTotal'
        '（tool/regression.sh 会按序号拼回来）');
  }

  _sectionMatched = false;
  void sec(String line) {
    final t = line.trim();
    // 只有顶级标题（`== xx ==`）才换段：子标题、空行分隔都不算，
    // 这样按段落名过滤时能整节命中，不会被子标题打断。
    if (t.startsWith('==')) {
      _section = line;
      if (_sectionFilter.isNotEmpty && t.contains(_sectionFilter)) {
        _sectionMatched = true;
      }
    }
    out(_sectionActive && (!sharded || probeShardIndex == 0) ? line : null);
  }

  void show(String name, _Result r) {
    out(r.skipped ? null : '${name.padRight(34)} $r${r._reachNote}');
  }

  /// 同一个局面、同一手牌、同一个下注尺度，只差 AI 有没有位置。
  void pos(String name,
      {required String hole,
      required String board,
      double frac = 0.5,
      Street street = Street.flop,
      AiStyle style = AiStyle.tightAggressive}) {
    // 转牌/河牌的对照要把翻牌也串起来（英雄翻牌也要开一枪），不然
    // 「AI 自己把两条街都打了」的手数根本轮不到面对下注，样本会空掉。
    final script = <Street, ({ActionType type, double frac})>{
      if (street != Street.flop) Street.flop: (type: ActionType.bet, frac: 0.5),
      street: (type: ActionType.bet, frac: frac),
    };
    // 翻前线必须在两边一样，不然比出来的不是「位置」而是「翻前谁开的池」。
    // 这里统一成「AI 开池 3bb、英雄跟注」：
    //   有位置：AI 坐按钮、翻前先说话 → 它自己开池，英雄跟。
    //   没位置：英雄坐按钮、翻前先说话 → 让英雄先补齐，AI 从大盲加注到
    //           3bb，英雄再跟。两条线的 AI 都是「翻前主动方、一次加注」，
    //           翻后唯一的差别就只剩谁先说话。
    _Result run({required bool oop}) => _sample(
          hole: hole,
          heroHole: '4c 5d',
          board: board,
          target: street,
          style: style,
          oop: oop,
          facingOnly: true,
          heroFirst: script,
          preflopScript: oop
              ? [
                  (who: 'hero', type: ActionType.call, amount: null),
                  (who: 'ai', type: ActionType.raise, amount: 3 * 100),
                  (who: 'hero', type: ActionType.call, amount: null),
                ]
              : [
                  (who: 'ai', type: ActionType.raise, amount: 3 * 100),
                  (who: 'hero', type: ActionType.call, amount: null),
                ],
        );
    final ip = run(oop: false);
    final oop = run(oop: true);
    if (ip.skipped) {
      out(null); // 这一格不归本片跑，但这两行的序号要照样占掉
      out(null);
      return;
    }
    out('${name.padRight(30)} '
        '有位置 n=${ip.total.toString().padLeft(3)} $ip');
    out('${''.padRight(30)} '
        '没位置 n=${oop.total.toString().padLeft(3)} $oop');
  }

  sec('== 翻牌圈（无人下注）== ');
  show('听花 AKs on Qd7d2c',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop));
  show('两头顺 98 on 762r',
      _sample(hole: '9h 8h', heroHole: '3c 2h', board: '7s 6h 2d', target: Street.flop));
  show('卡顺 76 on A92',
      _sample(hole: '7h 6h', heroHole: '3c 2h', board: 'As 9d 2c', target: Street.flop));
  // 用 87s 而不是 72o：翻前范围表里的牌才会真的走到翻牌圈，
  // 否则 AI 翻前就弃了、这一格永远是空的（87s 在 AKQ 上仍是纯空气）。
  show('空气 87s on AKQ',
      _sample(hole: '8h 7h', heroHole: '9c 8d', board: 'As Kd Qc', target: Street.flop));
  show('三条 99 on 9s6h2d',
      _sample(hole: '9h 9d', heroHole: '3c 2h', board: '9s 6h 2d', target: Street.flop));
  show('顶对顶踢 AQ on Qh7d2c',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c', target: Street.flop));

  sec('');
  sec('== 翻牌圈（英雄下注 1/2 池）== ');
  show('听花 面对方 bet',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  show('卡顺 面对方 bet',
      _sample(hole: '7h 6h', heroHole: '3c 2h', board: 'As 9d 2c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  show('空气 面对方 pot bet',
      _sample(hole: '8h 7h', heroHole: '9c 8d', board: 'As Kd Qc', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 1.0)}));
  // 底牌要挑 AI 翻前肯玩的（A2o 会直接弃牌、样本空掉 n=0），牌面还不能
  // 凑出花听——所以是 A2s 配一张黑桃 2 的牌面，量的才是「纯一对」。
  show('底对 面对方 1/3 池',
      _sample(hole: 'Ah 2h', heroHole: '3c 4h', board: 'Qc 7d 2s', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.33)}));
  show('第二对 面对方 1/3 池',
      _sample(hole: '8h 7s', heroHole: '3c 4h', board: 'Kh 8d 3c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.33)}));
  show('底对 面对方 pot bet',
      _sample(hole: 'Ah 2h', heroHole: '3c 4h', board: 'Qh 7d 2c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 1.0)}));
  show('顶对顶踢 AK 面对方 1/2 池',
      _sample(hole: 'Ah Kd', heroHole: '3c 2h', board: 'As 7c 2d', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  show('顶对顶踢 AK 面对方 1/4 池',
      _sample(hole: 'Ah Kd', heroHole: '3c 2h', board: 'As 7c 2d', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.25)}));
  show('顶对弱踢 A8 面对方 1/2 池',
      _sample(hole: 'Ah 8d', heroHole: '3c 2h', board: 'As 7c 2d', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  show('超对 99 面对方 1/2 池',
      _sample(hole: '9h 9d', heroHole: '3c 2h', board: '7s 4c 2d', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  // 翻牌的尺度扫描：转牌/河牌都量过「注越大弃得越多」，翻牌这一档还没有
  // 对过——翻牌只有一个「街道成本」系数（转牌 ×1.2、翻牌 ×1.0），跟注门槛
  // 里没有任何一项跟着下注尺度走（除了大注那个 ×1.35 的粗档）。
  //
  // 1.0 池往上每一步都要采：过渡区是 1.0~2.0 池（见 ai_player.dart 的
  // _overbetProgress），只采 0.66/1.0/1.5 的话整段过渡全被跳过去，看上去
  // 就像一道悬崖——当初正是这么漏过去的（过渡区只铺 1.0~1.2，探针也只采到
  // 1.2，于是「1.2 池往上和以前逐点一致」这条说法一直没被量过）。0.8 在
  // 过渡区之前，用来钉住「正常尺度那一侧的曲线没被带偏」。
  for (final frac in [0.33, 0.5, 0.66, 0.8, 1.0, 1.2, 1.3, 1.5, 2.0]) {
    final pct = '${(100 * frac).round()}%';
    show('第二对（翻牌 $pct 池）',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c', target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
    show('底对（翻牌 $pct 池）',
        _sample(hole: 'Ah 2h', heroHole: '4c 6d', board: 'Qc 7d 2s', target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }

  show('第二对（转牌 面对 1/3 池）',
      _sample(hole: '8h 7s', heroHole: '3c 4h', board: 'Kh 8d 3c 5s', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 0.33)}));
  show('底对（转牌 面对 1/3 池）',
      _sample(hole: 'Ah 2h', heroHole: '3c 4h', board: 'Qc 7d 2s 5h', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 0.33)}));
  // 转牌的尺度扫描：河牌那条「按尺度递减的跟注下限」是河牌专属；转牌这条
  // 街上，一个牌力的跟注率靠的是「胜率兑现率封顶」的街道项加下注尺度爬坡
  // （见 ai_player.dart 的 streetRealization）。这几格看的是「注越大弃得越
  // 多」这条规律在转牌成不成立，以及 1/2 池那档没被一起收走。
  for (final frac in [0.5, 0.66, 1.0, 1.5]) {
    final pct = '${(100 * frac).round()}%';
    show('第二对（转牌 $pct 池）',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c 5s', target: Street.turn,
            heroFirst: {Street.turn: (type: ActionType.bet, frac: frac)}));
    show('底对（转牌 $pct 池）',
        _sample(hole: 'Ah 2h', heroHole: '4c 6d', board: 'Qc 7d 2s 5h', target: Street.turn,
            heroFirst: {Street.turn: (type: ActionType.bet, frac: frac)}));
  }
  show('第二对（转牌 连开两枪超池）',
      _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c 5s', target: Street.turn,
          heroFirst: {
            Street.flop: (type: ActionType.bet, frac: 0.66),
            Street.turn: (type: ActionType.bet, frac: 1.5),
          }));

  sec('');
  sec('== 翻牌浮牌：注越大浮得越少，中间不许有悬崖 == ');
  // 浮牌（float）= 翻牌没成牌、但还有后路时跟一张看转牌，下一街对手过牌
  // 就把底池收走。它登记的就是半诈唬计划（[_PlanKind.semiBluff]），所以
  // 浮牌同时也是「听牌转诈唬」的入口——不浮，后面的转牌/河牌诈唬线整条
  // 都不存在。
  //
  // 这一档改过两次。第一次是一条硬门槛：`betSizeRel > 0.6 就不浮`（见
  // AiPlayer 的 [_floatChance]）。同一手「后门花 + 两张高张」，0.59 池还有
  // 三成在跟、0.61 池一个都不跟——而且不光这一条街：浮牌登记的那条线跟着
  // 一起没了，转牌对手过牌后「接着开火」的那部分也一起消失。对手试出
  // 「打 0.61 池就浮不动」，等于把这个入口整个关掉。
  //
  // 第二次是大注侧改成斜坡以后，「0.6 池以内逐点不变」留下的那段常量区间
  // 自己变成了新的破绽：0.40 / 0.50 / 0.55 / 0.60 池四格读数逐字相同
  // （弃 74%、跟 21%），注收小一点也不多浮。现在便宜那侧也铺了斜坡，所以
  // 这一节从 0.25 池一路扫到 1.0 池：整条曲线该是单调下降的。
  for (final frac in [0.25, 0.3, 0.35, 0.4, 0.5, 0.55, 0.6, 0.62, 0.7, 0.8, 1.0]) {
    show('后门花+两高张 翻牌面对 ${(100 * frac).round()}% 池',
        _sample(hole: 'Ah Qh', heroHole: '3c 4d', board: '8d 7c 2s',
            target: Street.flop, seeds: 200,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }

  sec('');
  sec('== 弱听牌（卡顺）面对下注：尺度扫描 == ');
  // 听牌那一档以前只有**强听牌**（8 outs 以上、组合听、坚果花听）在门槛上
  // 用 [_callMix] 混着打，弱听牌走的是裸 `drawEq >= need`：卡顺的出路数不
  // 随尺度变（JT on Q82 只有 9 这一张成顺，4 outs），门槛却随尺度线性爬，
  // 两条线交叉的那一点就把跟注整档切掉。这一节最初就是为了把那条竖直的边
  // 量出来（改之前实测：40.5% 池跟 93%、41% 池弃 93%，半个百分点的池差换
  // 一次决定；标签取整会把 40.5/41/41.5 写成同一个「41%」，所以这里保留
  // 一位小数）。现在门槛以下是 0.035 宽的斜坡、门槛以上一律跟（见
  // [AiPlayer._drawCallOrFold] 里 `band: 0` 那段），扫出来应该是一条单调
  // 收窄的曲线：约 41% 池跟 45% → 44% 池 32% → 46% 池 25% → 50% 池 13%
  // → 55% 池 0%。判定标准是「门槛以上不掉、门槛以下连续掉、中间没有一步
  // 掉光」，改这档时要盯着这三个。
  //
  // 这里**不能**给 AI 配 aiScript：脚本会把 AI 的那次行动钉死，而
  // facingOnly 要记的正是「AI 面对下注时的决策」——钉成过牌/跟注之后
  // AI 压根没有面对下注的机会，整节会安静地输出空行（踩过）。
  for (final frac in [
    0.30, 0.35, 0.38, 0.40, 0.405, 0.41, 0.415, 0.42, 0.44, 0.46, 0.50, 0.60,
  ]) {
    // 标签保留一位小数：这一节要看的正是 0.5% 池级别的过渡，取整会把
    // 40.5% / 41% / 41.5% 写成同一个「41%」，读不出斜坡到底铺了多宽。
    show('卡顺 JT on Q82 翻牌 面对方 ${(100 * frac).toStringAsFixed(1)}% 池',
        _sample(hole: 'Jh 10h', heroHole: '3c 2h', board: 'Qd 8d 2c',
            target: Street.flop, seeds: 400, facingOnly: true,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }

  sec('');
  sec('== 3bet 底池：范围窄一半、SPR 低一档，打法该跟着变 == ');
  // 3bet 底池是实战里最常见、也最不一样的一种池子，而这一整节以前一次都没
  // 量过——上面所有格子量的都是「翻前只加过一次」的池子（范围宽、SPR 深）。
  // 同一个 AI 拿着同一手牌，在一个范围窄了一半、SPR 掉了一半的池子里如果还
  // 照单加池的频率下注/跟注，对手拿顶对就能把它的价值线读穿，而它的抓诈唬
  // 范围也宽得离谱：3bet 方的范围里根本没有那么多空气。
  //
  // 每一对并排的是「单加池（对照）/ 3bet 底池」，翻前线都固定住：
  //   单加池：AI 按钮开 3bb、英雄跟；
  //   3bet池：AI 开 3bb、英雄 3bet 到 9bb、AI 跟（= 翻前加注两次）。
  // 翻后英雄先说话，所以两组里 AI 都是「翻前被动方 + 有位置」那一侧，唯一
  // 的差别就是底池里有没有那一次 3bet。
  const singleRaisedPot = <_Step>[
    (who: 'ai', type: ActionType.raise, amount: 3 * 100),
    (who: 'hero', type: ActionType.call, amount: null),
  ];
  const threeBetPot = <_Step>[
    (who: 'ai', type: ActionType.raise, amount: 3 * 100),
    (who: 'hero', type: ActionType.raise, amount: 9 * 100),
    (who: 'ai', type: ActionType.call, amount: null),
  ];
  const halfPotFlop = <Street, ({ActionType type, double frac})>{
    Street.flop: (type: ActionType.bet, frac: 0.5),
  };
  for (final (tag, script) in [
    ('单加池', singleRaisedPot),
    ('3bet池', threeBetPot),
  ]) {
    show('$tag 顶对顶踢 AQ（被过牌到）',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c',
            target: Street.flop, preflopScript: script, seeds: 200));
    show('$tag 顶对顶踢 AQ（面对方 1/2 池）',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c',
            target: Street.flop, preflopScript: script, seeds: 200,
            facingOnly: true, heroFirst: halfPotFlop));
    show('$tag 超对 99（面对方 1/2 池）',
        _sample(hole: '9h 9d', heroHole: '3c 2h', board: '7s 4c 2d',
            target: Street.flop, preflopScript: script, seeds: 200,
            facingOnly: true, heroFirst: halfPotFlop));
    show('$tag 第二对 87（面对方 1/2 池）',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c',
            target: Street.flop, preflopScript: script, seeds: 200,
            facingOnly: true, heroFirst: halfPotFlop));
    show('$tag 花听 AKs（面对方 1/2 池）',
        _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c',
            target: Street.flop, preflopScript: script, seeds: 200,
            facingOnly: true, heroFirst: halfPotFlop));
    // 3bet 池里 87s 本来不会跟进来（这里由脚本强制跟），所以这一行只回答
    // 一个问题：范围窄了以后 AI 还敢不敢拿纯空气开火。
    show('$tag 空气 87s（被过牌到）',
        _sample(hole: '8h 7h', heroHole: '3c 2h', board: 'As Kd Qc',
            target: Street.flop, preflopScript: script, seeds: 200));

    // 翻牌那几格只看了第一次决策。3bet 底池真正不一样的地方在**后面两条
    // 街**：SPR 从单加池的十几掉到 4 上下，翻牌跟一枪之后 SPR 只剩 2 出头，
    // 「筹码套进去」那几档（低 SPR 自动推、河牌按尺度挑着弃）会整片被打
    // 开。同一个牌力在两条街之间的收窄幅度也得跟着池子类型变，不然探针里
    // 单加池那条平滑的曲线在 3bet 池里直接变成「一律推」。
    const twoBarrels = <Street, ({ActionType type, double frac})>{
      Street.flop: (type: ActionType.bet, frac: 0.5),
      Street.turn: (type: ActionType.bet, frac: 0.5),
    };
    const threeBarrels = <Street, ({ActionType type, double frac})>{
      Street.flop: (type: ActionType.bet, frac: 0.5),
      Street.turn: (type: ActionType.bet, frac: 0.5),
      Street.river: (type: ActionType.bet, frac: 0.5),
    };
    // 翻牌之前那几条街一律钉成「过牌 / 跟注」（见 _sample 的 [aiScript]）：
    // 不钉的话 AI 有时会在翻牌就把顶对反加回去，底池和 SPR 跟着全变，
    // 同一格 200 个种子里会混进十几种不同场景，读数根本没法比。
    const aiCalls = <_AiStep>[
      (street: Street.flop, type: ActionType.call, amount: null),
    ];
    const aiCallsTwice = <_AiStep>[
      (street: Street.flop, type: ActionType.call, amount: null),
      (street: Street.turn, type: ActionType.call, amount: null),
    ];
    const aiChecks = <_AiStep>[
      (street: Street.flop, type: ActionType.check, amount: null),
    ];
    const aiChecksTwice = <_AiStep>[
      (street: Street.flop, type: ActionType.check, amount: null),
      (street: Street.turn, type: ActionType.check, amount: null),
    ];
    show('$tag 转牌 顶对顶踢（被过牌到）',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s',
            target: Street.turn, preflopScript: script, aiScript: aiChecks,
            seeds: 200));
    show('$tag 转牌 顶对顶踢（面对方 1/2 池）',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s',
            target: Street.turn, preflopScript: script, aiScript: aiCalls,
            seeds: 200, facingOnly: true, heroFirst: twoBarrels));
    show('$tag 转牌 第二对（面对方 1/2 池）',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c 5s',
            target: Street.turn, preflopScript: script, aiScript: aiCalls,
            seeds: 200, facingOnly: true, heroFirst: twoBarrels));
    show('$tag 转牌 花听（面对方 1/2 池）',
        _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h',
            target: Street.turn, preflopScript: script, aiScript: aiCalls,
            seeds: 200, facingOnly: true, heroFirst: twoBarrels));
    show('$tag 河牌 顶对顶踢（面对方 1/2 池）',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s 9d',
            target: Street.river, preflopScript: script, aiScript: aiCallsTwice,
            seeds: 200, facingOnly: true, heroFirst: threeBarrels));
    show('$tag 河牌 第二对（面对方 1/2 池）',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c 5s 9d',
            target: Street.river, preflopScript: script, aiScript: aiCallsTwice,
            seeds: 200, facingOnly: true, heroFirst: threeBarrels));
    // 「低 SPR 就把筹码推出去」的频率也得跟着 SPR 连续走：以前是
    // `SPR ≤ 1.5` 一刀切，同一手牌 SPR 1.33 推 100%、1.52 推 3%（见
    // [AiPlayer._facingBet] 里的 jamRamp）。这三格把那条曲线钉在这里，
    // 闸门（1.5）两侧都要能看见中间档，而不是 100% 直接掉到个位数。
    if (tag == '3bet池') {
      for (final (spr, stk) in [(0.41, 8000), (1.15, 16000), (1.52, 20000)]) {
        show('$tag 河牌 顶对顶踢 SPR$spr（面对方 1/2 池）',
            _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s 9d',
                target: Street.river, preflopScript: script,
                aiScript: aiCallsTwice, seeds: 200, facingOnly: true,
                heroFirst: threeBarrels, stack: stk));
      }
      // 怪兽牌那一档以前是 `SPR ≤ 2.5` 也一律推（闸门上推的是 215% 池），
      // 尺度从 215% 池直接掉到 85% 池、中间没有档。这三格盯同一条曲线：
      // 推的频率随 SPR 连续收，收回去的落成常规的 85% 池价值加注。
      for (final (spr, stk) in [('0.59', 10000), ('1.52', 20000), ('2.50', 30600)]) {
        show('$tag 河牌 两对 97 SPR$spr（面对方 1/2 池）',
            _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s',
                target: Street.river, preflopScript: script,
                aiScript: aiCallsTwice, seeds: 200, facingOnly: true,
                heroFirst: threeBarrels, stack: stk));
      }
      // 「被过牌到」那一侧同样有两条 SPR 硬门槛（见 [AiPlayer._checkedTo]
      // 第 0 条），闸门也会在某个底池大小上把「下注」整段换成「全下」：
      // 同一手牌 SPR 1.50 推 100%、2.00 就掉成过牌 28% + 一堆小注。
      // 下面这几格把那条曲线钉住——翻牌/转牌英雄都下 1/2 池（AI 钉住跟），
      // 河牌英雄过牌，量 AI 在**无人下注**时怎么把筹码放进去。闸门两侧
      // 都要能看见中间档，而不是 100% 直接掉到个位数。
      for (final (spr, stk) in [
        ('0.89', 10000),
        ('1.25', 12600),
        ('1.75', 16200),
        ('2.35', 20500),
        ('2.85', 24100),
      ]) {
        show('$tag 河牌 顶对顶踢 SPR$spr（被过牌到）',
            _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s 9d',
                target: Street.river, preflopScript: script,
                aiScript: aiCallsTwice, seeds: 200, heroFirst: twoBarrels,
                stack: stk));
      }
      for (final (spr, stk) in [
        ('0.89', 10000),
        ('1.25', 12600),
        ('1.75', 16200),
        ('2.35', 20500),
        ('2.85', 24100),
      ]) {
        show('$tag 河牌 两对 97 SPR$spr（被过牌到）',
            _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s',
                target: Street.river, preflopScript: script,
                aiScript: aiCallsTwice, seeds: 200, heroFirst: twoBarrels,
                stack: stk));
      }
    }

    show('$tag 河牌 miss 花（被过牌到）',
        _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s',
            target: Street.river, preflopScript: script, aiScript: aiChecksTwice,
            seeds: 200));
  }

  sec('');
  sec('== 面对加注：加注越大越收手，门槛不该在 0.6 池上跳 == ');
  // 「我下注、被他加注」是牌桌上最常见的一手，可这条线以前只量过两个点
  // （tool/ai_vs_raise_probe.dart 的 2.2 倍 / 3.5 倍），尺度中间长什么样
  // 没人看过。而 [AiPlayer._facingBet] 里一对牌的「加注余量」是一道布尔：
  // 面对加注时 `need *= betSizeRel <= 0.6 ? 1.65 : 1.85`——门槛在 0.6 池
  // 上一步抬 12%，而且这个开关不看对手到底加了多少，只看落在哪一侧。
  // [AiPlayer._bluffRaiseChance] 里还有一道更大的：`betSizeRel >= 0.8`
  // 乘 0.2、否则乘 0.45（2.25 倍）。两处都在这条线上，所以这一节一次量两件事。
  //
  // 这一节把加注量铺成一条连续横轴：AI 先在这条街上自己开一枪（[aiScript]），
  // 英雄按「底池的 frac 倍」加回来（[heroFirst] 的 raise 分支，目标额是
  // `currentBet + pot * frac`，也就是令 AI 的 toCall = pot * frac）。AI 的
  // betSizeRel 就是 toCall 除以下注前的底池，所以 **frac 和 betSizeRel 是
  // 同一套刻度**：frac 0.60 落在其中一个开关的一侧、0.62 落在另一侧。
  //
  // 结论（改前改后各量一遍）：**没有台阶**。顶对弱踢 A8 在 0.54~0.66 上
  // 每 2% 池掉 3/3/6/5/4/6/10 个点，0.60 → 0.61 → 0.62 这三步是 -4、-6，
  // 跟两边的坡度连成一条曲线；第二对在 0.60 两侧都是 100% 弃（门槛早就
  // 跑过去了），空气的诈唬再加注在整段都是 0~2%。两处布尔都留着：
  // 12% / 2.25 倍的门槛扰动在这个场面上被赔率本身的坡度（约 +0.25 胜率
  // 每池）盖住了，落到决策上不到一个采样格。这一节留着当**护栏**——以后
  // 谁再动那两个数，先看这里有没有冒出跳变。
  const aiLeadsFlop = <_AiStep>[
    (street: Street.flop, type: ActionType.bet, amount: null),
  ];
  // 翻前必须让**英雄先说话**：这里 oop = true，AI 坐大盲，所以翻前第一个
  // 开口的是按钮上的英雄。写成「英雄补齐 → AI 加注到 3bb → 英雄跟」，AI
  // 就同时是「翻前主动方」和「翻后先说话」——正好是我们要的「AI 先开一枪，
  // 被加回来」。直接套下面 3bet 那节的 singleRaisedPot（AI 先加）会撞上
  // `Bad state: 轮到 hero，不是 ai`，整节安静地空掉。
  const heroLimpsThenAiOpens = <_Step>[
    (who: 'hero', type: ActionType.call, amount: null),
    (who: 'ai', type: ActionType.raise, amount: 3 * 100),
    (who: 'hero', type: ActionType.call, amount: null),
  ];
  void vsRaise(String name, String hole, String board, double frac) {
    show('$name 面对加注到 ${(100 * frac).toStringAsFixed(0)}% 池',
        _sample(hole: hole, heroHole: '4c 6d', board: board,
            target: Street.flop, seeds: 200, oop: true,
            preflopScript: heroLimpsThenAiOpens, aiScript: aiLeadsFlop,
            heroFirst: {Street.flop: (type: ActionType.raise, frac: frac)}));
  }

  // 门槛正落在这一段里的牌力：0.60 两侧各留三个采样点。
  for (final frac in const [0.54, 0.56, 0.58, 0.60, 0.61, 0.62, 0.64, 0.66]) {
    vsRaise('顶对弱踢 A8 on A72', 'Ah 8d', 'As 7c 2d', frac);
  }
  // 门槛早就跑过去的牌力：只在 0.60 两侧各取一点，看有没有反向跳变。
  for (final frac in const [0.50, 0.58, 0.62, 0.70, 0.80]) {
    vsRaise('第二对 87 on K83', '8h 7s', 'Kh 8d 3c', frac);
    vsRaise('超对 99 on 742', '9h 9d', '7s 4c 2d', frac);
    // 空气那几格量的是 [_bluffRaiseChance] 那条 2.25 倍的开关：面对加注
    // 拿空气再加一次，阈值卡在 0.8 池上。
    vsRaise('空气 87 on AKQ', '8h 7h', 'As Kd Qc', frac);
  }

  sec('== 转牌圈（听牌未成，对手一直过牌）== ');
  show('听花转牌（无人下注）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h', target: Street.turn));
  show('听花转牌（面对 1/2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 0.5)}));
  show('听花转牌（面对 1.2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 1.2)}));
  // 强牌档在**转牌**面对大注的应对：河牌那一档（重注要挑着弃）现在没有
  // 对转牌生效，这两格是量「同一条线在转牌上是什么样」的。转牌后面还有
  // 一条街，按理比河牌更该跟，但也不该像以前那样大注小注一个样。
  show('转牌顶对（面对 1/2 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 0.5)}));
  show('转牌顶对（面对 1 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 1.0)}));
  show('转牌顶对（面对 1.5 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 1.5)}));
  show('转牌顶对（对手连开两枪超池）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5s', target: Street.turn,
          heroFirst: {
            Street.flop: (type: ActionType.bet, frac: 0.66),
            Street.turn: (type: ActionType.bet, frac: 1.5),
          }));
  show('转牌两对（面对 1.5 池 bet）',
      _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5s 2s', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 1.5)}));

  sec('');
  sec('== 翻牌 vs 转牌：同一个牌力的防守范围该不该收窄 == ');
  for (final frac in [0.5, 0.66]) {
    sec('-- 第二对 87，对手下 ${(100 * frac).round()}% 池 --');
    show('  翻牌',
        _sample(hole: '8h 7s', heroHole: '3c 4h', board: 'Kh 8d 3c', target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
    show('  转牌',
        _sample(hole: '8h 7s', heroHole: '3c 4h', board: 'Kh 8d 3c 5s', target: Street.turn,
            heroFirst: {
              Street.flop: (type: ActionType.bet, frac: frac),
              Street.turn: (type: ActionType.bet, frac: frac),
            }));
  }

  sec('');
  sec('== 无人下注时的薄价值/控池 == ');
  // 每档都配一行「底对」做对照：薄价值下注的频率必须跟着牌力走，第二对和
  // 底对不能是同一个数——以前两档共用 0.42，这里逐桶一样的分布就是证据。
  show('翻牌第二对（无人下注）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c', target: Street.flop));
  show('翻牌底对（无人下注）',
      _sample(hole: 'Ah 4h', heroHole: '3c 2h', board: 'Qc 7d 4s', target: Street.flop));
  show('转牌第二对（无人下注）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h', target: Street.turn));
  show('转牌底对（无人下注）',
      _sample(hole: 'Ah 4h', heroHole: '3c 2h', board: 'Qc 7d 4s 5h', target: Street.turn));
  show('河牌第二对（无人下注）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river));
  show('河牌底对（无人下注）',
      _sample(hole: 'Ah 4h', heroHole: '3c 2h', board: 'Qc 7d 4s 5h 9d', target: Street.river));
  show('河牌顶对（无人下注）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river));
  // 薄价值还要读「他前面跟了我们几条街」：同一个牌面、同一手牌，只差英雄
  // 跟过几次我们的下注。以前这一档完全不读 villainCalls——探针实测中对 88 的
  // 河牌下注率是「没跟过 28% / 跟一条街 28% / 跟两条街 28%」逐点相同，等于
  // 对手连跟两条街这条最强的信息在薄价值上不存在。现在每多被跟一条街收一档
  // （第二对/底对：28% → 21% → 11%），顶对的价值下注不动。
  const aiChecksFlopTurnThin = <_AiStep>[
    (street: Street.flop, type: ActionType.check, amount: null),
    (street: Street.turn, type: ActionType.check, amount: null),
  ];
  const aiFiresFlopThenChecksThin = <_AiStep>[
    (street: Street.flop, type: ActionType.bet, amount: null),
    (street: Street.turn, type: ActionType.check, amount: null),
  ];
  const aiFiresFlopTurnThin = <_AiStep>[
    (street: Street.flop, type: ActionType.bet, amount: null),
    (street: Street.turn, type: ActionType.bet, amount: null),
  ];
  for (final (tag, script) in <(String, List<_AiStep>)>[
    ('没人跟过', aiChecksFlopTurnThin),
    ('被跟一条街', aiFiresFlopThenChecksThin),
    ('被跟两条街', aiFiresFlopTurnThin),
  ]) {
    for (final (name, hole, board) in [
      ('第二对', '8h 7s', 'Kh 8d 3c 5h 9s'),
      ('底对', 'Ah 4h', 'Qc 7d 4s 5h 9d'),
      ('顶对', 'Ah Qd', 'Qh 7d 2c 5h 9s'),
    ]) {
      show('河牌$name（$tag）',
          _sample(hole: hole, heroHole: '3c 2h', board: board,
              target: Street.river, aiScript: script));
    }
  }

  sec('');
  sec('== 河牌圈（听牌已经错过）== ');
  show('miss 花（无人下注）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river));
  show('miss 花（面对 1/4 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.25)}));
  show('miss 花（面对 1 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('miss 花（面对 1/2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  show('miss 花（面对 1/3 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.33)}));
  // 0.4 池是「小注档」的上界（[AiPlayer._facingBet] 里的 smallStab），
  // 采样点原来从 1/3 直接跳到 1/2，正好把这道门两侧的空档让过去了。
  for (final frac in [0.38, 0.4, 0.42]) {
    show('miss 花（面对 $frac 池 bet）',
        _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  show('河牌第二对（面对 1/4 池 bet）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.25)}));
  show('河牌底对（面对 1/4 池 bet）',
      _sample(hole: '4h 3h', heroHole: '3c 2h', board: 'Ks 7d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.25)}));
  show('河牌第二对（面对 1/3 池 bet）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.33)}));
  show('河牌第二对（面对 1/2 池 bet）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  // 0.4 池是「弱成牌小注档」那道硬门槛的两侧，第二对/底对也得各采一点，
  // 不然只能看到门槛外的 1/3 和门槛里的 1/2，中间跳了多少看不出来。
  for (final frac in [0.4, 0.42]) {
    show('河牌第二对（面对 $frac 池 bet）',
        _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  // 0.5 池到 2/3 池之间原来是空的，而这一档的跟注率在那里掉得最凶
  // （0.5 池跟 99%、2/3 池只剩 61%）——中间是不是一道台阶看不出来。
  for (final frac in [0.55, 0.6]) {
    show('河牌第二对（面对 $frac 池 bet）',
        _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  show('河牌第二对（面对 2/3 池 bet）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.66)}));
  show('河牌第二对（面对 1 池 bet）',
      _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('河牌底对（面对 2/3 池 bet）',
      _sample(hole: '4h 3h', heroHole: '3c 2h', board: 'Ks 7d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.66)}));
  show('miss 花（面对 2/3 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.66)}));
  show('河牌底对（面对 1 池 bet）',
      _sample(hole: '4h 3h', heroHole: '3c 2h', board: 'Ks 7d 3c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('高牌 Q 高（面对 1/4 池 bet）',
      _sample(hole: 'Qh Jd', heroHole: '3c 2h', board: '9d 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.25)}));
  show('高牌 Q 高（面对 1/2 池 bet）',
      _sample(hole: 'Qh Jd', heroHole: '3c 2h', board: '9d 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  // 上面那两行是**同一张牌面**上的对照：A 高（AdKd）和 Q 高（QhJd）在
  // 9d7d2c5h9s 上都只是「没中牌的高张」，唯一的差别是 A 高挡掉了一张 A
  // （blockerScore 0.45 对 0.15）。以前 A 高那几行用的是 Qd7d2c5h9s，跟
  // Q 高不是同一个牌面，两边的数字根本没法直接比——牌面结构本身就在动
  // 范围模型给出的胜率。要看「阻断牌有没有在河牌小注上提频」，只能看这两行。
  for (final frac in [0.25, 0.5]) {
    show('miss 花 A 高（9d7d2c5h9s，面对 $frac 池）',
        _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: '9d 7d 2c 5h 9s', target: Street.river,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  show('成花（面对 1/2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 3d', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  show('河牌顶对（面对 1/2 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  // 顶对是「抓诈唬」牌：对手敢在河牌砸一个超池，范围是两级的（坚果或空气），
  // 顶对必须有一部分让开——不能像面对 1/2 池那样一路跟到底。
  show('河牌顶对（面对 1 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('河牌顶对（面对 1.5 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.5)}));
  // 对照：两对面对同一个超池，还是得跟（它已经打赢了顶对/超对那条线）。
  show('河牌两对（面对 1.5 池 bet）',
      _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.5)}));
  show('河牌顶对（对手连开三枪超池）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          heroFirst: {
            Street.flop: (type: ActionType.bet, frac: 0.66),
            Street.turn: (type: ActionType.bet, frac: 0.66),
            Street.river: (type: ActionType.bet, frac: 1.5)}));
  show('河牌两对（面对 1/2 池 bet）',
      _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));

  sec('');
  sec('== 强牌档内部的听牌：顶对 + 坚果花听 vs 纯顶对 == ');
  // [HandTier] 的「强牌」把「顶对顶踢」和「顶对顶踢 + 坚果花听」装成同一手
  // 牌，而强牌那两条线（下注尺度走 [_valueFrac]、加注频率走
  // [_strongRaiseChance]）都只看 tier、没读 [HandReading.hasDraw]——于是同一
  // 块 Q♦7♦2♣ 上 A♦Q♦ 和 A♠Q♦（只差底牌花色，牌面逐字相同）三格读数**逐字
  // 相同**，连下注频率都一模一样。真人拿顶对 + 坚果花听是既敢下大注、也乐意
  // 把筹码放进去的一手（被跟了还有一条街的出路），跟纯顶对不是一条线。
  // 现在这两格差落在 [_strongDrawSizeScale] 和 [_strongDrawRaiseBonus] 上，
  // 这一节是它们的对照。
  //
  // 下面「第二对」那两行是反面对照：第二对不在强牌档里，走的是听牌半诈唬那
  // 条分支，本来就读 hasDraw——8♦7♦ 和 8♠7♠ 的数字本来就差得远，说明「不读
  // 听牌」是强牌这一档独有的漏，不是整套读牌都不看听牌。
  {
    const fdBoard = 'Qd 7d 2c';
    // 注意四手底牌的**牌面必须逐字相同**（Q♦7♦2♣ + 3♣2♥），否则差的是牌面
    // 纹理不是听牌；「纯顶对」那行用 A♠Q♦（一张方片）才刚好没有花听。
    final hands = <(String, String)>[
      ('顶对顶踢 坚果花听', 'Ad Qd'),
      ('顶对顶踢 无花听  ', 'As Qd'),
      ('第二对 花听     ', '8d 7d'),
      ('第二对 无花听   ', '8s 7s'),
    ];
    for (final (name, hole) in hands) {
      show('  $name 翻牌 被过牌到',
          _sample(hole: hole, heroHole: '3c 2h', board: fdBoard,
              target: Street.flop));
      show('  $name 翻牌 面对方 0.5池',
          _sample(hole: hole, heroHole: '3c 2h', board: fdBoard,
              target: Street.flop,
              heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
      show('  $name 转牌 面对方 0.5池',
          _sample(hole: hole, heroHole: '3c 2h', board: 'Qd 7d 2c 5h',
              target: Street.turn,
              heroFirst: {Street.turn: (type: ActionType.bet, frac: 0.5)}));
    }
  }

  sec('== 强牌档内部：超对和顶对不该是同一条线 == ');
  // [HandTier] 的「强牌」把超对和顶对顶踢装在一起，而 AI 只看 tier：
  // [HandReading.overPair] 这个字段早就算好了，可很长一段时间里除了
  // verify_engine 那句断言之外没人读它——于是这两手在 AI 眼里一模一样。
  // 超对打赢顶对（对手拿顶对就是被我们盖住），面对重注弃得比顶对少得多、
  // 被加注时也更有理由 3-bet，真人这两手根本不是一个打法。
  // 现在这两条线分别落在 [HandReading.strongFoldScale] 和
  // [AiPlayer._overPairFlopRaiseBonus] 上，这一节是它们的对照。
  //
  // 同一块 Q♥7♦2♣5♥9♠，只换底牌：A♥Q♦ 是顶对顶踢，K♥K♠ 是超对。
  const overBoard = 'Qh 7d 2c 5h 9s';
  for (final (name, hole) in [
    ('顶对顶踢 AQ', 'Ah Qd'),
    ('超对 KK', 'Kh Ks'),
  ]) {
    for (final frac in [0.5, 1.0, 1.5]) {
      show('  $name 河牌 面对 $frac池',
          _sample(hole: hole, heroHole: '3c 2h', board: overBoard,
              target: Street.river,
              heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
    }
  }
  // 「他下注、我回应」这条线：同一块 Q♥7♦2♣ 上，超对（KK）打赢顶对
  // （AQ 就是被我们盖住的那一手），面对同一个下注该比顶对更愿意加回去。
  // 翻牌这一档是三张同花面那种极端情形之外、最常被对手看到的一条线。
  for (final (name, hole) in [
    ('顶对顶踢 AQ', 'Ah Qd'),
    ('超对 KK', 'Kh Ks'),
  ]) {
    for (final frac in [0.33, 0.5, 1.0]) {
      show('  $name 翻牌 面对方 $frac池',
          _sample(hole: hole, heroHole: '3c 2h', board: 'Qh 7d 2c',
              target: Street.flop,
              heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
    }
  }

  // 转牌那一档也要对：加成只挂在翻牌上，转牌如果又塌回一条线，
  // 对手看到「转牌加注」就知道我们手里是哪一档。
  for (final (name, hole) in [
    ('顶对顶踢 AQ', 'Ah Qd'),
    ('超对 KK', 'Kh Ks'),
  ]) {
    for (final frac in [0.33, 0.5, 1.0]) {
      show('  $name 转牌 面对方 $frac池',
          _sample(hole: hole, heroHole: '3c 2h', board: 'Qh 7d 2c 5h',
              target: Street.turn,
              heroFirst: {Street.turn: (type: ActionType.bet, frac: frac)}));
    }
  }

  // 「我下注、被他加注」这条线更该分：顶对被加注基本只能跟（加回去只被
  // 更好的牌跟），超对还有理由再加一次。AI 要坐大盲先说话，所以这里
  // oop: true（英雄坐按钮），翻前钉成「英雄开 3bb、AI 跟」。
  const overPreflop = <_Step>[
    (who: 'hero', type: ActionType.raise, amount: 300),
    (who: 'ai', type: ActionType.call, amount: null),
  ];
  for (final (name, hole) in [
    ('顶对顶踢 AQ', 'Ah Qd'),
    ('超对 KK', 'Kh Ks'),
  ]) {
    show('  $name 翻牌 下注被加注',
        _sample(hole: hole, heroHole: '3c 2h', board: 'Qh 7d 2c',
            target: Street.flop,
            oop: true,
            preflopScript: overPreflop,
            aiScript: const [
              (street: Street.flop, type: ActionType.bet, amount: null),
            ],
            heroFirst: {Street.flop: (type: ActionType.raise, frac: 2.0)}));
  }

  sec('');
  sec('== 三张同花面：顺子/三条/两对 和 顶对 不该是同一条线 == ');
  // [HandTier] 只有五档，`_tierOf` 把「三张同花面上的顺子/三条/两对」整档
  // 降到强牌，注释里写的意图是「以跟注为主、不会无脑打光」。可强牌那一档
  // 在河牌还有一条 `strongFoldVsBigBet`（注越大弃得越多）——降档的副作用
  // 是这些牌跟顶对顶踢共用同一条弃牌线。顺子已经打赢了对手范围里的两对/
  // 三条/顶对，真人不会拿它像顶对那样弃给一个超池。
  //
  // 同一块 3 张方片的牌面 Q♦7♦2♣5♥3♦，只换底牌：
  //   6♥4♥ = 3-4-5-6-7 顺子、7♥7♠ = 三条(set)、Qs7c = 两对、
  //   A♠Q♥ = 顶对顶踢、A♦K♦ = 成花（对照，本来就在怪兽档）。
  const flushBoard = 'Qd 7d 2c 5h 3d';
  for (final (name, hole) in [
    ('顺子 64', '6h 4h'),
    ('三条 77', '7h 7s'),
    ('两对 Q7', 'Qs 7c'),
    ('顶对顶踢 AQ', 'As Qh'),
    ('成花 AKd', 'Ad Kd'),
  ]) {
    for (final frac in [0.5, 1.5]) {
      show('  $name 面对 $frac池',
          _sample(hole: hole, heroHole: '3c 2h', board: flushBoard,
              target: Street.river,
              heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
    }
  }

  sec('');
  sec('== 河牌听牌错过：转诈唬 == ');
  // 原话是「没有正确的听牌转诈唬」。翻牌/转牌的半诈唬别处都有探针，漏的是
  // 最后一环：河牌牌没到，这一枪还开不开、面对下注还加不加。这里把两件事
  // 分开量，因为它们是两条不同的线：
  //   1) 前面双方都过牌（AI 没接手）→ 河牌面对一枪，量「跟/加/弃」；
  //   2) 脚本钉死 AI 连开两枪 → 河牌被过牌到。钉死的开火走引擎 `apply`，
  //      AI 从没登记跨街计划，所以这一格量的是「没有延续这条线」的下界；
  //   3) [requireSelfFire]：AI 自己连开两枪 → 河牌被过牌到。这一格才带上
  //      `_plan` 那条 1.7~2.0 倍的延续项，是「听牌转诈唬」的本体，也正是
  //      真实对局走的那条路。
  // 2 和 3 必须并排看：只留 2 的那串数字（这一格以前就是这么写的）会得出
  // 「AI 连第三枪都懒得开」的错误结论——实测同一手破花 A 高，2 是 19%、
  // 3 是 40%，差的就是那条延续线；更要命的是改 AI 时会把 2 的读数当成
  // 「这个漏洞我已经修好了」的证据。
  // 以前只有零散两格（miss 花），看不出「一样是破听牌、阻断牌强弱不同」
  // 的差别，也看不出尺度扫描中间有没有台阶。四手里前两手是破花（A 高挡了
  // 坚果 / J 高什么都没挡），第三手是破顺，第四手是没后路的纯空气对照。
  const aiChecksTwoStreets = <_AiStep>[
    (street: Street.flop, type: ActionType.check, amount: null),
    (street: Street.turn, type: ActionType.check, amount: null),
  ];
  const aiFiresTwoStreets = <_AiStep>[
    (street: Street.flop, type: ActionType.bet, amount: null),
    (street: Street.turn, type: ActionType.bet, amount: null),
  ];
  const bustedDraws = <({String name, String hole, String board})>[
    (name: '破花 A高', hole: 'Ad Kd', board: 'Qd 7d 2c 5h 9s'),
    (name: '破花 J高', hole: 'Jh 10h', board: 'Kh 8h 2c 5s 9d'),
    (name: '破顺 T高', hole: '10h 9h', board: '8d 7c 2s 5h Kd'),
    (name: '纯空气 8高（对照）', hole: '8h 7h', board: 'As Kd Qc 5h 9s'),
  ];
  for (final h in bustedDraws) {
    for (final frac in [0.25, 0.33, 0.45, 0.5, 1.0]) {
      show('${h.name} 面对 ${(100 * frac).round()}% 池',
          _sample(hole: h.hole, heroHole: '3c 2h', board: h.board,
              target: Street.river, seeds: 200, aiScript: aiChecksTwoStreets,
              heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
    }
  }
  // A 高那一手是唯一会走「高张抓诈唬」那条线的（有 overcard），其余三手
  // 都是「诈唬加注 or 弃」。它的跟注率掉得比那三手快得多，所以单独把
  // 0.33~0.5 之间铺密一点，确认是斜坡而不是又一道台阶。
  for (final frac in [0.38, 0.42, 0.48, 0.55]) {
    show('破花 A高 面对 ${(100 * frac).round()}% 池（加密）',
        _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s',
            target: Street.river, seeds: 200, aiScript: aiChecksTwoStreets,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  for (final h in bustedDraws) {
    show('${h.name} 连开两枪后被过牌到（脚本钉死）',
        _sample(hole: h.hole, heroHole: '3c 2h', board: h.board,
            target: Street.river, seeds: 200, aiScript: aiFiresTwoStreets));
    // 真实路径给 600 个种子：触发率各手不同（破花 A 高约七成，纯空气只有
    // 三成出头），600 才够把每格落到 200 手上下。这一族的决策全是「被过牌
    // 到」，不花估值模拟，多出来的手数是毫秒级的。
    show('${h.name} 自己连开两枪后被过牌到',
        _sample(hole: h.hole, heroHole: '3c 2h', board: h.board,
            target: Street.river, seeds: 600, requireSelfFire: true));
  }

  sec('');
  sec('== 怪兽牌：对手下得越大，加注越少（超池主要是跟）== ');
  // 以前这一档完全不看尺度：河牌拿两对对着 0.5 倍池加 76%、对着 1.5~2 倍池
  // 反而加到 95%（多出来的全是低 SPR 的自动推）。真人对小注加注、对大注
  // 跟注——对手下得越大，他的范围越两极，我们的加注只会把诈唬打走。
  // 现在这条线要随尺度单调往下；翻牌圈不吃这一档（那是收听牌的钱，见
  // 「怪兽牌面对下注」那两条）。
  //
  // 另外，这几格以前只钉了河牌那一下注，翻前和翻牌/转牌都是 AI 自己打
  // 的：同一个格子 300 个种子里底池从 600 到几万都有，SPR 从 1 出头到十几
  // 全混在一起（桶列表里那串 175%/190%/215% 就是这么来的），读出来的
  // 「对着 0.5 倍池加了多少」其实是一堆 SPR 的平均。现在把翻前钉成
  // 「AI 开 3bb、英雄跟」，翻牌/转牌双方都过牌，只有河牌英雄下 [frac] 池，
  // SPR 于是固定在 11 上下——这一节量到的就只剩「尺度 → 加注率」一条线。
  //
  // 再往下三格是**被过牌到**那一侧：真人不会拿两对和拿顺子用同一套尺寸，
  // 超池（1.2 倍池那条线）是「坚果或空气」的长度，薄两对做的是正常尺寸的
  // 价值注。这三格以前同样是逐字相同的分布（超池桶都占 38%）。
  //
  // 这里横跨怪兽档里的三档成色（同一块 Q♥9♦7♣5♥2♠，只换底牌）：
  //   97 = 两对、99 = 三条(set)、86 补成 5-6-7-8-9 顺子。以前 AI 的怪兽
  // 分支只吃 tier、看不到 category，三种成色对着同一注的读数**逐字相同**
  // （河牌 1.5 倍池都是「跟 62% / 加 38%」）——对手从「他加不加」里读不出
  // 我们是哪一档，我们自己也拿薄两对跟三条一样猛。现在按
  // [HandReading.monsterGrade] 拉开：同一个 1.5 倍池，跟注率
  // 两对 71% > 三条 62% > 顺子 54%，同时各自都还随尺度单调往下；
  // 被过牌到时反过来，超池桶 两对 26% < 三条 48% < 顺子 65%。
  const monsterPreflop = <_Step>[
    (who: 'ai', type: ActionType.raise, amount: 3 * 100),
    (who: 'hero', type: ActionType.call, amount: null),
  ];
  const checkFlopTurn = <_AiStep>[
    (street: Street.flop, type: ActionType.check, amount: null),
    (street: Street.turn, type: ActionType.check, amount: null),
  ];
  for (final frac in [0.5, 1.0, 1.5]) {
    show('  两对 河牌 $frac池',
        _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s',
            target: Street.river,
            preflopScript: monsterPreflop,
            aiScript: checkFlopTurn,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  for (final frac in [0.5, 1.5]) {
    show('  三条 河牌 $frac池',
        _sample(hole: '9h 9c', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s',
            target: Street.river,
            preflopScript: monsterPreflop,
            aiScript: checkFlopTurn,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  // 同一块牌面上的第三、第四种「怪兽」：86 补成 5-6-7-8-9 顺子。加上前面
  // 两对（97）和三条（99），这一节就横跨了怪兽档里的三档成色——它们的读数
  // 以前逐字相同（同一档只看 tier），现在必须拉开：顺子/三条对着大注加注
  // 收价值，两对以跟为主。
  for (final frac in [0.5, 1.5]) {
    show('  顺子 河牌 $frac池',
        _sample(hole: '8h 6h', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s',
            target: Street.river,
            preflopScript: monsterPreflop,
            aiScript: checkFlopTurn,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }
  // 反过来那一侧：三档成色**被过牌到**时怎么下注。真人不会拿两对和拿顺子
  // 用同一套尺寸——超池（1.2 倍池那条线）是给坚果和诈唬用的，薄两对通常
  // 只做正常尺寸的价值注。这里盯的就是超池桶在三种成色之间有没有差别。
  for (final (name, hole) in [
    ('两对', '9h 7d'),
    ('三条', '9h 9c'),
    ('顺子', '8h 6h'),
  ]) {
    show('  $name 河牌 被过牌到',
        _sample(hole: hole, heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s',
            target: Street.river,
            preflopScript: monsterPreflop,
            aiScript: checkFlopTurn));
  }

  sec('');
  sec('== 面对下注：强牌的加注率也要随尺度连续衰减 ==');
  // 加注频率以前被 `bigBet`（≥0.7 池）整条切掉：0.69 池加 31%、0.71 池
  // 永远加 0（翻牌/转牌/河牌三条街一样），而且 0.71 池往上一直到超池全是 0。
  // 对手试出「打大注不会被加」，拿任意两张牌打大注就能白抢底池。现在按尺度
  // 连续压到两成（见 [AiPlayer._bigBetRaiseScale]）；尺度折扣的两个分界点
  // （1/3 池、2/3 池）也从三档常量改成线性过渡——以前 0.35 池加 65%、
  // 0.37 池只剩 48%。这一节盯着这两条曲线：分界点左右必须挨着。
  for (final frac in [0.34, 0.36, 0.5, 0.59, 0.61, 0.69, 0.71, 1.0, 1.5]) {
    show('  顶对顶踢 翻牌 面对方 $frac池',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c',
            target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }
  // 弱成牌（第二对）走的是另一条加注函数 [_valueRaiseChance]，它里面还有
  // 一道 `betSizeRel >= 0.8` 的布尔（0.79 池乘 1.0、0.81 池乘 0.45）。
  // 顶对顶踢那条线走的是 [_strongRaiseChance]，量不到这一道。
  for (final frac in [0.5, 0.7, 0.79, 0.81, 1.0, 1.5]) {
    show('  第二对 87 翻牌 面对方 $frac池',
        _sample(hole: '8h 7s', heroHole: '3c 2h', board: 'Kh 8d 3c',
            target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }
  for (final frac in [0.69, 0.71, 1.0]) {
    show('  顶对顶踢 河牌 面对方 $frac池',
        _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s',
            target: Street.river,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }

  sec('');
  sec('== 面对下注：注越大弃得越多，中间不许有悬崖 ==');
  // 「超池就不封顶」那道门槛（betSizeRel < 1.15）以前是一条硬线，两边是
  // 两个世界：探针实测第二对（有位置）对着 1.14 池弃 9%、对着 1.16 池弃
  // 99%，两头顺 1.14 池弃 0%、1.16 池弃 91%，没位置的顶对弱踢更是
  // 1.14 池弃 0%、1.16 池弃 98%——中间没有任何过渡。对手拿任意两张牌下
  // 1.16 池就能白拿底池，而下 1.14 池又几乎必被跟。
  // 现在门槛换成 1.0~1.2 池之间的线性过渡（[AiPlayer._overbetProgress]），
  // 1.0 池以内和 1.2 池以上跟以前逐点一致。这一节就是盯着这条曲线用：
  // 1.14 和 1.16 必须挨着，中间不该有几十个点的跳变。
  // 1.2 到 1.5 这一段原来是个盲区（采样点直接从 1.2 跳到 1.5），实测
  // 第二对 1.2 池弃 47%、1.5 池弃 96%——中间这 0.3 池里还藏着一次跳变。
  // 这正是这一节要盯的东西，采样点必须铺满整条曲线。
  for (final frac in [1.0, 1.06, 1.1, 1.14, 1.16, 1.2, 1.25, 1.3, 1.35, 1.4, 1.45, 1.5]) {
    show('  第二对 87 面对方 $frac池',
        _sample(hole: '8s 7d', heroHole: '3c 2h', board: 'Kh 8d 3c',
            target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }
  for (final frac in [1.14, 1.16, 1.18, 1.2, 1.25, 1.3, 1.35, 1.4, 1.5, 1.6]) {
    show('  两头顺 98 面对方 $frac池',
        _sample(hole: '9h 8h', heroHole: '3c 2h', board: '7s 6h 2d',
            target: Street.flop,
            heroFirst: {Street.flop: (type: ActionType.bet, frac: frac)}));
  }

  sec('');
  sec('== 河牌第二对：连开三枪 vs 只砸一枪，注越大跟得越少 ==');
  // 弱成牌（第二对）的河牌门槛里有一项是「大注 = 真牌」的余量，而它挂在
  // `bigBet = betSizeRel >= 0.7` 这个布尔上：0.69 池乘 1.0、0.70 池乘
  // 1.35，门槛一步跳 35%。探针实测连开三枪的河牌第二对对着 0.45 池弃
  // 5%、0.70 池弃 90%，中间没有任何过渡——对手把尺度卡在 0.69 池就必被
  // 跟、卡在 0.71 池就稳收底池。这一节把两条线（对手一路开火 / 前面全
  // 过牌再突然砸一枪）的 0.4~1.5 池都铺满，盯的是「中间没有几十个点的
  // 跳变」，只采 0.5/1.0/1.5 会正好跳过那道台阶。
  const aiCallsFlopTurn = <_AiStep>[
    (street: Street.flop, type: ActionType.call, amount: null),
    (street: Street.turn, type: ActionType.call, amount: null),
  ];
  const aiChecksFlopTurn = <_AiStep>[
    (street: Street.flop, type: ActionType.check, amount: null),
    (street: Street.turn, type: ActionType.check, amount: null),
  ];
  for (final frac in [
      0.4, 0.5, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9, 1.0, 1.25, 1.5, 2.0, 2.5
    ]) {
    final pct = '${(100 * frac).round()}%';
    show('  连开三枪 河牌 $pct池',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c 5h 9s',
            target: Street.river, aiScript: aiCallsFlopTurn, seeds: 200,
            facingOnly: true,
            heroFirst: {
              Street.flop: (type: ActionType.bet, frac: 0.6),
              Street.turn: (type: ActionType.bet, frac: 0.6),
              Street.river: (type: ActionType.bet, frac: frac),
            }));
    show('  只砸一枪 河牌 $pct池',
        _sample(hole: '8h 7s', heroHole: '4c 6d', board: 'Kh 8d 3c 5h 9s',
            target: Street.river, aiScript: aiChecksFlopTurn, seeds: 200,
            facingOnly: true,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }

  sec('');
  sec('== 河牌中等牌（顶对好踢）：连开三枪 vs 只砸一枪 ==');
  // 同一个「大注余量」的布尔在中等牌那一档也留着：`if (bigBet) need *= 1.2`。
  // 这一档的胜率本来就压着赔率线（探针里顶对好踢对 0.6 池 eq 0.366 / 赔率
  // 0.375），1.2 这一下会把整条跟注范围直接推下悬崖——实测连开三枪 0.6 池
  // 跟 99%、0.7 池只剩 19%，中间没有任何过渡。这一节按 0.4~1.5 池铺满，
  // 和上面弱成牌那一节同样盯「中间没有几十个点的跳变」。
  //
  // 采样点铺到 2.5 倍池还兼管超池那一段：范围模型读下注尺度的那个乘子在
  // 1.2 倍池就饱和了，「只砸一枪」这条线因此在 1.25~2.5 倍池整段压平成
  // 100/97/92/91%（中等牌那一档的跟注上限就是为它加的，见
  // [AiPlayer._facingBet] 的 overbetCap）。这一段要随尺度单调收，不能是
  // 一条水平线。
  for (final frac in [
      0.4, 0.5, 0.6, 0.65, 0.69, 0.7, 0.71, 0.75, 0.8, 0.9, 1.0, 1.25, 1.5, 2.0,
      2.5
    ]) {
    final pct = '${(100 * frac).round()}%';
    show('  连开三枪 河牌 $pct池',
        _sample(hole: 'Kc Qd', heroHole: '4c 6d', board: 'Kh 8d 3c 5h 9s',
            target: Street.river, aiScript: aiCallsFlopTurn, seeds: 200,
            facingOnly: true,
            heroFirst: {
              Street.flop: (type: ActionType.bet, frac: 0.6),
              Street.turn: (type: ActionType.bet, frac: 0.6),
              Street.river: (type: ActionType.bet, frac: frac),
            }));
    show('  只砸一枪 河牌 $pct池',
        _sample(hole: 'Kc Qd', heroHole: '4c 6d', board: 'Kh 8d 3c 5h 9s',
            target: Street.river, aiScript: aiChecksFlopTurn, seeds: 200,
            facingOnly: true,
            heroFirst: {Street.river: (type: ActionType.bet, frac: frac)}));
  }

  sec('');
  sec('');
  sec('== 位置对照：面对下注时，有位置 vs 没位置 ==');
  pos('空气+后门花 Ad10d on 9d7c2c', hole: 'Ad 10d', board: '9d 7c 2c', frac: 0.33);
  pos('空气+后门花 Kh9h on As7h2c', hole: 'Kh 9h', board: 'As 7h 2c');
  pos('卡顺 76 on A92', hole: '7h 6h', board: 'As 9d 2c');
  pos('花听 AKs on Qd7d2c', hole: 'Ad Kd', board: 'Qd 7d 2c');
  pos('底对 Ah2h on Qh7d2c', hole: 'Ah 2h', board: 'Qh 7d 2c');
  pos('顶对弱踢 Qh3h on Qd7c2s', hole: 'Qh 3h', board: 'Qd 7c 2s');
  pos('顶对顶踢 AhKd on Kh8d3c', hole: 'Ah Kd', board: 'Kh 8d 3c');
  pos('花听（转牌 2/3 池）', hole: 'Ad Kd', board: 'Qd 7d 2c 5h',
      frac: 0.66, street: Street.turn);
  pos('花听+底对（转牌）', hole: 'Ah 2h', board: 'Qh 7d 2c 5h',
      frac: 0.66, street: Street.turn);
  // 下面两行才是「没有听牌的一对牌」：挑牌时注意别让底牌和公共牌凑出
  // 同花听/顺子听（前两行的「底对」其实都带着花听，量出来的是听牌那一档）。
  // 同样避开 A2o（会翻前弃牌）：A2s 配黑桃 2 的牌面，没有花听/顺听。
  pos('底对（转牌 2/3 池）', hole: 'Ah 2h', board: 'Qc 7d 2s 5h',
      frac: 0.66, street: Street.turn);
  pos('第二对（转牌 2/3 池）', hole: '8h 7s', board: 'Kh 8d 3c 5s',
      frac: 0.66, street: Street.turn);

  sec('');
  sec('== 河牌小注抓诈唬：有位置 vs 没位置 == ');
  pos('A 高（河牌 1/4 池）', hole: 'Ad Kd', board: 'Qd 7d 2c 5h 9s',
      frac: 0.25, street: Street.river);
  pos('A 高（河牌 1/3 池）', hole: 'Ad Kd', board: 'Qd 7d 2c 5h 9s',
      frac: 0.33, street: Street.river);
  pos('第二对（河牌 1/4 池）', hole: '8h 7s', board: 'Kh 8d 3c 5h 9s',
      frac: 0.25, street: Street.river);
  pos('底对（河牌 1/4 池）', hole: 'Ah 4h', board: 'Qc 7d 4s 5h 9d',
      frac: 0.25, street: Street.river);
  pos('第二对（河牌 2/3 池）', hole: '8h 7s', board: 'Kh 8d 3c 5h 9s',
      frac: 0.66, street: Street.river);

  sec('');
  sec('== 松凶风格对照 == ');
  show('听花（无人下注）LAG',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop,
          style: AiStyle.looseAggressive));
  show('空气（无人下注）LAG',
      _sample(hole: '9h 8h', heroHole: '3c 2h', board: 'As Kd Qc', target: Street.flop,
          style: AiStyle.looseAggressive));
  show('miss 花（无人下注）LAG',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.looseAggressive));
  show('miss 花（面对 1 池 bet）LAG',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.looseAggressive,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('河牌顶对（面对 1/2 池 bet）LAG',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.looseAggressive,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));

  sec('');
  sec('== 松被动风格对照 == ');
  show('听花（无人下注）LP',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop,
          style: AiStyle.loosePassive));
  show('miss 花（无人下注）LP',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.loosePassive));
  // 跟注站的另一面：小注面前手里完全没东西也跟一张（紧凶是干净地弃）。
  // 上面那些「空气」行量的都是紧凶——它按赔率抓，纯空气的胜率够不上任何
  // 门槛，一律弃；跟注站不一样，他的招牌就是「你打不跑他」。两行并排看，
  // 「跟注站」在牌桌上认不认得出来就一目了然。
  // 注意底池不能只有盲注的 1.5bb：那样 1/3 池（66）比最小下注（1bb=100）
  // 还小，会被夹到 100，量到的是「1/2 池」而不是标题写的 1/3。统一先让
  // AI 开池 3bb、英雄跟，翻牌底池 6bb，1/3 池 = 198 > 100 才真的落到
  // 「小注」那一档。
  final stationPreflop = [
    (who: 'ai', type: ActionType.raise, amount: 3 * 100),
    (who: 'hero', type: ActionType.call, amount: null),
  ];
  show('空气（面对 1/3 池 bet）紧凶',
      _sample(hole: '8h 7h', heroHole: '4c 6d', board: 'As Kd Qc', target: Street.flop,
          preflopScript: stationPreflop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.33)}));
  show('空气（面对 1/3 池 bet）LP',
      _sample(hole: '8h 7h', heroHole: '4c 6d', board: 'As Kd Qc', target: Street.flop,
          style: AiStyle.loosePassive,
          preflopScript: stationPreflop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.33)}));
  show('空气（面对 2/3 池 bet）LP',
      _sample(hole: '8h 7h', heroHole: '4c 6d', board: 'As Kd Qc', target: Street.flop,
          style: AiStyle.loosePassive,
          preflopScript: stationPreflop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.66)}));
  show('成花（面对 1/2 池 bet）LP',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 3d', target: Street.river,
          style: AiStyle.loosePassive,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));

  if (_sectionFilter.isNotEmpty && !_sectionMatched) {
    print('AI_PROBE_SECTION=「$_sectionFilter」没命中任何段落——用 '
        'grep "== " tool/ai_probe.dart 看段落名。');
  }
}
