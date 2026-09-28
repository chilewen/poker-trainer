import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/hand_history.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/hero_stats.dart';

/// 英雄打法统计：VPIP / PFR / 3bet / 攻击系数 / 摊牌胜率。
///
/// 历史手写——只要精确摆出「英雄在这手做了什么」，引擎发牌反而不可控。
void main() {
  const hero = 'hero';

  ActionRecord rec(String id, ActionType type, int potAfter,
          {Street street = Street.preflop, int amount = 0}) =>
      ActionRecord(
          street: street,
          actorId: id,
          type: type,
          amount: amount,
          potAfter: potAfter);

  List<Card> cards(String text) =>
      text.split(' ').map(Card.parse).toList();

  HandHistory hand({
    required String id,
    required List<String> seats,
    required List<ActionRecord> actions,
    List<Card> board = const [],
    int buttonIndex = 0,
    required Map<String, int> net,
  }) {
    final h = HandHistory(
      id: id,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      playerNames: {for (var i = 0; i < seats.length; i++) seats[i]: 'P$i'},
      startingStacks: {for (final s in seats) s: 10000},
      holeCards: {hero: cards('Ah Kd')},
      buttonIndex: buttonIndex,
      smallBlind: 50,
      bigBlind: 100,
    );
    h.board.addAll(board);
    h.actions.addAll(actions);
    h.netResult.addAll(net);
    return h;
  }

  test('打法统计：入池、加注、3bet、AF、摊牌各算各的', () {
    // 第 1 手：单挑坐庄，翻前加注，一路过牌到摊牌并赢。
    final h1 = hand(
      id: 'h1',
      seats: ['hero', 'p1'],
      board: cards('2c 7d 9h Js Qc'),
      net: {hero: 300, 'p1': -300},
      actions: [
        rec(hero, ActionType.bet, 50),
        rec('p1', ActionType.bet, 150),
        rec(hero, ActionType.raise, 400, amount: 300),
        rec('p1', ActionType.call, 600),
        rec('p1', ActionType.check, 600, street: Street.flop),
        rec(hero, ActionType.check, 600, street: Street.flop),
        rec('p1', ActionType.check, 600, street: Street.turn),
        rec(hero, ActionType.check, 600, street: Street.turn),
        rec('p1', ActionType.check, 600, street: Street.river),
        rec(hero, ActionType.check, 600, street: Street.river),
      ],
    );

    // 第 2 手：翻前直接弃。既不算入池，也不算摊牌。
    final h2 = hand(
      id: 'h2',
      seats: ['hero', 'p1'],
      net: {hero: -50, 'p1': 50},
      actions: [
        rec(hero, ActionType.bet, 50),
        rec('p1', ActionType.bet, 150),
        rec(hero, ActionType.fold, 150),
      ],
    );

    // 第 3 手：有人加注在前，英雄跟注——这是一次 3bet 机会，但他没 3bet。
    final h3 = hand(
      id: 'h3',
      seats: ['p0', 'p1', 'p2', 'p3', hero, 'p5'],
      buttonIndex: 0,
      net: {hero: -300, 'p3': 750},
      actions: [
        rec('p1', ActionType.bet, 50),
        rec('p2', ActionType.bet, 150),
        rec('p3', ActionType.raise, 450, amount: 300),
        rec(hero, ActionType.call, 750),
        rec('p5', ActionType.fold, 750),
        rec('p0', ActionType.fold, 750),
        rec('p1', ActionType.fold, 750),
        rec('p2', ActionType.fold, 750),
      ],
    );

    final s = HeroStats.from([h1, h2, h3], heroId: hero);
    expect(s.hands, 3);
    expect(s.vpipHands, 2, reason: '加注和跟注都算入池');
    expect(s.vpip, closeTo(2 / 3, 1e-9));
    expect(s.pfr, closeTo(1 / 3, 1e-9));
    expect(s.threeBetChances, 1);
    expect(s.threeBet, 0.0, reason: '面对加注只跟了，没 3bet');
    expect(s.aggressiveActs, 1);
    expect(s.calls, 1);
    expect(s.aggressionFactor, 1.0);
    expect(s.showdowns, 1);
    expect(s.showdownWinRate, 1.0);
    expect(s.wins, 1);
    expect(s.net, -50);
    expect(s.cumulativeNet, [300, 250, -50]);
  });

  test('打法统计：没机会就返回 null，别把 0/0 显示成 0%', () {
    final s = HeroStats.from([
      hand(
        id: 'h1',
        seats: ['hero', 'p1'],
        net: {hero: -50, 'p1': 50},
        actions: [
          rec(hero, ActionType.bet, 50),
          rec('p1', ActionType.bet, 150),
          rec(hero, ActionType.fold, 150),
        ],
      ),
    ], heroId: hero);

    expect(s.hands, 1);
    expect(s.vpip, 0);
    expect(s.pfr, 0);
    expect(s.threeBet, isNull);
    expect(s.aggressionFactor, isNull, reason: '一次没跟过，AF 是「没数据」');
    expect(s.showdownWinRate, isNull);
    expect(s.netPerHand, -50);
  });
}
