import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/hand_history.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/hand_analysis.dart';
import 'package:poker_trainer/features/game/domain/hand_grade.dart';

/// 单手「教学视角」：范围归属、翻前胜率、失误标记。
///
/// 这里的历史是手写的——要精确摆出一副牌和一条行动线，用引擎发牌反而绕。
/// 范围、牌力、赔率那几层各自有用例，这一层只验「怎么判好坏」。
void main() {
  const hero = 'hero';

  List<Card> cards(String text) =>
      text.split(' ').map(Card.parse).toList();

  /// seats 按开局顺序给；heroId 固定为 `hero`。
  HandHistory hand({
    required List<String> seats,
    required List<ActionRecord> actions,
    List<Card> board = const [],
    List<Card> heroHole = const [],
    int buttonIndex = 0,
    Map<String, int> net = const {},
  }) {
    final h = HandHistory(
      id: 'h',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      playerNames: {for (var i = 0; i < seats.length; i++) seats[i]: 'P$i'},
      startingStacks: {for (final s in seats) s: 10000},
      holeCards: {if (heroHole.isNotEmpty) hero: heroHole},
      buttonIndex: buttonIndex,
      smallBlind: 50,
      bigBlind: 100,
    );
    h.board.addAll(board);
    h.actions.addAll(actions);
    h.netResult.addAll(net);
    return h;
  }

  ActionRecord bet(String id, int amount, int potAfter) => ActionRecord(
      street: Street.preflop,
      actorId: id,
      type: ActionType.bet,
      amount: amount,
      potAfter: potAfter);

  ActionRecord act(String id, ActionType type, int potAfter,
          {Street street = Street.preflop, int amount = 0}) =>
      ActionRecord(
          street: street,
          actorId: id,
          type: type,
          amount: amount,
          potAfter: potAfter);

  HandGrade grade(HandHistory h) =>
      HandGrade.of(HandAnalysis.of(h, heroId: hero));

  /// 单挑坐庄，翻牌 KQ9：英雄拿 76s 中不到牌也没听，对手下半个池。
  HandHistory airHand() => hand(
        seats: ['hero', 'p1'],
        heroHole: cards('7h 6h'),
        board: cards('Kh Qd 9c'),
        actions: [
          bet('hero', 50, 50),
          bet('p1', 100, 150),
          act('hero', ActionType.call, 200),
          act('p1', ActionType.check, 200),
          act('p1', ActionType.bet, 400, street: Street.flop, amount: 200),
          act('hero', ActionType.call, 600, street: Street.flop),
        ],
      );

  /// 单挑坐庄，翻牌 9K2：英雄中暗三条，对手只下 1/6 池。
  HandHistory setHand() => hand(
        seats: ['hero', 'p1'],
        heroHole: cards('9h 9d'),
        board: cards('9s Kh 2d'),
        actions: [
          bet('hero', 50, 50),
          bet('p1', 100, 150),
          act('hero', ActionType.raise, 400, amount: 300),
          act('p1', ActionType.call, 600),
          act('p1', ActionType.bet, 700, street: Street.flop, amount: 100),
          act('hero', ActionType.fold, 700, street: Street.flop),
        ],
      );

  test('范围：按钮位开池比枪口宽，K7s 只有按钮能开', () {
    // 6 人桌：hero 在 0 号位、按钮也是 0 → 庄位。
    final btn = grade(hand(
      seats: ['hero', 'p1', 'p2', 'p3', 'p4', 'p5'],
      heroHole: cards('Kh 7h'),
      actions: [
        bet('p1', 50, 50),
        bet('p2', 100, 150),
        act('p3', ActionType.fold, 150),
        act('p4', ActionType.fold, 150),
        act('p5', ActionType.fold, 150),
        act(hero, ActionType.raise, 450, amount: 300),
      ],
    ));
    expect(btn.analysis.heroPosition, '庄位');
    expect(btn.preflopLabel, 'K7s');
    expect(btn.inOpenRange, isTrue);
    expect(btn.mistakes, isEmpty, reason: '按钮开 K7s 是好牌，不该报失误');

    // 同一个 K7s 挪到枪口（hero 在 3 号位、按钮 0）就不该开。
    final ep = grade(hand(
      seats: ['p0', 'p1', 'p2', 'hero', 'p4', 'p5'],
      heroHole: cards('Kh 7h'),
      actions: [
        bet('p1', 50, 50),
        bet('p2', 100, 150),
        act(hero, ActionType.fold, 150),
      ],
    ));
    expect(ep.analysis.heroPosition, '枪口');
    expect(ep.inOpenRange, isFalse);
    expect(ep.mistakes, isEmpty, reason: '枪口弃 K7s 是对的');
  });

  test('失误：枪口能开池的牌先弃了算太紧', () {
    final g = grade(hand(
      seats: ['p0', 'p1', 'p2', 'hero', 'p4', 'p5'],
      heroHole: cards('Ah 10h'),
      actions: [
        bet('p1', 50, 50),
        bet('p2', 100, 150),
        act(hero, ActionType.fold, 150),
      ],
    ));
    expect(g.inOpenRange, isTrue, reason: 'ATo 在前位开池范围里');
    expect(g.mistakes.map((m) => m.kind).toList(), [MistakeKind.preflopTooTight]);
  });

  test('失误：按钮拿 72o 进池算太松', () {
    final g = grade(hand(
      seats: ['hero', 'p1', 'p2', 'p3', 'p4', 'p5'],
      heroHole: cards('7s 2d'),
      actions: [
        bet('p1', 50, 50),
        bet('p2', 100, 150),
        act('p3', ActionType.fold, 150),
        act('p4', ActionType.fold, 150),
        act('p5', ActionType.fold, 150),
        act(hero, ActionType.raise, 450, amount: 300),
      ],
    ));
    expect(g.inOpenRange, isFalse);
    expect(g.mistakes.map((m) => m.kind).toList(), [MistakeKind.preflopTooLoose]);
  });

  test('失误：翻后拿空气牌跟重注 → 跟注没赔率', () {
    final g = grade(airHand());
    final heroes =
        g.analysis.heroFacingBet.firstWhere((d) => d.street == Street.flop);
    expect(heroes.potOdds, closeTo(200 / 600, 1e-9));
    expect(g.mistakes.map((m) => m.kind).toList(), [MistakeKind.badCall]);
  });

  test('失误：成牌很强却面对便宜下注弃牌 → 弃牌太紧', () {
    final g = grade(setHand());
    final fold = g.analysis.heroFacingBet
        .firstWhere((d) => d.street == Street.flop);
    expect(fold.potOdds, lessThanOrEqualTo(HandGrade.cheapPotOdds));
    expect(g.mistakes.map((m) => m.kind).toList(), [MistakeKind.badFold]);
  });

  test('EV：跟注的即时 EV 有正负，且同种子可复现', () {
    final air = grade(airHand());
    final airCall = air.analysis.heroFacingBet
        .firstWhere((d) => d.street == Street.flop);
    final airEv = air.callEv(airCall);
    expect(airEv, isNotNull);
    expect(airEv, lessThan(0), reason: '空气牌跟半个池是负 EV');

    final set = grade(setHand());
    final setCall = set.analysis.heroFacingBet
        .firstWhere((d) => d.street == Street.flop);
    final setEv = set.callEv(setCall);
    expect(setEv, isNotNull);
    expect(setEv, greaterThan(0), reason: '暗三面对 1/6 池，跟注是大正 EV');
    expect(set.callEv(setCall), closeTo(setEv!, 1e-12),
        reason: '同一个决策点算几遍必须是同一个数');
  });

  test('翻前胜率：固定种子可复现，AA 远高于 72o', () {
    double equity(String hole) {
      final h = hand(
        seats: ['hero', 'p1'],
        heroHole: cards(hole),
        actions: [bet('hero', 50, 50), bet('p1', 100, 150)],
      );
      return grade(h).preflopEquity(opponents: 1, seed: 5)!;
    }

    final aces = equity('Ah Ad');
    final trash = equity('7s 2d');
    expect(aces, closeTo(equity('Ah Ad'), 1e-12), reason: '同种子必须同一个数');
    expect(aces, greaterThan(0.8));
    expect(trash, lessThan(0.45));
    expect(aces, greaterThan(trash));
  });
}
