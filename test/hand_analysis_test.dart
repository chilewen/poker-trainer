import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/hand_analysis.dart';

/// 单手复盘数据：位置、行动线、底池与赔率。
///
/// 数据全部从 `HandHistory` 推，不额外落盘；这里用引擎真打一手来验算，
/// 而不是手写一份历史——手写的历史改了引擎也不会跟着变。
void main() {
  const hero = 'hero';
  const ai = 'ai0';
  const config =
      GameConfig(startingStack: 1000, smallBlind: 5, bigBlind: 10);

  /// 单挑，英雄坐按钮（= 小盲，单挑里按钮先说话）。
  GameEngine newHeadsUp() {
    final g = GameEngine(config: config, random: Random(1))
      ..addPlayer(hero, '我')
      ..addPlayer(ai, '紧凶·AI1');
    g.buttonIndex = -1; // startHand 里 +1 → 0 = 英雄坐按钮
    g.startHand();
    return g;
  }

  test('分析：位置、盲注、底池赔率都从历史里推得出来', () {
    final g = newHeadsUp();
    g.apply(hero, ActionType.raise, amount: 30); // 加注到 30
    g.apply(ai, ActionType.call); // 跟 20
    g.apply(ai, ActionType.bet, amount: 40); // 翻牌：大盲先说话，下 40
    g.apply(hero, ActionType.call); // 跟 40
    g.apply(ai, ActionType.check); // 转牌
    g.apply(hero, ActionType.check);
    g.apply(ai, ActionType.check); // 河牌
    g.apply(hero, ActionType.check);

    final a = HandAnalysis.of(g.lastHand!, heroId: hero);

    expect(a.heroPosition, '庄位', reason: '单挑里按钮位就是庄位');
    expect(a.nPlayers, 2);
    expect(a.heroSeat, 0);

    // 前两条是盲注（记录里也是 bet），不当作「面对下注」的决策。
    final sb = a.decisions[0];
    final bb = a.decisions[1];
    expect(sb.isBlind, isTrue);
    expect(sb.type, ActionType.bet);
    expect(sb.amountIn, 5, reason: '单挑里按钮投小盲');
    expect(sb.toCall, 0);
    expect(bb.isBlind, isTrue);
    expect(bb.amountIn, 10);
    expect(bb.position, '大盲');

    // 英雄加注前：底池 15（小盲 5 + 大盲 10），还要补 5 才跟得上大盲。
    final raise = a.decisions[2];
    expect(raise.isHero, isTrue);
    expect(raise.toCall, 5);
    expect(raise.potBefore, 15);
    expect(raise.potOdds, closeTo(5 / 20, 1e-9), reason: '5 跟 15，保本 25%');
    expect(raise.stackBefore, 995, reason: '小盲已经先投出去了');

    // 翻牌大盲下 40：英雄面对 40 的底池赔率 = 40 / (100 + 40)。
    final heroCall =
        a.heroFacingBet.firstWhere((d) => d.street == Street.flop);
    expect(heroCall.street, Street.flop);
    expect(heroCall.toCall, 40);
    expect(heroCall.potBefore, 100);
    expect(heroCall.amountIn, 40);
    expect(heroCall.potOdds, closeTo(40 / 140, 1e-9));

    // 翻牌圈底池 60，双方各剩 970 → SPR 970/60。
    expect(a.potPreflop, 60);
    expect(a.potAtFlop, 60);
    expect(a.effectiveStackAtFlop, 970);
    expect(a.spr, closeTo(970 / 60, 1e-6));

    // 行动线：翻前盲注 + 加注跟注，翻牌下注跟注，转/河都过牌。
    expect(a.actionLine, contains('翻牌前 小盲 5 → 大盲 10 → 我 加注到 30 → 大盲 跟注 20'));
    expect(a.actionLine, contains('翻牌 大盲 下注 40 → 我 跟注 40'));
    expect(a.actionLine, contains('转牌 大盲 过牌 → 我 过牌'));
    expect(a.lines.first.street, Street.preflop);
  });

  test('分析：翻前就结束的手没有 SPR，底池就是翻前底池', () {
    final g = newHeadsUp();
    g.apply(hero, ActionType.fold);

    final a = HandAnalysis.of(g.lastHand!, heroId: hero);
    expect(a.potAtFlop, isNull);
    expect(a.spr, isNull);
    expect(a.effectiveStackAtFlop, isNull);
    expect(a.potPreflop, 15, reason: '只有盲注进了池');
    expect(a.heroNet, -5, reason: '弃掉小盲');
    // 小盲弃牌也是「面对下注」：补 5 去赢 15，保本 25%——这条得算出来，
    // 不然复盘时会以为这里可以白看翻牌。
    final sbFold = a.heroFacingBet.single;
    expect(sbFold.street, Street.preflop);
    expect(sbFold.toCall, 5);
    expect(sbFold.potBefore, 15);
    expect(sbFold.potOdds, closeTo(0.25, 1e-9));
    expect(sbFold.type, ActionType.fold);
  });

  test('分析：每个决策点都能对上底池的变化', () {
    // 跑几种人数/随机种子，逐条核对「动作前的底池 + 这一步投的 = 动作后的底池」。
    for (final players in [2, 3, 6]) {
      for (var seed = 0; seed < 3; seed++) {
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 2000, smallBlind: 10, bigBlind: 20),
          random: Random(seed),
        );
        for (var i = 0; i < players; i++) {
          g.addPlayer(i == 0 ? hero : 'ai$i', i == 0 ? '我' : '松凶·AI$i');
        }
        g.startHand();
        var guard = 0;
        while (!g.handOver && guard++ < 200) {
          final pending = g.pendingAction();
          final legal = g.legalActions(pending.player);
          final raise = legal.lastWhere(
              (l) => l.type == ActionType.raise || l.type == ActionType.bet,
              orElse: () => legal.first);
          final choice = legal.length > 1 &&
                  (pending.player.id == hero && seed.isEven)
              ? raise
              : legal.first;
          g.apply(pending.player.id,
              choice.type,
              amount: choice.type == ActionType.raise ||
                      choice.type == ActionType.bet
                  ? choice.maxAmount
                  : null);
        }

        final a = HandAnalysis.of(g.lastHand!, heroId: hero);
        expect(a.decisions.length, g.lastHand!.actions.length);
        for (final d in a.decisions) {
          expect(d.potBefore + d.amountIn, d.potAfter,
              reason: '第 ${d.index} 步：底池对不上');
          expect(d.potOdds, inInclusiveRange(0, 1));
          expect(d.stackBefore, greaterThanOrEqualTo(0));
        }
        // 走到翻牌才有 SPR，而且一定非负。
        expect(a.potAtFlop == null, a.spr == null);
        if (a.spr != null) expect(a.spr, greaterThanOrEqualTo(0));
        expect(a.finalPot, g.lastHand!.finalPot);
      }
    }
  });
}
