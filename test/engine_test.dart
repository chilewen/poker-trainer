import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';
import 'package:poker_trainer/features/game/domain/preflop_ranges.dart';

List<Card> _cs(String s) => s.split(' ').map(Card.parse).toList();

void main() {
  test('引擎冒烟：发牌后盲注入池且轮到枪口', () {
    final g = GameEngine(
      config:
          const GameConfig(startingStack: 1000, smallBlind: 5, bigBlind: 10),
      random: Random(7),
    )
      ..addPlayer('hero', '我')
      ..addPlayer('ai0', 'AI')
      ..addPlayer('ai1', 'AI2')
      ..startHand();
    expect(g.potTotal(), 15);
    expect(g.currentBet, 10);
    expect(g.handOver, isFalse);
  });

  test('Chen 起手牌评分：对子不扣间隔分', () {
    expect(AiPlayer.preflopScore(_cs('Ah Ad')), 20);
    expect(AiPlayer.preflopScore(_cs('9h 9d')), 9);
    expect(AiPlayer.preflopScore(_cs('2h 2d')), 5);
    expect(AiPlayer.preflopScore(_cs('7d 2c')), lessThan(2));
  });

  test('读牌：听牌 outs 与成牌层级', () {
    final flushDraw = HandReading.of(_cs('Ad Kd'), _cs('Qd 7d 2c'));
    expect(flushDraw.flushOuts, 9);
    expect(flushDraw.nutFlushDraw, isTrue);
    expect(flushDraw.tier, HandTier.junk, reason: '只有听牌时还不算成牌');

    expect(HandReading.of(_cs('9h 8h'), _cs('7s 6h 2d')).straightOuts, 8);
    expect(HandReading.of(_cs('9h 8h'), _cs('7s 5h 2d')).straightOuts, 4);
    expect(HandReading.of(_cs('Ah Qd'), _cs('Qh 7d 2c')).tier, HandTier.strong);
    expect(HandReading.of(_cs('Ah 2d'), _cs('Qh 7d 2c')).tier, HandTier.weak);
    expect(
        HandReading.of(_cs('9h 9d'), _cs('9s 6h 2d')).tier, HandTier.monster);
    expect(HandReading.of(_cs('Ad Kd'), _cs('Qd 7d 2c 5h 9s')).drawOuts, 0);
  });

  test('翻前范围：位置越靠后开池越宽，大盲防守最宽', () {
    final ep = PreflopRanges.open(Seat.ep);
    final btn = PreflopRanges.open(Seat.btn);
    PreflopHand h(String s) => PreflopHand.of(_cs(s));

    expect(ep.contains(h('7s 6s')), isFalse, reason: '前位不玩同花连张');
    expect(btn.contains(h('7s 6s')), isTrue, reason: '按钮位可以用同花连张开池');
    expect(ep.contains(h('Ad 4d')), isFalse, reason: '前位不玩 A4s');
    expect(btn.contains(h('Ad 4d')), isTrue, reason: '按钮位偷盲会打 A4s');

    PreflopRange defend(Seat s, bool ip) =>
        PreflopRanges.coldCallRange(seat: s, inPosition: ip);
    expect(defend(Seat.bb, false).contains(h('7s 6s')), isTrue,
        reason: '大盲价格好，同花连张可以防守');
    expect(defend(Seat.btn, true).contains(h('Ad Jc')), isTrue,
        reason: '有位置可以用 AJo 冷跟开池');
    expect(defend(Seat.co, false).contains(h('Ad Jc')), isFalse,
        reason: '没位置冷跟的范围更依赖牌力');

    // 大盲防守：加注越大越紧；短筹码不买三条。
    OpenDefense vs(String hole, double raiseBb, {double stackBb = 100}) =>
        PreflopRanges.versusOpen(
          seat: Seat.bb,
          hand: h(hole),
          raiser: Seat.ep,
          inPosition: false,
          callers: 0,
          raiseBb: raiseBb,
          stackBb: stackBb,
        );
    expect(vs('Qd Jh', 2.2).call, isTrue, reason: '2.2bb 便宜，QJo 可以防守');
    expect(vs('Qd Jh', 3).call, isFalse, reason: '3bb 就弃掉 QJo');
    expect(vs('5h 5d', 3, stackBb: 20).call, isFalse,
        reason: '20bb 没有买三条的隐含赔率');
    expect(vs('Ad Ad', 3).valueThreeBet, isTrue);
  });

  test('翻前位置：AI 前位扔垃圾牌，按钮位会偷盲', () {
    final g = GameEngine(
      config:
          const GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: Random(9),
    );
    for (var i = 0; i < 9; i++) {
      g.addPlayer('p$i', 'P$i');
    }
    g.startHand(holeOverride: {'p3': _cs('7h 2c'), 'p0': _cs('Ad 4d')});
    final ai = AiPlayer(AiStyle.tightAggressive, random: Random(1));

    // 9 人桌翻前第一个行动的是枪口位（大盲下家，p3）。
    final utg = g.pendingAction().player;
    expect(utg.id, 'p3');
    expect(PreflopRanges.seatOf(g, utg), Seat.ep);
    expect(ai.decide(g, utg).type, ActionType.fold, reason: '前位 72o 直接弃');

    final btn = g.players[g.buttonIndex];
    expect(PreflopRanges.seatOf(g, btn), Seat.btn);
    expect(ai.decide(g, btn).type, ActionType.raise, reason: '按钮位 A4s 开池');
  });

  test('补码：补满至起始买入', () {
    final g = GameEngine(random: Random(1))..addPlayer('hero', '我');
    g.players[0].stack = 100;
    expect(g.topUp('hero'), 9900);
    expect(g.players[0].stack, 10000);
    expect(g.topUp('hero'), 0);
  });
}
