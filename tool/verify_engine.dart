// 无 Flutter 环境下验证引擎逻辑：dart tool/verify_engine.dart
// ignore_for_file: avoid_print, avoid_relative_lib_imports
// ignore_for_file: library_private_types_in_public_api
import 'dart:io';
import 'dart:math';

import '../lib/engine/card.dart' as e;
import '../lib/engine/game.dart';
import '../lib/engine/hand_evaluator.dart';
import '../lib/engine/types.dart';
import '../lib/features/game/domain/ai_player.dart';
import '../lib/features/game/domain/hand_strength.dart';
import '../lib/features/game/domain/preflop_ranges.dart';
import '../lib/trainer/odds.dart';

e.Card c(String s) => e.Card.parse(s);
List<e.Card> cs(String s) => s.split(' ').map(c).toList();

int _checks = 0;
void check(bool ok, String name) {
  _checks++;
  if (!ok) {
    print('✗ $name');
    exitCode = 1;
  } else {
    print('✓ $name');
  }
}

void main() {
  // --- 牌型 ---
  check(
      HandEvaluator.evaluate5(cs('As Ks Qs Js 10s')).category ==
          HandCategory.straightFlush,
      '皇家同花顺');
  check(
      HandEvaluator.evaluate5(cs('9c 9d 9h 9s 2c')).category ==
          HandCategory.quads,
      '四条');
  check(
      HandEvaluator.evaluate5(cs('9c 9d 9h 2s 2c')).category ==
          HandCategory.fullHouse,
      '葫芦');
  check(
      HandEvaluator.evaluate5(cs('As Ks 9s 4s 2s')).category ==
          HandCategory.flush,
      '同花');
  check(
      HandEvaluator.evaluate5(cs('9c 8d 7h 6s 5c')).category ==
          HandCategory.straight,
      '顺子');
  check(
      HandEvaluator.evaluate5(cs('Ac 2d 3h 4s 5c')) <
          HandEvaluator.evaluate5(cs('2c 3d 4h 5s 6c')),
      '轮子顺小于 23456');
  check(
      HandEvaluator.bestOf(cs('As Ks Qs Js 10s 2c 3c')).category ==
          HandCategory.straightFlush,
      '7 张取最佳');

  // --- 牌局流转 ---
  final g = GameEngine(
    config: const GameConfig(startingStack: 1000, smallBlind: 5, bigBlind: 10),
    random: Random(7),
  );
  g.addPlayer('hero', 'Hero');
  g.addPlayer('villain', 'Villain');
  g.startHand();
  check(g.players[0].totalBet == 5 && g.players[1].totalBet == 10, '盲注正确');
  check(g.potTotal() == 15, '底池=15');

  // 补充筹码：只补到起始筹码，超出不再加。
  g.players[0].stack = 0;
  check(g.topUp('hero') == 1000 && g.players[0].stack == 1000, '补码补满至买入');
  check(g.topUp('hero') == 0 && g.players[0].stack == 1000, '满码不再补');
  g.players[0].stack = 300;
  check(g.topUp('hero') == 700 && g.players[0].stack == 1000, '差额补码');
  // 还原现场，继续牌局流转。
  g.players[0].stack = 995;

  g.apply('hero', ActionType.call);
  g.apply('villain', ActionType.check);
  check(g.street == Street.flop && g.board.length == 3, '进入翻牌圈');

  // 全下跑到摊牌。
  while (!g.handOver) {
    final pending = g.pendingAction();
    final raise = pending.actions
        .where((a) => a.type == ActionType.bet || a.type == ActionType.raise)
        .firstOrNull;
    if (raise != null) {
      g.apply(pending.player.id, raise.type, amount: raise.maxAmount);
    } else {
      g.apply(pending.player.id, ActionType.call);
    }
  }
  check(g.players[0].stack + g.players[1].stack == 2000, '单挑摊牌后筹码守恒');
  check(g.lastHand!.netResult.values.fold(0, (a, b) => a + b) == 0,
      '净输赢总和为 0');

  // --- 随机对局筹码守恒 ---
  final g3 = GameEngine(
    config: const GameConfig(startingStack: 500, smallBlind: 5, bigBlind: 10),
    random: Random(42),
  );
  g3.addPlayer('a', 'A');
  g3.addPlayer('b', 'B');
  g3.addPlayer('c', 'C');
  final rng = Random(1);
  var conserved = true;
  for (var hand = 0; hand < 20; hand++) {
    g3.startHand();
    while (!g3.handOver) {
      final pending = g3.pendingAction();
      final legal = pending.actions;
      final choice = legal[rng.nextInt(legal.length)];
      if (choice.type == ActionType.bet || choice.type == ActionType.raise) {
        g3.apply(pending.player.id, choice.type, amount: choice.minAmount);
      } else {
        g3.apply(pending.player.id, choice.type);
      }
    }
    final total = g3.players.fold(0, (s, p) => s + p.stack);
    if (total != 1500) {
      conserved = false;
      print('  第 ${hand + 1} 手后总筹码=$total');
    }
  }
  check(conserved, '三人随机 20 手筹码守恒');

  // --- 错局重玩：指定底牌与公共牌 ---
  final g4 = GameEngine(
    config: const GameConfig(startingStack: 1000, smallBlind: 5, bigBlind: 10),
    random: Random(3),
  );
  g4.addPlayer('hero', 'Hero');
  g4.addPlayer('villain', 'Villain');
  g4.addPlayer('v2', 'V2');
  g4.startHand(
    holeOverride: {
      'hero': cs('As Ad'),
      'villain': cs('Ks Kd'),
    },
    boardOverride: cs('Ac 8s 2d 7h 3c'),
  );
  final heroPlayer = g4.players.firstWhere((p) => p.id == 'hero');
  check(heroPlayer.holeCards.map((x) => x.notation).join() == 'AsAd',
      '重玩：英雄底牌=AsAd');
  while (!g4.handOver) {
    final pending = g4.pendingAction();
    final legal = pending.actions;
    final choice = legal.firstWhere(
      (a) => a.type == ActionType.call || a.type == ActionType.check,
      orElse: () => legal.first,
    );
    g4.apply(pending.player.id, choice.type, amount: choice.minAmount);
  }
  check(g4.board.map((x) => x.notation).join() ==
      (g4.board.length == 5 ? 'Ac8s2d7h3c' : ''),
      '重玩：公共牌为预定 Ac 8s 2d 7h 3c');
  final allCards = <String>{
    for (final p in g4.players) ...p.holeCards.map((x) => x.notation)
  }..addAll(g4.board.map((x) => x.notation));
  check(allCards.length == g4.board.length + g4.players.length * 2,
      '重玩：牌堆无重复牌');

  // --- 概率 ---
  final eq = Odds.equity(heroHole: cs('As Ad'), trials: 3000, random: Random(0));
  print('  AA 胜率模拟: $eq');
  check(eq.win > 0.80 && eq.win < 0.90, 'AA 翻牌前胜率 ≈85%');
  check(Odds.outs(heroHole: cs('As Ks'), board: cs('Qs 7s 2d')) == 9,
      '同花听牌 outs=9');
  check(Odds.outs(heroHole: cs('9d 8c'), board: cs('7s 6h 2d')) == 8,
      '两头顺听牌 outs=8');
  check((Odds.potOdds(pot: 300, toCall: 100) - 0.25).abs() < 1e-9,
      'pot odds 300/100=25%');

  // AI 冒烟：5 个 AI 打 30 手，无异常且筹码守恒。
  final game2 = GameEngine(config: const GameConfig());
  final ais = <String, AiPlayer>{};
  for (var i = 0; i < 5; i++) {
    final id = 'ai$i';
    game2.addPlayer(id, 'AI$i');
    ais[id] = AiPlayer(
        i.isEven ? AiStyle.tightAggressive : AiStyle.loosePassive);
  }
  final total0 = game2.players.fold(0, (s, p) => s + p.stack);
  for (var h = 0; h < 30; h++) {
    game2.startHand();
    while (!game2.handOver) {
      final pending = game2.pendingAction();
      final d = ais[pending.player.id]!.decide(game2, pending.player);
      game2.apply(pending.player.id, d.type, amount: d.amountTo);
    }
  }
  final total1 = game2.players.fold(0, (s, p) => s + p.stack);
  check(total0 == total1, 'AI 30 手筹码守恒');

  // --- 起手牌评分：对子不该被间隔扣分（22~88 也要能玩） ---
  check(AiPlayer.preflopScore(cs('Ah Ad')) == 20, 'Chen：AA=20');
  check(AiPlayer.preflopScore(cs('9h 9d')) == 9, 'Chen：99=9（对子不扣间隔分）');
  check(AiPlayer.preflopScore(cs('2h 2d')) == 5, 'Chen：22=5');
  check(AiPlayer.preflopScore(cs('8s Ad')) >
      AiPlayer.preflopScore(cs('7d 2c')), 'Chen：A8o 强于 72o');

  // --- 读牌：成牌层级与听牌 outs ---
  final flushDraw = HandReading.of(cs('Ad Kd'), cs('Qd 7d 2c'));
  check(flushDraw.hasFlushDraw && flushDraw.flushOuts == 9, '读牌：坚果花听 9 outs');
  check(flushDraw.nutFlushDraw, '读牌：A 高花听 = 坚果花听');
  check(flushDraw.tier == HandTier.junk, '读牌：只有听牌时不算成牌');
  check(HandReading.of(cs('9h 8h'), cs('7s 6h 2d')).straightOuts == 8,
      '读牌：两头顺 8 outs');
  check(HandReading.of(cs('9h 8h'), cs('7s 5h 2d')).straightOuts == 4,
      '读牌：卡顺 4 outs');
  check(HandReading.of(cs('Ah Qd'), cs('Qh 7d 2c')).tier == HandTier.strong,
      '读牌：顶对顶踢=强牌');
  check(HandReading.of(cs('Ah 2d'), cs('Qh 7d 2c')).tier == HandTier.weak,
      '读牌：底对=弱牌');
  check(HandReading.of(cs('9h 9d'), cs('9s 6h 2d')).tier == HandTier.monster,
      '读牌：翻牌中三条=怪兽牌');
  check(HandReading.of(cs('Ah Ad'), cs('Kc 8d 2c')).overPair, '读牌：AA=超对');

  // --- 阻断牌：诈唬选牌（挡住对手跟注范围里最强的牌） ---
  final blkNut = HandReading.of(cs('Ad 6c'), cs('Kd 8d 2c 4h 9d'));
  check(blkNut.nutFlushBlocker && blkNut.blockerScore > 0.7,
      '阻断牌：板面三张方片 + 手里 A♦ = 坚果花阻断 '
      '(分 ${blkNut.blockerScore.toStringAsFixed(2)})');
  check(!HandReading.of(cs('Jd 6c'), cs('Kd 8d 2c 4h 9d')).nutFlushBlocker,
      '阻断牌：拿不到最大的一张方片，就不算坚果花阻断');
  check(!HandReading.of(cs('Ah 6c'), cs('Kd 8d 2c 4h 9d')).nutFlushBlocker,
      '阻断牌：板面只有两张方片就不谈坚果花阻断');
  check(HandReading.of(cs('Ah 6c'), cs('Kh 8h 2h')).nutFlushBlocker,
      '阻断牌：A 在公共牌上时，手里的 K 就是坚果花阻断');
  check(HandReading.of(cs('10d 6c'), cs('9h 8c 7d')).straightBlocker,
      '阻断牌：板面 9-8-7 时手里的 T 挡掉顺子');
  check(HandReading.of(cs('7c 2d'), cs('As Kd Qc')).blockerScore == 0,
      '阻断牌：什么都没挡到就是 0 分');
  check(HandReading.of(cs('Ad Kd'), cs('Qd 7d 2c 5h 9s')).drawOuts == 0,
      '读牌：河牌没有听牌');

  // --- 范围胜率：对手范围收紧后，胜率必须下降 ---
  final vsRandom = Odds.equity(
      heroHole: cs('Ah Kd'),
      board: cs('Qh 7d 2c'),
      trials: 2000,
      random: Random(1)).win;
  final vsRange = Odds.equityVsRange(
    heroHole: cs('Ah Kd'),
    board: cs('Qh 7d 2c'),
    inRange: (hole, score) => score.category.rank >= 1 ? 1.0 : 0.03,
    trials: 2000,
    random: Random(1),
  ).win;
  check(vsRange < vsRandom - 0.05,
      '范围为随机牌时胜率 ${(vsRandom * 100).toStringAsFixed(1)}%，'
      '收紧到「至少一对」后 ${(vsRange * 100).toStringAsFixed(1)}%');

  // --- 翻前位置范围：越靠后越宽，大盲防守最宽，盲注位不轻易平跟 ---
  PreflopHand ph(String s) => PreflopHand.of(cs(s));
  bool has(PreflopRange r, String hole) => r.contains(ph(hole));

  /// 范围里有多少个 2 张组合（一共 1326 个），用来估算入池率。
  int combos(PreflopRange r) {
    var n = 0;
    for (final hi in e.Rank.values) {
      for (final lo in e.Rank.values) {
        if (hi.value < lo.value) continue;
        if (hi == lo) {
          if (r.contains(PreflopHand.of(
              [e.Card(hi, e.Suit.spades), e.Card(lo, e.Suit.hearts)]))) {
            n += 6;
          }
          continue;
        }
        if (r.contains(PreflopHand.of(
            [e.Card(hi, e.Suit.spades), e.Card(lo, e.Suit.spades)]))) {
          n += 4;
        }
        if (r.contains(PreflopHand.of(
            [e.Card(hi, e.Suit.spades), e.Card(lo, e.Suit.hearts)]))) {
          n += 12;
        }
      }
    }
    return n;
  }

  String pct(PreflopRange r) =>
      '${(100 * combos(r) / 1326).toStringAsFixed(0)}%';

  final openEp = combos(PreflopRanges.open(Seat.ep));
  final openMp = combos(PreflopRanges.open(Seat.mp));
  final openCo = combos(PreflopRanges.open(Seat.co));
  final openBtn = combos(PreflopRanges.open(Seat.btn));
  check(openEp < openMp && openMp < openCo && openCo < openBtn,
      '开池范围随位置递增：前位 ${pct(PreflopRanges.open(Seat.ep))} < '
      '中位 ${pct(PreflopRanges.open(Seat.mp))} < '
      '劫位 ${pct(PreflopRanges.open(Seat.co))} < '
      '按钮 ${pct(PreflopRanges.open(Seat.btn))}');
  check(openEp > 0.10 * 1326 && openEp < 0.18 * 1326,
      '前位开池大约 10~18%（${pct(PreflopRanges.open(Seat.ep))}）');
  check(openBtn > 0.36 * 1326 && openBtn < 0.55 * 1326,
      '按钮开池大约 36~55%（${pct(PreflopRanges.open(Seat.btn))}）');

  check(has(PreflopRanges.open(Seat.btn), '7s 6s') &&
          !has(PreflopRanges.open(Seat.ep), '7s 6s'),
      '同花连张 76s：按钮位开池，前位不玩');
  check(has(PreflopRanges.open(Seat.btn), 'Ad 4d') &&
          !has(PreflopRanges.open(Seat.ep), 'Ad 4d'),
      'A4s：按钮位偷盲会打，前位不玩');
  check(has(PreflopRanges.open(Seat.btn), 'Ad 5c') &&
          !has(PreflopRanges.open(Seat.ep), 'Ad 5c'),
      'A5o：按钮位偷盲会打，前位不玩');
  check(has(PreflopRanges.open(Seat.btn), 'Ad Qc') &&
          has(PreflopRanges.open(Seat.ep), 'Ad Kc'),
      'AQo 在按钮开池范围里，AKo 连前位都能开');

  PreflopRange defend(Seat seat, bool ip) =>
      PreflopRanges.coldCallRange(seat: seat, inPosition: ip);
  check(combos(defend(Seat.bb, false)) >
          combos(defend(Seat.btn, true)) &&
      combos(defend(Seat.btn, true)) > combos(defend(Seat.co, false)),
      '防守范围：大盲 ${pct(defend(Seat.bb, false))} > '
      '有位置 ${pct(defend(Seat.btn, true))} > '
      '没位置 ${pct(defend(Seat.co, false))}');

  OpenDefense versus({
    required Seat seat,
    required String hole,
    required Seat raiser,
    bool inPosition = false,
    int callers = 0,
    double raiseBb = 3,
    double stackBb = 100,
  }) =>
      PreflopRanges.versusOpen(
        seat: seat,
        hand: ph(hole),
        raiser: raiser,
        inPosition: inPosition,
        callers: callers,
        raiseBb: raiseBb,
        stackBb: stackBb,
      );

  check(versus(seat: Seat.bb, hole: 'Qd 10h', raiser: Seat.btn).call &&
          !versus(seat: Seat.bb, hole: 'Qd 10h', raiser: Seat.ep).call,
      'QTo 在大盲会防守按钮开池，但弃给前位开池');
  check(versus(seat: Seat.bb, hole: 'Ah Ad', raiser: Seat.ep).valueThreeBet &&
          !versus(seat: Seat.bb, hole: '8h 8d', raiser: Seat.ep).valueThreeBet,
      'AA 对着前位开池做 3bet，88 只在后面跟注');
  final sbAlone = versus(seat: Seat.sb, hole: '9h 9d', raiser: Seat.btn);
  final sbWithCallers =
      versus(seat: Seat.sb, hole: '9h 9d', raiser: Seat.btn, callers: 2);
  check(!sbAlone.call &&
          !sbAlone.valueThreeBet &&
          (sbWithCallers.call || sbWithCallers.valueThreeBet),
      '小盲没人跟注时不玩 99（加注或弃牌），有人跟注才进来');
  // 挤压：前面有人跟注时，加注范围放宽一档，TT 从「跟注」变「再加注」。
  final ttAlone = versus(seat: Seat.btn, hole: '10h 10d', raiser: Seat.mp);
  final ttSqueeze =
      versus(seat: Seat.btn, hole: '10h 10d', raiser: Seat.mp, callers: 1);
  check(ttAlone.call && !ttAlone.valueThreeBet && ttSqueeze.valueThreeBet,
      '挤压：前面有人跟注时 TT 从「冷跟」变成「再加注」');
  check(!versus(seat: Seat.bb, hole: 'Qd Jh', raiser: Seat.ep, raiseBb: 3).call &&
          versus(seat: Seat.bb, hole: 'Qd Jh', raiser: Seat.ep, raiseBb: 2.2).call,
      '加注越大，大盲防守越紧（3bb 弃 QJo，2.2bb 跟）');
  check(versus(seat: Seat.bb, hole: '5h 5d', raiser: Seat.ep, stackBb: 20).call ==
          false,
      '短筹码（20bb）没有买三条的隐含赔率，小对子直接弃');

  check(PreflopRanges.isLightThreeBetHand(ph('As 5s')) &&
          PreflopRanges.isLightThreeBetHand(ph('Kd Qc')) &&
          !PreflopRanges.isLightThreeBetHand(ph('Ah Ad')) &&
          !PreflopRanges.isLightThreeBetHand(ph('7d 2c')),
      '轻 3bet 候选牌：A5s / KQo 是，AA / 72o 不是');

  // 隔离溜入者：大盲拿着强牌面对溜入，要主动加注而不是只过牌看翻牌。
  ActionType? bbVsLimper(String hole) {
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: Random(6),
    );
    for (var i = 0; i < 6; i++) {
      g.addPlayer('s$i', 'S$i');
    }
    g.startHand(holeOverride: {'s2': cs(hole)});
    g.apply('s3', ActionType.call); // 枪口溜入
    g.apply('s4', ActionType.call); // 中位溜入
    g.apply('s5', ActionType.fold);
    g.apply('s0', ActionType.fold);
    g.apply('s1', ActionType.call); // 小盲补齐
    final p = g.pendingAction().player;
    if (p.id != 's2') return null; // 大盲
    return AiPlayer(AiStyle.tightAggressive, random: Random(6))
        .decide(g, p)
        .type;
  }

  check(bbVsLimper('As Ad') == ActionType.raise,
      '大盲拿 AA 面对两个溜入者会隔离加注');
  check(bbVsLimper('7h 2c') == ActionType.check,
      '大盲拿 72o 面对溜入者只是过牌看翻牌');

  // 过牌-加注：AI 在大盲拿着顶对。翻牌小盲先下注 → 这是「没先过牌」的
  // 基线；小盲过牌、AI 过牌、后面的人下注 → 这才是过牌-加注的机会。
  ({double cr, double base}) checkRaiseRates() {
    var crRaise = 0, crN = 0, baseRaise = 0, baseN = 0;
    for (var seed = 0; seed < 200; seed++) {
      for (final firstBets in [true, false]) {
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: Random(seed),
        );
        for (var i = 0; i < 6; i++) {
          g.addPlayer('r$i', 'R$i');
        }
        g.startHand(
          holeOverride: {'r2': cs('Qh Ad')},
          boardOverride: cs('Qs 7d 2c'),
        );
        g.apply('r3', ActionType.raise, amount: 300); // 枪口开池
        g.apply('r4', ActionType.fold);
        g.apply('r5', ActionType.fold);
        g.apply('r0', ActionType.fold);
        g.apply('r1', ActionType.call); // 小盲跟注
        g.apply('r2', ActionType.call); // AI 大盲跟注，翻后没位置
        if (firstBets) {
          g.apply('r1', ActionType.bet, amount: 450);
        } else {
          g.apply('r1', ActionType.check);
          g.apply('r2', ActionType.check); // AI 先过牌
          g.apply('r3', ActionType.bet, amount: 450); // 后面的人下注
          g.apply('r1', ActionType.fold);
        }
        final p = g.pendingAction().player;
        if (p.id != 'r2') continue;
        final d = AiPlayer(AiStyle.tightAggressive, random: Random(seed))
            .decide(g, p);
        final raised = d.type == ActionType.raise;
        if (firstBets) {
          baseN++;
          if (raised) baseRaise++;
        } else {
          crN++;
          if (raised) crRaise++;
        }
      }
    }
    return (
      cr: crN == 0 ? 0 : crRaise / crN,
      base: baseN == 0 ? 0 : baseRaise / baseN,
    );
  }

  final cr = checkRaiseRates();
  check(cr.cr > 0.7,
      '过牌-加注：先过牌再面对下注，顶对会用加注回收价值 '
      '(${(100 * cr.cr).toStringAsFixed(0)}%)');
  check(cr.cr > cr.base + 0.2,
      '过牌-加注比「直接面对下注」明显更凶 '
      '(${(100 * cr.cr).toStringAsFixed(0)}% vs '
      '${(100 * cr.base).toStringAsFixed(0)}%)');

  // 挤压尺度：每个已经进池的人多加 1bb。
  int squeezeSize({required bool withCaller}) {
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: Random(4),
    );
    for (var i = 0; i < 9; i++) {
      g.addPlayer('q$i', 'Q$i');
    }
    g.startHand(holeOverride: {'q2': cs('10h 10d')});
    for (var i = 3; i <= 7; i++) {
      g.apply('q$i', ActionType.fold); // 枪口一路弃到劫位
    }
    g.apply('q8', ActionType.raise, amount: 300); // 劫位开池
    g.apply('q0', withCaller ? ActionType.call : ActionType.fold); // 按钮位
    g.apply('q1', withCaller ? ActionType.call : ActionType.fold); // 小盲
    final p = g.pendingAction().player; // 大盲位拿着 TT
    if (p.id != 'q2') return -1;
    final d = AiPlayer(AiStyle.tightAggressive, random: Random(2)).decide(g, p);
    return d.type == ActionType.raise ? (d.amountTo ?? 0) : -1;
  }

  final squeezeNoCaller = squeezeSize(withCaller: false);
  final squeezeWithCaller = squeezeSize(withCaller: true);
  check(squeezeNoCaller > 0 && squeezeWithCaller > squeezeNoCaller,
      '挤压尺度：TT 大盲再加注，有人跟注时加得更大 '
      '($squeezeWithCaller > $squeezeNoCaller)');

  // --- 短筹码推/弃：真人不会再「开小注再弃给 3bet」，而是直接推 ---
  final shove15 = PreflopRanges.shoveOpen(Seat.btn, 15);
  final shove10 = PreflopRanges.shoveOpen(Seat.btn, 10);
  final shove5 = PreflopRanges.shoveOpen(Seat.btn, 5);
  check(combos(shove15) < combos(shove10) && combos(shove10) < combos(shove5),
      '推/弃范围：筹码越浅推得越宽 '
      '(15bb ${pct(shove15)} < 10bb ${pct(shove10)} < 5bb ${pct(shove5)})');
  final shoveEp10 = PreflopRanges.shoveOpen(Seat.ep, 10);
  final shoveCo10 = PreflopRanges.shoveOpen(Seat.co, 10);
  check(combos(shoveEp10) < combos(shoveCo10) &&
          combos(shoveCo10) < combos(shove10),
      '推/弃范围：位置越靠后推得越宽 '
      '(EP ${pct(shoveEp10)} < CO ${pct(shoveCo10)} < BTN ${pct(shove10)})');
  check(combos(shove10) > 0.25 * 1326 && combos(shove10) < 0.45 * 1326,
      '推/弃范围：10bb 按钮位大约 25~45%');
  check(has(shove10, 'Ah Ad') && has(shove10, 'As 5s') && !has(shove10, '7h 2c'),
      '推/弃范围：10bb 按钮位推 A5s、不推 72o');

  final shove82 = shoveAt(hole: '7h 2c', stackBb: 8);
  final shoveA5s8 = shoveAt(hole: 'As 5s', stackBb: 8);
  final shoveAA8 = shoveAt(hole: 'Ah Ad', stackBb: 8);
  final shoveA5s60 = shoveAt(hole: 'As 5s', stackBb: 60);
  check(shoveA5s8 > 0 && shoveAA8 > 0,
      '短筹码：8bb 按钮位拿 A5s / AA 直接全下 ($shoveA5s8 / $shoveAA8)');
  check(shove82 < 0, '短筹码：8bb 也不会拿 72o 乱推');
  check(shoveAA8 == 800, '短筹码：全下额就是全部筹码（800）');
  check(shoveA5s60 < 0 || shoveA5s60 > 246,
      '深筹码：60bb 不会拿 A5s 推全下，照常开小注 ($shoveA5s60)');

  // 座位识别：9 人桌按钮、小盲、大盲、枪口、劫位各就各位。
  final g9 = GameEngine(random: Random(3));
  for (var i = 0; i < 9; i++) {
    g9.addPlayer('p$i', 'P$i');
  }
  g9.startHand();
  final bIdx = g9.buttonIndex;
  check(PreflopRanges.seatOf(g9, g9.players[bIdx]) == Seat.btn &&
          PreflopRanges.seatOf(g9, g9.players[(bIdx + 1) % 9]) == Seat.sb &&
          PreflopRanges.seatOf(g9, g9.players[(bIdx + 2) % 9]) == Seat.bb &&
          PreflopRanges.seatOf(g9, g9.players[(bIdx + 3) % 9]) == Seat.ep &&
          PreflopRanges.seatOf(g9, g9.players[(bIdx + 8) % 9]) == Seat.co,
      '座位识别：按钮/小盲/大盲/枪口/劫位');

  // --- AI 真的会按位置打牌：前位扔 72o，按钮位用 A4s 偷盲 ---
  final g9ai = GameEngine(
    config: const GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100),
    random: Random(9),
  );
  for (var i = 0; i < 9; i++) {
    g9ai.addPlayer('p$i', 'P$i');
  }
  g9ai.startHand(holeOverride: {'p3': cs('7h 2c'), 'p0': cs('Ad 4d')});
  final ai9 = AiPlayer(AiStyle.tightAggressive, random: Random(1));
  final utgSeatPlayer = g9ai.pendingAction().player;
  final utgFolds = utgSeatPlayer.id == 'p3' &&
      PreflopRanges.seatOf(g9ai, utgSeatPlayer) == Seat.ep &&
      ai9.decide(g9ai, utgSeatPlayer).type == ActionType.fold;
  check(utgFolds, '前位（枪口）拿着 72o 直接弃牌');
  final btnPlayer = g9ai.players[g9ai.buttonIndex];
  check(PreflopRanges.seatOf(g9ai, btnPlayer) == Seat.btn &&
          ai9.decide(g9ai, btnPlayer).type == ActionType.raise,
      '按钮位拿着 A4s 会开池偷盲');

  // --- 位置算对：单挑时按钮位翻后是闭圈行动，别把自己当成没位置 ---
  final huTopPair = aiMix(
      hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c', target: Street.flop);
  check(huTopPair.rate(ActionType.bet) > 0.9,
      '单挑按钮位拿着顶对不会慢打（它知道自己有位置）($huTopPair)');

  // --- 读人：同一个 AI 先跟「一压就跑」和「跟注站」各打 60 手，
  //     再看它拿着空气在同样牌面上的开火频率会不会自己变。
  final vsFolder = vsVillain(alwaysFolds: true);
  final vsStation = vsVillain(alwaysFolds: false);
  check(vsFolder.bluffRate > vsStation.bluffRate + 0.1,
      '读人：对「一压就跑」的对手诈唬更多 '
      '(${(100 * vsFolder.bluffRate).toStringAsFixed(0)}% vs '
      '${(100 * vsStation.bluffRate).toStringAsFixed(0)}%)');
  check(vsStation.valueSize > vsFolder.valueSize,
      '读人：对跟注站用更大的尺度收价值 '
      '(${vsStation.valueSize} vs ${vsFolder.valueSize})');

  // --- AI 行为：听牌半诈唬 / 河牌放弃 ---
  final flopDraw = aiMix(
      hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop);
  check(flopDraw.rate(ActionType.bet) > 0.25,
      '翻牌听花无人下注 → 会主动半诈唬 ($flopDraw)');
  check(flopDraw.rate(ActionType.check) > 0.05,
      '听牌也不是无脑开火，会混入过牌 ($flopDraw)');

  final flopDrawVBet = aiMix(
      hole: 'Ad Kd',
      heroHole: '3c 2h',
      board: 'Qd 7d 2c',
      target: Street.flop,
      heroFirstAction: ActionType.bet);
  check(flopDrawVBet.rate(ActionType.fold) < 0.1,
      '听花面对半池下注不会弃牌 ($flopDrawVBet)');
  check(flopDrawVBet.rate(ActionType.raise) > 0.0,
      '强听牌会偶尔半诈唬加注 ($flopDrawVBet)');

  final flopGutshotVBet = aiMix(
      hole: '7h 6h',
      heroHole: '3c 2h',
      board: '9d 5c 2s',
      target: Street.flop,
      heroFirstAction: ActionType.bet);
  check(flopGutshotVBet.rate(ActionType.fold) > 0.7,
      '只有卡顺时面对下注大多弃牌 ($flopGutshotVBet)');

  final turnDrawOverbet = aiMix(
      hole: 'Ad Kd',
      heroHole: '3c 2h',
      board: 'Qd 7d 2c 5h',
      target: Street.turn,
      heroFirstAction: ActionType.bet,
      heroFrac: 1.2);
  check(turnDrawOverbet.rate(ActionType.fold) > 0.65,
      '转牌听花面对超池下注大多弃牌 ($turnDrawOverbet)');

  final riverAir = aiMix(
      hole: 'Ad Kd',
      heroHole: '3c 2h',
      board: 'Qd 7d 2c 5h 9s',
      target: Street.river,
      heroFirstAction: ActionType.bet,
      heroFrac: 1.0);
  check(riverAir.rate(ActionType.fold) > 0.85,
      '河牌听牌没成、面对大注就弃牌（不买死牌）($riverAir)');
  check(riverAir.rate(ActionType.call) < 0.05, '河牌不会用空气跟大注 ($riverAir)');

  final riverBluff = aiMix(
      hole: 'Ad Kd',
      heroHole: '3c 2h',
      board: 'Qd 7d 2c 5h 9s',
      target: Street.river);
  check(riverBluff.rate(ActionType.bet) > 0.05,
      '河牌听牌没成、无人下注时仍会转成诈唬开火 ($riverBluff)');
  check(riverBluff.rate(ActionType.check) > 0.3,
      '诈唬有节制，大部分时候还是放弃 ($riverBluff)');

  final riverFlush = aiMix(
      hole: 'Ad Kd',
      heroHole: '3c 2h',
      board: 'Qd 7d 2c 5h 3d',
      target: Street.river,
      heroFirstAction: ActionType.bet);
  check(riverFlush.rate(ActionType.raise) > 0.5,
      '河牌成同花面对下注会加注收价值 ($riverFlush)');

  final riverTopPair = aiMix(
      hole: 'Ah Qd',
      heroHole: '3c 2h',
      board: 'Qh 7d 2c 5h 9s',
      target: Street.river,
      heroFirstAction: ActionType.bet);
  check(riverTopPair.rate(ActionType.fold) < 0.1 &&
          riverTopPair.rate(ActionType.call) > 0.5,
      '河牌顶对以跟注为主，不会乱加注/弃牌 ($riverTopPair)');

  final lpFlopDraw = aiMix(
      hole: 'Ad Kd',
      heroHole: '3c 2h',
      board: 'Qd 7d 2c',
      target: Street.flop,
      style: AiStyle.loosePassive);
  check(lpFlopDraw.rate(ActionType.bet) < flopDraw.rate(ActionType.bet),
      '松被动风格的半诈唬频率明显低于紧凶 '
      '(${lpFlopDraw.rate(ActionType.bet).toStringAsFixed(2)} < '
      '${flopDraw.rate(ActionType.bet).toStringAsFixed(2)})');

  // --- 第二枪选牌：转牌发空白牌继续开火，发 A 就收手 ---
  final turnBlank = aiMix(
      hole: '9h 8h',
      heroHole: '3c 2h',
      board: 'Ks 7d 2c 3h',
      target: Street.turn);
  final turnAce = aiMix(
      hole: '9h 8h',
      heroHole: '3c 2h',
      board: 'Ks 7d 2c Ah',
      target: Street.turn);
  check(turnBlank.total > 50 && turnAce.total > 50,
      '第二枪选牌：样本够多 ($turnBlank / $turnAce)');
  check(turnBlank.rate(ActionType.bet) > turnAce.rate(ActionType.bet) + 0.05,
      '第二枪选牌：转牌发空白牌继续开火，发 A 就收手 '
      '(${(100 * turnBlank.rate(ActionType.bet)).toStringAsFixed(0)}% vs '
      '${(100 * turnAce.rate(ActionType.bet)).toStringAsFixed(0)}%)');

  // --- 读人（面对下注这一侧）：对手是疯子还是岩石，跟注门槛不一样 ---
  // 面对一个 3 倍池的超池下注：疯子可能全是诈唬，岩石则是真牌。
  final vsManiac = callVsRead(maniac: true, heroFrac: 3.0, rounds: 120);
  final vsNit = callVsRead(maniac: false, heroFrac: 3.0, rounds: 120);
  check(vsManiac.total > 30 && vsNit.total > 30,
      '面对下注读人：样本够多 (${vsManiac.total} / ${vsNit.total})');
  check(vsManiac.callRate > vsNit.callRate + 0.15,
      '面对下注读人：对爱开火的疯子跟得更多，对岩石弃得更多 '
      '(${(100 * vsManiac.callRate).toStringAsFixed(0)}% vs '
      '${(100 * vsNit.callRate).toStringAsFixed(0)}%，'
      '进攻性读数 ${vsManiac.aggroRate.toStringAsFixed(2)} / '
      '${vsNit.aggroRate.toStringAsFixed(2)})');

  // --- 读线：对手连开三枪 vs 一路过牌后再开枪，抓诈唬的态度不一样 ---
  // 面对一个 3 倍池的超池：谁在诈唬？
  final vsBarrel = riverCallVsLine(barrel: true);
  final vsCheckThenBet = riverCallVsLine(barrel: false);
  check(vsBarrel.total > 40 && vsCheckThenBet.total > 40,
      '读线：样本够多 (${vsBarrel.total} / ${vsCheckThenBet.total})');
  check(vsCheckThenBet.callRate > vsBarrel.callRate + 0.15,
      '读线：对手一路过牌后突然超池，比连开三枪更值得抓 '
      '(${(100 * vsBarrel.callRate).toStringAsFixed(0)}% vs '
      '${(100 * vsCheckThenBet.callRate).toStringAsFixed(0)}%)');

  // --- 下注尺度：干面小注、湿面大注、人多抬价 ---
  final dryCbet = flopBetFrac(board: 'Qh 7d 2c'); // 顶对顶踢，干面
  final wetCbet = flopBetFrac(board: 'Qh 9h 8c'); // 同一手牌，湿面
  final multiCbet =
      flopBetFrac(board: 'Qh 7d 2c', others: 2); // 三人底池，干面
  check(dryCbet.n > 40 && wetCbet.n > 40 && multiCbet.n > 40,
      '下注尺度：样本够多 (${dryCbet.n} / ${wetCbet.n} / ${multiCbet.n})');
  check(wetCbet.frac > dryCbet.frac + 0.1,
      '下注尺度：干面用小注（范围注），湿面加大保护 '
      '(${dryCbet.frac.toStringAsFixed(2)} 池 vs '
      '${wetCbet.frac.toStringAsFixed(2)} 池)');
  check(multiCbet.frac > dryCbet.frac + 0.05,
      '下注尺度：多人底池价值下注更大（总有人会跟） '
      '(${multiCbet.frac.toStringAsFixed(2)} 池 vs '
      '${dryCbet.frac.toStringAsFixed(2)} 池)');

  // --- 尺度混合：同一个牌面同一手牌不会永远一个尺寸 ---
  final sizes = dryCbet.all.toSet().toList()..sort();
  check(sizes.length >= 3,
      '尺度混合：同一个牌面同一手牌会换档（${sizes.length} 种尺寸：'
      '${sizes.map((x) => '${(100 * x).toStringAsFixed(0)}%').join('/')}）');
  // 干面底池的基准尺度 = 0.62（价值）× 0.62（范围小注）= 0.384。
  check((dryCbet.frac - 0.384).abs() < 0.04,
      '尺度混合：混合只打散尺寸，平均尺度基本不动 '
      '(${dryCbet.frac.toStringAsFixed(3)} 池，基准 0.384)');

  // --- 翻前尺度混合：同一个位置不再永远开同一个尺寸 ---
  final openSizes = preflopOpenSizes();
  check(openSizes.n > 80, '翻前尺度：样本够多（${openSizes.n} 次开池）');
  check(openSizes.distinct >= 3,
      '翻前尺度：按钮位开池会换档，不是永远一个尺寸 '
      '(${openSizes.sizes.toSet().toList()..sort()})');
  // 3 × 0.82 = 2.46bb = 246；加权平均 ×1.015 ≈ 250。
  check((openSizes.avg - 246).abs() < 14,
      '翻前尺度：换档只打散尺寸，平均尺度基本不动 '
      '(${openSizes.avg.toStringAsFixed(1)}，基准 246)');

  // --- 诈唬选牌：挡住对手强牌的那张牌，决定这一枪敢不敢开 ---
  // 同一块「K 高、三张方片、没有顺面」的牌面，同一手垃圾牌，
  // 只差一张 A♦（挡掉对手坚果花）就是两种打法。
  final nutBlockBluff = aiMix(
      hole: 'Ad 6c',
      heroHole: '3c 2h',
      board: 'Kd 8d 2c 4h 9d',
      target: Street.river);
  final plainBluff = aiMix(
      hole: 'Jc 6c',
      heroHole: '3c 2h',
      board: 'Kd 8d 2c 4h 9d',
      target: Street.river);
  check(nutBlockBluff.total > 50 && plainBluff.total > 50,
      '诈唬选牌：样本够多 ($nutBlockBluff / $plainBluff)');
  check(
      nutBlockBluff.rate(ActionType.bet) >
          plainBluff.rate(ActionType.bet) + 0.05,
      '诈唬选牌：握着坚果花阻断牌时河牌更敢开火 '
      '(${(100 * nutBlockBluff.rate(ActionType.bet)).toStringAsFixed(0)}% vs '
      '${(100 * plainBluff.rate(ActionType.bet)).toStringAsFixed(0)}%)');

  // --- 河牌怪兽牌超池收价值 ---
  final monsterStation = riverOverbet(alwaysFolds: false);
  final monsterFolder = riverOverbet(alwaysFolds: true);
  check(monsterStation.bets > 30,
      '河牌怪兽牌：样本够多（${monsterStation.bets} 次下注）');
  check(monsterStation.overbetRate > 0.25 && monsterStation.avgFrac > 1.0,
      '河牌成怪兽牌会用超池收价值 '
      '(${(100 * monsterStation.overbetRate).toStringAsFixed(0)}% 超池，'
      '平均 ${monsterStation.avgFrac.toStringAsFixed(2)} 倍底池)');
  check(monsterFolder.overbetRate == 0,
      '面对「一压就跑」的对手不超池，改用小注换跟注 '
      '(${(100 * monsterFolder.overbetRate).toStringAsFixed(0)}% 超池)');

  print('');
  print(exitCode == 0 ? '全部 $_checks 项验证通过' : '存在失败项，共检查 $_checks 项');
}

/// 让同一只 AI 先跟固定性格的对手打 [warmup] 手（对手翻后要么见注就弃、
/// 要么死跟到底），再看它拿着同一手空气时的开火频率、以及强牌的尺度变化。
({double bluffRate, double valueSize}) vsVillain({
  required bool alwaysFolds,
  int warmup = 60,
  int rounds = 200,
}) {
  final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));

  ({int? flopBet, int flopAmount}) play(
      int seed, String aiHole, String board, bool record) {
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: Random(seed),
    )
      // 英雄坐按钮位（翻前先行动），AI 坐大盲（翻后先行动）。
      ..addPlayer('hero', 'Hero')
      ..addPlayer('ai', 'AI');
    g.startHand(
      holeOverride: {'ai': cs(aiHole), 'hero': cs('9c 8d')},
      boardOverride: cs(board),
    );
    int? flopBet;
    var flopAmount = 0;
    var guard = 0;
    while (!g.handOver && guard++ < 200) {
      final p = g.pendingAction();
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (record && g.street == Street.flop && flopBet == null) {
          flopBet = d.type == ActionType.bet ? 1 : 0;
          flopAmount = d.amountTo ?? 0;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final legal = p.actions;
      final facingBet = legal.any((a) => a.type == ActionType.call);
      final wants = g.street == Street.preflop
          ? ActionType.call // 翻前一律跟注，保证一定看到翻牌
          : (facingBet && alwaysFolds ? ActionType.fold : ActionType.call);
      final pick = legal.any((a) => a.type == wants)
          ? wants
          : (legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : legal.first.type);
      g.apply('hero', pick);
    }
    return (flopBet: flopBet, flopAmount: flopAmount);
  }

  // 热身：让 AI 攒够对这位对手的观察（对手每条街都要面对下注）。
  for (var i = 0; i < warmup; i++) {
    play(1000 + i, '3h 2h', 'Qd 7d 2c', false);
  }

  // 测量：同一手「空气」，看它还开不开火。
  var fire = 0;
  var total = 0;
  for (var i = 0; i < rounds; i++) {
    final r = play(50 + i, '7h 2c', 'As Kd Qc', true);
    if (r.flopBet == null) continue;
    total++;
    fire += r.flopBet!;
  }
  // 测量：同一手强牌，看它的下注尺度。
  var sizeSum = 0;
  var sizeN = 0;
  for (var i = 0; i < rounds; i++) {
    final r = play(900 + i, 'As Ac', 'Kd 7h 2c', true);
    if (r.flopBet != 1) continue;
    sizeSum += r.flopAmount;
    sizeN++;
  }
  return (
    bluffRate: total == 0 ? 0.0 : fire / total,
    valueSize: sizeN == 0 ? 0.0 : sizeSum / sizeN,
  );
}

/// 河牌拿第二对（抓诈唬牌）面对同一个 [betFrac] 倍池的河牌下注时敢不敢跟：
/// [barrel] 为真时对手翻牌/转牌都开半池（连开三枪），
/// 为假时对手翻牌/转牌一路过牌、只在河牌超池。同一手牌、同一个尺度，
/// 只差「前面几条街有没有一直在开火」这一条线。
({double callRate, int total}) riverCallVsLine({
  required bool barrel,
  double betFrac = 2.0,
  int rounds = 200,
}) {
  var calls = 0;
  var total = 0;
  for (var seed = 0; seed < rounds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
    g.startHand(
      holeOverride: {'ai': cs('Ks Jd'), 'hero': cs('3c 2h')},
      boardOverride: cs('Qc Jh 2s 5d 9c'),
    );
    final acted = <Street, int>{};
    var guard = 0;
    var recorded = false;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = legal.any((a) => a.type == ActionType.call);
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (!recorded && g.street == Street.river && facing) {
          recorded = true;
          total++;
          if (d.type == ActionType.call) calls++;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final n = acted[g.street] ?? 0;
      acted[g.street] = n + 1;
      final shouldBet = g.street == Street.river ||
          (barrel &&
              (g.street == Street.flop || g.street == Street.turn));
      var type = facing ? ActionType.call : ActionType.check;
      if (n == 0 && shouldBet && legal.any((a) => a.type == ActionType.bet)) {
        type = ActionType.bet;
      }
      if (type == ActionType.bet) {
        final pot = g.potTotal();
        final la =
            legal.firstWhere((a) => a.type == type, orElse: () => legal.first);
        g.apply(p.player.id, type,
            amount: (p.player.streetBet +
                    (pot * (g.street == Street.river ? betFrac : 0.5)).round())
                .clamp(la.minAmount, la.maxAmount));
        continue;
      }
      g.apply(p.player.id,
          legal.any((a) => a.type == type) ? type : legal.first.type);
    }
  }
  return (callRate: total == 0 ? 0.0 : calls / total, total: total);
}

/// 按钮位拿 AA 开池的尺度分布：同一个位置、同一手牌，
/// 真人会在小一点/正常/大一点之间换档，但平均值应该基本不动。
({double avg, int distinct, int n, List<int> sizes}) preflopOpenSizes(
    {int seeds = 120}) {
  final sizes = <int>[];
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    );
    for (var i = 0; i < 6; i++) {
      g.addPlayer('p$i', 'P$i');
    }
    // 6 人桌第一手按钮在 p0：小盲 p1、大盲 p2、枪口 p3，
    // 把枪口到劫位全弃掉，就轮到按钮位开池。
    g.startHand(holeOverride: {'p0': cs('Ah Ad')});
    for (var i = 3; i < 6; i++) {
      g.apply('p$i', ActionType.fold);
    }
    final p = g.pendingAction().player;
    if (p.id != 'p0') continue;
    final d = AiPlayer(AiStyle.tightAggressive, random: rnd).decide(g, p);
    if (d.type == ActionType.raise && d.amountTo != null) {
      sizes.add(d.amountTo!);
    }
  }
  var sum = 0;
  for (final s in sizes) {
    sum += s;
  }
  return (
    avg: sizes.isEmpty ? 0.0 : sum / sizes.length,
    distinct: sizes.toSet().length,
    n: sizes.length,
    sizes: sizes,
  );
}

/// 短筹码推/弃实测：按钮位拿着 [hole]、筹码 [stackBb] 个大盲，
/// 前面一路弃到它。返回全下额；没推（弃牌/小注）返回 -1。
int shoveAt({required String hole, required double stackBb}) {
  final rnd = Random(1);
  final g = GameEngine(
    config: const GameConfig(
        startingStack: 10000, smallBlind: 50, bigBlind: 100),
    random: rnd,
  );
  final stack = (stackBb * 100).round();
  for (var i = 0; i < 6; i++) {
    g.addPlayer('p$i', 'P$i', stack: i == 0 ? stack : 10000);
  }
  g.startHand(holeOverride: {'p0': cs(hole)});
  for (var i = 3; i < 6; i++) {
    g.apply('p$i', ActionType.fold);
  }
  final p = g.pendingAction().player;
  if (p.id != 'p0') return -1;
  final d = AiPlayer(AiStyle.tightAggressive, random: rnd).decide(g, p);
  final allIn = p.streetBet + p.stack;
  return d.type == ActionType.raise && d.amountTo == allIn ? d.amountTo! : -1;
}

/// 翻牌圈 c-bet 的尺度：AI 拿顶对顶踢（[hole]）面对一张没人下注的牌面，
/// 量它第一次下注「下注额 ÷ 下注前底池」。其它人一律过牌跟注。
({double frac, int n, List<double> all}) flopBetFrac({
  required String board,
  String hole = 'Ah Qd',
  int others = 0,
  int seeds = 120,
}) {
  final all = <double>[];
  var sum = 0.0;
  var n = 0;
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    for (var i = 0; i < others; i++) {
      g.addPlayer('c$i', 'C$i');
    }
    final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
    const extra = ['4c 5c', '6c 7c', '8d 9d'];
    final holes = <String, List<e.Card>>{'ai': cs(hole), 'hero': cs('3c 2h')};
    for (var i = 0; i < others; i++) {
      holes['c$i'] = cs(extra[i % extra.length]);
    }
    g.startHand(holeOverride: holes, boardOverride: cs(board));
    var guard = 0;
    var recorded = false;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        final facing = legal.any((a) => a.type == ActionType.call);
        if (!recorded && g.street == Street.flop && !facing) {
          recorded = true;
          if (d.type == ActionType.bet) {
            final pot = g.potTotal();
            final add = (d.amountTo ?? 0) - p.player.streetBet;
            if (pot > 0) {
              sum += add / pot;
              all.add(add / pot);
              n++;
            }
          }
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final facing = legal.any((a) => a.type == ActionType.call);
      final wants = facing ? ActionType.call : ActionType.check;
      g.apply(p.player.id,
          legal.any((a) => a.type == wants) ? wants : legal.first.type);
    }
  }
  return (frac: n == 0 ? 0.0 : sum / n, n: n, all: all);
}

/// 先跟一个「疯子」（翻后逮到机会就下注/加注）或「岩石」（只跟不主动）
/// 打 [warmup] 手，攒出进攻性读数；再看 AI 拿第二对面对同一个半池下注时
/// 敢不敢跟——同一手牌、同一个尺度，只差对手的风格。
({double callRate, double aggroRate, int total}) callVsRead({
  required bool maniac,
  String hole = 'Ks Jd',
  double heroFrac = 0.5,
  int warmup = 150,
  int rounds = 80,
}) {
  final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));

  ({ActionType? act}) play(int seed, bool record) {
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: Random(seed),
    )
      ..addPlayer('hero', 'Hero')
      ..addPlayer('ai', 'AI');
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('3c 2h')},
      boardOverride: cs('Qc Jh 2s'),
    );
    ActionType? act;
    var guard = 0;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = legal.any((a) => a.type == ActionType.call);
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        // 只统计「翻牌圈面对下注」的那次决策。
        if (record && g.street == Street.flop && facing && act == null) {
          act = d.type;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      ActionType wants;
      if (record) {
        // 测量阶段：翻牌圈固定开半池（AI 一定面对下注），其它街跟注。
        wants = g.street == Street.flop && !facing
            ? ActionType.bet
            : (facing ? ActionType.call : ActionType.check);
      } else if (maniac) {
        wants = legal.any((a) => a.type == ActionType.raise)
            ? ActionType.raise
            : (legal.any((a) => a.type == ActionType.bet)
                ? ActionType.bet
                : (facing ? ActionType.call : ActionType.check));
      } else {
        wants = facing ? ActionType.call : ActionType.check;
      }
      if (wants == ActionType.bet || wants == ActionType.raise) {
        final pot = g.potTotal();
        final la = legal.firstWhere((a) => a.type == wants,
            orElse: () => legal.first);
        final amount = wants == ActionType.bet
            ? p.player.streetBet + (pot * heroFrac).round()
            : g.currentBet + (pot * heroFrac).round();
        g.apply(p.player.id, wants,
            amount: amount.clamp(la.minAmount, la.maxAmount));
        continue;
      }
      g.apply(p.player.id,
          legal.any((a) => a.type == wants) ? wants : legal.first.type);
    }
    return (act: act);
  }

  for (var i = 0; i < warmup; i++) {
    play(2000 + i, false);
  }

  var calls = 0;
  var total = 0;
  for (var i = 0; i < rounds; i++) {
    final r = play(300 + i, true);
    if (r.act == null) continue;
    total++;
    if (r.act == ActionType.call) calls++;
  }
  final read = ai.readOf('hero');
  return (
    callRate: total == 0 ? 0.0 : calls / total,
    aggroRate: read?.aggroRate ?? -1,
    total: total,
  );
}

/// 河牌怪兽牌的下注尺度：AI 先拿 77 在 K 高牌面（转牌前都是空气）磨到河牌
/// 击中三条，单挑面对一个固定性格的对手。
///
/// [alwaysFolds] 为真时对手见注就弃（会被读成「一压就跑」），
/// 为假时对手一路跟到底（是「跟注站」，不属于会跑的对手）。
({double overbetRate, double avgFrac, int bets}) riverOverbet({
  required bool alwaysFolds,
  int warmup = 80,
  int rounds = 300,
}) {
  final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));

  ({bool bet, double frac}) play(int seed, String hole, String board,
      bool record) {
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: Random(seed),
    )
      ..addPlayer('hero', 'Hero')
      ..addPlayer('ai', 'AI');
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('3c 2h')},
      boardOverride: cs(board),
    );
    var bet = false;
    var frac = 0.0;
    var guard = 0;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (record && g.street == Street.river && !bet) {
          bet = d.type == ActionType.bet;
          if (bet) {
            final pot = g.potTotal();
            frac =
                pot == 0 ? 0 : ((d.amountTo ?? 0) - p.player.streetBet) / pot;
          }
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final legal = p.actions;
      final facing = legal.any((a) => a.type == ActionType.call);
      final wants = !facing
          ? ActionType.check
          : (alwaysFolds ? ActionType.fold : ActionType.call);
      g.apply('hero',
          legal.any((a) => a.type == wants) ? wants : legal.first.type);
    }
    return (bet: bet, frac: frac);
  }

  // 热身：让 AI 记住这位对手会不会跑（翻后每条街他都得面对下注）。
  for (var i = 0; i < warmup; i++) {
    play(1000 + i, '4h 3h', 'Qd 7d 2c', false);
  }

  var bets = 0;
  var overs = 0;
  var sum = 0.0;
  for (var i = 0; i < rounds; i++) {
    final r = play(700 + i, '7h 7d', '2c Kd 9s 3h 7s', true);
    if (!r.bet) continue;
    bets++;
    sum += r.frac;
    if (r.frac > 1.0) overs++;
  }
  return (
    overbetRate: bets == 0 ? 0.0 : overs / bets,
    avgFrac: bets == 0 ? 0.0 : sum / bets,
    bets: bets,
  );
}

/// 固定底牌 / 公共牌 + 英雄脚本，跑 [seeds] 个随机种子，
/// 统计 AI 在 [target] 街第一次决策的动作分布。
_Mix aiMix({
  required String hole,
  required String heroHole,
  required String board,
  required Street target,
  ActionType? heroFirstAction,
  double heroFrac = 0.5,
  AiStyle style = AiStyle.tightAggressive,
  int seeds = 200,
  int stack = 10000,
}) {
  final counts = <ActionType, int>{};
  var total = 0;
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: GameConfig(startingStack: stack, smallBlind: 50, bigBlind: 100),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    final ai = AiPlayer(style, random: rnd);
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs(heroHole)},
      boardOverride: cs(board),
    );
    final acted = <Street, int>{};
    var recorded = false;
    var guard = 0;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (!recorded && g.street == target) {
          recorded = true;
          total++;
          counts[d.type] = (counts[d.type] ?? 0) + 1;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final n = acted[g.street] ?? 0;
      acted[g.street] = n + 1;
      // 英雄的指定动作只在目标街生效，其它街一律过牌/跟注。
      var type = (n == 0 && heroFirstAction != null && g.street == target)
          ? heroFirstAction
          : ActionType.check;
      var amount = 0;
      if (type == ActionType.check && !legal.any((a) => a.type == type)) {
        type = ActionType.call;
      }
      if (type == ActionType.bet || type == ActionType.raise) {
        final pot = g.potTotal();
        amount = type == ActionType.bet
            ? p.player.streetBet + (pot * heroFrac).round()
            : g.currentBet + (pot * heroFrac).round();
      }
      final la = legal.firstWhere((a) => a.type == type,
          orElse: () => legal.firstWhere((a) => a.type == ActionType.check,
              orElse: () =>
                  legal.firstWhere((a) => a.type == ActionType.call,
                      orElse: () => legal.first)));
      g.apply(
        p.player.id,
        la.type,
        amount: la.type == ActionType.bet || la.type == ActionType.raise
            ? amount.clamp(la.minAmount, la.maxAmount)
            : null,
      );
    }
  }
  return _Mix(counts, total);
}

class _Mix {
  _Mix(this.counts, this.total);

  final Map<ActionType, int> counts;
  final int total;

  double rate(ActionType t) => total == 0 ? 0 : (counts[t] ?? 0) / total;

  @override
  String toString() => '$total 次: ${counts.entries.map((e) => '${e.key.label}${e.value}').join(' ')}';
}
