import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/hand_evaluator.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/data/table_session.dart';
import 'package:poker_trainer/features/game/data/table_session_store.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';
import 'package:poker_trainer/features/game/domain/table_restore.dart';
import 'package:poker_trainer/features/game/presentation/table_controller.dart';
import 'package:poker_trainer/features/game/domain/preflop_ranges.dart';
import 'package:poker_trainer/trainer/odds.dart';

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

  test('读牌：阻断牌（诈唬选牌用）', () {
    // 牌面三张方片，手里握着 A♦：对手的坚果花被挡掉。
    final nut = HandReading.of(_cs('Ad 6c'), _cs('Kd 8d 2c 4h 9d'));
    expect(nut.nutFlushBlocker, isTrue);
    expect(nut.blockerScore, greaterThan(0.7));

    // 手里是 J♦（A♦ 还在牌堆里）→ 什么都没挡掉。
    final low = HandReading.of(_cs('Jd 6c'), _cs('Kd 8d 2c 4h 9d'));
    expect(low.nutFlushBlocker, isFalse);
    expect(low.blockerScore, 0.0);

    // A♦ 已经在公共牌上，手里的 K♦ 就成了坚果花阻断。
    expect(HandReading.of(_cs('Ah 6c'), _cs('Kh 8h 2h')).nutFlushBlocker,
        isTrue);
    // 公共牌只有两张同花：谈不上坚果花阻断。
    expect(HandReading.of(_cs('Ah 6c'), _cs('Kd 8d 2c 4h 9d')).nutFlushBlocker,
        isFalse);

    // 顺子阻断：牌面 9-8-7，手里的 T 正好补顺。
    expect(HandReading.of(_cs('10d 6c'), _cs('9h 8c 7d')).straightBlocker,
        isTrue);

    // 空气牌什么都没挡到。
    expect(HandReading.of(_cs('7c 2d'), _cs('As Kd Qc')).blockerScore, 0.0);
  });

  test('范围胜率：河牌圈收紧对手范围后，胜率要明显低于对随机牌', () {
    // 顶对弱踢（K9）在 K-J-8-2-3 的河牌面。
    final hole = _cs('Ks 9h');
    final board = _cs('Kd Jc 8h 2s 3d');
    // 对手连开三枪的范围：两对以上为主，一对留一点，纯空气极少。
    double inRange(List<Card> h, HandScore s) => s.category.rank >= 2
        ? 1.0
        : (s.category.rank == 1 ? 0.3 : 0.04);

    double vsRangeWith(int seed) => Odds.equityVsRange(
          heroHole: hole,
          board: board,
          inRange: inRange,
          trials: 4000,
          random: Random(seed),
        ).win;

    final vsRandom = Odds.equity(
      heroHole: hole,
      board: board,
      trials: 4000,
      random: Random(1),
    ).win;
    final vsRange = vsRangeWith(1);
    final vsRange2 = vsRangeWith(2);

    expect(vsRandom, greaterThan(0.85)); // 对随机牌，顶对是大优势
    // 早先的实现把牌堆里相邻两张配成一手（整个牌堆只凑出十几个组合），
    // 范围等于没生效，同样条件下会算出 ≈0.87（跟对随机牌差不多）。
    expect(vsRange, lessThan(0.70),
        reason: '收紧到「连开三枪」的范围后，胜率应掉到六成上下');
    expect(vsRange, greaterThan(0.50)); // 但也不至于被打死
    expect(vsRange2, closeTo(vsRange, 0.05)); // 换随机种子结果稳定
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

  test('位置：单挑时按钮位知道自己在闭圈（顶对直接下注，不慢打）', () {
    // 单挑的翻后顺序是「大盲先动、按钮最后动」，按钮位是有位置的一方。
    // 曾经把按钮位算成没位置，导致它拿顶对也在慢打。
    for (var seed = 0; seed < 20; seed++) {
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: Random(seed),
      )
        ..addPlayer('ai', 'AI') // 按钮 / 小盲
        ..addPlayer('hero', '我'); // 大盲
      g.startHand(
        holeOverride: {'ai': _cs('Ah Qd'), 'hero': _cs('3c 2h')},
        boardOverride: _cs('Qh 7d 2c'),
      );
      final ai = AiPlayer(AiStyle.tightAggressive, random: Random(seed));
      var flopActed = false;
      var bet = false;
      var guard = 0;
      while (!g.handOver && guard++ < 100) {
        final p = g.pendingAction();
        if (p.player.id == 'ai') {
          final d = ai.decide(g, p.player);
          if (g.street == Street.flop) {
            flopActed = true;
            bet = d.type == ActionType.bet;
            break;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        final legal = p.actions;
        final wants = legal.any((a) => a.type == ActionType.call)
            ? ActionType.call
            : ActionType.check;
        g.apply('hero', wants);
      }
      expect(flopActed, isTrue);
      expect(bet, isTrue, reason: '有位置的顶对应该直接下注');
    }
  });

  test('读人：AI 会把对手「见注就弃」记进档案，并据此调整打法', () {
    final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));
    // 英雄坐按钮位（翻前先动），AI 坐大盲（翻后先动）。
    // 英雄翻后见注就弃，AI 应该很快读出「一压就跑」。
    final read = <String, int>{};
    for (var i = 0; i < 30; i++) {
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: Random(1000 + i),
      )
        ..addPlayer('hero', '我')
        ..addPlayer('ai', 'AI');
      g.startHand(
        holeOverride: {'ai': _cs('7h 2c'), 'hero': _cs('9c 8d')},
        boardOverride: _cs('As Kd Qc'),
      );
      var guard = 0;
      while (!g.handOver && guard++ < 200) {
        final p = g.pendingAction();
        if (p.player.id == 'ai') {
          final d = ai.decide(g, p.player);
          if (g.street == Street.flop && d.type == ActionType.bet) {
            read['bet'] = (read['bet'] ?? 0) + 1;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        final legal = p.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        final wants = g.street == Street.preflop
            ? ActionType.call
            : (facing ? ActionType.fold : ActionType.check);
        g.apply(
            'hero',
            legal.any((a) => a.type == wants)
                ? wants
                : legal.first.type);
      }
    }
    final r = ai.readOf('hero');
    expect(r, isNotNull, reason: 'AI 应该已经观察过英雄');
    expect(r!.hands, greaterThan(20));
    expect(r.seen, greaterThan(5), reason: '攒到了足够「面对下注」的样本');
    expect(r.foldToBet, 1.0, reason: '英雄翻后见注就弃 = 弃牌率 100%');
    expect(r.aggroRate, lessThan(0.2),
        reason: '英雄从没主动下注过，进攻性读数应该很低');
  });

  test('读人：对手是疯子还是岩石，决定我们抓诈唬时跟不跟', () {
    // 先跟一个「逮到机会就下注/加注」的疯子、和一个「只跟不主动」的岩石
    // 各打一批准牌，攒出进攻性读数；再拿同一手第二对面对同一个 3 倍池
    // 超池下注，看 AI 敢不敢抓。
    ({double callRate, double aggroRate, int total}) callVsRead(
        {required bool maniac}) {
      final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));
      ({ActionType? act}) play(int seed, bool record) {
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: Random(seed),
        )
          ..addPlayer('hero', '我')
          ..addPlayer('ai', 'AI');
        g.startHand(
          holeOverride: {'ai': _cs('Ks Jd'), 'hero': _cs('3c 2h')},
          boardOverride: _cs('Qc Jh 2s'),
        );
        ActionType? act;
        var guard = 0;
        while (!g.handOver && guard++ < 300) {
          final p = g.pendingAction();
          final legal = p.actions;
          final facing = legal.any((a) => a.type == ActionType.call);
          if (p.player.id == 'ai') {
            final d = ai.decide(g, p.player);
            if (record && g.street == Street.flop && facing && act == null) {
              act = d.type;
            }
            g.apply('ai', d.type, amount: d.amountTo);
            continue;
          }
          ActionType wants;
          if (record) {
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
                ? p.player.streetBet + (pot * 3.0).round()
                : g.currentBet + (pot * 3.0).round();
            g.apply(p.player.id, wants,
                amount: amount.clamp(la.minAmount, la.maxAmount));
            continue;
          }
          g.apply(p.player.id,
              legal.any((a) => a.type == wants) ? wants : legal.first.type);
        }
        return (act: act);
      }

      for (var i = 0; i < 150; i++) {
        play(2000 + i, false);
      }
      var calls = 0, total = 0;
      for (var i = 0; i < 120; i++) {
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

    final vsManiac = callVsRead(maniac: true);
    final vsNit = callVsRead(maniac: false);
    expect(vsManiac.aggroRate, greaterThan(vsNit.aggroRate + 0.2),
        reason: '进攻性读数要能区分这两种对手');
    expect(vsManiac.total, greaterThan(30));
    expect(vsManiac.callRate, greaterThan(vsNit.callRate + 0.15),
        reason: '对爱开火的对手抓得更多，对岩石弃得更多 '
            '(${(100 * vsManiac.callRate).toStringAsFixed(0)}% vs '
            '${(100 * vsNit.callRate).toStringAsFixed(0)}%)');
  });

  test('读线：对手前面几条街一路开火后河牌超池，就别轻易跟', () {
    // 同一手牌（AI 第二对）、同一个河牌超池尺度，只差对手前面几条街
    // 有没有一直在下注：一路开火说明价值更实，一路过牌再突然超池更像诈唬。
    ({double callRate, int total}) riverCallVsLine({required bool barrel}) {
      var calls = 0;
      var total = 0;
      for (var seed = 0; seed < 200; seed++) {
        final rnd = Random(seed);
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: rnd,
        )
          ..addPlayer('ai', 'AI')
          ..addPlayer('hero', '我');
        final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
        g.startHand(
          holeOverride: {'ai': _cs('Ks Jd'), 'hero': _cs('3c 2h')},
          boardOverride: _cs('Qc Jh 2s 5d 9c'),
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
            final la = legal
                .firstWhere((a) => a.type == type, orElse: () => legal.first);
            g.apply(p.player.id, type,
                amount: (p.player.streetBet +
                        (pot * (g.street == Street.river ? 2.0 : 0.5)).round())
                    .clamp(la.minAmount, la.maxAmount));
            continue;
          }
          g.apply(p.player.id,
              legal.any((a) => a.type == type) ? type : legal.first.type);
        }
      }
      return (callRate: total == 0 ? 0.0 : calls / total, total: total);
    }

    final vsBarrel = riverCallVsLine(barrel: true);
    final vsCheckThenBet = riverCallVsLine(barrel: false);
    expect(vsBarrel.total, greaterThan(40));
    expect(vsCheckThenBet.total, greaterThan(40));
    expect(vsCheckThenBet.callRate, greaterThan(vsBarrel.callRate + 0.15),
        reason: '对手一路过牌后突然超池，比连开三枪更值得抓 '
            '(${(100 * vsBarrel.callRate).toStringAsFixed(0)}% vs '
            '${(100 * vsCheckThenBet.callRate).toStringAsFixed(0)}%)');
  });

  test('下注尺度：干面用小注、湿面加大、多人底池抬价', () {
    // 量 AI 在翻牌圈拿顶对顶踢时「下注额 ÷ 下注前底池」。
    ({double frac, int n, List<double> all}) flopBetFrac(
        {required String board, int others = 0}) {
      final all = <double>[];
      var sum = 0.0;
      var n = 0;
      for (var seed = 0; seed < 120; seed++) {
        final rnd = Random(seed);
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: rnd,
        )
          ..addPlayer('ai', 'AI')
          ..addPlayer('hero', '我');
        for (var i = 0; i < others; i++) {
          g.addPlayer('c$i', 'C$i');
        }
        final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
        const extra = ['4c 5c', '6c 7c', '8d 9d'];
        final holes = <String, List<Card>>{
          'ai': _cs('Ah Qd'),
          'hero': _cs('3c 2h'),
        };
        for (var i = 0; i < others; i++) {
          holes['c$i'] = _cs(extra[i % extra.length]);
        }
        g.startHand(holeOverride: holes, boardOverride: _cs(board));
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

    final dry = flopBetFrac(board: 'Qh 7d 2c');
    final wet = flopBetFrac(board: 'Qh 9h 8c');
    final multi = flopBetFrac(board: 'Qh 7d 2c', others: 2);
    expect(dry.n, greaterThan(40));
    expect(wet.frac, greaterThan(dry.frac + 0.1),
        reason: '干面用范围小注、湿面加大保护 '
            '(${dry.frac.toStringAsFixed(2)} vs '
            '${wet.frac.toStringAsFixed(2)} 池)');
    expect(multi.frac, greaterThan(dry.frac + 0.05),
        reason: '多人底池总有人会跟，价值下注更大 '
            '(${multi.frac.toStringAsFixed(2)} vs '
            '${dry.frac.toStringAsFixed(2)} 池)');

    // 尺度混合：同一个牌面、同一手牌，尺寸要换档，不能永远是同一个数。
    final sizes = dry.all.toSet().toList()..sort();
    expect(sizes.length, greaterThanOrEqualTo(3),
        reason: '同一手牌应该有多种尺寸 '
            '(${sizes.map((x) => '${(100 * x).toStringAsFixed(0)}%').join('/')})');
    // 干面基准 = 0.62（价值）× 0.62（范围小注）= 0.384，混合不该改变均值。
    expect((dry.frac - 0.384).abs(), lessThan(0.04),
        reason: '混合只打散尺寸，平均尺度基本不动 '
            '(${dry.frac.toStringAsFixed(3)} 池)');
  });

  test('第二枪选牌：转牌发空白牌继续开火，发 A 就收手', () {
    // 转牌这张新牌对谁更有利，决定还要不要开第二枪。
    double betRate(String turn) {
      var fire = 0, total = 0;
      for (var seed = 0; seed < 200; seed++) {
        final rnd = Random(seed);
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: rnd,
        )
          ..addPlayer('ai', 'AI')
          ..addPlayer('hero', '我');
        final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
        g.startHand(
          holeOverride: {'ai': _cs('9h 8h'), 'hero': _cs('3c 2h')},
          boardOverride: _cs('Ks 7d 2c $turn'),
        );
        var guard = 0;
        var recorded = false;
        while (!g.handOver && guard++ < 300) {
          final p = g.pendingAction();
          if (p.player.id == 'ai') {
            final d = ai.decide(g, p.player);
            if (!recorded && g.street == Street.turn) {
              recorded = true;
              total++;
              if (d.type == ActionType.bet) fire++;
            }
            g.apply('ai', d.type, amount: d.amountTo);
            continue;
          }
          final legal = p.actions;
          final facing = legal.any((a) => a.type == ActionType.call);
          final wants = facing ? ActionType.call : ActionType.check;
          g.apply('hero',
              legal.any((a) => a.type == wants) ? wants : legal.first.type);
        }
      }
      return total == 0 ? 0 : fire / total;
    }

    final blank = betRate('3h'); // 比 K 小的空白牌
    final ace = betRate('Ah'); // 高张 A：更容易打中跟注方
    expect(blank, greaterThan(ace + 0.05),
        reason: '转牌空白牌继续开火、发 A 就收手 '
            '(${(100 * blank).toStringAsFixed(0)}% vs '
            '${(100 * ace).toStringAsFixed(0)}%)');
  });

  test('诈唬选牌：握着坚果花阻断牌时，河牌更敢开火', () {
    double betRate(String hole, String board) {
      var fire = 0, total = 0;
      for (var seed = 0; seed < 200; seed++) {
        final rnd = Random(seed);
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: rnd,
        )
          ..addPlayer('ai', 'AI')
          ..addPlayer('hero', '我');
        final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
        g.startHand(
          holeOverride: {'ai': _cs(hole), 'hero': _cs('3c 2h')},
          boardOverride: _cs(board),
        );
        var guard = 0;
        var recorded = false;
        while (!g.handOver && guard++ < 300) {
          final p = g.pendingAction();
          if (p.player.id == 'ai') {
            final d = ai.decide(g, p.player);
            if (!recorded && g.street == Street.river) {
              recorded = true;
              total++;
              if (d.type == ActionType.bet) fire++;
            }
            g.apply('ai', d.type, amount: d.amountTo);
            continue;
          }
          final legal = p.actions;
          final facing = legal.any((a) => a.type == ActionType.call);
          final wants = facing ? ActionType.call : ActionType.check;
          g.apply('hero',
              legal.any((a) => a.type == wants) ? wants : legal.first.type);
        }
      }
      return total == 0 ? 0 : fire / total;
    }

    // 同一块牌面、同样是「打不中」的垃圾牌，只差一张 A♦。
    final nut = betRate('Ad 6c', 'Kd 8d 2c 4h 9d');
    final plain = betRate('Jc 6c', 'Kd 8d 2c 4h 9d');
    expect(nut, greaterThan(plain + 0.05),
        reason: '挡掉对手坚果花的那张牌能让它多开火 '
            '(${(100 * nut).toStringAsFixed(0)}% vs '
            '${(100 * plain).toStringAsFixed(0)}%)');
  });

  test('河牌怪兽牌：会用超池收价值，但面对「一压就跑」的对手不超池', () {
    // AI 拿 77 在 K 高牌面（转牌前都是空气），到河牌击中三条。
    ({double overbetRate, double avgFrac, int bets}) run(
        {required bool villainFolds}) {
      final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));
      ({bool bet, double frac}) play(int seed, String hole, String board,
          bool record) {
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: Random(seed),
        )
          ..addPlayer('hero', '我')
          ..addPlayer('ai', 'AI');
        g.startHand(
          holeOverride: {'ai': _cs(hole), 'hero': _cs('3c 2h')},
          boardOverride: _cs(board),
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
                frac = pot == 0
                    ? 0
                    : ((d.amountTo ?? 0) - p.player.streetBet) / pot;
              }
            }
            g.apply('ai', d.type, amount: d.amountTo);
            continue;
          }
          final legal = p.actions;
          final facing = legal.any((a) => a.type == ActionType.call);
          final wants = !facing
              ? ActionType.check
              : (villainFolds ? ActionType.fold : ActionType.call);
          g.apply('hero',
              legal.any((a) => a.type == wants) ? wants : legal.first.type);
        }
        return (bet: bet, frac: frac);
      }

      // 热身：让 AI 记住这位对手会不会跑。
      for (var i = 0; i < 80; i++) {
        play(1000 + i, '4h 3h', 'Qd 7d 2c', false);
      }

      var bets = 0, overs = 0;
      var sum = 0.0;
      for (var i = 0; i < 300; i++) {
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

    final station = run(villainFolds: false);
    final folder = run(villainFolds: true);
    expect(station.bets, greaterThan(30));
    expect(station.overbetRate, greaterThan(0.25),
        reason: '对跟注站会用超池压价值 '
            '(${(100 * station.overbetRate).toStringAsFixed(0)}%，'
            '平均 ${station.avgFrac.toStringAsFixed(2)} 倍底池)');
    expect(station.avgFrac, greaterThan(1.0));
    expect(folder.overbetRate, 0.0,
        reason: '对手见注就弃时不超池，改用小注换跟注');
  });

  test('短筹码：按推/弃来打，不做「开小注再弃给 3bet」', () {
    // 按钮位、前面一路弃到它：8bb 拿 A5s 该直接推全下，72o 该扔。
    int shoveAt(String hole, double stackBb) {
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
      g.startHand(holeOverride: {'p0': _cs(hole)});
      for (var i = 3; i < 6; i++) {
        g.apply('p$i', ActionType.fold);
      }
      final p = g.pendingAction().player;
      if (p.id != 'p0') return -1;
      final d = AiPlayer(AiStyle.tightAggressive, random: rnd).decide(g, p);
      final allIn = p.streetBet + p.stack;
      return d.type == ActionType.raise && d.amountTo == allIn
          ? d.amountTo!
          : -1;
    }

    expect(shoveAt('Ah Ad', 8), 800, reason: '8bb 拿 AA 直接推，全下额就是全部筹码');
    expect(shoveAt('As 5s', 8), 800, reason: '8bb 按钮位 A5s 也在推/弃范围里');
    expect(shoveAt('7h 2c', 8), -1, reason: '短筹码也不会拿 72o 乱推');
    expect(shoveAt('As 5s', 60), -1, reason: '深筹码照常开小注，不推全下');

    // 范围本身：筹码越浅越宽、位置越靠后越宽。
    int combos(PreflopRange r) {
      var n = 0;
      for (final hi in Rank.values) {
        for (final lo in Rank.values) {
          if (hi.value < lo.value) continue;
          if (hi == lo) {
            if (r.contains(PreflopHand.of(
                [Card(hi, Suit.spades), Card(lo, Suit.hearts)]))) {
              n += 6;
            }
            continue;
          }
          if (r.contains(PreflopHand.of(
              [Card(hi, Suit.spades), Card(lo, Suit.spades)]))) {
            n += 4;
          }
          if (r.contains(PreflopHand.of(
              [Card(hi, Suit.spades), Card(lo, Suit.hearts)]))) {
            n += 12;
          }
        }
      }
      return n;
    }

    expect(combos(PreflopRanges.shoveOpen(Seat.btn, 15)),
        lessThan(combos(PreflopRanges.shoveOpen(Seat.btn, 10))),
        reason: '筹码越浅推得越宽');
    expect(combos(PreflopRanges.shoveOpen(Seat.btn, 10)),
        lessThan(combos(PreflopRanges.shoveOpen(Seat.btn, 5))));
    expect(combos(PreflopRanges.shoveOpen(Seat.ep, 10)),
        lessThan(combos(PreflopRanges.shoveOpen(Seat.btn, 10))),
        reason: '位置越靠后推得越宽');
  });

  test('翻前尺度：按钮位开池会换档，平均尺度不变', () {
    // 同一个位置、同一手牌，真人不会永远开同一个尺寸——固定尺度最容易被读死。
    final sizes = <int>[];
    for (var seed = 0; seed < 60; seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      );
      for (var i = 0; i < 6; i++) {
        g.addPlayer('p$i', 'P$i');
      }
      // 6 人桌第一手按钮在 p0，枪口到劫位全弃掉就轮到它开池。
      g.startHand(holeOverride: {'p0': _cs('Ah Ad')});
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
    expect(sizes.length, greaterThan(40));
    expect(sizes.toSet().length, greaterThanOrEqualTo(3),
        reason: '按钮位开池不该永远是一个尺寸（实测 $sizes）');
    var sum = 0;
    for (final s in sizes) {
      sum += s;
    }
    final avg = sum / sizes.length;
    expect((avg - 246).abs(), lessThan(14),
        reason: '换档只打散尺寸，平均尺度基本不动（实测 $avg，基准 246）');
  });

  test('存档：一局的桌面快照能原样存回来，坏存档不会崩', () async {
    final file = File('${Directory.systemTemp.path}/poker_session_test.json');
    final store = TableSessionStore(file);
    await store.clear();
    expect(await store.load() == null, isTrue, reason: '没存过就读到 null');

    final session = TableSession(
      id: 'table-1',
      label: '实战 6人桌 · 50/100',
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      styles: [AiStyle.tightAggressive.name, AiStyle.loosePassive.name],
      seats: const [
        SessionSeat(id: 'hero', name: '我', stack: 12345),
        SessionSeat(id: 'ai0', name: '紧凶·AI1', stack: 8800),
        SessionSeat(id: 'ai1', name: '松被动·AI2', stack: 9900),
      ],
      buttonIndex: 2,
      handsPlayed: 17,
      savedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    await store.save(session);

    final back = await store.load();
    expect(back != null, isTrue);
    final r = back!;
    expect(r.label, '实战 6人桌 · 50/100');
    expect(r.config.startingStack, 10000);
    expect(r.config.smallBlind, 50);
    expect(r.config.bigBlind, 100);
    expect(r.styles.length, 2);
    expect(r.styles[1], 'loosePassive');
    expect(r.seats.length, 3);
    expect(r.stackOf('hero'), 12345);
    expect(r.stackOf('ai1'), 9900);
    expect(r.stackOf('nobody') == null, isTrue);
    expect(r.buttonIndex, 2);
    expect(r.handsPlayed, 17);
    expect(r.savedAt.millisecondsSinceEpoch, 1700000000000);

    // 半截 JSON（App 被杀时常见的残档）当没有存档处理，不许抛异常。
    await file.writeAsString('{ 这不是一个合法存档');
    expect(await store.load() == null, isTrue);

    await store.clear();
    expect(await store.load() == null, isTrue);
  });

  test('存档：按钮位拨回上一手后，下一手照常前移', () {
    final g = GameEngine(config: const GameConfig(), random: Random(5))
      ..addPlayer('a', 'A')
      ..addPlayer('b', 'B')
      ..addPlayer('c', 'C');
    g.buttonIndex = 1;
    g.startHand();
    expect(g.buttonIndex, 2);
    expect(g.handOver, isFalse);
  });

  test('存档：按快照重建的牌桌，座位/筹码/按钮位都照原样', () {
    final session = TableSession(
      id: 'table-2',
      label: '单挑 · 松凶',
      config: const GameConfig(
          startingStack: 2000, smallBlind: 10, bigBlind: 20),
      styles: [AiStyle.looseAggressive.name],
      seats: const [
        SessionSeat(id: 'hero', name: '我', stack: 2600),
        SessionSeat(id: 'ai0', name: '松凶·AI1', stack: 1400),
      ],
      buttonIndex: 1,
      handsPlayed: 9,
      savedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    final rebuilt = restoreTable(session, heroId: 'hero', random: Random(11));
    final engine = rebuilt.engine;
    expect(engine.players.length, 2);
    expect(engine.players[0].name, '我');
    expect(engine.players[0].stack, 2600);
    expect(engine.players[1].name, '松凶·AI1');
    expect(engine.players[1].stack, 1400);
    expect(engine.config.bigBlind, 20);
    expect(engine.buttonIndex, 1);
    expect(rebuilt.ais.length, 1);
    expect(rebuilt.ais['ai0']!.style == AiStyle.looseAggressive, isTrue,
        reason: '对手风格要跟着存档一起回来');

    // 接着开下一手：按钮位前移，上一手的筹码原封不动带进来。
    engine.startHand();
    expect(engine.buttonIndex, 0);
    expect(engine.players[0].stack + engine.players[0].totalBet, 2600);
    expect(engine.handOver, isFalse);
  });

  test('存档：关掉再打开，回来还是同一张桌、同一批筹码', () async {
    final dir = Directory.systemTemp.createTempSync('poker_session_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/session.json');
    const config = GameConfig(
        startingStack: 10000, smallBlind: 50, bigBlind: 100);

    // 第一台：开一桌、把筹码打散一点，然后落盘。
    final first = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(3),
      aiThinkTime: Duration.zero,
    );
    first.startRealTable(
        label: '实战 6人桌 · 50/100', config: config, playerCount: 6);
    first.engine.players[0].stack = 13400;
    first.engine.players[1].stack = 7200;
    first.engine.buttonIndex = 3;
    first.handsPlayed = 5;
    // 标记这一手已结束 = 存档停在两手之间（打到一半的存档另有用例覆盖）。
    first.engine.handOver = true;
    await first.persistSession();
    final sessionId = first.savedSession!.id;

    // 第二台：模拟 App 重启——内存里空空如也，只剩磁盘上的存档。
    final second = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(3),
      aiThinkTime: Duration.zero,
    );
    expect(second.hasSavedSession, isFalse, reason: '还没读档');
    expect(second.sessionNeedsRestore, isFalse);
    await second.loadSession();
    expect(second.hasSavedSession, isTrue);
    expect(second.sessionNeedsRestore, isTrue, reason: '磁盘有档、内存没桌');

    second.resumeSession();
    expect(second.sessionNeedsRestore, isFalse);
    expect(second.savedSession!.id, sessionId);
    expect(second.tableLabel, '实战 6人桌 · 50/100');
    expect(second.engine.config.bigBlind, 100);
    expect(second.engine.config.smallBlind, 50);
    expect(second.engine.config.startingStack, 10000);
    expect(second.engine.players.length, 6);
    expect(second.handsPlayed, 5);
    expect(second.engine.buttonIndex, 4, reason: '上一手 3，续上一手要前移');
    expect(second.engine.handOver, isFalse, reason: '接着打，不是停在结算');
    for (var i = 0; i < 6; i++) {
      expect(second.engine.players[i].name, first.engine.players[i].name);
    }
    // 筹码带进新一手（盲注已下注，用「筹码 + 本手投入」核对）。
    expect(second.engine.players[0].stack + second.engine.players[0].totalBet,
        13400);
    expect(second.engine.players[1].stack, 7200);

    // 没关 App、只是逛回大厅再进来：不该重发牌、不该重置筹码。
    final heroBefore = second.hero.stack;
    final buttonBefore = second.engine.buttonIndex;
    second.resumeSession();
    expect(second.hero.stack, heroBefore);
    expect(second.engine.buttonIndex, buttonBefore);
  });

  test('引擎快照：打到一半存下来，恢复后接着打完一模一样', () {
    const config =
        GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);
    GameEngine fresh() => GameEngine(config: config, random: Random(17))
      ..addPlayer('hero', '我')
      ..addPlayer('ai0', '紧凶·AI1')
      ..addPlayer('ai1', '松被动·AI2')
      ..startHand();

    final a = fresh();
    for (var i = 0; i < 4; i++) {
      final p = a.pendingAction().player;
      a.apply(p.id, ActionType.call);
    }
    expect(a.handOver, isFalse, reason: '要在手牌中途存快照');

    final b = GameEngine.fromSnapshotJson(
      a.toSnapshotJson(),
      config: config,
      random: Random(17),
    );
    expect(b.street, a.street);
    expect(b.buttonIndex, a.buttonIndex);
    expect(b.potTotal(), a.potTotal());
    expect(b.board.map((c) => c.notation), a.board.map((c) => c.notation));
    expect(b.pendingAction().player.id, a.pendingAction().player.id,
        reason: '轮到的还是同一个人');
    for (var i = 0; i < a.players.length; i++) {
      expect(b.players[i].stack, a.players[i].stack);
      expect(b.players[i].streetBet, a.players[i].streetBet);
      expect(b.players[i].totalBet, a.players[i].totalBet);
      expect([for (final c in b.players[i].holeCards) c.notation],
          [for (final c in a.players[i].holeCards) c.notation]);
    }

    // 两边按同样的动作打完：连后面几条街发的牌都要一致（牌堆顺序没丢）。
    var guard = 0;
    while (!a.handOver && !b.handOver && guard++ < 200) {
      for (final e in [a, b]) {
        final p = e.pendingAction().player;
        e.apply(p.id, ActionType.call);
      }
    }
    expect(a.handOver, isTrue);
    expect(b.handOver, isTrue);
    expect(b.board.map((c) => c.notation), a.board.map((c) => c.notation));
    for (var i = 0; i < a.players.length; i++) {
      expect(b.players[i].stack, a.players[i].stack);
    }
  });

  test('存档：牌局打到一半退出，回来接着把这一手打完', () async {
    final dir = Directory.systemTemp.createTempSync('poker_midhand');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/session.json');
    const config =
        GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

    final first = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(9),
      aiThinkTime: Duration.zero,
    );
    first.startRealTable(
        label: '实战 单挑 · 50/100', config: config, playerCount: 2);
    // 打几个动作，停在手牌中途（没打完就「退出 App」）。
    var steps = 0;
    while (!first.engine.handOver && steps++ < 3) {
      if (first.heroToAct) first.heroAct(ActionType.call);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(first.engine.handOver, isFalse, reason: '用例要在手牌中途退出');

    final handId = first.engine.lastHand!.id;
    final boardBefore = [for (final c in first.engine.board) c.notation];
    final potBefore = first.engine.potTotal();
    final streetBefore = first.engine.street;
    final actorBefore = first.engine.pendingAction().player.id;
    final stacksBefore = [for (final p in first.engine.players) p.stack];
    final holeBefore = [
      for (final p in first.engine.players)
        [for (final c in p.holeCards) c.notation],
    ];

    // 每个动作之后都会自动落盘 —— 不用等 App 正常退出，被杀也留得下。
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['hand'] != null, isTrue, reason: '打到一半也要落盘');

    // 模拟 App 被杀：内存全丢，只剩磁盘上的存档。
    final second = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(9),
      aiThinkTime: Duration.zero,
    );
    await second.loadSession();
    expect(second.savedSession!.handInProgress, isTrue,
        reason: '存档里带着「打到一半」的那一手');
    expect(second.sessionNeedsRestore, isTrue);
    expect(second.resumeSession(), isTrue);

    // 接着打的是同一手牌：底牌、公共牌、底池、轮次、行动者都一样。
    expect(second.engine.handOver, isFalse);
    expect(second.engine.lastHand!.id, handId);
    expect([for (final c in second.engine.board) c.notation], boardBefore);
    expect(second.engine.potTotal(), potBefore);
    expect(second.engine.street, streetBefore);
    expect(second.engine.pendingAction().player.id, actorBefore);
    expect([for (final p in second.engine.players) p.stack], stacksBefore);
    expect(
        [
          for (final p in second.engine.players)
            [for (final c in p.holeCards) c.notation],
        ],
        holeBefore);
    expect(second.handsPlayed, first.handsPlayed);

    // 接着打完：这一手照常进历史。
    var guard = 0;
    while (!second.engine.handOver && guard++ < 400) {
      if (second.heroToAct) second.heroAct(ActionType.call);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(second.engine.handOver, isTrue, reason: '这一手要能打完');
    expect(second.handsPlayed, first.handsPlayed + 1);
    expect(second.history.first.id, handId, reason: '记下的就是续上的这一手');
  });

  test('存档：一手打完后不再存这半截，下一手照常重新发牌', () async {
    final dir = Directory.systemTemp.createTempSync('poker_between');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/session.json');
    const config =
        GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

    final first = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(21),
      aiThinkTime: Duration.zero,
    );
    first.startRealTable(
        label: '实战 单挑 · 50/100', config: config, playerCount: 2);
    var guard = 0;
    while (!first.engine.handOver && guard++ < 400) {
      if (first.heroToAct) first.heroAct(ActionType.fold);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(first.engine.handOver, isTrue);
    final finishedId = first.engine.lastHand!.id;
    final handsAfter = first.handsPlayed;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['hand'] == null, isTrue, reason: '两手之间不存半截手牌');

    final second = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(21),
      aiThinkTime: Duration.zero,
    );
    await second.loadSession();
    expect(second.savedSession!.handInProgress, isFalse);
    second.resumeSession();
    expect(second.handsPlayed, handsAfter, reason: '打过的手机数带回来');
    expect(second.engine.handOver, isFalse, reason: '恢复后直接发下一手');
    expect(second.engine.lastHand!.id, isNot(finishedId),
        reason: '上一手已经结算，不该重开同一手');
  });

  test('补码：补满至起始买入', () {
    final g = GameEngine(random: Random(1))..addPlayer('hero', '我');
    g.players[0].stack = 100;
    expect(g.topUp('hero'), 9900);
    expect(g.players[0].stack, 10000);
    expect(g.topUp('hero'), 0);
  });
}
