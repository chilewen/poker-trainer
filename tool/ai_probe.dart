// 定向试探 AI 的单点决策：dart tool/ai_probe.dart
// 用固定底牌 / 公共牌 + 英雄脚本，跑很多个随机种子，
// 看电脑玩家在各种局面的动作分布是否合理。
//
// 只跑其中一节（改完一处 AI 时最常用，整跑约 42 秒、一节 1 秒内）：
//   AI_PROBE_SECTION=强牌的加注率 dart tool/ai_probe.dart
// 段落名就是源码里 `sec('== xx ==')` 的 xx，grep "== " tool/ai_probe.dart 可列全。
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
/// 回归里会按格子拆片并行），
/// 看一段通常一秒以内。没命中的段落连模拟都不跑——在 [_sample] 里直接
/// 短路返回 skipped，省的是实打实的 CPU，不是只把打印关掉。
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

  /// [pot] = 决策时的底池，[ref] = 加注前的最高注（下注时为 0）。
  /// 下注/加注不按绝对筹码分类，而是按「相对底池的档位」（5% 一档）——
  /// 尺度混合之后同一个局面会有好几档尺寸，绝对数字看着就是一团乱麻。
  void add(AiDecision d, {required int pot, required int ref}) {
    total++;
    var key = d.type.label;
    if ((d.type == ActionType.bet || d.type == ActionType.raise) && pot > 0) {
      final frac = ((d.amountTo ?? 0) - ref) / pot;
      final bucket = (frac * 20).round() / 20;
      key = '${d.type.label} ~${(100 * bucket).toStringAsFixed(0)}%池';
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
          final sized = la.type == ActionType.bet || la.type == ActionType.raise
              ? (f.amount ?? la.minAmount).clamp(la.minAmount, la.maxAmount)
              : null;
          g.apply('ai', la.type, amount: sized);
          continue;
        }
        final d = ai.decide(g, p.player);
        final facing = g.currentBet > p.player.streetBet;
        if (!recorded && g.street == target && (!facingOnly || facing)) {
          recorded = true;
          res.add(
            d,
            pot: g.potTotal(),
            ref: d.type == ActionType.bet ? p.player.streetBet : g.currentBet,
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
    out(r.skipped ? null : '${name.padRight(34)} $r');
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
  for (final frac in [
      0.4, 0.5, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9, 1.0, 1.25, 1.5, 2.0, 2.5
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
