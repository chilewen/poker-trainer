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
  check(!versus(seat: Seat.sb, hole: '9h 9d', raiser: Seat.btn).call &&
          versus(seat: Seat.sb, hole: '9h 9d', raiser: Seat.btn, callers: 2).call,
      '小盲没人跟注时不平跟 99，有人跟注才便宜买三条');
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

  print('');
  print(exitCode == 0 ? '全部 $_checks 项验证通过' : '存在失败项，共检查 $_checks 项');
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
