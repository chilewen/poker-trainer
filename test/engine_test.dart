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

  test('范围胜率：翻牌圈按全组合采样，窄范围不能系统性低估', () {
    final hole = _cs('Ks 9h'); // 顶对弱踢
    final flop = _cs('Kd Jc 8h');
    // 只有「两对以上」才有分量——对手这条线基本是真东西。
    double onlyTwoPairPlus(List<Card> h, HandScore s) =>
        s.category.rank >= 2 ? 1.0 : 0.02;
    double wide(List<Card> h, HandScore s) => s.category.rank >= 2 ? 1.0 : 0.5;

    double sample(int seed, double Function(List<Card>, HandScore) range) =>
        Odds.equityVsRange(
          heroHole: hole,
          board: flop,
          inRange: range,
          trials: 900,
          random: Random(seed),
        ).win;

    final narrow =
        [for (var seed = 0; seed < 4; seed++) sample(seed, onlyTwoPairPlus)];
    final avg = narrow.reduce((a, b) => a + b) / narrow.length;
    final vsWide = sample(0, wide);

    // 精确枚举「对手底牌 × 后续公共牌」得到的基准是 0.536。
    // 旧实现（洗牌后相邻两张配成一手）只在 ~21 个随机候选里挑，
    // 窄范围下几乎抽不到范围里的牌，会系统性低估到 0.38。
    expect(avg, greaterThan(0.46), reason: '窄范围下不能系统性低估我方胜率');
    expect(avg, lessThan(0.60));
    expect(vsWide, greaterThan(avg), reason: '对手范围越宽，我方胜率越高');
  });

  test('范围胜率：多人底池的权重乘积不能提前断掉', () {
    final hole = _cs('Ks 9h'); // 顶对弱踢
    final board = _cs('Kd Jc 8h 2s 3d');
    double range(List<Card> h, HandScore s) => s.category.rank >= 2
        ? 1.0
        : (s.category.rank == 1 ? 0.5 : 0.15);

    final runs = [
      for (var seed = 0; seed < 3; seed++)
        Odds.equityVsRange(
          heroHole: hole,
          board: board,
          opponents: 2,
          inRange: range,
          trials: 640,
          random: Random(seed),
        ).win
    ];
    final avg = runs.reduce((a, b) => a + b) / runs.length;

    // 精确枚举所有对手组合（990×990 合法配对）得到的基准是 0.531。
    // 曾经的写法是「输给某个对手就提前跳出」：那样这一份样本的权重
    // 乘积会少乘后面几个对手，分母偏小，两家的胜率被压到 0.38。
    expect(avg, greaterThan(0.47), reason: '两家对手时权重乘积必须完整');
    expect(avg, lessThan(0.62));
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

  /// 6 人桌：p3 弃 → p4 开 300 → p5 3bet 900 → 轮到按钮位 p0（AI）。
  ({int raise, int call, int fold}) aiFacingThreeBet(String hole,
      {int seeds = 200, AiStyle style = AiStyle.tightAggressive}) {
    var raise = 0, call = 0, fold = 0;
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
      g.startHand(holeOverride: {'p0': _cs(hole)});
      g.apply('p3', ActionType.fold);
      g.apply('p4', ActionType.raise, amount: 300);
      g.apply('p5', ActionType.raise, amount: 900);
      final p = g.pendingAction().player;
      if (p.id != 'p0') fail('轮到的是 ${p.id}，不是 p0');
      final d = AiPlayer(style, random: rnd).decide(g, p);
      switch (d.type) {
        case ActionType.raise:
          raise++;
        case ActionType.call:
          call++;
        default:
          fold++;
      }
    }
    return (raise: raise, call: call, fold: fold);
  }

  test('翻前 4bet：QQ+/AK 面对方 3bet 会再加注回去，不是一路慢打', () {
    for (final hole in ['Ah Ad', 'Kh Kd', 'Qh Qd', 'As Ks', 'Ah Kc']) {
      final r = aiFacingThreeBet(hole);
      expect(r.raise / 200, greaterThan(0.4),
          reason: '$hole 面对方 3bet 该经常 4bet（4bet ${(100 * r.raise / 200).round()}%）');
      // 也要留一部分跟注：全 4bet 就变成「一被 3bet 就加」的机器。
      expect(r.call / 200, greaterThan(0.05),
          reason: '$hole 也要有跟注的分量（跟注 ${(100 * r.call / 200).round()}%）');
      expect(r.fold, 0, reason: '$hole 这种牌不能弃给 3bet');
    }
    // 垃圾牌不能跟着 4bet。
    final trash = aiFacingThreeBet('7h 2c');
    expect(trash.raise, 0, reason: '72o 不许 4bet');
    expect(trash.fold / 200, greaterThan(0.9));
  });

  test('翻前 4bet：松被动拿 AA 更多是慢打（风格要分得开）', () {
    final tag = aiFacingThreeBet('Ah Ad');
    final lag = aiFacingThreeBet('Ah Ad', style: AiStyle.looseAggressive);
    final lp = aiFacingThreeBet('Ah Ad', style: AiStyle.loosePassive);
    expect(lag.raise, greaterThan(tag.raise),
        reason: '松凶 4bet 比紧凶多（${lag.raise} vs ${tag.raise}）');
    expect(lp.raise, lessThan(tag.raise - 40),
        reason: '松被动拿 AA 大半只是跟注（4bet ${lp.raise}/200）');
    // 但松被动也不会拿 AA 去弃牌。
    expect(lp.fold, 0);
  });

  test('翻前 4bet：对手 4bet/5bet 回来，只有 AA/KK 还继续', () {
    // 我们 4bet 后对手直接推全下，再轮回我们。
    ({int cont, int fold}) facingJam(String hole) {
      var cont = 0, fold = 0;
      for (var seed = 0; seed < 200; seed++) {
        final rnd = Random(seed);
        final g = GameEngine(
          config: const GameConfig(
              startingStack: 10000, smallBlind: 50, bigBlind: 100),
          random: rnd,
        );
        for (var i = 0; i < 6; i++) {
          g.addPlayer('p$i', 'P$i');
        }
        g.startHand(holeOverride: {'p0': _cs(hole)});
        g.apply('p3', ActionType.fold);
        g.apply('p4', ActionType.raise, amount: 300);
        g.apply('p5', ActionType.raise, amount: 900);
        final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
        final p0 = g.pendingAction().player;
        final d0 = ai.decide(g, p0);
        g.apply('p0', d0.type, amount: d0.amountTo);
        g.apply('p1', ActionType.fold);
        g.apply('p2', ActionType.fold);
        g.apply('p4', ActionType.raise, amount: 10000);
        g.apply('p5', ActionType.fold);
        if (g.handOver) continue;
        final p = g.pendingAction().player;
        if (p.id != 'p0') continue;
        final d = ai.decide(g, p);
        d.type == ActionType.fold ? fold++ : cont++;
      }
      return (cont: cont, fold: fold);
    }

    for (final hole in ['Ah Ad', 'Kh Kd']) {
      final r = facingJam(hole);
      expect(r.cont / 200, greaterThan(0.8),
          reason: '$hole 面对全下要跟（继续 ${(100 * r.cont / 200).round()}%）');
    }
    for (final hole in ['Qh Qd', 'As Ks', 'Ah Kc']) {
      final r = facingJam(hole);
      expect(r.fold / 200, greaterThan(0.8),
          reason: '$hole 不该跟人家推出来的全下（弃 ${(100 * r.fold / 200).round()}%）');
    }
  });

  /// 单挑（AI 在按钮位、有位置）、英雄全程跟注或过牌，
  /// 统计 AI 在某条街「没人下注」时的下注率。
  double aiBetRateWhenCheckedTo(String hole, String board, Street street,
      {int seeds = 200}) {
    var fire = 0, total = 0;
    for (var seed = 0; seed < seeds; seed++) {
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
        holeOverride: {'ai': _cs(hole), 'hero': _cs('6c 5c')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      var recorded = false;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        if (p.id == 'ai') {
          final d = ai.decide(g, p);
          if (!recorded && !facing && g.street == street) {
            recorded = true;
            total++;
            if (d.type == ActionType.bet) fire++;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          if (recorded) break; // 要量的就是这一下，后面的街不用打完
          continue;
        }
        // 英雄：能过牌就过牌，否则跟注（一路不弃，保证后面几条街的样本量）。
        var want = legal.any((a) => a.type == ActionType.check)
            ? ActionType.check
            : (legal.any((a) => a.type == ActionType.call)
                ? ActionType.call
                : legal.first.type);
        g.apply('hero',
            legal.any((a) => a.type == want) ? want : legal.first.type);
      }
    }
    return total == 0 ? 0 : fire / total;
  }

  test('薄价值下注：顶对（哪怕踢脚不大）比第二对/底对打得更多', () {
    // 干燥牌面 K-8-3 的翻牌圈，单挑、有位置、英雄过牌。
    const flop = 'Kd 8c 3h';
    final topPairGood = aiBetRateWhenCheckedTo('Kh Qh', flop, Street.flop);
    final topPairWeak = aiBetRateWhenCheckedTo('Kh 5h', flop, Street.flop);
    final secondPair = aiBetRateWhenCheckedTo('8h 7h', flop, Street.flop);
    final bottomPair = aiBetRateWhenCheckedTo('Ac 3c', flop, Street.flop);

    // 顶对是翻牌的主力价值牌：过牌太多就是明牌告诉对手「我没东西」。
    // 以前中等牌 45%、弱牌 50% 一刀切，顶对只打 43%，反而比第二对
    // （47%）还少。
    expect(topPairGood, greaterThan(0.65),
        reason: '顶对好踢该经常下注（${(100 * topPairGood).round()}%）');
    expect(topPairGood, greaterThan(secondPair + 0.15),
        reason: '顶对该比第二对打得多 '
            '(${(100 * topPairGood).round()}% vs ${(100 * secondPair).round()}%)');
    expect(topPairWeak, greaterThan(secondPair + 0.1),
        reason: '顶对弱踢也比第二对打得多 '
            '(${(100 * topPairWeak).round()}% vs ${(100 * secondPair).round()}%)');
    // 第二对/底对是薄价值，频率收在中间档，不该跟顶对一样高。
    expect(secondPair, lessThan(0.55));
    expect(bottomPair, lessThan(0.55));

    // 河牌：顶对收成摊牌牌，打得比翻牌少，但还是要打薄价值。
    final river =
        aiBetRateWhenCheckedTo('Kh Qh', 'Kd 8c 3h 2s 5d', Street.river);
    expect(river, lessThan(topPairGood), reason: '河牌比翻牌收敛一点');
    expect(river, greaterThan(0.4),
        reason: '河牌顶对还是要打薄价值（${(100 * river).round()}%）');
  });

  /// 单挑：英雄（按钮位）开池、AI（大盲）跟注；翻后 AI 先过牌、
  /// 英雄每条街都按 [frac] 池下注，统计 AI 在 [street] 面对下注的应对。
  ///
  /// 这就是「过牌-加注」的那个位置：AI 本街已经过了牌，再加注算过牌-加注。
  ({double fold, double call, double raise, int total}) aiVsCheckBet(
      String hole, String board, double frac,
      {Street street = Street.flop, int seeds = 150}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('hero', '我')
        ..addPlayer('ai', 'AI');
      final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('6c 5c')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      var recorded = false;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          if (g.street == Street.preflop) {
            g.apply('ai', ActionType.call);
            continue;
          }
          // 固定成「AI 先过牌」这条线，专门量面对下注时的选择。
          if (canCheck && !facing) {
            g.apply('ai', ActionType.check);
            continue;
          }
          final d = ai.decide(g, p);
          if (!recorded && facing && g.street == street) {
            recorded = true;
            total++;
            switch (d.type) {
              case ActionType.fold:
                fold++;
              case ActionType.call:
                call++;
              default:
                raise++;
            }
          }
          g.apply('ai', d.type, amount: d.amountTo);
          // 要量的是这一下的选择，后面的街不用打完（省 2/3 的对局时间）。
          if (recorded) break;
          continue;
        }
        if (g.street == Street.preflop) {
          if (!facing) {
            g.apply('hero', ActionType.raise, amount: 300);
            continue;
          }
          g.apply('hero', ActionType.call);
          continue;
        }
        // 翻后英雄先行动（大盲先说话），能下注就按 frac 池下注。
        if (!facing && legal.any((a) => a.type == ActionType.bet)) {
          final pot = g.potTotal();
          final la = legal.firstWhere((a) => a.type == ActionType.bet);
          g.apply('hero', ActionType.bet,
              amount: (p.streetBet + (pot * frac).round())
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        final want = canCheck ? ActionType.check : ActionType.call;
        g.apply('hero', legal.any((a) => a.type == want) ? want : legal.first.type);
      }
    }
    final n = total;
    double r(int v) => n == 0 ? 0 : v / n;
    return (fold: r(fold), call: r(call), raise: r(raise), total: n);
  }

  test('面对下注：中等牌/弱成牌也会过牌-加注，不再只会跟或弃', () {
    const flop = 'Kd 8c 3h';
    final topPair = aiVsCheckBet('Kh Qh', flop, 0.5, seeds: 120);
    final secondPair = aiVsCheckBet('8h 7h', flop, 0.5, seeds: 120);
    String pct(double v) => '${(100 * v).round()}%';

    // 以前中等牌/弱成牌面对下注只有「跟或弃」，加注范围里清一色是
    // 怪兽牌和听牌——对手看到我们加注就知道自己撞上大牌了。
    expect(topPair.raise, greaterThan(0.12),
        reason: '顶对过牌后面对半池也该有过牌-加注（加 ${pct(topPair.raise)}）');
    expect(topPair.raise, lessThan(topPair.call),
        reason: '主体还是跟注，加注只是混入的频率');
    // 实测第二对约 8%（以前是 0%），阈值取 3% 留出余量。
    expect(secondPair.raise, greaterThan(0.03),
        reason: '第二对也要有反击频率（加 ${pct(secondPair.raise)}）');
    expect(topPair.raise, greaterThan(secondPair.raise),
        reason: '牌越强加得越多（${pct(topPair.raise)} vs ${pct(secondPair.raise)}）');
    // 有摊牌价值的一对不能弃给半池注。
    expect(topPair.fold, lessThan(0.05), reason: '顶对不会弃给半池注');
    expect(secondPair.fold, lessThan(0.1), reason: '第二对也不会');

    // 河牌没有牌可发，加注只剩价值：价值不够就老实跟注，
    // 把跟注范围也拿去加注反而更亏。
    final river = aiVsCheckBet('Kh Qh', 'Kd 8c 3h 2s 5d', 0.5,
        street: Street.river, seeds: 80);
    expect(river.raise, lessThan(0.1),
        reason: '河牌顶对以跟注为主（加 ${pct(river.raise)}）');
    expect(river.call, greaterThan(0.8),
        reason: '河牌顶对要留住跟注（跟 ${pct(river.call)}）');
    expect(river.fold, lessThan(0.05), reason: '河牌顶对不弃牌');
  });

  /// 单挑：AI（按钮位）开池、英雄（大盲）跟注；翻牌英雄先过牌、AI
  /// 下注（c-bet），英雄再加注到 [raiseTo] 倍，统计 AI 面对这次
  /// 「过牌-加注」的应对——下注和加注是两条线，量的是被加注这一侧。
  ({double fold, double call, double raise, int total}) aiVsCheckRaise(
      String hole, String board, double raiseTo,
      {int seeds = 150}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < seeds; seed++) {
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
        holeOverride: {'ai': _cs(hole), 'hero': _cs('6c 5d')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      var cbet = false;
      var done = false;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        if (p.id == 'ai') {
          final d = ai.decide(g, p);
          if (g.street == Street.preflop && d.type != ActionType.raise) {
            break; // 没开池就不看了
          }
          if (g.street == Street.flop) {
            if (!cbet) {
              if (d.type != ActionType.bet) break; // 没 c-bet 就不看了
              cbet = true;
            } else if (facing && !done) {
              done = true;
              total++;
              switch (d.type) {
                case ActionType.fold:
                  fold++;
                case ActionType.call:
                  call++;
                default:
                  raise++;
              }
              break;
            }
          }
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        if (g.street == Street.preflop) {
          g.apply('hero', facing ? ActionType.call : ActionType.check);
          continue;
        }
        if (g.street != Street.flop) break;
        if (!facing) {
          g.apply('hero', ActionType.check);
          continue;
        }
        // 面对 AI 的 c-bet：加注到 c-bet 的 raiseTo 倍。
        final la = legal.where((a) => a.type == ActionType.raise).firstOrNull;
        if (la == null) break;
        final to =
            (p.streetBet + (g.currentBet - p.streetBet) * raiseTo).round();
        g.apply('hero', ActionType.raise,
            amount: to.clamp(la.minAmount, la.maxAmount));
      }
    }
    double r(int v) => total == 0 ? 0 : v / total;
    return (fold: r(fold), call: r(call), raise: r(raise), total: total);
  }

  test('面对过牌-加注：第二对不再一路跟，超对会有一部分 3bet', () {
    // 以前 AI 面对「加注」也按对手的整条跟注范围算胜率，第二对 100%
    // 跟注；现在加注线会把对手范围收窄、跟注门槛也跟着抬。
    const flop = 'Kd 8c 3h';
    final topPair = aiVsCheckRaise('Kh Qh', flop, 3.0, seeds: 200);
    final overPair = aiVsCheckRaise('Ah Ad', flop, 3.0, seeds: 200);
    final secondPair = aiVsCheckRaise('8h 7s', flop, 3.0, seeds: 200);
    final set = aiVsCheckRaise('8h 8s', flop, 3.0, seeds: 200);
    String pct(double v) => '${(100 * v).round()}%';

    expect(secondPair.total, greaterThan(50));
    expect(secondPair.fold, greaterThan(0.45),
        reason: '第二对去跟一个三倍的过牌-加注基本是送 '
            '（弃 ${pct(secondPair.fold)}）');
    expect(topPair.fold, lessThan(0.1),
        reason: '顶对不会弃给一次加注（弃 ${pct(topPair.fold)}）');
    expect(topPair.call, greaterThan(0.6),
        reason: '顶对以跟注为主（跟 ${pct(topPair.call)}）');
    expect(overPair.raise, greaterThan(0.1),
        reason: '超对要有一部分 3bet，不然对手随便抬一手就能把强牌打走 '
            '（加 ${pct(overPair.raise)}）');
    expect(set.raise, greaterThan(0.8),
        reason: '三条直接再加回去（加 ${pct(set.raise)}）');

    // 尺度别一刀切：最小加注（约 2 倍）给的赔率好得多，第二对该多跟一些。
    final minRaise = aiVsCheckRaise('8h 7s', flop, 1.5, seeds: 200);
    expect(minRaise.fold, lessThan(secondPair.fold - 0.15),
        reason: '小加注不该弃得跟三倍加注一样多 '
            '（弃 ${pct(minRaise.fold)} vs ${pct(secondPair.fold)}）');
  });

  /// 单挑：翻牌/转牌都过牌，河牌没人下注时量 AI 的选择——
  /// 过牌率 / 下注率 / 平均尺度（下注额 ÷ 下注前底池）/ 超池率。
  /// [oop] 为真时 AI 在大盲位（河牌先说话）。
  ({double bet, double check, double avgFrac, double overbet, int n})
      aiRiverCheckedTo(String hole, String board,
          {bool oop = false, int seeds = 200}) {
    var bet = 0, check = 0, over = 0, n = 0;
    final fracs = <double>[];
    for (var seed = 0; seed < seeds; seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      );
      if (oop) {
        g
          ..addPlayer('hero', '我')
          ..addPlayer('ai', 'AI');
      } else {
        g
          ..addPlayer('ai', 'AI')
          ..addPlayer('hero', '我');
      }
      final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('6c 5d')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          if (g.street != Street.river) {
            g.apply('ai', canCheck ? ActionType.check : ActionType.call);
            continue;
          }
          final d = ai.decide(g, p);
          n++;
          if (d.type == ActionType.bet) {
            bet++;
            final f = (d.amountTo ?? 0) / max(1, g.potTotal());
            fracs.add(f);
            if (f >= 1.0) over++;
          } else {
            check++;
          }
          break;
        }
        if (g.street == Street.preflop) {
          g.apply('hero', oop ? (facing ? ActionType.call : ActionType.raise) : (facing ? ActionType.call : ActionType.check),
              amount: 300);
          continue;
        }
        g.apply('hero', canCheck ? ActionType.check : ActionType.call);
      }
    }
    double r(int v) => n == 0 ? 0 : v / n;
    final avg =
        fracs.isEmpty ? 0.0 : fracs.reduce((a, b) => a + b) / fracs.length;
    return (bet: r(bet), check: r(check), avgFrac: avg, overbet: r(over), n: n);
  }

  test('河牌尺度：超池不再是「只有坚果」的独家信号', () {
    const board = 'Kd 8c 3h 2s 5d';
    final set = aiRiverCheckedTo('8h 8s', board);
    final over = aiRiverCheckedTo('Ah Ad', board);
    final secondPair = aiRiverCheckedTo('8h 7s', board);
    String pct(double v) => '${(100 * v).round()}%';

    expect(set.n, greaterThan(100));
    expect(set.overbet, greaterThan(0.3),
        reason: '怪兽牌还是拿超池收价值（超池 ${pct(set.overbet)}）');
    // 以前超池清一色是怪兽牌，对手看到超池就弃、看到 0.6 池就敢跟。
    expect(over.overbet, greaterThan(0.08),
        reason: '超对也得混一点超池进去（超池 ${pct(over.overbet)}）');
    expect(over.avgFrac, greaterThan(0.7),
        reason: '平均尺度要跟着上去（均 ${over.avgFrac.toStringAsFixed(2)} 池）');
    // 但一对牌别抡超池：被跟注的都是更好的牌，属于白送。
    expect(secondPair.overbet, lessThan(0.05),
        reason: '第二对不拿超池送钱（超池 ${pct(secondPair.overbet)}）');

    // 没位置时怪兽牌要有一部分过牌：河牌的过牌范围不能清一色「我没东西」。
    final oopSet = aiRiverCheckedTo('8h 8s', board, oop: true);
    expect(oopSet.check, greaterThan(0.15),
        reason: '没位置的三条偶尔过牌钓一次（过牌 ${pct(oopSet.check)}）');
    expect(set.check, lessThan(0.05),
        reason: '有位置该收价值就收（过牌 ${pct(set.check)}）');
  });

  test('浮牌：后门花 + 两张高张不会见注就弃', () {
    // 8-7-2 这种小牌面：A 高配后门花是真人最爱跟一张的浮牌。
    const board = '8h 7d 2s';
    final float = aiVsCheckBet('As Qs', board, 0.5, seeds: 150);
    final dry = aiVsCheckBet('As Qd', board, 0.5, seeds: 150);
    String pct(double v) => '${(100 * v).round()}%';

    expect(float.call, greaterThan(dry.call + 0.08),
        reason: '有后门花才值得跟一张看转牌 '
            '(${pct(float.call)} vs ${pct(dry.call)})');
    // 但浮牌是少数派：大注不浮、没位置的浮牌也不能变成「什么都跟」。
    expect(float.fold, greaterThan(0.4),
        reason: '浮牌只是混入的频率，主体还是弃牌（弃 ${pct(float.fold)}）');
  });

  test('开火选牌：有后路（高张/后门花）的牌才值得一直开火', () {
    // 同一个牌面、同一档牌力（都是没成牌的空气），只差「后路」：
    // 真人是按「我还能变成什么」挑开火牌的，什么都不沾的纯垃圾
    // 抡起来就是白送——以前 AI 不看这一项，两张高张配后门花和
    // 7 高什么都没配到的下注率一模一样。
    final bdFlush =
        aiBetRateWhenCheckedTo('Qs Js', '9s 5d 2c', Street.flop, seeds: 200);
    final twoOver =
        aiBetRateWhenCheckedTo('Qs Jd', '9s 5d 2c', Street.flop, seeds: 200);
    expect(bdFlush, greaterThan(twoOver + 0.06),
        reason: '同样两张高张，多一个后门花更敢开火 '
            '(${(100 * bdFlush).round()}% vs ${(100 * twoOver).round()}%)');

    final nothing =
        aiBetRateWhenCheckedTo('9h 8h', 'Kd 2c 3s', Street.flop, seeds: 150);
    final oneOver =
        aiBetRateWhenCheckedTo('Ah 5h', 'Kd 2c 3s', Street.flop, seeds: 150);
    final bdOnly =
        aiBetRateWhenCheckedTo('Qd Jd', 'Kd 2c 3s', Street.flop, seeds: 150);
    expect(twoOver, greaterThan(nothing + 0.1),
        reason: '两张高张比纯垃圾打得更多 '
            '(${(100 * twoOver).round()}% vs ${(100 * nothing).round()}%)');
    expect(oneOver, greaterThan(nothing + 0.05),
        reason: '一张高张也算后路（${(100 * oneOver).round()}% vs '
            '${(100 * nothing).round()}%）');
    expect(bdOnly, greaterThan(nothing + 0.06),
        reason: '后门花同理（${(100 * bdOnly).round()}% vs '
            '${(100 * nothing).round()}%）');
    // 但纯垃圾不是完全不开火：有弃牌率、有对手读数时还是要有这一手。
    expect(nothing, greaterThan(0.05),
        reason: '纯空气也要留一点开火频率（${(100 * nothing).round()}%）');
  });

  /// 单挑/多人：AI 在按钮位开池，其他人都过牌/跟注，量 AI 翻牌圈
  /// 「下注额 ÷ 下注前底池」的平均值（只看它真的下注的那些手）。
  ({double frac, int n}) aiFlopBetFrac(String hole, String board,
      {int others = 0, int seeds = 250}) {
    final all = <double>[];
    for (var seed = 0; seed < seeds; seed++) {
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
      g.startHand(holeOverride: {'ai': _cs(hole)});
      var guard = 0;
      var recorded = false;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          final d = ai.decide(g, p);
          if (!recorded &&
              !facing &&
              g.street == Street.flop &&
              d.type == ActionType.bet &&
              d.amountTo != null) {
            recorded = true;
            all.add((d.amountTo! - p.streetBet) / g.potTotal());
          }
          g.apply('ai', d.type, amount: d.amountTo);
          if (recorded) break;
          continue;
        }
        if (g.street == Street.preflop && facing) {
          g.apply(p.id, ActionType.call);
          continue;
        }
        final want = canCheck ? ActionType.check : ActionType.call;
        g.apply(p.id,
            legal.any((a) => a.type == want) ? want : legal.first.type);
      }
    }
    final n = all.length;
    return (
      frac: n == 0 ? 0.0 : all.reduce((a, b) => a + b) / n,
      n: n,
    );
  }

  test('下注尺度：诈唬和价值不能分成两档（不然小注就是明牌）', () {
    // 同一个干燥牌面 K-8-3：成牌主力、薄价值（顶对）、有后路的空气。
    // 以前多人底池里价值 ×1.24、诈唬 ×0.8（现在 ×1.08 / ×0.97），
    // 结果「大注 = 价值、小注 = 空枪」成了一条明线，对手看到小注就抬。
    const board = 'Kd 8c 3h';
    ({double frac, int n}) v(int others) =>
        aiFlopBetFrac('Ks Kc', board, others: others);
    ({double frac, int n}) thin(int others) =>
        aiFlopBetFrac('Kh Qh', board, others: others);
    ({double frac, int n}) bluff(int others) =>
        aiFlopBetFrac('Qs Js', board, others: others);

    final hv = v(0), ht = thin(0), hb = bluff(0);
    expect(hv.n > 50 && ht.n > 50 && hb.n > 50, isTrue,
        reason: '样本要够（${hv.n}/${ht.n}/${hb.n}）');
    expect((hv.frac - hb.frac).abs(), lessThan(0.12),
        reason: '单挑：价值和诈唬的尺度要重叠 '
            '(${hv.frac.toStringAsFixed(2)} vs ${hb.frac.toStringAsFixed(2)})');
    expect((hv.frac - ht.frac).abs(), lessThan(0.15),
        reason: '薄价值的尺度也得在同一档里 '
            '(${ht.frac.toStringAsFixed(2)} vs ${hv.frac.toStringAsFixed(2)})');

    final mv = v(2), mt = thin(2), mb = bluff(2);
    expect(mv.n > 50 && mt.n > 50 && mb.n > 50, isTrue,
        reason: '多人样本要够（${mv.n}/${mt.n}/${mb.n}）');
    expect((mv.frac - mb.frac).abs(), lessThan(0.15),
        reason: '多人底池同理（以前差 0.24 池）'
            '(${mv.frac.toStringAsFixed(2)} vs ${mb.frac.toStringAsFixed(2)})');
    expect((mv.frac - mt.frac).abs(), lessThan(0.15),
        reason: '多人底池的薄价值同样不许另开一档 '
            '(${mt.frac.toStringAsFixed(2)} vs ${mv.frac.toStringAsFixed(2)})');
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
