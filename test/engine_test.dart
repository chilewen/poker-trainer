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

import 'support/test_shard.dart';

List<Card> _cs(String s) => s.split(' ').map(Card.parse).toList();

/// 迭代加速档。日常快速自查用 `zsh tool/regression.sh --fast`：它只跑标了
/// `fast: true` 的结构性冒烟用例（发牌 / 牌型评估 / 存档 / 标题），要重放牌局
/// 的 AI 用例整条跳过（输出里报成 skipped），所以快且不会假失败。代价是——
/// AI 行为有没有被改坏，它在原理上看不出来，那种改动必须跑全量。
///
/// 另有更粗暴的 TEST_SEEDS_SCALE（按比例缩小每个用例重放的牌局数，默认 1.0）：
///
///   TEST_SEEDS_SCALE=0.5 flutter test
///
/// 它直接动的是样本量，比例类断言（「加注率 > 0.4」之类）的余量本来就是按全量
/// 留的，砍一半噪声涨 1.4 倍，会稳定地假失败 4~6 条。只适合「我就想看它跑不跑
/// 得起来」，别拿它的红绿下结论。
double get _seedScale =>
    double.tryParse(Platform.environment['TEST_SEEDS_SCALE'] ?? '') ?? 1.0;

int _trialSeeds(int seeds) =>
    _seedScale >= 1 ? seeds : max(20, (seeds * _seedScale).round());

/// 读存档文件，直到 [done] 满意为止；一直不满意就返回 null（读不到也算 null）。
///
/// 落盘是异步的（控制器里到处是 `unawaited(persistSession())`），所以「动作做完了
/// → 立刻读文件」本来就是在赌它写完了；机器一忙（比如同时跑着诊断探针）固定
/// sleep 的 20ms 根本不够，会读到上一次的旧快照，用例假失败。这里改成轮询等
/// 目标状态出现，既不用多等，也不会flaky。
Future<Map<String, Object?>?> _readSessionWhen(
  File file,
  bool Function(Map<String, Object?>) done, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      if (done(raw)) return raw;
    } on Object {
      // 文件还没建出来 / 正被截断，下一轮再看。
    }
    if (DateTime.now().isAfter(deadline)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  t('引擎冒烟：发牌后盲注入池且轮到枪口', () {
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
  }, fast: true);

  t('Chen 起手牌评分：对子不扣间隔分', () {
    expect(AiPlayer.preflopScore(_cs('Ah Ad')), 20);
    expect(AiPlayer.preflopScore(_cs('9h 9d')), 9);
    expect(AiPlayer.preflopScore(_cs('2h 2d')), 5);
    expect(AiPlayer.preflopScore(_cs('7d 2c')), lessThan(2));
  }, fast: true);

  t('牌型评估：计数法与枚举法逐位一致', () {
    // bestOf 已经改成计数法实现（比枚举 C(7,5) 个组合快十几倍，AI 的
    // 「思考时间」基本就是它）。这里拿随机牌跟「枚举所有五张组合取最大」
    // 的老写法对拍，防止手写分支漏掉边界。
    //
    // 比的是 toString 而不是大小：一对的踢脚多带一张时，两手牌 value 相同
    // 却分出了胜负——这种错只能靠逐位对拍才抓得到。
    HandScore slowBestOf(List<Card> cards) {
      var best = HandEvaluator.evaluate5(cards.sublist(0, 5));
      for (var a = 0; a < cards.length; a++) {
        for (var b = a + 1; b < cards.length; b++) {
          for (var c = b + 1; c < cards.length; c++) {
            for (var d = c + 1; d < cards.length; d++) {
              for (var e = d + 1; e < cards.length; e++) {
                final s = HandEvaluator.evaluate5(
                    [cards[a], cards[b], cards[c], cards[d], cards[e]]);
                if (s > best) best = s;
              }
            }
          }
        }
      }
      return best;
    }

    final rng = Random(20240925);
    final deck = [
      for (final suit in Suit.values)
        for (final rank in Rank.values) Card(rank, suit),
    ];
    for (final n in [5, 6, 7]) {
      for (var i = 0; i < 2000; i++) {
        deck.shuffle(rng);
        final hand = deck.sublist(0, n);
        expect(HandEvaluator.bestOf(hand).toString(), slowBestOf(hand).toString(),
            reason: hand.map((c) => c.notation).join(' '));
      }
    }

    // 几个手写边界：轮子顺子、两个三条当葫芦、同花顺、四条、两对。
    const cases = [
      'Ah 2d 3c 4s 5h 9d 10c',
      'Ah Ad Ac Kh Kd Kc 2s',
      'Ah Kh Qh Jh 10h 9h 8h',
      '2h 2d 2c 2s 3h 4d 5c',
      'Ah Ad Kh Kd Qh 3c 2s',
      'Ah Ad 9c 8s 7h 6d 2c',
    ];
    for (final c in cases) {
      final hand = _cs(c);
      expect(HandEvaluator.bestOf(hand).toString(), slowBestOf(hand).toString(),
          reason: c);
    }
  });

  t('读牌：听牌 outs 与成牌层级', () {
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
  }, fast: true);

  t('读牌：牌面三张同花时，不是同花的大牌降一档', () {
    const board = '10d Qd 3s Kd'; // 转牌已经摆出三张方片
    expect(HandReading.of(_cs('7d 6d'), _cs(board)).tier, HandTier.monster,
        reason: '自己成花还是怪兽牌');
    expect(HandReading.of(_cs('Jc 9c'), _cs(board)).tier, HandTier.strong,
        reason: '顺子输给任何同花，不能再当怪兽牌');
    expect(HandReading.of(_cs('3h 3d'), _cs(board)).tier, HandTier.strong,
        reason: 'set 在同花面上同样会被盖过');
    expect(HandReading.of(_cs('Qs 3s'), _cs(board)).tier, HandTier.strong,
        reason: '两张底牌都中的两对，同花面上只是抓牌');
    // 干面上同样的两对仍是怪兽牌，别把降档做成全局的。
    expect(HandReading.of(_cs('Qs 3s'), _cs('Qh 3d 2c Ks')).tier,
        HandTier.monster);
    // 葫芦不受影响：三张同花面上照样是怪兽牌。
    expect(HandReading.of(_cs('3h 3c'), _cs('Kd Ks 3d 10d')).tier,
        HandTier.monster);
  }, fast: true);

  t('读牌：阻断牌（诈唬选牌用）', () {
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
  }, fast: true);

  t('范围胜率：河牌圈收紧对手范围后，胜率要明显低于对随机牌', () {
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
  }, fast: true);

  t('范围胜率：翻牌圈按全组合采样，窄范围不能系统性低估', () {
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

  t('范围胜率：多人底池的权重乘积不能提前断掉', () {
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

  t('翻前范围：位置越靠后开池越宽，大盲防守最宽', () {
    final ep = PreflopRanges.open(Seat.ep);
    final btn = PreflopRanges.open(Seat.btn);
    PreflopHand h(String s) => PreflopHand.of(_cs(s));

    expect(ep.contains(h('7s 6s')), isFalse, reason: '前位不玩同花连张');
    expect(btn.contains(h('7s 6s')), isTrue, reason: '按钮位可以用同花连张开池');
    expect(ep.contains(h('Ad 4d')), isFalse, reason: '前位不玩 A4s');
    expect(btn.contains(h('Ad 4d')), isTrue, reason: '按钮位偷盲会打 A4s');

    // 中位这一档单独钉：以前写的是 A7s+，于是中位会开 33 / 76s / 87s，
    // 却把 A5s 扔掉——一张自相矛盾的表。真实牌桌上，轮子 A（A5s~A2s）
    // 是最好的开池牌之一（坚果花 + 轮子顺 + 3bet 诈唬的阻断牌），
    // 会开 76s 的表不可能不开 A5s。tool/ai_preflop3bet_probe.dart 实测
    // 改之前 A5s 在中位的开池率是 0/300，同一条线上的 22 / 98s / 76s
    // 都在开；改之后 286/300，面对 3bet 加注 28% / 跟 51% / 弃 21%。
    // 后位的 CO / BTN 本来就是「任意同花 A」，这里跟它们对齐。
    final mp = PreflopRanges.open(Seat.mp);
    final co = PreflopRanges.open(Seat.co);
    expect(mp.contains(h('Ad 5d')), isTrue, reason: '中位要开 A5s');
    expect(mp.contains(h('Ad 2d')), isTrue, reason: '中位的同花 A 一路开到 A2s');
    expect(ep.contains(h('Ad 5d')), isFalse, reason: '前位还是只开 A8s+');
    // 补上同花 A 之后中位也不能跟劫位一样宽：这两档的差别在别处。
    expect(mp.contains(h('6s 5s')), isFalse, reason: '中位不玩 65s');
    expect(co.contains(h('6s 5s')), isTrue, reason: '劫位玩 65s');
    expect(mp.contains(h('2d 2c')), isFalse, reason: '中位不玩 22');
    expect(co.contains(h('2d 2c')), isTrue, reason: '劫位玩任意对子');

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
  }, fast: true);

  t('翻前位置：AI 前位扔垃圾牌，按钮位会偷盲', () {
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

  /// 9 人桌，p0 是按钮位：AI 坐在「按钮位往后数第 [rel] 个座位」上，前面的
  /// 人全弃（[limpAhead] = true 时改成全跟），记录它的第一个动作。
  /// rel：1=小盲 2=大盲 3~4=前位 5~6=中位 7~8=劫位。
  ({int raise, int call, int fold, int n}) aiOpenDecision(String hole,
      {required int rel,
      bool limpAhead = false,
      int? limpCount,
      AiStyle style = AiStyle.tightAggressive,
      int seeds = 150}) {
    var raise = 0, call = 0, fold = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config:
            const GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      );
      for (var i = 0; i < 9; i++) {
        g.addPlayer('p$i', 'P$i');
      }
      g.startHand(holeOverride: {'p$rel': _cs(hole)});
      var guard = 0;
      var acted = 0; // 目标前面已经行动过的家数（数溜入用）
      while (!g.handOver && guard++ < 40) {
        final p = g.pendingAction();
        if (p.player.id == 'p$rel') {
          n++;
          final d = AiPlayer(style, random: rnd).decide(g, p.player);
          switch (d.type) {
            case ActionType.raise:
              raise++;
            case ActionType.call:
              call++;
            default:
              fold++;
          }
          break;
        }
        // [limpCount] 只让目标前面的前几家补齐，其余弃牌——把「已经进来几家」
        // 钉死。不传 = 老行为（目标前面所有人一起溜入）。
        final wantsLimp = limpAhead && (limpCount == null || acted < limpCount);
        g.apply(p.player.id, wantsLimp ? ActionType.call : ActionType.fold);
        acted++;
      }
    }
    return (raise: raise, call: call, fold: fold, n: n);
  }

  t('翻前：前中位不「开门溜入」，跟溜入和跟注站照旧', () {
    // 「前面没人进池时的溜入」是最典型的鱼味破绽：用一个跟注把全桌都请
    // 进来，自己既没位置、翻后又拿不到弃牌率，对手读几手就知道
    // 「他溜入 = 没有强牌」。以前这里跟「跟在别人后面溜入」共用一个范围，
    // 实测紧凶前位拿 A5s / 76s / J9s 是 100% 溜入，中位 A5s 也是 100%。
    // 真人在这些位置只有两个动作：加注，或者弃。
    for (final rel in [3, 5]) {
      for (final hole in ['Ah 5h', '7h 6h', 'Jh 9h', '9h 8h']) {
        final r = aiOpenDecision(hole, rel: rel);
        expect(r.call, 0,
            reason: '$hole 在 rel=$rel 不该开门溜入（溜 ${r.call}/${r.n}）');
      }
    }
    // 而且不是「一律加注遮过去」：这些牌在前位本来就该扔。
    for (final hole in ['Ah 5h', '7h 6h', 'Jh 9h']) {
      final r = aiOpenDecision(hole, rel: 3);
      expect(r.fold / r.n, greaterThan(0.85),
          reason: '$hole 前位该弃（弃 ${r.fold}/${r.n}）');
    }

    // 跟在别人后面溜入是另一回事：中位面对两个溜入者，投机的同花连张
    // 便宜看翻牌，真人确实会这么打，不能一起禁掉。
    final behind = aiOpenDecision('7h 6h', rel: 5, limpAhead: true);
    expect(behind.call / behind.n, greaterThan(0.5),
        reason: '中位跟两个溜入者，76s 便宜看翻牌（溜 ${behind.call}/${behind.n}）');

    // 跟注站的招牌就是溜入，标准风格收紧时不能把它一起收掉。
    final station =
        aiOpenDecision('7h 6h', rel: 3, style: AiStyle.loosePassive);
    expect(station.call / station.n, greaterThan(0.4),
        reason: '松被动前位照样溜入（溜 ${station.call}/${station.n}）');
    // 风格差异要在牌桌上看得出来：松凶在前位也不开门溜入。
    final lag =
        aiOpenDecision('Ah 5h', rel: 3, style: AiStyle.looseAggressive);
    expect(lag.call, 0, reason: '松凶前位也不溜入（溜 ${lag.call}/${lag.n}）');
  });

  t('翻前：面对溜入者，后位用边缘牌跟着溜入，不是只会加注或弃牌', () {
    // 真人在后面有人溜入时不是「加注或弃牌」两档：小对子、同花连张、
    // A2s~A7s、K9s 这类牌一半加注、一半跟着便宜看翻牌，加注留给真能拿
    // 价值的那一段。以前这里没有这条线——探针实测（9 人桌、169 种起手牌
    // 各 60 手、面对两个溜入者）紧凶在按钮位「加 54% / 跟 0% / 弃 46%」、
    // 松凶「加 74% / 跟 0% / 弃 26%」，一次都不跟注，唯一会溜入的风格反倒
    // 是松被动（跟 54%）。对手读几手就能确定「他跟进池 = 他加注过 = 他牌
    // 很强」，而跟注站成了牌桌上的异类。
    for (final rel in [0, 1]) {
      // rel 0 = 按钮位、rel 1 = 小盲：都是「后面还有人溜入」的场合。
      for (final hole in ['5h 5d', '7h 6h', 'Ah 2h', 'Kh 9h']) {
        final r = aiOpenDecision(hole, rel: rel, limpAhead: true);
        expect(r.call / r.n, greaterThan(0.25),
            reason: '$hole 在 rel=$rel 该有一部分跟着溜入（跟 ${r.call}/${r.n}）');
        expect(r.raise / r.n, greaterThan(0.25),
            reason: '$hole 在 rel=$rel 也不能一次都不加注（加 ${r.raise}/${r.n}）');
      }
      // 真正该拿价值的牌照旧加注：混合不能把加注范围一起洗掉，不然
      // 「他跟着溜入 = 他没有强牌」这个新的破绽就跟旧的对称了。
      for (final hole in ['Kh Kd', 'Ah Kd', 'Qh Qd']) {
        final r = aiOpenDecision(hole, rel: rel, limpAhead: true);
        expect(r.call, 0,
            reason: '$hole 在 rel=$rel 面对溜入者该加注拿价值（跟 ${r.call}/${r.n}）');
      }
    }
    // 没人进池时不吃这一套：开门溜入照旧是破绽（见上一条用例）。
    final noLimps = aiOpenDecision('5h 5d', rel: 0);
    expect(noLimps.call, 0,
        reason: '前面没人进池时 55 不该开门溜入（溜 ${noLimps.call}/${noLimps.n}）');

    // 「溜入家数」这一维以前是死的：探针实测（tool/ai_preflop3bet_probe.dart
    // 第五节：8 人桌、AI 钉在按钮、桌子大小和座位固定）1 / 2 / 3 / 4 家溜入的
    // 动作**逐字相同**——87o 这种非同花连张从第 1 家起就只剩「加 10% / 补 12%
    // / 弃 79%」、2 家往后一律弃；A8o / KQo 到了 4 家也是一样弃，因为标准溜入
    // 表（[PreflopRanges.limp]）里只有同花牌、对子和 A 高张，非同花牌掉出开池
    // 范围之后根本没有落点。真人是在后面一大堆溜入、价格又便宜的时候拿这些牌
    // 补着看翻牌，而且溜进来的人越多越愿意补。
    //
    // 现在：非同花开池范围按人数一档一档收（[AiPlayer] 里的 shiftedOffsuit），
    // 两家以上再开一档「中间档」溜入表（[PreflopRanges.limpMid]），里面那批牌
    // 只按比例进来（midMix 0.45 起、随人数往上）。实测 87o 紧凶补齐
    // 12% → 42% → 57% → 69%（1 → 4 家），KQo 从「一律加注」变成 3 家
    // 「加 21% / 补 46% / 弃 33%」、4 家「补 69% / 弃 31%」。
    final swing1 = aiOpenDecision('8h 7d', rel: 0, limpAhead: true, limpCount: 1);
    final swing4 = aiOpenDecision('8h 7d', rel: 0, limpAhead: true, limpCount: 4);
    expect(swing4.call / swing4.n, greaterThan(swing1.call / swing1.n + 0.25),
        reason: '87o：溜入越多越该补着看翻牌'
            '（4 家补 ${swing4.call}/${swing4.n} vs 1 家补 ${swing1.call}/${swing1.n}）');
    // 中间档只按比例进来，不是整档放开——不然只是把「一律弃」那道台阶挪成
    // 「一律补」，读起来还是一句话。
    expect(swing4.fold, greaterThan(swing4.n ~/ 10),
        reason: '87o 在 4 家溜入面前该留一部分弃牌（弃 ${swing4.fold}/${swing4.n}）');
    final broad1 = aiOpenDecision('Kh Qs', rel: 0, limpAhead: true, limpCount: 1);
    final broad4 = aiOpenDecision('Kh Qs', rel: 0, limpAhead: true, limpCount: 4);
    expect(broad4.raise / broad4.n, lessThan(broad1.raise / broad1.n - 0.3),
        reason: 'KQo：溜入多了就不该再一律隔离加注'
            '（4 家加 ${broad4.raise}/${broad4.n} vs 1 家加 ${broad1.raise}/${broad1.n}）');
  });

  t('位置：单挑时按钮位知道自己在闭圈（顶对直接下注，不慢打）', () {
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

  t('读人：AI 会把对手「见注就弃」记进档案，并据此调整打法', () {
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

  t('读人：对手是疯子还是岩石，决定我们抓诈唬时跟不跟', () {
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
    expect(vsManiac.total, greaterThan(_trialSeeds(30)));
    expect(vsManiac.callRate, greaterThan(vsNit.callRate + 0.15),
        reason: '对爱开火的对手抓得更多，对岩石弃得更多 '
            '(${(100 * vsManiac.callRate).toStringAsFixed(0)}% vs '
            '${(100 * vsNit.callRate).toStringAsFixed(0)}%)');
  });

  t('读线：对手前面几条街一路开火后河牌超池，就别轻易跟', () {
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
    expect(vsBarrel.total, greaterThan(_trialSeeds(40)));
    expect(vsCheckThenBet.total, greaterThan(_trialSeeds(40)));
    expect(vsCheckThenBet.callRate, greaterThan(vsBarrel.callRate + 0.15),
        reason: '对手一路过牌后突然超池，比连开三枪更值得抓 '
            '(${(100 * vsBarrel.callRate).toStringAsFixed(0)}% vs '
            '${(100 * vsCheckThenBet.callRate).toStringAsFixed(0)}%)');
  });

  /// 单挑：AI 在按钮位，英雄（大盲）翻牌/转牌按 [barrel] 决定要不要各开
  /// 一枪，河牌按 [frac] 池下注；量 AI 面对这一注的应对（弃/跟/加）。
  ({double fold, double call, double raise, int total}) aiVsRiverBet(
      String hole, String board, double frac,
      {bool barrel = false,
      int preflopRaiseTo = 0,
      int seeds = 200,
      AiPlayer? persistentAi}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      // [persistentAi] 让同一个 AI 连着打多手：真桌就是这样的（TableController
      // 里每个座位只在开局建一次），读牌档案跨手累积。不给的话每个种子换一个
      // 新 AI——那是「对手第一次这么打」的冷启动视角，量不到读人的效果。
      final ai = persistentAi ?? AiPlayer(AiStyle.tightAggressive, random: rnd);
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
          if (!facing) break; // 英雄没下注的手不算样本
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
        if (g.street == Street.preflop) {
          // 默认翻前谁都不加，底池很小；[preflopRaiseTo] 让英雄开一枪，
          // 用来复现「翻前造大池 → 河牌超池把 SPR 压到极低」那种牌局。
          final raise =
              legal.where((a) => a.type == ActionType.raise).firstOrNull;
          if (preflopRaiseTo > 0 &&
              raise != null &&
              g.currentBet < preflopRaiseTo) {
            g.apply('hero', ActionType.raise,
                amount: min(preflopRaiseTo, raise.maxAmount));
          } else {
            g.apply('hero', facing ? ActionType.call : ActionType.check);
          }
          continue;
        }
        if (facing) {
          g.apply('hero', ActionType.call);
          continue;
        }
        final la = legal.where((a) => a.type == ActionType.bet).firstOrNull;
        if (la != null &&
            (g.street == Street.river ||
                (barrel && g.street != Street.river))) {
          final f = g.street == Street.river ? frac : 0.6;
          g.apply('hero', ActionType.bet,
              amount: (p.streetBet + (g.potTotal() * f).round())
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        g.apply('hero', canCheck ? ActionType.check : ActionType.call);
      }
    }
    double r(int v) => total == 0 ? 0 : v / total;
    return (fold: r(fold), call: r(call), raise: r(raise), total: total);
  }

  /// 河牌防守的「范围级」量法：随机发牌、英雄一路开火、AI 每个决策都自己打，
  /// 只统计它到河牌面对第三枪时弃了多少（跟 tool/ai_river_defense_probe.dart
  /// 一个路子）。
  ///
  /// 为什么不能只靠 [aiVsRiverBet]：那个量法为了一手牌一个尺度出结论，把 AI
  /// 钉死在「翻牌/转牌过牌或跟注」上。可读牌对**范围模型**的影响恰恰先落在
  /// 「这条街要不要继续」上——同一手牌、同一个尺度，放开前后一模一样，
  /// 钉住前两条街就把它整个盖住了。这一条看的是结果：对手连开三枪，AI 在
  /// 河牌总共交出去多少。传 [persistentAi]（同一个 AI 连着打）= 真桌视角，
  /// 读牌档案跨手累积；不传就是每手一个新 AI 的冷启动视角。
  ({double fold, int total}) aiRiverDefenseRange(String board, double frac,
      {AiPlayer? persistentAi, int seeds = 2500}) {
    var fold = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      final ai = persistentAi ?? AiPlayer(AiStyle.tightAggressive, random: rnd);
      g.buttonIndex = 0; // startHand 里 +1 → 英雄坐按钮，AI 守大盲
      g.startHand(boardOverride: _cs(board));
      var guard = 0;
      while (!g.handOver && guard++ < 400) {
        final p = g.pendingAction();
        final street = g.street;
        final facing = g.currentBet > p.player.streetBet;
        if (p.player.id == 'ai') {
          if (!facing) {
            // AI 先说话：要求它过牌，让英雄开火（它主动下注就不是我们要
            // 量的局面了）。
            if (ai.decide(g, p.player).type != ActionType.check) break;
            g.apply('ai', ActionType.check);
            continue;
          }
          if (street == Street.river) {
            final d = ai.decide(g, p.player);
            total++;
            if (d.type == ActionType.fold) fold++;
            break;
          }
          // 翻牌/转牌面对下注：跟注才继续看下一条街。
          final d = ai.decide(g, p.player);
          if (d.type != ActionType.call) break;
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        // 英雄：翻前加到 3bb；之后无人下注就开火，有人下注就跟。
        final legal = p.actions;
        if (street == Street.preflop) {
          final raise =
              legal.where((a) => a.type == ActionType.raise).firstOrNull;
          if (raise != null && g.currentBet < 300) {
            g.apply('hero', ActionType.raise,
                amount: min(300, raise.maxAmount));
          } else if (legal.any((a) => a.type == ActionType.call)) {
            g.apply('hero', ActionType.call);
          } else {
            break;
          }
          continue;
        }
        if (facing) {
          g.apply('hero', ActionType.call);
          continue;
        }
        final bet = legal.where((a) => a.type == ActionType.bet).firstOrNull;
        if (bet == null) break;
        final f = street == Street.river ? frac : 0.66;
        g.apply('hero', ActionType.bet,
            amount: (g.potTotal() * f).round().clamp(bet.minAmount, bet.maxAmount));
      }
    }
    return (fold: total == 0 ? 0 : fold / total, total: total);
  }

  /// 单挑：AI 按钮开池、英雄跟注；翻牌英雄过牌/跟注，转牌英雄按 [frac] 池
  /// 下注，统计 AI 在转牌面对下注的应对（就是「听牌面对第二枪」那条线）。
  ({double fold, double call, double raise, int n}) aiVsTurnBet(
      String hole, String board, double frac,
      {AiStyle style = AiStyle.tightAggressive,
      int preflopRaiseTo = 0,
      int stack = 10000,
      bool barrel = false,
      bool aiCheckFlop = false,
      int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: GameConfig(
            startingStack: stack, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      final ai = AiPlayer(style, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3s 2s')},
        boardOverride: _cs(board),
      );
      // 默认开 250（约 3bb）；[preflopRaiseTo] 用来把翻前底池造大，复现
      // 「转牌超池把 SPR 压到 1.5 上下」那种牌局——低 SPR 下强牌档以前
      // 会直接推全下。
      final openTo = preflopRaiseTo > 0 ? preflopRaiseTo : 250;
      final la = g
          .pendingAction()
          .actions
          .where((a) => a.type == ActionType.raise)
          .firstOrNull;
      g.apply('ai', ActionType.raise,
          amount:
              la == null ? openTo : openTo.clamp(la.minAmount, la.maxAmount));
      g.apply('hero', ActionType.call);
      var guard = 0;
      var asked = false;
      var heroBet = false;
      while (!g.handOver && guard++ < 200) {
        final p = g.pendingAction();
        final legal = p.actions;
        final facing = g.currentBet > p.player.streetBet;
        if (p.player.id == 'ai') {
          // [aiCheckFlop] 用来复现诊断探针里那一格：AI 在翻牌先过牌，
          // 把「听牌面对转牌第二枪」这一格单独隔出来（不然 AI 自己先开一
          // 枪，底池被撑大，筹码/底池比整条压到斜坡以下，量不出门槛）。
          if (aiCheckFlop &&
              g.street == Street.flop &&
              !facing &&
              legal.any((a) => a.type == ActionType.check)) {
            g.apply('ai', ActionType.check);
            continue;
          }
          final d = ai.decide(g, p.player);
          if (g.street == Street.turn && facing && !asked) {
            asked = true;
            n++;
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
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        // 英雄：翻牌按 [barrel] 决定要不要先开一枪，转牌拿到说话权就按
        // [frac] 池下注（第二枪），其余过牌/跟注。
        final wantsBet = !facing &&
            legal.any((a) => a.type == ActionType.bet) &&
            (g.street == Street.turn
                ? !heroBet
                : (barrel && g.street == Street.flop));
        if (wantsBet) {
          if (g.street == Street.turn) heroBet = true;
          final la = legal.firstWhere((a) => a.type == ActionType.bet);
          final f = g.street == Street.turn ? frac : 0.6;
          g.apply(
              'hero',
              ActionType.bet,
              amount:
                  (g.potTotal() * f).round().clamp(la.minAmount, la.maxAmount));
          continue;
        }
        final want = facing ? ActionType.call : ActionType.check;
        g.apply(p.player.id,
            legal.any((a) => a.type == want) ? want : ActionType.check);
      }
    }
    double r(int v) => n == 0 ? 0 : v / n;
    return (fold: r(fold), call: r(call), raise: r(raise), n: n);
  }

  /// 单挑：AI 按钮开池（写死 250，任何起手牌都能进翻牌）、英雄跟注，
  /// 翻牌英雄按 [frac] 池下注，统计 AI 在翻牌圈的应对。
  ({double fold, double call, double raise, int n}) aiVsFlopBet(
      String hole, String board, double frac,
      {AiStyle style = AiStyle.tightAggressive, int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      final ai = AiPlayer(style, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3s 2s')},
        boardOverride: _cs(board),
      );
      g.apply('ai', ActionType.raise, amount: 250);
      g.apply('hero', ActionType.call);
      var guard = 0;
      var asked = false;
      while (!g.handOver && guard++ < 200) {
        final p = g.pendingAction();
        final legal = p.actions;
        if (p.player.id == 'ai') {
          final d = ai.decide(g, p.player);
          if (g.street == Street.flop && !asked) {
            asked = true;
            n++;
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
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        final la = legal.firstWhere((a) => a.type == ActionType.bet,
            orElse: () => legal.first);
        if (legal.any((a) => a.type == ActionType.bet)) {
          g.apply(
              'hero',
              ActionType.bet,
              amount: (g.potTotal() * frac)
                  .round()
                  .clamp(la.minAmount, la.maxAmount));
        } else {
          g.apply('hero', legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : legal.first.type);
        }
      }
    }
    return (
      fold: n == 0 ? 0 : fold / n,
      call: n == 0 ? 0 : call / n,
      raise: n == 0 ? 0 : raise / n,
      n: n,
    );
  }

  /// [aiVsFlopBet] 的 3bet 底池版：翻前线固定成
  /// 「AI 开 3bb → 英雄 3bet 到 9bb → AI 跟」，翻后英雄先下注 [frac] 池，
  /// 量 AI（有位置、翻前跟注方）的第一次应对。跟 [aiVsFlopBet] 并排跑，
  /// 两边唯一的差别就是底池里多不多那一次 3bet。
  ({double fold, double call, double raise, int n}) aiVsFlopBetInThreeBetPot(
      String hole, String board, double frac,
      {AiStyle style = AiStyle.tightAggressive, int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      final ai = AiPlayer(style, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3s 2s')},
        boardOverride: _cs(board),
      );
      g.apply('ai', ActionType.raise, amount: 300);
      g.apply('hero', ActionType.raise, amount: 900);
      g.apply('ai', ActionType.call);
      var guard = 0;
      var asked = false;
      while (!g.handOver && guard++ < 200) {
        final p = g.pendingAction();
        final legal = p.actions;
        if (p.player.id == 'ai') {
          final d = ai.decide(g, p.player);
          if (g.street == Street.flop && !asked) {
            asked = true;
            n++;
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
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        final la = legal.firstWhere((a) => a.type == ActionType.bet,
            orElse: () => legal.first);
        if (legal.any((a) => a.type == ActionType.bet)) {
          g.apply(
              'hero',
              ActionType.bet,
              amount: (g.potTotal() * frac)
                  .round()
                  .clamp(la.minAmount, la.maxAmount));
        } else {
          g.apply('hero', legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : legal.first.type);
        }
      }
    }
    return (
      fold: n == 0 ? 0 : fold / n,
      call: n == 0 ? 0 : call / n,
      raise: n == 0 ? 0 : raise / n,
      n: n,
    );
  }

  /// [aiVsBetInThreeBetPot]：翻前线还是「AI 开 3bb → 英雄 3bet 到 9bb →
  /// AI 跟」，但英雄在 [target] 街之前每一街都下 [frac] 池、AI 一律跟，
  /// 把底池和 SPR 钉死，只量 AI 在 [target] 街面对同一个尺度的第一次应对。
  ///
  /// 不钉住前几条街的话，同一格 200 个种子里会混进十几种不同的底池/SPR
  /// （AI 有时在翻牌就反加回去），读数就成了「一堆局面的平均」；[stack]
  /// 则决定决策那一刻的 SPR（这个脚本下：stack 8000 → 0.41、16000 →
  /// 1.15、20000 → 1.52）。
  ///
  /// [checkTo] = true 时英雄在 [target] 街**过牌**，量的是 AI 被过牌到
  /// （[_checkedTo]）那一侧的决策——同一条脚本下 SPR 10000 → 0.89、
  /// 16200 → 1.75、24100 → 2.85。
  ({double fold, double call, double raise, double jam, int n})
      aiVsBetInThreeBetPot(String hole, String board, Street target, double frac,
          {int stack = 10000,
          AiStyle style = AiStyle.tightAggressive,
          int seeds = 200,
          bool checkTo = false}) {
    var fold = 0, call = 0, raise = 0, jam = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config:
            GameConfig(startingStack: stack, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      final ai = AiPlayer(style, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3c 2h')},
        boardOverride: _cs(board),
      );
      g.apply('ai', ActionType.raise, amount: 300);
      g.apply('hero', ActionType.raise, amount: 900);
      g.apply('ai', ActionType.call);
      var guard = 0;
      while (!g.handOver && guard++ < 200) {
        final p = g.pendingAction();
        final legal = p.actions;
        if (p.player.id == 'ai') {
          // target 街之前一律钉成跟注/过牌：让 AI 自己打的话，它有时会在
          // 翻牌就反加回去（底池、SPR 全变），有的种子干脆提前结束，同一格
          // 200 个种子会混进十几种不同场景——那样量出来的「SPR 1.15
          // 推多少」就不是一个 SPR 下的数。
          if (g.street != target) {
            g.apply(
                'ai',
                legal.any((a) => a.type == ActionType.call)
                    ? ActionType.call
                    : legal.first.type);
            continue;
          }
          final d = ai.decide(g, p.player);
          n++;
          switch (d.type) {
            case ActionType.fold:
              fold++;
            case ActionType.call:
              call++;
            default:
              raise++;
              // 加注直接把筹码推光 = 走的是「低 SPR 套进去」那条分支。
              // 光看加注尺度分不出超池和常规加注：低 SPR 下 85% 池的加注
              // 也会被夹到全下。
              if (d.amountTo != null &&
                  d.amountTo! >= p.player.stack + p.player.streetBet) {
                jam++;
              }
          }
          break;
        }
        final la = legal.firstWhere((a) => a.type == ActionType.bet,
            orElse: () => legal.first);
        if (checkTo && g.street == target) {
          g.apply(
              'hero',
              legal.any((a) => a.type == ActionType.check)
                  ? ActionType.check
                  : legal.first.type);
        } else if (legal.any((a) => a.type == ActionType.bet)) {
          g.apply(
              'hero',
              ActionType.bet,
              amount: (g.potTotal() * frac)
                  .round()
                  .clamp(la.minAmount, la.maxAmount));
        } else {
          g.apply('hero', legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : legal.first.type);
        }
      }
    }
    return (
      fold: n == 0 ? 0 : fold / n,
      call: n == 0 ? 0 : call / n,
      raise: n == 0 ? 0 : raise / n,
      jam: n == 0 ? 0 : jam / n,
      n: n,
    );
  }

  t('3bet 底池：强牌面对下注留一点加注，不能只剩两对以上', () {
    // 「对手的线很实」以前是一道硬开关：villainStrength > 0.8 就 100% 跟。
    // 可范围模型给 3bet 方的强度几乎总是压在 0.97——探针里同一手牌、同一个
    // 尺度的「顶对顶踢/超对 面对半池」，在单加池是加注 46%，进了 3bet 池就
    // 成了加注 0%。也就是说 AI 在 3bet 池里的加注范围只剩两对以上，对手一
    // 看到加注就知道撞上了大家伙；可真人拿顶对/超对在 3bet 池里照样会加一
    // 部分（挡听牌，也让跟注范围有掩护），只是比单加池少。
    //
    // 同一类漏在听牌那一侧也有：[_semiBluffRaiseChance] 从来没看过池子类型，
    // 于是半诈唬加注在 3bet 池里和单加池逐档一模一样（花听 23% 加）。
    String pct(double v) => '${(100 * v).round()}%';
    final singleTop = aiVsFlopBet('Ah Qd', 'Qh 7d 2c', 0.5);
    final threeTop = aiVsFlopBetInThreeBetPot('Ah Qd', 'Qh 7d 2c', 0.5);
    final threeOver = aiVsFlopBetInThreeBetPot('9h 9d', '7s 4c 2d', 0.5);
    final singleDraw = aiVsFlopBet('Ad Kd', 'Qd 7d 2c', 0.5);
    final threeDraw = aiVsFlopBetInThreeBetPot('Ad Kd', 'Qd 7d 2c', 0.5);
    for (final r in [singleTop, threeTop, threeOver, singleDraw, threeDraw]) {
      expect(r.n, greaterThan(_trialSeeds(150)), reason: '样本要够');
    }
    // 单加池那一档是原来的行为，这次不动它——改的只是模型饱和的 3bet 池。
    expect(singleTop.raise, greaterThan(0.35),
        reason: '单加池里顶对顶踢照样要加（加 ${pct(singleTop.raise)}）');
    // 3bet 池里加注要明显更少，但不能一个都没有。
    expect(threeTop.raise, greaterThan(0.03),
        reason: '3bet 池里顶对不能一个加注都没有（加 ${pct(threeTop.raise)}）');
    expect(threeOver.raise, greaterThan(0.03),
        reason: '超对同理（加 ${pct(threeOver.raise)}）');
    expect(threeTop.raise, lessThan(singleTop.raise - 0.15),
        reason: '范围窄了一半就该收着加 '
            '(${pct(threeTop.raise)} vs 单加池 ${pct(singleTop.raise)})');
    expect(threeTop.call, greaterThan(0.8),
        reason: '3bet 池里还是以跟为主（跟 ${pct(threeTop.call)}）');
    // 听牌那一侧：半诈唬加注也得跟着池子类型收一档。
    expect(threeDraw.raise, lessThan(singleDraw.raise - 0.05),
        reason: '3bet 池里半诈唬加注要收一档 '
            '(${pct(threeDraw.raise)} vs 单加池 ${pct(singleDraw.raise)})');
  });

  t('低 SPR 推全下：推的频率跟着 SPR 连续走，闸门两侧不该是两个世界', () {
    // 「低 SPR 就把筹码推出去」以前是一道硬开关（`SPR ≤ jamSpr` 一律
    // 全下，单挑 jamSpr = 1.5）。筹码真套进去时它是对的——加注量小到接近
    // 最小加注，对手范围里抓诈唬/听牌/更差的成牌全都得跟。问题在开关的
    // 另一侧：3bet 池里拿顶对顶踢面对半池，探针把 stack 扫成一排 SPR
    // 之后量到，翻牌 SPR 1.44 推 100%、1.67 推 4%；转牌 1.33 推 100%、
    // 1.52 推 3%；河牌 1.15 推 100%、1.52 推 2%——同一手牌、同一个尺度，
    // 落在闸门哪一侧完全是两个世界。对手只要把尺度调到闸门下面，就能
    // 稳定收走全下；调上去又几乎收不到。
    //
    // 改成跟 SPR 连续的斜坡之后：河牌 SPR 0.41 推 100%（加注量才 5% 池，
    // 等于让你白跟）、1.15 推四成、1.52 落到个位数；转牌同一条曲线。
    String pct(double v) => '${(100 * v).round()}%';
    final shallow =
        aiVsBetInThreeBetPot('Ah Qd', 'Qh 7d 2c 5s 9d', Street.river, 0.5,
            stack: 8000);
    final mid = aiVsBetInThreeBetPot(
        'Ah Qd', 'Qh 7d 2c 5s 9d', Street.river, 0.5,
        stack: 16000);
    final deep = aiVsBetInThreeBetPot(
        'Ah Qd', 'Qh 7d 2c 5s 9d', Street.river, 0.5,
        stack: 20000);
    final turnMid =
        aiVsBetInThreeBetPot('Ah Qd', 'Qh 7d 2c 5s', Street.turn, 0.5,
            stack: 8000);
    final turnDeep =
        aiVsBetInThreeBetPot('Ah Qd', 'Qh 7d 2c 5s', Street.turn, 0.5,
            stack: 10000);
    for (final r in [shallow, mid, deep, turnMid, turnDeep]) {
      expect(r.n, greaterThan(_trialSeeds(150)), reason: '样本要够');
    }
    // 加注量接近最小加注那一档照旧推到底：不推才是白白少要一趟价值。
    expect(shallow.raise, greaterThan(0.8),
        reason: 'SPR 0.41 该推（推 ${pct(shallow.raise)}）');
    // 中间那一档必须是个混合，而不是「一律推」。
    expect(mid.raise, greaterThan(0.15),
        reason: 'SPR 1.15 不能一个都不推（推 ${pct(mid.raise)}）');
    expect(mid.raise, lessThan(0.7),
        reason: 'SPR 1.15 也不能还是一律推（推 ${pct(mid.raise)}）');
    // 闸门上面（SPR 1.52）收得干净，但不能收成 0——留一点，
    // 免得「他一推就是大家伙」写在脸上。
    expect(deep.raise, lessThan(0.15),
        reason: 'SPR 1.52 该以跟为主（推 ${pct(deep.raise)}）');
    expect(deep.raise, greaterThan(0.005),
        reason: '闸门上面也要留一点加注（推 ${pct(deep.raise)}）');
    // 单调：SPR 越小推得越勤。
    expect(mid.raise, lessThan(shallow.raise - 0.2),
        reason: 'SPR 0.41 到 1.15 要多收一截 '
            '(${pct(shallow.raise)} → ${pct(mid.raise)})');
    expect(deep.raise, lessThan(mid.raise),
        reason: 'SPR 越大推得越少（${pct(mid.raise)} → ${pct(deep.raise)}）');
    // 转牌是同一条曲线：同一档 SPR 上下不能又变成两个世界。
    expect(turnMid.raise, greaterThan(0.15),
        reason: '转牌 SPR 1.15 不能一个都不推（推 ${pct(turnMid.raise)}）');
    expect(turnMid.raise, lessThan(0.7),
        reason: '转牌 SPR 1.15 也不能一律推（推 ${pct(turnMid.raise)}）');
    expect(turnDeep.raise, lessThan(turnMid.raise),
        reason: '转牌 SPR 越大推得越少'
            '（${pct(turnMid.raise)} → ${pct(turnDeep.raise)}）');

    // 怪兽牌那一档（两对）的闸门更高（2.5），但同一条曲线也得成立：改之前
    // 河牌两对面对半池，SPR 0.59~2.50 推 100%（闸门那格推 215% 池），
    // SPR 2.81 直接掉成「85% 池加注 76%」——加注尺度在 215% 池和 85% 池
    // 之间没有中间档，对手把尺度卡在闸门上面就永远收不到超池尺寸。
    final mShallow =
        aiVsBetInThreeBetPot('9h 7d', 'Qh 9d 7c 5h 2s', Street.river, 0.5,
            stack: 10000);
    final mMid = aiVsBetInThreeBetPot('9h 7d', 'Qh 9d 7c 5h 2s', Street.river, 0.5,
        stack: 20000);
    final mGate = aiVsBetInThreeBetPot('9h 7d', 'Qh 9d 7c 5h 2s', Street.river, 0.5,
        stack: 30600);
    for (final r in [mShallow, mMid, mGate]) {
      expect(r.n, greaterThan(_trialSeeds(150)), reason: '样本要够');
    }
    expect(mShallow.jam, greaterThan(0.9),
        reason: '两对 SPR 0.59（加注量才 25% 池）该推（推 ${pct(mShallow.jam)}）');
    expect(mMid.jam, greaterThan(0.3),
        reason: '两对 SPR 1.52 还要推一部分（推 ${pct(mMid.jam)}）');
    expect(mMid.jam, lessThan(0.9),
        reason: '两对 SPR 1.52 也不能还是一律推（推 ${pct(mMid.jam)}）');
    expect(mGate.jam, lessThan(0.08),
        reason: '两对 SPR 2.50 不该再推超池（推 ${pct(mGate.jam)}）');
    // 收掉超池尺寸 ≠ 把价值加注也收掉：落回去的那部分要是常规加注。
    expect(mGate.raise, greaterThan(0.5),
        reason: '闸门上面还得有 85% 池的价值加注（加 ${pct(mGate.raise)}）');
    expect(mMid.jam, lessThan(mShallow.jam),
        reason: '两对也是 SPR 越大推得越少'
            '（${pct(mShallow.jam)} → ${pct(mMid.jam)}）');
    expect(mGate.jam, lessThan(mMid.jam),
        reason: '两对 SPR 2.50 要收到几乎不推'
            '（${pct(mMid.jam)} → ${pct(mGate.jam)}）');

    // 「被过牌到」那一侧（[AiPlayer._checkedTo]）以前是另外两道硬门槛
    // （怪兽 SPR ≤ 2.5 / 强牌 SPR ≤ 1.5 一律推全下），毛病因一条：
    // 闸门两侧是两个世界。探针把 stack 扫成一排 SPR 量到，顶对顶踢
    // SPR 0.89 推 100%、1.25 推 100%，SPR 1.75 立刻掉成「过牌 28% +
    // 一堆小注」；两对 97 SPR 2.35 还是 235% 池 100%，2.85 就只剩
    // 「120% 池 19%」。换成同形状的斜坡之后（探针实测）：两对 被过牌到
    // SPR 0.89/1.25/1.75/2.35/2.85 推 100/88/51/9/0%。
    final cShallow = aiVsBetInThreeBetPot(
        'Ah Qd', 'Qh 7d 2c 5s 9d', Street.river, 0.5,
        stack: 10000, checkTo: true);
    final cMid = aiVsBetInThreeBetPot(
        'Ah Qd', 'Qh 7d 2c 5s 9d', Street.river, 0.5,
        stack: 12600, checkTo: true);
    final cDeep = aiVsBetInThreeBetPot(
        'Ah Qd', 'Qh 7d 2c 5s 9d', Street.river, 0.5,
        stack: 24100, checkTo: true);
    final cMonsterShallow = aiVsBetInThreeBetPot(
        '9h 7d', 'Qh 9d 7c 5h 2s', Street.river, 0.5,
        stack: 10000, checkTo: true);
    final cMonsterMid = aiVsBetInThreeBetPot(
        '9h 7d', 'Qh 9d 7c 5h 2s', Street.river, 0.5,
        stack: 20500, checkTo: true);
    final cMonsterDeep = aiVsBetInThreeBetPot(
        '9h 7d', 'Qh 9d 7c 5h 2s', Street.river, 0.5,
        stack: 24100, checkTo: true);
    for (final r in [
      cShallow,
      cMid,
      cDeep,
      cMonsterShallow,
      cMonsterMid,
      cMonsterDeep,
    ]) {
      expect(r.n, greaterThan(_trialSeeds(150)), reason: '样本要够');
    }
    // 强牌那一档：闸门（1.5）下面照旧把筹码放进去，往上收干净。
    expect(cShallow.jam, greaterThan(0.4),
        reason: '被过牌到 SPR 0.89 该推（推 ${pct(cShallow.jam)}）');
    expect(cMid.jam, greaterThan(0.05),
        reason: '被过牌到 SPR 1.25 不能一个都不推（推 ${pct(cMid.jam)}）');
    expect(cMid.jam, lessThan(cShallow.jam - 0.15),
        reason: 'SPR 越接近闸门推得越少'
            '（${pct(cShallow.jam)} → ${pct(cMid.jam)}）');
    expect(cDeep.jam, lessThan(0.05),
        reason: '被过牌到 SPR 2.85 不该再推（推 ${pct(cDeep.jam)}）');
    // 收掉全下尺寸 ≠ 把价值也收掉：闸门上面照样得下注，不能变成过牌。
    expect(cDeep.raise, greaterThan(0.5),
        reason: '闸门上面还得有常规价值下注（下注 ${pct(cDeep.raise)}）');
    // 怪兽牌那一档（闸门 2.5）同一条曲线。
    expect(cMonsterShallow.jam, greaterThan(0.9),
        reason: '被过牌到两对 SPR 0.89 该推（推 ${pct(cMonsterShallow.jam)}）');
    expect(cMonsterMid.jam, greaterThan(0.02),
        reason: '被过牌到两对 SPR 2.35 还要推一点（推 ${pct(cMonsterMid.jam)}）');
    expect(cMonsterMid.jam, lessThan(0.5),
        reason: '被过牌到两对 SPR 2.35 不能还是一律推'
            '（推 ${pct(cMonsterMid.jam)}）');
    expect(cMonsterDeep.jam, lessThan(0.05),
        reason: '被过牌到两对 SPR 2.85 不该再推（推 ${pct(cMonsterDeep.jam)}）');
    expect(cMonsterDeep.raise, greaterThan(0.5),
        reason: '收掉全下之后要落回常规价值下注（下注 ${pct(cMonsterDeep.raise)}）');
  });


  t('风格差异：跟注站更黏、更爱慢打，紧凶加得最凶', () {
    // 同一个牌面、同一个尺度，三种风格必须打得不一样，否则「风格」只是
    // 一个标签：以前三条/两对面对下注是三种风格一律 100% 加注，面对下注
    // 的弃牌率也几乎一样（松被动 20% vs 紧凶 19%），牌桌上最黏的那类人
    // 反而比谁都果断。
    double pct(double v) => 100 * v;

    // 三条面对 2/3 池：紧凶基本加注，跟注站一大半只是跟（慢打设陷阱）。
    final setTight = aiVsFlopBet('8h 8s', 'Ks 8c 3d', 0.66);
    final setStation = aiVsFlopBet('8h 8s', 'Ks 8c 3d', 0.66,
        style: AiStyle.loosePassive);
    // 不是「必须 100% 加注」：以前三条面对下注是三种风格一律 100% 加，
    // 「他一加就是大家伙」等于写在脸上，对手拿顶对、拿听牌都老远就弃。
    // 干面上留一档慢打，才能让对手继续开火、也才能让加注范围里有别的东西。
    expect(setTight.raise, greaterThan(0.55),
        reason: '紧凶三条以加注为主（加 ${pct(setTight.raise).round()}%），'
            '但要留一档慢打（跟 ${pct(setTight.call).round()}%）');
    expect(setStation.raise, lessThan(0.7),
        reason: '跟注站三条会先慢打（加 ${pct(setStation.raise).round()}%）');
    expect(setStation.call, greaterThan(setTight.call + 0.2),
        reason: '跟注站的慢打比例要看得出来 '
            '（跟 ${pct(setStation.call).round()}% vs '
            '${pct(setTight.call).round()}%）');

    // 但慢打不能变成「永不加注」：跟注站也得留一部分价值加注。
    expect(setStation.raise, greaterThan(0.25),
        reason: '跟注站三条仍要有加注（加 ${pct(setStation.raise).round()}%）');

    // 一对牌面对 2/3 池：跟注站比紧凶明显更少弃牌。
    final bpTight = aiVsFlopBet('4h 3h', 'Ks 7d 3c', 0.66);
    final bpStation = aiVsFlopBet('4h 3h', 'Ks 7d 3c', 0.66,
        style: AiStyle.loosePassive);
    expect(bpStation.fold, lessThan(bpTight.fold + 0.01),
        reason: '底对上跟注站不该比紧凶弃得更多 '
            '（弃 ${pct(bpStation.fold).round()}% vs '
            '${pct(bpTight.fold).round()}%）');
    expect(bpStation.call, greaterThan(bpTight.call - 0.01),
        reason: '底对上跟注站跟得更多（跟 ${pct(bpStation.call).round()}%）');

    // 封顶（胜率兑现率的上限）也要跟着风格缩：封顶写成死数的话，大注面前
    // 三种风格的门槛会被压成同一个数——探针实测底对面对翻牌一个满池，
    // 紧凶/松被动/松凶的弃牌率都是 83%，跟注站「什么都跟」这张标签在最
    // 该体现的大注局面里整个消失。封顶乘上 (1 - callSlack) 之后：紧凶弃
    // 83%、松被动弃 2%、松凶弃 49%，三种风格在大注面前重新分得开。
    final potTight = aiVsFlopBet('4h 3h', 'Ks 7d 3c', 1.0);
    final potStation = aiVsFlopBet('4h 3h', 'Ks 7d 3c', 1.0,
        style: AiStyle.loosePassive);
    expect(potTight.fold, greaterThan(0.6),
        reason: '底对面对满池，紧凶该弃（弃 ${pct(potTight.fold).round()}%）');
    expect(potStation.fold, lessThan(potTight.fold - 0.3),
        reason: '跟注站在大注面前照样黏（弃 '
            '${pct(potStation.fold).round()}% vs '
            '${pct(potTight.fold).round()}%）');

    // 再加注的线不能让风格把门槛也拉低：面对加注，第二对在三张同花面上
    // 照样得弃（那是对着价值下注付钱，不是「黏」）。
    // （见「三条同花面」那条用例。）
  });

  t('跟注站：小注面前空气也跟一张，大注面前照样收手', () {
    // 真人里最典型的一类对手是「你打不跑他」：1/3 池这种小注，他手里连
    // 后门花都没有也跟一张；同一个空气面对 2/3 池就收手。以前这一档完全
    // 不存在——纯空气按赔率永远够不上任何门槛，三种风格一律干净弃牌
    // （探针实测 1/3 池：紧凶弃 88%、松被动弃 97%，牌桌上最黏的那类人
    // 反而比谁都果断），玩家就永远练不到「对着跟注站别诈唬、拿价值牌
    // 往死里打」这件事。
    double pct(double v) => 100 * v;

    final smallTight = aiVsFlopBet('8h 7h', 'As Kd Qc', 0.33);
    final smallStation = aiVsFlopBet('8h 7h', 'As Kd Qc', 0.33,
        style: AiStyle.loosePassive);
    expect(smallStation.call, greaterThan(0.3),
        reason: '跟注站对着 1/3 池拿纯空气也跟一张'
            '（跟 ${pct(smallStation.call).round()}%）');
    expect(smallStation.call - smallTight.call, greaterThan(0.25),
        reason: '这一档只属于跟注站，紧凶照旧弃'
            '（跟 ${pct(smallStation.call).round()}% vs '
            '${pct(smallTight.call).round()}%）');

    // 分叉只在「小注」：大注面前跟注站也得收手，不然就成了无脑跟。
    final bigStation = aiVsFlopBet('8h 7h', 'As Kd Qc', 0.66,
        style: AiStyle.loosePassive);
    expect(bigStation.fold, greaterThan(0.8),
        reason: '同样是纯空气，2/3 池面前跟注站也弃'
            '（弃 ${pct(bigStation.fold).round()}%）');
  });

  t('抓诈唬：对手前面都过牌后砸出来的大注，第二对也敢接', () {
    // 同一手第二对、同一个 0.75 池的河牌下注，只差对手前面两条街有没有
    // 一直在开火：一路过牌再突然砸一枪是「突然开火」的线，诈唬占比高，
    // 我们的一对牌就是合格的抓牌。以前两种线共用同一套门槛（赔率乘
    // 1.82），第二对对着这一枪 99% 弃牌，对手随便抡一下我们就交牌。
    const board = '9d 5c 2h 8d Jd';
    final stab = aiVsRiverBet('Kc 8h', board, 0.75);
    final barrel = aiVsRiverBet('Kc 8h', board, 0.75, barrel: true);
    String pct(double v) => '${(100 * v).round()}%';

    expect(stab.total, greaterThan(_trialSeeds(50)));
    expect(stab.call, greaterThan(0.25),
        reason: '过牌-过牌-重注这条线上第二对要敢抓（跟 ${pct(stab.call)}）');
    expect(barrel.fold, greaterThan(0.85),
        reason: '连开三枪的重注还是得尊重（弃 ${pct(barrel.fold)}）');
    expect(stab.call, greaterThan(barrel.call + 0.2),
        reason: '两条线的抓牌率要分得开（${pct(stab.call)} vs '
            '${pct(barrel.call)}）');

    // 下注尺度不能被一道布尔闸门切成两段：`bigBet = betSizeRel >= 0.7`
    // 以前同时管着弱成牌档里「大注 = 真牌」的余量和「突然开火 = 两极线」
    // 的折扣，于是这条线的跟注率在闸门两侧来回跳——探针实测 0.68 池跟
    // 62%、0.70 池跟 71%、0.72 池跟 91%、0.80 池又掉回 62%：对手把注从
    // 0.68 抬到 0.72 反而更容易被跟，等于给了他一个「照着 0.72 打」的
    // 开关。真人这条曲线只有一个方向：注越大跟得越少（探针改后 0.70 /
    // 0.75 / 0.80 池 = 跟 70 / 50 / 42%）。
    const steps = [0.65, 0.7, 0.75, 0.8];
    final trend = [for (final f in steps) aiVsRiverBet('Kc 8h', board, f)];
    for (var i = 1; i < trend.length; i++) {
      expect(trend[i].call, lessThan(trend[i - 1].call + 0.07),
          reason: '注越大不能跟得越多（${100 * steps[i - 1]}% 池 '
              '${pct(trend[i - 1].call)} → ${100 * steps[i]}% 池 '
              '${pct(trend[i].call)}）');
    }
    expect(trend.last.call, lessThan(trend.first.call),
        reason: '整条曲线要往下走'
            '（${pct(trend.first.call)} → ${pct(trend.last.call)}）');
  });

  t('中等牌：顶对好踢面对连开三枪，跟注率随尺度连续下滑', () {
    // 中等牌那一档的「大注余量」以前也挂在 `bigBet = betSizeRel >= 0.7`
    // 这道布尔上：0.69 池乘 1.0、0.70 池乘 1.2。这一档的胜率本来就压在
    // 赔率线上（探针里顶对好踢对 0.6 池 eq 0.366 / 门槛 0.375），1.2 这一
    // 下会把整条跟注范围直接推下悬崖——实测连开三枪 0.65 池跟 91%、0.70
    // 池只剩 18%，中间没有任何过渡，对手把最后一枪卡在 0.7 池就能稳收底池。
    //
    // 改法是把这一项铺成跟弱成牌档一样的 sizePremium 斜坡（0.5 池以下不增
    // 不减、1.0 池爬到满档），同时把「从跟到弃」摊在一个够宽的尺度区间里
    // 做完（foldBand 0.10，理由见 AiPlayer._callMix：门槛和胜率都随尺度在
    // 动，一条 ±0.04 的窄带子会被整条穿过去）。探针改后 0.60 / 0.65 /
    // 0.70 / 0.75 / 0.80 池 = 跟 98 / 79 / 51 / 23 / 16%。
    const board = 'Kh 8d 3c 5h 9s';
    const steps = [0.6, 0.65, 0.7, 0.75, 0.8];
    final trend = [
      for (final f in steps) aiVsRiverBet('Kc Qd', board, f, barrel: true),
    ];
    String pct(double v) => '${(100 * v).round()}%';
    expect(trend.first.total, greaterThan(_trialSeeds(50)));

    expect(trend.first.call, greaterThan(0.75),
        reason: '0.6 池这个价格顶对好踢得跟（跟 ${pct(trend.first.call)}）');
    expect(trend.last.call, lessThan(0.4),
        reason: '0.8 池的三枪要收手（跟 ${pct(trend.last.call)}）');
    for (var i = 1; i < trend.length; i++) {
      // 一堵墙（改前 0.65→0.70 池掉了 73 个点）会让这一段报红。
      expect(trend[i].call, greaterThan(trend[i - 1].call - 0.35),
          reason: '从跟到弃要摊开，不能一步跳完（${100 * steps[i - 1]}% 池 '
              '${pct(trend[i - 1].call)} → ${100 * steps[i]}% 池 '
              '${pct(trend[i].call)}）');
    }
  });

  t('浅筹码：河牌连开三枪，注越大不能反过来跟得更多', () {
    // 弱成牌那一档原来是 `spr <= 1.0 就无脑跟` 的硬闸门，中等牌那一档是
    // `spr <= 1.2 而且注小于 1.15 池就无脑跟`。注越大 spr 越小，所以这两道
    // 门都是「越贵越敢跟」的来源——方向跟真人正好相反，而且是一条硬台阶。
    //
    // 这一条把翻前底池造大（preflopRaiseTo，复现「翻前造池 → 河牌超池把
    // spr 压到极低」那种牌局），再把 1.0~2.5 池铺满，两档各钉一头：
    //   * 弱成牌（第二对 87，preflopRaiseTo 300）：spr 在 1.5→2.0 池之间
    //     掉进闸门，改前跟注率一步从 2% 跳到 100%——对手把最后一枪加到
    //     2 倍池，我们反而把一对牌全送出去。
    //   * 中等牌（顶对好踢 KQ，preflopRaiseTo 500）：改前 1.0 池跟 100%、
    //     1.5 池只剩 11%，中间 89 个点的台阶，台阶的位置正是 `注 < 1.15 池`
    //     那道墙。
    // 改法是两档都换成「按**下注前**的 spr 连续打折」，见 AiPlayer 里的
    // committed / committedMedium（用下注前的 spr 是为了让折扣不跟着这一注
    // 一起涨，否则会把价格项抵消掉）。
    const board = 'Kh 8d 3c 5h 9s';
    const steps = [1.0, 1.5, 2.0, 2.5];
    String pct(double v) => '${(100 * v).round()}%';

    final weak = [
      for (final f in steps)
        aiVsRiverBet('8h 7s', board, f, barrel: true, preflopRaiseTo: 300),
    ];
    final medium = [
      for (final f in steps)
        aiVsRiverBet('Kc Qd', board, f, barrel: true, preflopRaiseTo: 500),
    ];
    expect(weak.first.total, greaterThan(_trialSeeds(50)));
    expect(medium.first.total, greaterThan(_trialSeeds(50)));

    for (var i = 1; i < steps.length; i++) {
      expect(weak[i].call, lessThan(weak[i - 1].call + 0.07),
          reason: '第二对：浅筹码下注越大也不能跟得越多（${100 * steps[i - 1]}% 池 '
              '${pct(weak[i - 1].call)} → ${100 * steps[i]}% 池 ${pct(weak[i].call)}）');
      expect(medium[i].call, greaterThan(medium[i - 1].call - 0.45),
          reason: '顶对好踢：从跟到弃要摊开，不能是一堵墙（${100 * steps[i - 1]}% 池 '
              '${pct(medium[i - 1].call)} → ${100 * steps[i]}% 池 ${pct(medium[i].call)}）');
    }
  });

  t('中等牌河牌：两极线的超池要接着收，1.2 倍池往后不能是一条水平线', () {
    // 范围模型里读下注尺度的那一项在 1.2 倍池就饱和了（两个乘子都不再动），
    // 于是「过牌-过牌-超池」这条线在 1.25~2.5 倍池被读成同一条：探针
    // （ai_probe「河牌中等牌」那节）里模型胜率逐点都是 0.499，顶对好踢的
    // 跟注率 1.25 倍池 100%、1.5 倍池 97%、2.0 倍池 92%、2.5 倍池 91%——
    // 对手把最后一枪从 1.25 倍池抬到 2.5 倍池，能拿到的弃牌率几乎没变，
    // 尺度这一维在超池段整个失效（拿顶对去接 2.5 倍池本来就是这个游戏里
    // 最典型的送钱方式）。
    //
    // 真人不会这么读：1.5 倍池往上，「他敢下这么大」本身就是最强的信息，
    // 两极线里的空气也掉得比前一段快。修法是把这一档给两极线的折扣做成
    // 「驼峰」（见 [AiPlayer._facingBet] 里的 overbetCliff）：折扣照旧在
    // 1.0~2.5 池之间给出去，再从 1.4 倍池起按超池段加倍收回来。改后探针
    // 里这条线是 100/93/55/29%（1.25/1.5/2.0/2.5 池），最后一档正好落在
    // MDF 上。这条用例盯的是超池段**接着单调收**，不能是一条水平线。
    const board = 'Kh 8d 3c 5h 9s';
    const steps = [1.25, 1.5, 2.0, 2.5];
    String pct(double v) => '${(100 * v).round()}%';
    final trend = [
      for (final f in steps) aiVsRiverBet('Kc Qd', board, f),
    ];
    expect(trend.first.total, greaterThan(_trialSeeds(50)));
    expect(trend.last.total, greaterThan(_trialSeeds(50)));
    // 改之前这条必红：1.25 池 100% → 2.5 池 91%，只掉 9 个点。
    expect(trend.last.call, lessThan(trend.first.call - 0.3),
        reason: '2.5 倍池的跟注率要比 1.25 倍池低三成以上（'
            '${pct(trend.first.call)} → ${pct(trend.last.call)}）');
    for (var i = 1; i < trend.length; i++) {
      expect(trend[i].call, lessThan(trend[i - 1].call + 0.12),
          reason: '超池段要接着收，不能反过来涨（${100 * steps[i - 1]}% 池 '
              '${pct(trend[i - 1].call)} → ${100 * steps[i]}% 池 '
              '${pct(trend[i].call)}）');
    }
  });

  t('中等牌河牌：连开三枪的超池也要接着收，1 倍池往后不能是一条水平线', () {
    // 上一条钉的是「过牌-过牌-超池」那条两极线，这一条钉连开三枪那条线——
    // 同一手牌、同一张牌面、同一个尺寸区间，两条线的超池段是两套逻辑，
    // 而连开三枪这一侧原来漏了。
    //
    // 漏在哪儿：[AiPlayer] 的 `riverDefendFloor`（河牌不许把成牌接近 100%
    // 扔掉的那条混合跟注下限）里，那一串「MDF 斜率 + 0.03 地板 + 中等牌
    // 再加 0.10」在 0.73 倍池就被地板夹住了，于是中等牌这一档从 0.95 倍池
    // 一直到 2.5 倍池，下限是一个常数。按 0.02 池铺满扫一遍（顶对好踢、
    // 连开三枪）：0.94 倍池弃 86%、1.00 倍池 86%、1.50 倍池 86%、2.50 倍池
    // 还是 86%，中间一个点都不动。对手拿任意两张牌在河牌抡超池，能拿到的
    // 弃牌率跟下 0.95 倍池完全一样（他保本只要 71%），尺度这一维在超池段
    // 整个失效——跟上面那两条用例要修的毛病是同一个。
    //
    // 修法是给**非**两极线加一条超池斜坡（见 `overbetFloorFade`）：1.0 倍池
    // 以内逐点不变（所以「3/4 池照旧收手」「1/2 池按 MDF 守住」那几条不受
    // 影响），往上线性把下限收到原来的两成八。这条用例盯的就是 1.0 倍池往
    // 上要接着单调收：改之前下面那条必红（四个点全是跟 12%），改之后是
    // 跟 12/9/5/3%（探针 ai_probe「河牌中等牌（顶对好踢）」那一节的
    // 1.25/1.5/2.0/2.5 倍池 = 跟 10/8/6/4%）。
    const board = 'Kh 8d 3c 5h 9s';
    const steps = [1.0, 1.5, 2.0, 2.5];
    String pct(double v) => '${(100 * v).round()}%';
    final trend = [
      for (final f in steps)
        aiVsRiverBet('Kc Qd', board, f, barrel: true, seeds: 400),
    ];
    expect(trend.first.total, greaterThan(_trialSeeds(100)));
    expect(trend.last.total, greaterThan(_trialSeeds(100)));
    // 改之前这条必红：1.0 倍池弃 88% → 2.5 倍池还是 88%，一个点不掉。
    expect(trend.last.fold, greaterThan(trend.first.fold + 0.05),
        reason: '连开三枪的 2.5 倍池要比 1 倍池弃得多（'
            '${pct(trend.first.fold)} → ${pct(trend.last.fold)}）');
    for (var i = 1; i < trend.length; i++) {
      expect(trend[i].fold, greaterThan(trend[i - 1].fold - 0.02),
          reason: '超池段要接着收，不能反过来涨（${100 * steps[i - 1]}% 池 '
              '${pct(trend[i - 1].fold)} → ${100 * steps[i]}% 池 '
              '${pct(trend[i].fold)}）');
    }
  });

  t('听牌隐含赔率：筹码从 1.5 倍池涨到 1.8 倍池，跟注率不能一步跳', () {
    // 听牌的隐含赔率补贴以前挂在一条布尔门槛上（`me.stack > pot * 1.5`）：
    // 同一个坚果花听、同一注 2/3 池，筹码从 1.35 倍池挪到 1.5 倍池，那几个
    // 点的补贴就从无到有，弃牌率一步掉一整档（探针实测 1.5 倍池弃 11%、
    // 1.6 倍池直接弃 0%）。对手只要把筹码摆到那个数上就能读出来。
    //
    // 现在是 1.2~1.8 倍池之间的线性斜坡：补贴在窗口里就一点点长出来，
    // 深筹码那端（≥1.8 倍池）锚点跟以前逐点一致。前身那版布尔已经删掉，
    // 这条用例就是钉住它别再退回去。
    //
    // 场景要 AI 在翻牌先过牌，把「听牌面对转牌第二枪」单独隔出来（AI 自己
    // 先开一枪的话底池被撑大，筹码/底池比整条落到斜坡以下，什么都量不到）。
    // 翻前 AI 开 300、英雄跟，翻牌双方过牌 → 转牌底池 600、英雄下 2/3 池
    // 400，所以筹码/底池比 =（筹码 − 300）/1000，下表的筹码正好落在
    // 1.2 / 1.35 / 1.5 / 2.1 倍池这几个锚点上。
    final stacks = [1500, 1650, 1800, 2400];
    final rs = stacks
        .map((st) => aiVsTurnBet('Ad Kd', 'Qd 7d 2c 5h', 0.66,
            preflopRaiseTo: 300, stack: st, aiCheckFlop: true))
        .toList();
    for (final r in rs) {
      expect(r.n, greaterThan(100), reason: '样本太少，比例不可信');
    }
    // 单调：筹码越深补贴越多，跟注率只升不降（留 2pt 抽样噪声）。
    for (var i = 1; i < rs.length; i++) {
      expect(rs[i].call, greaterThanOrEqualTo(rs[i - 1].call - 0.02),
          reason: '筹码 ${stacks[i]} vs ${stacks[i - 1]} 跟注率反而掉了');
    }
    // 补贴在 1.2~1.8 倍池的窗口里就开始了：1.35 倍池那点弃牌率必须已经
    // 明显低于 1.2 倍池那端。布尔门槛那版这两点是同一个值（都还没到 1.5
    // 倍池，补贴都是 0），会在这里报红——这条断言就是那个悬崖的守门人。
    expect(rs[1].fold, lessThan(rs[0].fold - 0.03),
        reason: '1.35 倍池还没开始长补贴——又退回布尔门槛了？');
    // 没有悬崖：相邻两点之间跟注率跳变不超过 8pt。
    for (var i = 1; i < rs.length; i++) {
      expect(rs[i].call - rs[i - 1].call, lessThan(0.08),
          reason: '筹码 ${stacks[i - 1]} → ${stacks[i]} 之间出现台阶');
    }
    // 深筹码那端（2.1 倍池，斜坡已跑满）仍然跟以前一样：不弃。
    expect(rs.last.fold, lessThanOrEqualTo(0.03));
  });

  t('河牌防守：连开三枪的 1/2 池也要按 MDF 守住，3/4 池照旧收手', () {
    // 上一条量的是「对手前面全过牌、河牌突然砸一枪」那条线（诈唬占比高，
    // 第二对要敢接）。这一条是它的反面：对手**连开三枪**，第二对面对
    // 3/4 池必须收手（弃 85% 以上），但同样这条线、同样这手牌，面对
    // 1/2 池不能整档交出去。
    //
    // 河牌防守的下限以前是 [AiPlayer] 里一条拍脑袋的直线 `1.02 - 1.2b`：
    // 1/2 池给出 0.42（也就是允许弃 58%）。可对手下 b 倍池，他的诈唬保本
    // 弃牌率是 b/(1+b) = 33%——我们至少得跟 67% 才不让他拿任意两张白赚。
    // 探针实测（tool/ai_river_defense_probe.dart，湿润面）改之前河牌面对
    // 1/2 池整体弃 59%、保本线 33%，标着「★可被任意两张白抢 +25pt」；
    // 下限改成按 MDF 的斜率给之后，同一格弃 28%（另外两块牌面
    // 24%→14%、65%→30%）。
    //
    // 但 MDF 只对**小注**是硬指标：注越大，对手那条线里的价值牌越多，
    // 到了 3/4 池还照 MDF 防就是拿一对去接重注。所以下限在 1/2 池往上
    // 按一条直线收回去，3/4 池回到 0.03，跟以前接上——下面这两个断言
    // 量的就是这条分界。
    String pct(double v) => '${(100 * v).round()}%';
    const board = '9d 5c 2h 8d Jd';
    final half = aiVsRiverBet('Kc 8h', board, 0.5, barrel: true);
    final threeQuarter = aiVsRiverBet('Kc 8h', board, 0.75, barrel: true);
    expect(half.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(threeQuarter.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    // 改之前这条必红：1/2 池弃 60%。
    expect(half.fold, lessThan(0.5),
        reason: '连开三枪的 1/2 池也要按 MDF 守住（弃 ${pct(half.fold)}）');
    expect(threeQuarter.fold, greaterThan(0.85),
        reason: '连开三枪的 3/4 池照旧收手（弃 ${pct(threeQuarter.fold)}）');
    expect(threeQuarter.fold, greaterThan(half.fold),
        reason: '注越大还是弃得越多（1/2 池弃 ${pct(half.fold)}、'
            '3/4 池弃 ${pct(threeQuarter.fold)}）');
  });

  t('河牌防守：对手读成疯子之后，2/3 池的第三枪不能照旧交出去', () {
    // 上面那几条量的都是「对手只开过这一次火」的 AI——每个种子换一个新
    // AiPlayer，读牌档案是空的、进攻率停在样本不足的中性 0.33。可真桌不是
    // 这么打的：TableController 里每个座位只在开局建一次 AI，对手的进攻率
    // 是**跨手累积**的。连开三枪开了几手的对手，进攻率会顶到 1.0，AI 该把
    // 他读成「逮到机会就往里砸」的那种，然后河牌也得跟宽一点。
    //
    // 探针（tool/ai_river_defense_probe.dart）现在也按真桌来：同一个 AI
    // 连着打完整格。读完牌量出来的是——翻牌/转牌的跟注量翻倍（每格 47 →
    // 100 手），可河牌面对 2/3 池照旧弃 75%、满池弃 89%，按每 6000 手算的
    // **绝对**弃牌数比读牌生效前还多一倍。也就是说读牌只放宽了前两条街：
    // 我们付了三条街的价钱去摊一次牌，最后那一下照旧交出去。
    //
    // 根因有两处，「注越大，他这条线里的价值牌越多」在两处都被当成了硬道理，
    // 可它只是**一个正常对手**的性质，真疯子的重注里一样大半是空气：
    //   * [AiPlayer] 里 `floorShape` 那条 2.3 的斜率（整档的防守份额）；
    //   * `_rangeFilter` 里的 `lineAgg` → `airKeep`（胜率估计用的对手范围）。
    // 第二处不改的话，跟注门槛那边放宽了、范围模型却还是「三枪 = 硬货」，
    // 算出来的胜率照旧很难看——AI 变成「翻牌跟得宽、河牌算出来自己还是
    // 垃圾」。现在两处都跟着同一条 0.45 疯子线的连续量（`_maniacWiden`）
    // 回调，顶格时各收掉七成。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh Jh 4c 9h 2d';
    final ai = AiPlayer(AiStyle.tightAggressive, random: Random(7));
    // 先用同一个 AI 打 60 手把读牌养起来，再接着量 400 手。
    aiVsRiverBet('9c 8h', board, 0.66, barrel: true, seeds: 60,
        persistentAi: ai);
    final warm = aiVsRiverBet('9c 8h', board, 0.66, barrel: true, seeds: 400,
        persistentAi: ai);
    expect(warm.total, greaterThan(20), reason: '样本要够（${warm.total}）');
    // 改之前这条必红：弃 78%（只改下限那一半也是 53%）。
    expect(warm.fold, lessThan(0.35),
        reason: '读成疯子之后 2/3 池的第三枪不能照旧交出去（弃 ${pct(warm.fold)}）');

  });

  t('河牌防守：读牌生效之后，整条范围在第三枪上的弃牌率要明显下降', () {
    // 上一条钉的是「钉死一手牌 + 钉住前两条街」的河牌决策；这一条钉**范围
    // 构造**那一半——读牌对范围模型的影响先落在「这条街要不要继续」上，
    // 钉住前两条街就把它整个盖住了（实测同一手牌、同一个尺度，放开前后
    // 一模一样）。
    //
    // 量的东西就是探针（tool/ai_river_defense_probe.dart）那一栏：对手拿任何
    // 两张一路开三枪，AI 在河牌面对第三枪弃掉多少。冷启动（每手一个新 AI，
    // 读牌档案永远是空的）时那格是弃 75%；真桌视角（同一个 AI 连着打，
    // 对手的进攻率几手之内顶到 1.0）现在只剩三成出头。
    //
    // 冷热对比而不是绝对值：探针里那个「★可被任意两张白抢」按的是「比保本
    // 线高多少」，而保本线算的是「对手完全不收范围」这种极限；这里钉的是
    // 更硬的一条——读牌之后必须**明显**比不读牌时敢接，方向反了就是读人
    // 那一整条线又断了。
    String pct(double v) => '${(100 * v).round()}%';
    final cold = aiRiverDefenseRange('Qh Jh 4c 9h 2d', 0.66);
    final warm = aiRiverDefenseRange('Qh Jh 4c 9h 2d', 0.66,
        persistentAi: AiPlayer(AiStyle.tightAggressive, random: Random(7)));
    expect(cold.total, greaterThan(10), reason: '冷启动样本要够（${cold.total}）');
    expect(warm.total, greaterThan(10), reason: '读牌样本要够（${warm.total}）');
    expect(warm.fold, lessThan(cold.fold - 0.15),
        reason: '读成疯子之后第三枪要敢接（冷 ${pct(cold.fold)} → '
            '热 ${pct(warm.fold)}）');
  });

  t('下注尺度：干面用小注、湿面加大、多人底池抬价', () {

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
    expect(dry.n, greaterThan(_trialSeeds(40)));
    expect(wet.frac, greaterThan(dry.frac + 0.1),
        reason: '干面用范围小注、湿面加大保护 '
            '(${dry.frac.toStringAsFixed(2)} vs '
            '${wet.frac.toStringAsFixed(2)} 池)');
    expect(multi.frac, greaterThan(dry.frac + 0.05),
        reason: '多人底池总有人会跟，价值下注更大 '
            '(${multi.frac.toStringAsFixed(2)} vs '
            '${dry.frac.toStringAsFixed(2)} 池)');

    // 尺度混合：同一个牌面、同一手牌，尺寸要换档，不能永远是同一个数。
    //
    // 这条断言以前只要求「不同尺寸的数量 ≥ 3」。第一版换档是 ×0.85 / ×1.0 /
    // ×1.18，三档确实凑得出三个不同的数，可三档全挤在 0.33~0.45 池之间，落进
    // 探针的尺度桶（5% 一档）里只有一个峰——对手打两圈就能把我们「永远三分之
    // 一池」记下来。所以这里量的不是「有几个不同的数」，而是「分布有多宽」：
    // 至少铺满 5 档、两头都要有量、任何一档都不能占掉一半。
    final buckets = <int, int>{};
    for (final x in dry.all) {
      buckets[(x * 20).round()] = (buckets[(x * 20).round()] ?? 0) + 1;
    }
    final keys = buckets.keys.toList()..sort();
    expect(keys.length, greaterThanOrEqualTo(5),
        reason: '尺度要铺满至少 5 档（实测 '
            '${keys.map((k) => '${5 * k}%').join('/')}）');
    expect(keys.first * 5, lessThanOrEqualTo(30),
        reason: '要有真正的小注（最小一档 ${keys.first * 5}% 池）');
    expect(keys.last * 5, greaterThanOrEqualTo(55),
        reason: '要有真正的大注（最大一档 ${keys.last * 5}% 池）');
    final small = (buckets[keys.first] ?? 0) + (buckets[keys[1]] ?? 0);
    final big = (buckets[keys.last] ?? 0) + (buckets[keys[keys.length - 2]] ?? 0);
    expect(small / dry.n, greaterThan(0.15),
        reason: '小注那一端要有量（占 ${(100 * small / dry.n).round()}%）');
    expect(big / dry.n, greaterThan(0.15),
        reason: '大注那一端要有量（占 ${(100 * big / dry.n).round()}%）');
    final top = buckets.values.reduce(max);
    expect(top / dry.n, lessThan(0.45),
        reason: '不能什么都挤在同一个尺寸上（最大一档占 '
            '${(100 * top / dry.n).round()}%）');
    // 干面基准 = 0.62（价值）× 0.62（范围小注）= 0.384，混合不该改变均值。
    expect((dry.frac - 0.384).abs(), lessThan(0.04),
        reason: '混合只打散尺寸，平均尺度基本不动 '
            '(${dry.frac.toStringAsFixed(3)} 池)');
  });

  t('第二枪选牌：转牌发空白牌继续开火，发 A 就收手', () {
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
    // 光有先后顺序不够：以前两档是 33% / 12%，顺序也对，但那是「被跟一次
    // 就基本放弃」——对手跟一张翻牌就能白捡后面两条街。真人的第二枪在
    // 空白牌上接近一半，出高张也留两成出头。
    expect(blank, greaterThan(0.35),
        reason: '空白牌的第二枪不能低到三成（${(100 * blank).round()}%）');
    expect(ace, greaterThan(0.15),
        reason: '发 A 也得留一部分第二枪（${(100 * ace).round()}%）');
  });

  t('诈唬选牌：握着坚果花阻断牌时，河牌更敢开火', () {
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

  t('第三枪：对手跟了两条街之后，破听牌也要收手（价值下注不动）', () {
    // 「翻牌开一枪被跟 → 转牌再开一枪被跟 → 河牌还开不开」是真人最容易被
    // 读穿的一步：被跟的每一条街都在把对手的范围往「真有牌」那边筛，第三
    // 枪的弃牌率跟前两枪完全不是一个量级。以前 AI 没有「他跟了我几条街」
    // 这个变量，河牌的开火频率只跟自己的牌力和牌面有关——探针实测破坚果
    // 花听在河牌开火 65%、纯空气 37%，而这两条线面对的对手范围差着一整个
    // 数量级；等于对手只要跟两张牌，我们就在河牌白送一个底池。
    //
    // 这里把 AI 前两条街的动作写成脚本（翻牌必开一枪、英雄必跟；转牌
    // 「接着开」或「过牌」两档），只让它在河牌做决策：同一个局面、同一手
    // 牌，只差「英雄跟了几次」这一个变量。
    ({double fire, int n}) river(String hole, {required bool barrelTurn}) {
      var fire = 0, n = 0;
      for (var seed = 0; seed < 300; seed++) {
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
          holeOverride: {'ai': _cs(hole), 'hero': _cs('4c 3d')},
          boardOverride: _cs('Kh 7h 2c 9s 3d'),
        );
        g.apply('ai', ActionType.raise, amount: 300);
        g.apply('hero', ActionType.call);
        // 翻后英雄（大盲）先动：过牌 → AI 开一枪 → 英雄跟。
        g.apply('hero', ActionType.check);
        g.apply('ai', ActionType.bet, amount: 500);
        g.apply('hero', ActionType.call);
        g.apply('hero', ActionType.check);
        if (barrelTurn) {
          g.apply('ai', ActionType.bet, amount: 1300);
          g.apply('hero', ActionType.call);
        } else {
          g.apply('ai', ActionType.check);
        }
        if (g.street != Street.river || g.handOver) continue;
        g.apply('hero', ActionType.check);
        n++;
        final p = g.pendingAction();
        if (ai.decide(g, p.player).type == ActionType.bet) fire++;
      }
      return (fire: n == 0 ? 0 : fire / n, n: n);
    }

    String pct(double v) => '${(100 * v).round()}%';
    // 破坚果花听（挡掉 A 花）和纯空气：两张都在河牌是「什么都没有」。
    final nutThird = river('Ah Jh', barrelTurn: true);
    final nutSecond = river('Ah Jh', barrelTurn: false);
    final airThird = river('Qc 6d', barrelTurn: true);
    final airSecond = river('Qc 6d', barrelTurn: false);
    // 顶对是价值牌，跟这张折扣毫无关系，两条线必须一模一样。
    final valueThird = river('Kc Qd', barrelTurn: true);
    final valueSecond = river('Kc Qd', barrelTurn: false);

    expect(nutThird.n, greaterThan(200), reason: '样本要够');
    expect(nutThird.fire, lessThan(nutSecond.fire - 0.03),
        reason: '被跟两条街之后要收手（被跟两条街 ${pct(nutThird.fire)} '
            'vs 被跟一条街 ${pct(nutSecond.fire)}）');
    expect(airThird.fire, lessThan(airSecond.fire - 0.03),
        reason: '纯空气收得更多（被跟两条街 ${pct(airThird.fire)} '
            'vs 被跟一条街 ${pct(airSecond.fire)}）');
    expect(airThird.fire, lessThan(0.25),
        reason: '被跟两条街之后，什么都没挡到的牌不该还开两成以上 '
            '（${pct(airThird.fire)}）');
    expect(airThird.fire, greaterThan(0.05),
        reason: '但也不能一被跟就整条线扔了（${pct(airThird.fire)}）');
    // 选牌的那一半：同样是「什么都没有」，挡掉对手跟注范围的那张 A 要
    // 明显多开火——第三枪的唯一理由就是「我挡掉了你能跟的牌」。
    expect(nutThird.fire, greaterThan(airThird.fire + 0.03),
        reason: '第三枪要挑阻断牌打（破坚果花听 ${pct(nutThird.fire)} '
            'vs 纯空气 ${pct(airThird.fire)}）');
    // 价值下注不该被这条折扣碰到。
    expect(valueThird.fire, greaterThan(0.5),
        reason: '顶对在河牌该照常收价值（${pct(valueThird.fire)}）');
    expect((valueThird.fire - valueSecond.fire).abs(), lessThan(0.06),
        reason: '顶对的价值下注不受「被跟了几条街」影响'
            '（${pct(valueThird.fire)} vs ${pct(valueSecond.fire)}）');
  });

  t('河牌薄价值：对手跟过几条街，中对/底对要跟着收（顶对价值不动）', () {
    // 「他一路跟过来」是河牌上最强的一条信息。诈唬那一侧早就在按
    // villainCalls 收（见上一条），薄价值这一侧却完全不读它：固定牌面
    // （Qd 7d 2c 5h 9s、翻前我开池、翻牌/转牌我开不开枪由脚本钉死，只差英雄
    // 跟了几次我们的下注）实测中对 88 的河牌下注率是「没跟过 28% / 跟一条街
    // 28% / 跟两条街 28%」逐点相同——真人在那儿基本就是过牌：中对、底对打
    // 出去，更好的牌跟、更差的牌弃，等于白送一个底池。翻牌街 villainCalls
    // 恒为 0，所以这条折扣实际只在转牌和河牌上动。
    //
    // 顶对是价值牌，这条折扣不该碰它（见上一条「价值下注不动」那几行）。
    ({double fire, int n}) river(String hole, {required int calls}) {
      var fire = 0, n = 0;
      for (var seed = 0; seed < 400; seed++) {
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
          holeOverride: {'ai': _cs(hole), 'hero': _cs('4c 3d')},
          boardOverride: _cs('Qd 7d 2c 5h 9s'),
        );
        g.apply('ai', ActionType.raise, amount: 300);
        g.apply('hero', ActionType.call);
        for (final street in [Street.flop, Street.turn]) {
          if (g.street != street || g.handOver) break;
          g.apply('hero', ActionType.check);
          final callHere = street == Street.flop ? calls >= 1 : calls >= 2;
          if (callHere) {
            g.apply('ai', ActionType.bet,
                amount: g.pendingAction().player.streetBet +
                    (g.potTotal() * 0.66).round());
            g.apply('hero', ActionType.call);
          } else {
            g.apply('ai', ActionType.check);
          }
        }
        if (g.street != Street.river || g.handOver) continue;
        g.apply('hero', ActionType.check);
        n++;
        final p = g.pendingAction();
        if (ai.decide(g, p.player).type == ActionType.bet) fire++;
      }
      return (fire: n == 0 ? 0 : fire / n, n: n);
    }

    String pct(double v) => '${(100 * v).round()}%';
    final midNone = river('8d 8s', calls: 0);
    final midOne = river('8d 8s', calls: 1);
    final midTwo = river('8d 8s', calls: 2);
    final bottomNone = river('6c 5c', calls: 0);
    final bottomTwo = river('6c 5c', calls: 2);
    final topNone = river('Qh Jc', calls: 0);
    final topTwo = river('Qh Jc', calls: 2);

    expect(midTwo.n, greaterThan(300), reason: '样本要够');
    // 中对：每多被跟一条街都要收一档，而且两条街之间也是连续的一档。
    expect(midOne.fire, lessThan(midNone.fire - 0.03),
        reason: '被跟一条街之后中对要收（没跟过 ${pct(midNone.fire)} '
            'vs 跟一条街 ${pct(midOne.fire)}）');
    expect(midTwo.fire, lessThan(midOne.fire - 0.03),
        reason: '被跟两条街之后还要再收（跟一条街 ${pct(midOne.fire)} '
            'vs 跟两条街 ${pct(midTwo.fire)}）');
    expect(midTwo.fire, lessThan(0.18),
        reason: '被跟两条街之后，中对不该还开两成以上（${pct(midTwo.fire)}）');
    expect(midTwo.fire, greaterThan(0.03),
        reason: '但也不能一被跟就整条线扔了（${pct(midTwo.fire)}）');
    expect(bottomTwo.fire, lessThan(bottomNone.fire - 0.06),
        reason: '底对同理（没跟过 ${pct(bottomNone.fire)} '
            'vs 跟两条街 ${pct(bottomTwo.fire)}）');
    // 顶对的价值下注不该被这条折扣碰到。
    expect(topNone.fire, greaterThan(0.5),
        reason: '顶对在河牌该照常收价值（${pct(topNone.fire)}）');
    expect((topTwo.fire - topNone.fire).abs(), lessThan(0.05),
        reason: '顶对的价值下注不受「被跟了几条街」影响'
            '（${pct(topTwo.fire)} vs ${pct(topNone.fire)}）');
  });

  t('第二枪：翻牌被跟过之后，听牌开火要和成牌拉开（对手的线要算进去）', () {
    // 上面那条讲的是河牌第三枪。第二枪有同一个毛病，而且更贵：花色听牌
    // 在转牌的开火率只由自己的 outs / 位置 / 人数决定，「翻牌这一枪有没有
    // 被跟」完全不进公式——听牌是下注侧唯一一条不看对手牌线的路。
    //
    // 探针实测（破坚果花听 Ah Jh on Kh7h2c9s3d，英雄一路过牌/跟注）：
    // 翻牌开火 87%、转牌 80%，而同一个探针里顶对（Kc Qd）的转牌价值下注
    // 也是 80%——「有 9 个 outs」和「有成牌」在转牌开火率上齐平了，四张
    // outs 的卡顺只有 27%、纯空气 23%。真人在这儿会收：翻牌 c-bet 被跟，
    // 转牌再开一枪被加注就得弃，outs 的价钱也比翻牌那一枪差。
    //
    // 同一个局面、同一手牌、同一个探针，只差「翻牌这一枪有没有被跟」：
    ({double fire, int n}) turn(String hole, {required bool called}) {
      var fire = 0, n = 0;
      for (var seed = 0; seed < 400; seed++) {
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
          holeOverride: {'ai': _cs(hole), 'hero': _cs('4c 3d')},
          boardOverride: _cs('Kh 7h 2c 9s 3d'),
        );
        g.apply('ai', ActionType.raise, amount: 300);
        g.apply('hero', ActionType.call);
        // 翻牌这一枪写成脚本（开或不开），不交给 AI——两条线只能差
        // 「他跟没跟过」这一件事，不然量出来的就不是这条折扣。
        g.apply('hero', ActionType.check);
        if (called) {
          g.apply('ai', ActionType.bet, amount: 500);
          g.apply('hero', ActionType.call);
        } else {
          g.apply('ai', ActionType.check);
        }
        if (g.street != Street.turn || g.handOver) continue;
        g.apply('hero', ActionType.check);
        n++;
        final p = g.pendingAction();
        if (ai.decide(g, p.player).type == ActionType.bet) fire++;
      }
      return (fire: n == 0 ? 0 : fire / n, n: n);
    }

    String pct(double v) => '${(100 * v).round()}%';
    final called = turn('Ah Jh', called: true);
    final checked = turn('Ah Jh', called: false);
    final valueCalled = turn('Kc Qd', called: true);
    final valueChecked = turn('Kc Qd', called: false);

    expect(called.n, greaterThan(300), reason: '样本要够');
    expect(checked.n, greaterThan(300), reason: '样本要够');
    // 核心：翻牌被跟过之后，转牌的第二枪要明显收手。
    expect(called.fire, lessThan(checked.fire - 0.08),
        reason: '翻牌被跟过之后听牌要收手（被跟 ${pct(called.fire)} '
            'vs 没被跟 ${pct(checked.fire)}）');
    // 但不能一被跟就整条线扔了：听牌还是得比纯空气敢打。
    expect(called.fire, greaterThan(0.4),
        reason: '听牌的第二枪还得开出去（${pct(called.fire)}）');
    // 收手之后要真的拉开：成牌的价值下注得高于听牌。
    expect(valueCalled.fire, greaterThan(called.fire),
        reason: '转牌成牌的价值下注要高于听牌（成牌 ${pct(valueCalled.fire)} '
            'vs 听牌 ${pct(called.fire)}）');
    // 价值下注不该被这条折扣碰到。
    expect((valueCalled.fire - valueChecked.fire).abs(), lessThan(0.08),
        reason: '成牌不受「被跟过」影响（${pct(valueCalled.fire)} '
            'vs ${pct(valueChecked.fire)}）');
  });

  t('河牌怪兽牌：会用超池收价值，但面对「一压就跑」的对手不超池', () {
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

  t('短筹码：按推/弃来打，不做「开小注再弃给 3bet」', () {
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

  t('翻前尺度：按钮位开池会换档，平均尺度不变', () {
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

  /// 6 人桌：p3 弃 → p4 开 300 → p5 3bet [threeBet] → 轮到按钮位 p0（AI）。
  ///
  /// 默认 900（3 倍，正常 3bet）；[threeBet] 给 470 就是「最小加注」那条线。
  ({int raise, int call, int fold}) aiFacingThreeBet(String hole,
      {int seeds = 200,
      AiStyle style = AiStyle.tightAggressive,
      int stack = 10000,
      int threeBet = 900}) {
    var raise = 0, call = 0, fold = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: GameConfig(
            startingStack: stack, smallBlind: 50, bigBlind: 100),
        random: rnd,
      );
      for (var i = 0; i < 6; i++) {
        g.addPlayer('p$i', 'P$i');
      }
      g.startHand(holeOverride: {'p0': _cs(hole)});
      g.apply('p3', ActionType.fold);
      g.apply('p4', ActionType.raise, amount: 300);
      g.apply('p5', ActionType.raise, amount: threeBet);
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

  t('翻前防守 3bet：投机牌混着跟，弱 A 同花改成轻 4bet', () {
    PreflopHand h(String s) => PreflopHand.of(_cs(s));
    final flat = PreflopRanges.callThreeBet;

    // 范围表：同花大牌必须在里面。范围表的「大牌」分支是短路的——同花大牌
    // 只查 suitedBroadway，查不到就直接判「不在范围内」，不会掉到下面的
    // 同花连张档。以前这里漏了 suitedBroadway，KQs 面对 3bet 被当成垃圾
    // 弃掉，87s 反而一路跟，跟注范围长成「有 A 的同花 + 小连张」。
    expect(flat.contains(h('Kh Qh')), isTrue, reason: 'KQs 跟 3bet 是标准打法');
    expect(flat.contains(h('Kc Jc')), isTrue, reason: 'KJs 同花大牌');
    expect(flat.contains(h('Ad 5d')), isFalse, reason: 'A5s 不是老实跟注的牌');

    // 同花连张只留最上面两张；76s/87s 在 3bet 底池里实现不了胜率。
    expect(flat.contains(h('10h 9h')), isTrue);
    expect(flat.contains(h('9h 8h')), isTrue);
    expect(flat.contains(h('8h 7h')), isFalse, reason: '87s 不在跟注范围里');
    expect(flat.contains(h('7h 6h')), isFalse, reason: '76s 不在跟注范围里');

    // 买三条（22~88）是单独一档：摘掉它不该顺手把 99+ 和大牌也摘掉。
    final noSetMine = flat.withoutSmallPairs();
    expect(flat.contains(h('5h 5d')), isTrue);
    expect(noSetMine.contains(h('5h 5d')), isFalse, reason: '摘掉买三条');
    expect(noSetMine.contains(h('9h 9d')), isTrue, reason: '99+ 不受影响');
    expect(noSetMine.contains(h('Kh Qh')), isTrue, reason: '大牌不受影响');

    // A5s/A2s 面对 3bet 用来轻 4bet（挡住 AA/AK），不是弃牌。
    expect(PreflopRanges.isLightFourBetHand(h('Ad 5d')), isTrue);
    expect(PreflopRanges.isLightFourBetHand(h('Ad 2d')), isTrue);
    expect(PreflopRanges.isLightFourBetHand(h('Ad 9d')), isFalse,
        reason: 'A9s 有摊牌价值，不该拿来 4bet 诈唬');

    // 实测（100bb 紧凶，200 次）。
    final s76 = aiFacingThreeBet('7h 6h');
    expect(s76.fold / 200, greaterThan(0.85),
        reason: '76s 面对 3bet 该弃（弃 ${s76.fold}/200）');
    final s87 = aiFacingThreeBet('8h 7h');
    expect(s87.fold / 200, greaterThan(0.5),
        reason: '87s 多数该弃（弃 ${s87.fold}/200）');
    final kqs = aiFacingThreeBet('Kh Qh');
    expect(kqs.call / 200, greaterThan(0.9),
        reason: 'KQs 该跟（跟 ${kqs.call}/200）');
    final a5s = aiFacingThreeBet('Ad 5d');
    expect(a5s.raise / 200, greaterThan(0.15),
        reason: 'A5s 该有一部分轻 4bet（4bet ${a5s.raise}/200）');
    expect(a5s.call, 0, reason: 'A5s 不做老实跟注（拖到翻后也是白送）');

    // 100bb 不买三条；300bb 深筹码才值得跟进去。
    final p55 = aiFacingThreeBet('5h 5d');
    expect(p55.call / 200, lessThan(0.25),
        reason: '100bb 不该买三条（跟 ${p55.call}/200）');
    final p55deep = aiFacingThreeBet('5h 5d', stack: 30000);
    expect(p55deep.call / 200, greaterThan(0.4),
        reason: '300bb 深筹码可以买三条（跟 ${p55deep.call}/200）');
    final tt = aiFacingThreeBet('10h 10d');
    expect(tt.fold, 0, reason: 'TT 不会弃给 3bet');
  });

  t('翻前轻 4bet：3bet 越贵，A5s 压回去的频率越低', () {
    // 轻 4bet（A5s~A2s：没有摊牌价值，全靠阻断牌压回去）的频率以前是个跟价格
    // 无关的常数，探针实测（tool/ai_preflop3bet_probe.dart）A5s 对着
    // 4.7 / 7.0 / 9.0 / 14.0bb 一律「加注 28%」——9bb 和 14bb 那两行连弃牌率
    // 都逐字相同。对手只要把 3bet 加到 14bb，就能稳定地拿 AA/KK 从我们身上
    // 收下两成八个 30bb 的 4bet：我们要投的筹码翻了三倍，敢加到 14bb 的范围
    // 又实得多（弃给我们 4bet 的比例低得多），两头的期望一起往负的走。
    //
    // 现在 10bb（代码里本来就认定「10bb 以上才算贵」，见 [AiPlayer] 的
    // `priceyShift`）以下逐点不动，往上线性收到基频的两成——不归零是因为
    // A5s 的阻断牌价值不随价格消失。这一条量的是「贵了要收」，配上探针那节
    // 的整条曲线看坡度。
    const seeds = 400;
    final total = _trialSeeds(seeds);
    final cheap = aiFacingThreeBet('Ah 5h', threeBet: 470, seeds: seeds);
    final normal = aiFacingThreeBet('Ah 5h', threeBet: 1000, seeds: seeds);
    final big = aiFacingThreeBet('Ah 5h', threeBet: 1400, seeds: seeds);
    final huge = aiFacingThreeBet('Ah 5h', threeBet: 2000, seeds: seeds);

    expect(normal.raise, greaterThan((0.2 * total).round()),
        reason: '10bb 以下照旧有轻 4bet（加注 ${normal.raise}/$total）');
    expect(cheap.raise * 0.7, lessThan(normal.raise.toDouble()),
        reason: '便宜档不该比正常档还少（${cheap.raise} vs ${normal.raise}）');
    expect(big.raise * 2, lessThan(normal.raise),
        reason: '14bb 要明显收着打（加注 ${big.raise} vs 10bb 的 ${normal.raise}）');
    expect(huge.raise * 2, lessThan(normal.raise),
        reason: '20bb 更少（加注 ${huge.raise}）');
    expect(huge.raise, greaterThan((0.02 * total).round()),
        reason: '不归零：阻断牌的价值不随价格消失（加注 ${huge.raise}）');
    expect(huge.call, 0, reason: '大 3bet 面前 A5s 不做老实跟注');

    // 但收完之后 14bb 往上自己又成了一段平台：改之前同一把量法在
    // 14 / 16 / 18 / 20 / 22bb 上量到的加注数是**逐字相同**的 87/1500
    // （松凶 164/1500）——对手把 3bet 从 14bb 抬到 22bb，我们 4bet 出去要投
    // 的筹码从三十个涨到五十几个，敢加到那个数的范围也硬得多（弃给我们
    // 4bet 的比例低得多），两头的期望一起往下走，频率却一个点不动。
    // 现在贵那侧接着收（倒数衰减，见 [AiPlayer] 里的 `lightExpensiveRamp`）：
    // 20bb 收到六成、22bb 收到一半，一路往零收但收不到零（A5s 的阻断牌价值
    // 不随价格消失）。故意不用「收到某个地板就夹住」——夹住等于在 22bb 又造
    // 一段平台，正是这条用例要修的东西。
    //
    // 样本要够：这两档只差三五个点，400 手的标准差就有一两个点，所以单拿
    // 3000 手对拍这一条。改之前两边的加注数完全一样，这条必红。
    const deepSeeds = 3000;
    final b14 = aiFacingThreeBet('Ah 5h', threeBet: 1400, seeds: deepSeeds);
    final b20 = aiFacingThreeBet('Ah 5h', threeBet: 2000, seeds: deepSeeds);
    expect(b20.raise * 5, lessThan(b14.raise * 4),
        reason: '20bb 要比 14bb 明显更少（${b14.raise} → ${b20.raise}）');
  });

  t('翻前轻 4bet：便宜档（4.7bb）要比 10bb 压回去更多', () {
    // 上一条钉的是「贵了要收」。收完贵那侧之后，10bb 以下那一整段自己又成了
    // 新的常数区间：探针实测（tool/ai_preflop3bet_probe.dart 第四节）A5s 对着
    // 4.7 / 6.2 / 8.0 / 10.0bb 一律「加注 28%」，三种风格全一样（紧凶 28%、
    // 松凶 55%）。
    //
    // 可 4.7bb 那档 4bet 出去只要投十几个 bb、14bb 那档要投三十个——「贵了要
    // 收」的理由（投进去的钱跟着价格翻倍）在便宜那头是**反过来**成立的：压回
    // 去的成本越低越该压。对手把 3bet 从 5bb 加到 10bb、看我们的 4bet 频率一
    // 动不动，就能白拿到「3bet 更贵、但还是一样的弃牌率」。
    //
    // 现在便宜侧也铺了斜坡：拿离 45% 上限的余量、按便宜程度补四成。这一条量
    // 的就是「便宜档明显高出一截、而且中间不许有台阶」——上一条管贵侧、这条
    // 管便宜侧，两条合起来才是完整的曲线。
    const seeds = 400;
    final cheap = aiFacingThreeBet('Ah 5h', threeBet: 470, seeds: seeds);
    final mid = aiFacingThreeBet('Ah 5h', threeBet: 620, seeds: seeds);
    final late = aiFacingThreeBet('Ah 5h', threeBet: 800, seeds: seeds);
    final normal = aiFacingThreeBet('Ah 5h', threeBet: 1000, seeds: seeds);

    expect(cheap.raise, greaterThan((normal.raise * 1.1).round()),
        reason: '4.7bb 要明显比 10bb 压得多（${cheap.raise} vs ${normal.raise}）');
    expect(cheap.raise, greaterThanOrEqualTo(mid.raise),
        reason: '从便宜到贵不许回头（${cheap.raise} → ${mid.raise}）');
    expect(mid.raise, greaterThanOrEqualTo(late.raise),
        reason: '从便宜到贵不许回头（${mid.raise} → ${late.raise}）');
    expect(late.raise, greaterThanOrEqualTo(normal.raise),
        reason: '从便宜到贵不许回头（${late.raise} → ${normal.raise}）');
  });

  /// 6 人桌：p3 弃 → p4 开 [open] → p5 弃 → 按钮位 p0（英雄）3bet 到
  /// [threeBet] → 小盲 p1、大盲 p2 里前 [coldCallers] 家跟注、其余弃牌 →
  /// 轮到从前面开池的 p4 面对 3bet。
  ///
  /// 跟 [aiFacingThreeBet] 的区别是「谁 3bet」：这里英雄坐按钮位，盲注位在
  /// p4 再次行动**之前**就先说话了，所以 [coldCallers] 能造出「p4 关着门、
  /// 池里还有一家陪着进池」的多路底池——单挑和多路就这一处不同。
  ({int raise, int call, int fold, int n}) aiFacingThreeBetColdCall(String hole,
      {int seeds = 200,
      AiStyle style = AiStyle.tightAggressive,
      int stack = 10000,
      int open = 300,
      int threeBet = 900,
      int coldCallers = 0}) {
    var raise = 0, call = 0, fold = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: GameConfig(
            startingStack: stack, smallBlind: 50, bigBlind: 100),
        random: rnd,
      );
      for (var i = 0; i < 6; i++) {
        g.addPlayer('p$i', 'P$i');
      }
      g.startHand(holeOverride: {'p4': _cs(hole)});
      g.apply('p3', ActionType.fold);
      g.apply('p4', ActionType.raise, amount: open);
      g.apply('p5', ActionType.fold);
      g.apply('p0', ActionType.raise, amount: threeBet);
      for (var i = 0; i < 2; i++) {
        final blind = 'p${i + 1}';
        final wait = g.pendingAction();
        if (wait.player.id != blind) fail('轮到的是 ${wait.player.id}，不是 $blind');
        g.apply(blind, i < coldCallers ? ActionType.call : ActionType.fold);
      }
      final p = g.pendingAction().player;
      if (p.id != 'p4') fail('轮到的是 ${p.id}，不是 p4');
      n++;
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
    return (raise: raise, call: call, fold: fold, n: n);
  }

  t('翻前防守 3bet：池里有人冷跟时，关门买三条跟得明显宽', () {
    // 真人被 3bet 之后，只要池里已经有别家跟注进来（关着门、价格便宜、
    // 还有一家陪着进池），小对子买三条的隐含赔率比单挑好一大截，跟得明显宽。
    // 以前这一档完全不看人数：实测 22~88、98s 在单挑和多路底池里逐格相同
    // （都是弃 100%），对手发现三家进池也照样 100% 弃就能拿任意两张牌 3bet。
    final single = aiFacingThreeBetColdCall('5h 5d');
    expect(single.n, greaterThan(60));
    expect(single.call / single.n, lessThan(0.15),
        reason: '单挑 100bb 别买三条（跟 ${single.call}/${single.n}）');

    final one = aiFacingThreeBetColdCall('5h 5d', coldCallers: 1);
    expect(one.call / one.n, greaterThan(0.6),
        reason: '一家冷跟时 55 该跟（单挑 ${single.call}/${single.n} → '
            '一家 ${one.call}/${one.n}）');

    final two = aiFacingThreeBetColdCall('5h 5d', coldCallers: 2);
    expect(two.call / two.n, greaterThan(0.6),
        reason: '两家冷跟时 55 照样跟（跟 ${two.call}/${two.n}）');
    // 人越多越宽，不能倒挂（一家跟的比两家还多就成了新的破绽）。
    expect(two.call / two.n, greaterThanOrEqualTo(one.call / one.n - 0.1),
        reason: '冷跟人数多的档不该比少的档还紧（一家 ${one.call}/${one.n} → '
            '两家 ${two.call}/${two.n}）');

    // 同一档也要跟着放宽：98s 这种同花连张单挑里该弃，多路底池里要跟一部分。
    final scSingle = aiFacingThreeBetColdCall('9h 8h');
    final scTwo = aiFacingThreeBetColdCall('9h 8h', coldCallers: 2);
    expect(scSingle.call / scSingle.n, lessThan(0.05),
        reason: '98s 单挑别跟 3bet（跟 ${scSingle.call}/${scSingle.n}）');
    expect(scTwo.call / scTwo.n, greaterThan(0.1),
        reason: '98s 多路底池里跟一部分（跟 ${scTwo.call}/${scTwo.n}）');

    // 有摊牌价值的那半不该因为人多再放宽，也不该退化：AQo/KQs 本来就该跟。
    for (final hole in ['Ah Qd', 'Kh Qh']) {
      final s0 = aiFacingThreeBetColdCall(hole);
      final s2 = aiFacingThreeBetColdCall(hole, coldCallers: 2);
      expect(s0.fold / s0.n, lessThan(0.1),
          reason: '$hole 单挑就该跟（弃 ${s0.fold}/${s0.n}）');
      expect(s2.fold / s2.n, lessThan(0.1),
          reason: '$hole 多路底池也得跟（弃 ${s2.fold}/${s2.n}）');
    }

    // 要价真的很大（4.7 倍、14bb）时「关门价」就不成立了，人多也一样该弃。
    final pricey =
        aiFacingThreeBetColdCall('5h 5d', coldCallers: 2, threeBet: 1400);
    expect(pricey.fold / pricey.n, greaterThan(0.9),
        reason: '要价 14bb 时买三条照样弃（弃 ${pricey.fold}/${pricey.n}）');
  });

  /// 3 人桌：按钮 p0 开 300 → 小盲 p1 3bet 900 → 大盲 p2（AI）面对 3bet。
  /// 这是「没位置跟 3bet」的那条线。
  ({int raise, int call, int fold, int n}) aiFacingThreeBetOop(String hole,
      {int seeds = 200,
      AiStyle style = AiStyle.tightAggressive,
      int stack = 10000,
      int open = 300,
      int threeBet = 900}) {
    var raise = 0, call = 0, fold = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: GameConfig(
            startingStack: stack, smallBlind: 50, bigBlind: 100),
        random: rnd,
      );
      for (var i = 0; i < 3; i++) {
        g.addPlayer('p$i', 'P$i');
      }
      g.startHand(holeOverride: {
        'p0': _cs('4c 3c'),
        'p1': _cs('8c 7d'),
        'p2': _cs(hole),
      });
      g.apply('p0', ActionType.raise, amount: open);
      g.apply('p1', ActionType.raise, amount: threeBet);
      final p = g.pendingAction().player;
      if (p.id != 'p2') fail('轮到的是 ${p.id}，不是 p2');
      n++;
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
    return (raise: raise, call: call, fold: fold, n: n);
  }

  t('翻前防守 3bet：没位置只跟有牌力的那一半，不会把 KK/QQ 白扔', () {
    // 以前「跟 3bet」的范围不分位置，没位置的人除了 4bet 就是 100% 弃牌，
    // 连 KK/QQ/AK 都被扔掉（跟注站连 4bet 都不打，弃得最狠）。一条永远
    // 不会用强牌跟注的线，对手拿任意两张牌 3bet 都是赚的。
    for (final hole in ['Kh Kd', 'Qh Qd', 'As Ks', 'Ah Kd']) {
      final r = aiFacingThreeBetOop(hole);
      expect(r.fold, 0, reason: '$hole 没位置也不能弃给 3bet');
      expect(r.call + r.raise, r.n, reason: '$hole 要么跟要么 4bet');
    }
    final kkStation = aiFacingThreeBetOop('Kh Kd', style: AiStyle.loosePassive);
    expect(kkStation.fold, 0, reason: '跟注站也不会把 KK 扔了');

    // 有牌力的：TT/KQs 跟；靠位置的投机牌没位置一律不留。
    final tt = aiFacingThreeBetOop('10h 10d');
    expect((tt.call + tt.raise) / tt.n, greaterThan(0.7),
        reason: 'TT 没位置也要继续（跟 ${tt.call}）');
    final kqs = aiFacingThreeBetOop('Kh Qh');
    expect(kqs.call / kqs.n, greaterThan(0.6),
        reason: 'KQs 可以跟（跟 ${kqs.call}）');
    final ats = aiFacingThreeBetOop('Ah 10h');
    expect(ats.fold / ats.n, greaterThan(0.6),
        reason: 'ATs 没位置不跟 3bet（投机牌）');
    final sc = aiFacingThreeBetOop('7h 6h');
    expect(sc.fold / sc.n, greaterThan(0.85),
        reason: '76s 没位置别跟 3bet（弃 ${sc.fold}）');
  });

  t('翻前防守 3bet：便宜档边界是斜坡，不在 2.2 倍开池上跳崖', () {
    // 「便宜 3bet」原来是 `<=5.5bb 或者 <=2.2 倍开池` 两个硬条件的或：
    // 开池 286 时门槛落在 629 筹码附近，于是 KQo 对着 620 跟 100%、对着
    // 640 只跟 37%——对手只要多叫两个小盲，跟注范围就从整档缩成一条缝，
    // 这是能被精确挑的开关，不是人。现在两个条件各自铺成斜坡
    // （[5.5, 6.5]bb / [2.2, 2.45] 倍开池），跟注率该随价格连续往下走。
    // 这里量的就是边界那一段的斜率。
    final cheap = aiFacingThreeBetOop('Kh Qs', open: 286, threeBet: 620);
    expect(cheap.call, cheap.n,
        reason: '2.17 倍开池还是便宜档，KQo 该照跟（弃 ${cheap.fold}/${cheap.n}）');
    final edge = aiFacingThreeBetOop('Kh Qs', open: 286, threeBet: 660, seeds: 300);
    final edgeRate = edge.call / edge.n;
    expect(edgeRate, greaterThan(0.5),
        reason: '2.31 倍刚过旧门槛，不该一步掉到正常档（跟 $edgeRate）');
    expect(edgeRate, lessThan(0.8),
        reason: '2.31 倍已经比满便宜档贵了（跟 $edgeRate）');
    final mid = aiFacingThreeBetOop('Kh Qs', open: 286, threeBet: 700, seeds: 300);
    final midRate = mid.call / mid.n;
    expect(midRate, greaterThan(0.1),
        reason: '2.45 倍才该收满到正常档（跟 $midRate）');
    expect(midRate, lessThan(0.35),
        reason: '2.45 倍已是正常档（跟 $midRate）');
    // 坡度中间那一点必须夹在两端之间：跳崖会在这里露馅（旧代码 660 之后就
    // 是塌的，680 只能等于 700）。
    final slope = aiFacingThreeBetOop('Kh Qs', open: 286, threeBet: 680, seeds: 300);
    expect(slope.call, lessThan(edge.call),
        reason: '跟注率该随价格单调下降（680 跟 ${slope.call} ≥ 660 跟 ${edge.call}）');
    expect(slope.call, greaterThan(mid.call),
        reason: '跟注率该随价格单调下降（680 跟 ${slope.call} ≤ 700 跟 ${mid.call}）');
  });

  t('翻前防守 3bet：最小加注跟得宽，3 倍加注才收着', () {
    // 跟注范围得跟着 3bet 的大小放缩。英雄把 3bb 最小加注到 4.7bb 时，
    // 跟 1.85bb 就能去抢一个 9bb 的底池（约 20% 赔率，后面还留着 95bb 的
    // 隐含赔率），99 这种中等对子弃掉是纯亏。以前这里一个门槛打天下，
    // 实测 99 有 82% 直接弃牌——对手拿任意两张牌最小加注都是白赚的。
    final small = aiFacingThreeBetOop('9h 9d', open: 286, threeBet: 470);
    expect(small.fold, 0, reason: '99 面对最小加注该跟（弃 ${small.fold}/${small.n}）');
    final kqo = aiFacingThreeBetOop('Kh Qs', open: 286, threeBet: 470);
    expect(kqo.call / kqo.n, greaterThan(0.7),
        reason: 'KQo 面对最小加注也跟得起（跟 ${kqo.call}/${kqo.n}）');
    final setMine = aiFacingThreeBetOop('5h 5d', open: 286, threeBet: 470);
    expect(setMine.call / setMine.n, greaterThan(0.3),
        reason: '小 3bet 后小对子买三条（跟 ${setMine.call}/${setMine.n}）');

    // 大小看的是「相对开池的倍数」，不是绝对筹码：开 5bb 被加到 9bb
    // （1.8 倍）价格一样便宜，不能因为数字到了 9bb 就当大 3bet 处理。
    final ratio = aiFacingThreeBetOop('9h 9d', open: 500, threeBet: 900);
    expect(ratio.fold, 0, reason: '开池大、倍数小，价格一样好');

    // 但「收着打」收过头就成了另一个破绽：面对 3 倍加注（7~9bb）时，
    // 99 对着任何合理的 3bet 范围都还有 44% 胜率，跟 6bb 去抢一个 19.5bb
    // 的底池只要 31% 赔率，跟注是明显的正期望。以前这里 99 弃 63%、
    // AQo 弃 63%，对手发现我们只有 TT+ 才接，拿任意两张牌 3bet 都是赚的。
    final normal = aiFacingThreeBetOop('9h 9d');
    expect(normal.fold / normal.n, lessThan(0.15),
        reason: '99 面对 3 倍加注该跟（弃 ${normal.fold}/${normal.n}）');
    final aqo = aiFacingThreeBetOop('Ah Qd');
    expect(aqo.call / aqo.n, greaterThan(0.7),
        reason: 'AQo 没位置也跟得住 3 倍加注（跟 ${aqo.call}/${aqo.n}）');
    // 没位置仍然要比有位置紧：KQo 这种靠位置实现胜率的牌留在有位置才跟。
    final kqoOop = aiFacingThreeBetOop('Kh Qs');
    expect(kqoOop.fold / kqoOop.n, greaterThan(0.5),
        reason: 'KQo 没位置还是弃多跟少（弃 ${kqoOop.fold}/${kqoOop.n}）');
    expect(aiFacingThreeBet('Kh Qs').call / 200, greaterThan(0.5),
        reason: '同一手 KQo 有位置就是跟注');

    // 另一头也要收住：要价真的大到 4~5 倍（14bb）时，中等对子和同花大牌
    // 该扔掉——跟 11bb 去抢 19bb 只要 37% 赔率，99/JTs 没位置实现不了。
    final huge = aiFacingThreeBetOop('9h 9d', open: 300, threeBet: 1400);
    expect(huge.fold / huge.n, greaterThan(0.9),
        reason: '99 面对 4.7 倍 3bet 该弃（弃 ${huge.fold}/${huge.n}）');
    final jtsHuge = aiFacingThreeBetOop('Jh 10h', open: 300, threeBet: 1400);
    expect(jtsHuge.fold / jtsHuge.n, greaterThan(0.9),
        reason: 'JTs 面对 4.7 倍 3bet 没位置该弃（弃 ${jtsHuge.fold}/${jtsHuge.n}）');
    final qqHuge = aiFacingThreeBetOop('Qh Qd', open: 300, threeBet: 1400);
    expect(qqHuge.fold, 0, reason: 'QQ 面对多大的 3bet 都不会弃');
    // 价格再好也不能变成「什么都跟」：真正的垃圾牌照样弃，
    // 投机的同花连张混着打（有跟有弃），不能次次都跟。
    final trash = aiFacingThreeBetOop('8h 3d', open: 286, threeBet: 470);
    expect(trash.fold, trash.n, reason: '83o 面对 3bet 还是得弃');
    final sc = aiFacingThreeBetOop('7h 6h', open: 286, threeBet: 470);
    expect(sc.fold, greaterThan(0), reason: '76s 要混着打，不能次次都跟');
  });

  t('翻前防守 3bet：大小是连续的，不在门槛上跳崖', () {
    // 「大 3bet 要收着跟」这条以前是个开关：`threeBetBb >= 12 || toCall >= 10bb`
    // 一过就整档收紧两档。大盲已经投过 1bb，所以这条线上旧门槛落在名义 11bb，
    // 实测 99 对着 11.0bb 的 3bet 跟 100%、对着 11.1bb 弃 100%——只差 10 个
    // 筹码，中间没有任何过渡。对手把 3bet 加到门槛以上就能直接收走底池，
    // 压在门槛下面又几乎必被跟，跟注范围成了对手可以精确挑的开关。
    //
    // 现在换成线性过渡（[AiPlayer._preflop] 里的 priceyShift，铺在旧门槛
    // 下面那 2bb）：这一条盯着那条曲线——门槛那一点的值跟以前一样，但门槛
    // 下面这 2bb 里跟注率要一路往下走，不能再长出一条新悬崖。
    double foldAt(int threeBet) {
      final r = aiFacingThreeBetOop('9h 9d', open: 300, threeBet: threeBet);
      return r.fold / r.n;
    }

    // 0.5bb 一档扫过整条斜坡；两端是旧门槛以外、本来就不该动的地方。
    final ramp = [900, 950, 1000, 1050, 1100].map(foldAt).toList();

    expect(ramp.first, 0,
        reason: '9bb（门槛下面 2bb）照旧一点不收（弃 ${(100 * ramp.first).round()}%）');
    expect(ramp.last, greaterThan(0.95),
        reason: '11bb 就是这条线的旧门槛，照旧收满（弃 ${(100 * ramp.last).round()}%）');
    expect(ramp[1], greaterThan(0.1),
        reason: '门槛下面得真有过渡，不是只有两个端点不一样（9.5bb 弃 '
            '${(100 * ramp[1]).round()}%）');
    for (var i = 1; i < ramp.length; i++) {
      expect(ramp[i], greaterThanOrEqualTo(ramp[i - 1] - 0.02),
          reason: '越贵只能越少跟，不能回升（${(100 * ramp[i - 1]).round()}% → '
              '${(100 * ramp[i]).round()}%）');
      expect(ramp[i] - ramp[i - 1], lessThan(0.45),
          reason: '相邻 0.5bb 不许跳崖（${(100 * ramp[i - 1]).round()}% → '
              '${(100 * ramp[i]).round()}%）');
    }
    final deep = foldAt(1400); // 14.0bb，斜坡上端以上
    expect(deep, greaterThan(0.9),
        reason: '14bb 那条线照旧要弃（弃 ${(100 * deep).round()}%）');
    final minRaise = aiFacingThreeBetOop('9h 9d', open: 286, threeBet: 470);
    expect(minRaise.fold, 0, reason: '最小加注那条线不动（弃 ${minRaise.fold}）');
  });

  t('翻前防守 3bet：同花大牌不能比同花连张先扔', () {
    // 范围表的「大牌」分支是短路的——同花大牌只查 suitedBroadway，查不到就
    // 直接判「不在范围内」，不会掉到下面的同花连张/隔张档去。最小 3bet 那两
    // 张表以前写的是 suitedBroadway: 11（低牌要 ≥ J），于是 JTs 被挤出跟注
    // 范围，而 98s/76s 那种同花连张照样在。探针实测最小加注到 4.7bb：开池的
    // 人拿 JTs 弃 79%，拿 98s 跟 68%、76s 跟 68%、55 跟 68%——更好的牌反而
    // 先扔，是牌桌上最好读的一类破绽。
    PreflopHand h(String s) => PreflopHand.of(_cs(s));
    expect(PreflopRanges.callThreeBetSmall.contains(h('Jh 10h')), isTrue,
        reason: 'JTs 有位置跟小 3bet 是标准打法');
    expect(PreflopRanges.callThreeBetSmallOop.contains(h('Jh 10h')), isTrue,
        reason: 'JTs 没位置也该在最小 3bet 的跟注范围里');

    // 有位置：最小加注给的价格最好（跟 1.85bb 抢一个 9bb 的底池），JTs 该跟。
    final ipJts = aiFacingThreeBet('Jh 10h', threeBet: 470);
    final ip98s = aiFacingThreeBet('9h 8h', threeBet: 470);
    expect(ipJts.call / 200, greaterThan(0.9),
        reason: '有位置 JTs 跟最小 3bet（跟 ${ipJts.call}/200）');
    expect(ipJts.call, greaterThanOrEqualTo(ip98s.call),
        reason: 'JTs 不能比 98s 先扔（JTs ${ipJts.call} vs 98s ${ip98s.call}）');

    // 没位置：价格一样的便宜，JTs 照样是跟注那一半。
    final oopJts = aiFacingThreeBetOop('Jh 10h', open: 286, threeBet: 470);
    final oop98s = aiFacingThreeBetOop('9h 8h', open: 286, threeBet: 470);
    expect(oopJts.call / oopJts.n, greaterThan(0.9),
        reason: '没位置 JTs 也跟最小 3bet（跟 ${oopJts.call}/${oopJts.n}）');
    expect(oopJts.call * oop98s.n, greaterThanOrEqualTo(oop98s.call * oopJts.n),
        reason: 'JTs 不能比 98s 先扔'
            '（JTs ${oopJts.call}/${oopJts.n} vs 98s ${oop98s.call}/${oop98s.n}）');

    // 收住：这只是「小 3bet 价格好」那一档。要价真的大到 3 倍以上时，JTs
    // 没位置还是得扔（避免把这条修成了「什么 3bet 都跟」）。
    final oopJtsBig = aiFacingThreeBetOop('Jh 10h');
    expect(oopJtsBig.fold / oopJtsBig.n, greaterThan(0.5),
        reason: 'JTs 面对 3 倍 3bet 没位置还是弃多跟少'
            '（弃 ${oopJtsBig.fold}/${oopJtsBig.n}）');
  });

  t('翻前防守 3bet：跟注站不看位置也不看深度，不是全场最紧的人', () {
    // 跟注站的弱点本来就是「什么都不弃」：拿 22 / 76s / A5s 面对 3bet 是
    // 跟注，不像紧手那样「没位置、筹码不够深就扔」。以前这里给它们的也
    // 是紧凶那套范围（还要有位置），等于把全场最松的人打成了最紧的人。
    ({int raise, int call, int fold, int n}) station(String hole) =>
        aiFacingThreeBetOop(hole, style: AiStyle.loosePassive);
    for (final hole in ['2h 2d', '7h 6h', 'Ad 5d', 'Kc Jc']) {
      final r = station(hole);
      expect(r.call / r.n, greaterThan(0.4),
          reason: '跟注站拿 $hole 面对 3bet 是跟注（跟 ${r.call}/${r.n}）');
    }
    // 但也不是什么都跟：真正的垃圾牌照样弃。
    final trash = station('8h 3d');
    expect(trash.fold, trash.n, reason: '83o 面对 3bet 还是得弃');

    // 有位置的跟注站同样不挑深度（以前非极深筹码要把小对子摘掉）。
    final ip = aiFacingThreeBet('2h 2d', style: AiStyle.loosePassive);
    expect((ip.call + ip.raise) / 200, greaterThan(0.4),
        reason: '按钮位跟注站也会用小对子跟 3bet（跟+加 ${ip.call + ip.raise}/200）');
    // 紧凶在同一个点亮起的差别必须在：不然「风格」就白叫了。
    final tightIp = aiFacingThreeBet('2h 2d');
    expect(tightIp.fold / 200, greaterThan(0.9),
        reason: '紧凶 100bb 不买三条（弃 ${tightIp.fold}/200）');
  });

  t('翻前 4bet：QQ+/AK 面对方 3bet 会再加注回去，不是一路慢打', () {
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

  t('翻前 4bet：松被动拿 AA 更多是慢打（风格要分得开）', () {
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

  t('翻前 4bet：对手 4bet/5bet 回来，只有 AA/KK 还继续', () {
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
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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

  t('薄价值下注：干面一起打范围小注，转到转牌才按牌力分档', () {
    // 干燥牌面 K-8-3 的翻牌圈，单挑、有位置、英雄过牌。
    const flop = 'Kd 8c 3h';
    const turn = 'Kd 8c 3h 2s';
    final topPairFlop = aiBetRateWhenCheckedTo('Kh Qh', flop, Street.flop);
    final secondPairFlop = aiBetRateWhenCheckedTo('8h 7h', flop, Street.flop);
    String pct(double v) => '${(100 * v).round()}%';

    // 翻牌圈是「范围小注」（见另一条用例）：顶对当然要打，而且不该比
    // 第二对还少——以前中等牌 45%、弱牌 50% 一刀切，顶对只打 43%，
    // 反而比第二对 47% 还少。
    expect(topPairFlop, greaterThan(0.65),
        reason: '顶对好踢该经常下注（${pct(topPairFlop)}）');
    expect(topPairFlop, greaterThan(secondPairFlop - 0.05),
        reason: '干面上顶对不能比第二对打得还少 '
            '(${pct(topPairFlop)} vs ${pct(secondPairFlop)})');

    // 转牌：没有「范围小注」这一层了，牌力分档在这儿才看得出来。
    // 顶对是主力价值牌，第二对/底对只是薄价值，频率差一档。
    final topPairTurn = aiBetRateWhenCheckedTo('Kh Qh', turn, Street.turn);
    final topPairWeakTurn = aiBetRateWhenCheckedTo('Kh 5h', turn, Street.turn);
    final secondPairTurn = aiBetRateWhenCheckedTo('8h 7h', turn, Street.turn);
    final bottomPairTurn = aiBetRateWhenCheckedTo('Ac 3c', turn, Street.turn);
    expect(topPairTurn, greaterThan(secondPairTurn + 0.2),
        reason: '转牌顶对明显比第二对打得多 '
            '(${pct(topPairTurn)} vs ${pct(secondPairTurn)})');
    expect(topPairWeakTurn, greaterThan(bottomPairTurn + 0.15),
        reason: '顶对弱踢也比底对打得多 '
            '(${pct(topPairWeakTurn)} vs ${pct(bottomPairTurn)})');
    expect(secondPairTurn, lessThan(0.55),
        reason: '第二对是薄价值，别打成主力（${pct(secondPairTurn)}）');
    expect(bottomPairTurn, lessThan(0.6),
        reason: '底对同理（${pct(bottomPairTurn)}）');

    // 河牌：顶对收成摊牌牌，打得比转牌少，但还是要打薄价值。
    final river =
        aiBetRateWhenCheckedTo('Kh Qh', 'Kd 8c 3h 2s 5d', Street.river);
    expect(river, lessThan(topPairTurn), reason: '河牌比转牌收敛一点');
    expect(river, greaterThan(0.4),
        reason: '河牌顶对还是要打薄价值（${pct(river)}）');
  });

  t('转牌控池：发出的牌帮到跟注方时，顶对/超对不再无脑开第二枪', () {
    // 单挑、AI 有位置：翻牌 c-bet 被跟注，转牌英雄过牌。
    const flop = 'Kd 8c 3h';
    final blank = aiBetRateWhenCheckedTo('Ah Ad', '$flop 2s', Street.turn);
    final overcard = aiBetRateWhenCheckedTo('Ah Ad', '$flop Qh', Street.turn);
    final midCard = aiBetRateWhenCheckedTo('Ah Ad', '$flop 9d', Street.turn);
    final paired = aiBetRateWhenCheckedTo('Ah Ad', '$flop 8d', Street.turn);

    // 空白牌：跟注方什么都没中，超对继续开火收价值。
    expect(blank, greaterThan(0.9),
        reason: '空白牌转牌照样开火（${(100 * blank).round()}%）');
    // Q / 9 / 公对面都是会打中跟注方范围的牌（KQ、QJ、98s、8x）：
    // 以前这里一律 100% 开火，被对手等一张牌过牌-加注就得弃。
    for (final (name, rate) in [
      ('高张 Q', overcard),
      ('中间牌 9', midCard),
      ('公对面 8', paired),
    ]) {
      expect(rate, lessThan(blank - 0.15),
          reason: '转牌发 $name 时要收手控池 '
              '(${(100 * rate).round()}% vs 空白牌 ${(100 * blank).round()}%)');
      expect(rate, greaterThan(0.4),
          reason: '控池不等于放弃收价值（${(100 * rate).round()}%）');
    }

    // 不该波及中等牌：顶对好踢有自己的薄价值频率，本来就打得少。
    final mediumBlank =
        aiBetRateWhenCheckedTo('Kh Qh', '$flop 2s', Street.turn);
    final mediumScary =
        aiBetRateWhenCheckedTo('Kh Qh', '$flop 9d', Street.turn);
    expect((mediumScary - mediumBlank).abs(), lessThan(0.15),
        reason: '中等牌的薄价值频率不受控池这条线影响 '
            '(${(100 * mediumScary).round()}% vs '
            '${(100 * mediumBlank).round()}%)');
  });

  /// 单挑：英雄（按钮位）开池、AI（大盲）跟注；翻牌英雄下小注、
  /// 转牌 AI 先领打、英雄再加注 —— 也就是实战里「AI 领先下注被抬」这条线。
  /// 统计 AI 在转牌面对加注的应对，只取深筹码（SPR > 4）的样本：
  /// 筹码浅的时候「强牌直接全下」本来就是对的，量不出牌力分档。
  ({double fold, double call, double raise, int total, double spr})
      aiFacingTurnRaise(String hole, String board,
          {int seeds = 400,
          AiStyle style = AiStyle.loosePassive,
          double minSpr = 4.0}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    var spr = 0.0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 42000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('hero', '我')
        ..addPlayer('ai', 'AI');
      final ai = AiPlayer(style, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('4h 2c')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      var seen = 0;
      var led = false; // 转牌是它先领打（实战那条线）还是先过牌
      var recorded = false;
      while (!g.handOver && guard++ < 60) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          final d = ai.decide(g, p);
          if (g.street == Street.turn) {
            if (seen == 0) {
              led = d.type == ActionType.bet;
            } else if (seen == 1 && led) {
              final s = p.stack / max(1, g.potTotal());
              if (s < minSpr) break; // 浅筹码不算
              total++;
              spr += s;
              recorded = true;
              switch (d.type) {
                case ActionType.fold:
                  fold++;
                case ActionType.call:
                  call++;
                default:
                  raise++;
              }
            }
            seen++;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          if (recorded) break; // 要量的就是这一下
          continue;
        }
        // 英雄：翻前加注、翻牌下小注、转牌再加注，把压力拉满。
        var type = ActionType.check;
        var frac = 0.0;
        if (g.street == Street.preflop) {
          type = ActionType.raise;
        } else if (g.street == Street.flop) {
          type = ActionType.bet;
          frac = 0.5;
        } else if (g.street == Street.turn) {
          type = legal.any((a) => a.type == ActionType.raise)
              ? ActionType.raise
              : ActionType.bet;
          frac = 0.8;
        }
        if (!legal.any((a) => a.type == type)) {
          type = canCheck ? ActionType.check : ActionType.call;
        }
        final la = legal.firstWhere((a) => a.type == type);
        int? amount;
        if (type == ActionType.bet) {
          amount = (g.potTotal() * frac).round().clamp(la.minAmount, la.maxAmount);
        } else if (type == ActionType.raise) {
          final target = g.street == Street.preflop
              ? 700
              : g.currentBet + (g.potTotal() * frac).round();
          amount = target.clamp(la.minAmount, la.maxAmount);
        }
        g.apply('hero', type, amount: amount);
      }
    }
    final n = max(1, total);
    return (
      fold: fold / n,
      call: call / n,
      raise: raise / n,
      total: total,
      spr: spr / n,
    );
  }

  t('听牌面对转牌第二枪：正常尺度该跟，超池和弱听牌照旧弃', () {
    // 坚果花听 + 两张高张（AdKd 在 Qd7d2c5h）：只数 outs 是 9 个，算出来
    // 19.6% + 隐含 8% = 27.6%，对着转牌 2/3 池下注（要 28.6%）永远差一个
    // 多点，于是这类牌一律弃——探针实测跟注 0%，要么加注要么弃，一眼就不
    // 像真人。高张、后门这些出路「数 outs」看不见，得用对着对手范围算的
    // 蒙特卡洛胜率兜底（真实胜率三成上下，跟这个价格是够的）。
    String pct(double v) => '${(100 * v).round()}%';
    final normal = aiVsTurnBet('Ad Kd', 'Qd 7d 2c 5h', 0.66);
    expect(normal.n, greaterThan(_trialSeeds(40)), reason: '样本要够（${normal.n}）');
    expect(normal.call, greaterThan(0.4),
        reason: '坚果花听面对 2/3 池的下注要跟（跟 ${pct(normal.call)}）');
    expect(normal.fold, lessThan(0.3),
        reason: '不该一路弃（弃 ${pct(normal.fold)}）');

    // 超池是另一回事：敢超池的人范围偏价值，成牌之后也收不回钱，
    // 隐含赔率被吃掉，所以这时退回保守估值、老实弃牌。
    final over = aiVsTurnBet('Ad Kd', 'Qd 7d 2c 5h', 1.35);
    expect(over.fold, greaterThan(0.55),
        reason: '超池面前以弃为主（弃 ${pct(over.fold)}）');

    // 弱听牌（卡顺 4 outs）不享受这个兜底：对着范围算胜率会把它算高，
    // 真实可兑现的出路没那么多，该弃还是弃。
    final gut = aiVsTurnBet('7h 6h', '9d 5c 2s Kh', 0.66);
    expect(gut.fold, greaterThan(0.55),
        reason: '卡顺对着 2/3 池以弃为主（弃 ${pct(gut.fold)}）');
  });

  t('三条同花面：只有成花才打光，顺子/三条/两对转为跟注', () {
    // 实战第 175 手：转牌 10♦Q♦3♠K♦（三张方片），AI 拿 7♦6♦ 成花打光。
    const board = '10d Qd 3s Kd';
    final flush = aiFacingTurnRaise('7d 6d', board);
    final straight = aiFacingTurnRaise('Jc 9c', board);
    final set = aiFacingTurnRaise('3h 3d', board);
    final twoPair = aiFacingTurnRaise('Qs 3s', board);
    final secondPair = aiFacingTurnRaise('Qc Jc', board);
    String pct(double v) => '${(100 * v).round()}%';

    expect(flush.total, greaterThan(_trialSeeds(40)),
        reason: '成花这条线的样本要够（${flush.total}）');
    expect(flush.spr, greaterThan(3.5), reason: '这是深筹码点位（SPR ${flush.spr}）');
    // 成花在三条同花面上仍然是「继续加压」的那一档，但不再是无条件再加：
    // 一群怪兽牌里只有成花 100% 再加，等于告诉对手「他一再加就是坚果」。
    // 湿面上慢打的频率本来就该比干面低（听牌愿意付钱），所以成花留在
    // 七成上下——远高于下面那三档，同时留出慢打的空间。
    expect(flush.raise, greaterThan(0.55),
        reason: '成花面对加注当然继续加压（加 ${pct(flush.raise)}）');

    // 以前顺子/三条/两对全是「怪兽牌」，和成花走一模一样的线：被加注后
    // 100% 再加注，等于完全不看牌面有没有已经成花。现在它们只比成花
    // 低一档，被加注后以跟注为主。
    for (final (name, r) in [
      ('顺子', straight),
      ('set', set),
      ('两对', twoPair),
    ]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '$name 样本要够（${r.total}）');
      expect(r.raise, lessThan(0.35),
          reason: '$name 在三条同花面上不该再加注（加 ${pct(r.raise)}）');
      expect(r.call, greaterThan(0.55),
          reason: '$name 应该以跟注为主（跟 ${pct(r.call)}）');
      expect(r.fold, lessThan(0.15),
          reason: '$name 也不该一被加就弃（弃 ${pct(r.fold)}）');
    }
    expect(twoPair.raise, lessThan(flush.raise - 0.3),
        reason: '成花和两对必须分档（${pct(flush.raise)} vs ${pct(twoPair.raise)}）');

    // 弱成牌（这里是第二对）照旧弃牌：分档没被这次改动抹平。
    expect(secondPair.fold, greaterThan(0.6),
        reason: '第二对面对三张同花面的加注要弃（弃 ${pct(secondPair.fold)}）');
  });

  /// 单挑：英雄（按钮位）开池、AI（大盲）跟注，翻牌 AI 先行动 —— 这就是
  /// 「领先下注」（donk）的场合。统计它主动下注的频率，以及过牌后面对英雄
  /// 半池下注时的应对（加注=过牌-加注）。
  ({double donk, double raise, double call, double fold, int n})
      aiDonkRate(String hole, String board,
          {AiStyle style = AiStyle.tightAggressive, int seeds = 200}) {
    var n = 0, fire = 0;
    var faced = 0, raised = 0, called = 0, folded = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('hero', '我')
        ..addPlayer('ai', 'AI');
      final ai = AiPlayer(style, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3c 4h')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      while (!g.handOver && guard++ < 80) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        if (p.id == 'ai') {
          final d = ai.decide(g, p);
          if (g.street == Street.preflop) {
            g.apply('ai', d.type == ActionType.raise ? ActionType.call : d.type,
                amount: d.amountTo);
            if (d.type == ActionType.fold) break;
            continue;
          }
          if (g.street == Street.flop) {
            if (g.currentBet == 0) {
              n++;
              if (d.type == ActionType.bet) {
                fire++;
                break; // 已经领先下注，后面的街不用打完
              }
              g.apply('ai', d.type, amount: d.amountTo);
              continue; // 过牌：接着量面对下注的应对
            }
            faced++;
            switch (d.type) {
              case ActionType.fold:
                folded++;
              case ActionType.call:
                called++;
              default:
                raised++;
            }
            break;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        var type = ActionType.check;
        if (g.street == Street.preflop) {
          type = legal.any((a) => a.type == ActionType.raise)
              ? ActionType.raise
              : ActionType.call;
        } else if (g.street == Street.flop && g.currentBet == 0) {
          type = legal.any((a) => a.type == ActionType.bet)
              ? ActionType.bet
              : ActionType.check;
        }
        if (!legal.any((a) => a.type == type)) {
          type = legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : ActionType.call;
        }
        final la = legal.firstWhere((a) => a.type == type);
        int? amount;
        if (type == ActionType.raise) {
          amount = 300.clamp(la.minAmount, la.maxAmount);
        } else if (type == ActionType.bet) {
          amount = (g.potTotal() * 0.5).round().clamp(la.minAmount, la.maxAmount);
        }
        g.apply('hero', type, amount: amount);
      }
    }
    final m = max(1, faced);
    return (
      donk: n == 0 ? 0 : fire / n,
      raise: raised / m,
      call: called / m,
      fold: folded / m,
      n: faced,
    );
  }

  t('领先下注：大盲跟注后翻牌很少主动开火，强牌改成过牌-加注', () {
    const dry = 'Kd 8c 3h';
    final set = aiDonkRate('8h 8s', dry);
    final topPair = aiDonkRate('Kh Qh', dry);
    final straight = aiDonkRate('Jc 10c', 'Qh 9h 8c');
    final air = aiDonkRate('Qs Jd', '9s 5d 2c');
    String pct(double v) => '${(100 * v).round()}%';

    // 改前实测：三条 77% / 顶对 78% / 顺子（湿面）100% / 空气 15% 都领先
    // 下注。真人在这条线上以过牌为主——翻前加注者范围更强、还有位置，
    // donk 一被加注就很难受，强牌宁可留着过牌-加注。
    expect(straight.donk, lessThan(0.6),
        reason: '顺子在湿面不该每手都 donk（${pct(straight.donk)}）');
    expect(set.donk, lessThan(0.55),
        reason: '三条多数先过牌等过牌-加注（${pct(set.donk)}）');
    expect(topPair.donk, lessThan(0.6),
        reason: '顶对不该每手都领先下注（${pct(topPair.donk)}）');
    expect(air.donk, lessThan(0.15),
        reason: '空气别把 donk 变成「没牌才领先下注」（${pct(air.donk)}）');

    // 过牌不等于放弃这条街：没位置时的武器是过牌-加注。
    expect(set.raise, greaterThan(0.6),
        reason: '三条过牌后以过牌-加注为主（加 ${pct(set.raise)}，'
            'n=${set.n}），但也不是每手都加');
    expect(straight.raise, greaterThan(0.7),
        reason: '顺子过牌后要过牌-加注（加 ${pct(straight.raise)}，'
            'n=${straight.n}）——湿面上慢打本来就少，听牌愿意付钱');
    expect(topPair.raise, greaterThan(0.05),
        reason: '顶对也要留一点反击频率（加 ${pct(topPair.raise)}）');
    expect(topPair.call, greaterThan(topPair.raise),
        reason: '顶对主体还是跟注（跟 ${pct(topPair.call)}）');

    // 也不能一刀切成「永不领先下注」：真人会混一部分 donk 进来。
    expect(set.donk, greaterThan(0.12),
        reason: '强牌仍要留一部分领先下注（${pct(set.donk)}）');
    expect(straight.donk, greaterThan(0.15),
        reason: '顺子同理（${pct(straight.donk)}）');
  });

  /// 多人底池：AI 坐按钮（最后行动），英雄先下注、中间 [callers] 个人
  /// 依次跟注，量 AI 面对同一个下注时的选择。callers = 0 就是单挑。
  ({double fold, double call, double raise, double jam, int n})
      aiVsBetMultiway(String hole, String board,
          {int callers = 0, double frac = 0.5, int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, jam = 0, n = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI');
      final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
      g.addPlayer('hero', '我');
      for (var i = 0; i < callers; i++) {
        g.addPlayer('c$i', 'C$i');
      }
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3h 2c')},
        boardOverride: _cs(board),
      );
      var guard = 0;
      var recorded = false;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = g.currentBet > p.streetBet;
        if (p.id == 'ai') {
          final d = ai.decide(g, p);
          if (!recorded && facing && g.street == Street.flop) {
            recorded = true;
            n++;
            switch (d.type) {
              case ActionType.fold:
                fold++;
              case ActionType.call:
                call++;
              default:
                raise++;
                // 加注直接把筹码推光 = 走的是「低 SPR 套进去」那条分支。
                if (d.amountTo != null &&
                    d.amountTo! >= p.stack + p.streetBet) {
                  jam++;
                }
            }
            break;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        // 别人一律按「英雄能下注就下注、其余跟注」喂到 AI 面前。
        if (p.id == 'hero' &&
            !facing &&
            legal.any((a) => a.type == ActionType.bet)) {
          final la = legal.firstWhere((a) => a.type == ActionType.bet);
          g.apply(
              'hero',
              ActionType.bet,
              amount: (g.potTotal() * frac)
                  .round()
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        final want = legal.any((a) => a.type == ActionType.call)
            ? ActionType.call
            : ActionType.check;
        g.apply(p.id, want);
      }
    }
    return (
      fold: n == 0 ? 0 : fold / n,
      call: n == 0 ? 0 : call / n,
      raise: n == 0 ? 0 : raise / n,
      jam: n == 0 ? 0 : jam / n,
      n: n,
    );
  }

  /// 多人池：hero 在河牌按 [frac] 倍池先下注、中间几家全跟，量 AI 的应对。
  ///
  /// 专门盯「下注尺度要看**对手出手那一刻的池**」这条：分母里不扣掉中间那几家
  /// 跟注的钱，同一个 1.5 倍池的重注在三人池里会被读成「0.375 倍池的小注」，
  /// 靠尺度说话的那几档（河牌挑着弃、不拿一对反加）整条失效——改之前顶对顶踢
  /// 在三人池弃 0%（还会加注 5%）、四人池弃 0%，比单挑还松。
  ({double fold, double call, double raise, int total}) aiVsRiverBetMultiway(
      String hole, String board, double frac,
      {int callers = 0, int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      for (var i = 0; i < callers; i++) {
        g.addPlayer('c$i', 'C$i');
      }
      final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3h 2c')},
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
          if (!facing) break; // 英雄没下注（或还没下注）的手不算样本
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
        if (p.id == 'hero' &&
            g.street == Street.river &&
            !facing &&
            legal.any((a) => a.type == ActionType.bet)) {
          final la = legal.firstWhere((a) => a.type == ActionType.bet);
          g.apply(
              'hero',
              ActionType.bet,
              amount: (p.streetBet + (g.potTotal() * frac).round())
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        // 前面的街（和跟注的人）一律过牌/跟注，把底池留小、把人数留住。
        final want = facing ? ActionType.call : ActionType.check;
        g.apply(p.id, legal.any((a) => a.type == want) ? want : legal.first.type);
      }
    }
    double r(int v) => total == 0 ? 0 : v / total;
    return (fold: r(fold), call: r(call), raise: r(raise), total: total);
  }

  /// 单挑：AI 按钮开池 250、英雄跟注；翻后的街英雄一律过牌/跟注，到了
  /// [street] 英雄先下注 [frac] 池，统计 AI 面对这一注的应对。
  ///
  /// 和 aiVsCheckBet 的区别是「底池是加注过的、前面的街 AI 可以自由开火」，
  /// 更接近真实牌局里 AI 面对河牌下注的那个局面（底池大小会直接影响赔率）。
  ({double fold, double call, double raise, int total}) aiVsHeroBet(
      String hole, String board, double frac,
      {Street street = Street.flop, int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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
      g.apply('ai', ActionType.raise, amount: 250);
      g.apply('hero', ActionType.call);

      var guard = 0;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        if (pa.player.id == 'ai') {
          final d = ai.decide(g, pa.player);
          if (g.street == street && facing) {
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
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        if (g.street == street && !facing && legal.any((a) => a.type == ActionType.bet)) {
          final la = legal.firstWhere((a) => a.type == ActionType.bet);
          g.apply(
              'hero',
              ActionType.bet,
              amount: (g.potTotal() * frac)
                  .round()
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        final want = facing ? ActionType.call : ActionType.check;
        g.apply(
            'hero', legal.any((a) => a.type == want) ? want : ActionType.check);
      }
    }
    final n = total;
    double r(int v) => n == 0 ? 0 : v / n;
    return (fold: r(fold), call: r(call), raise: r(raise), total: n);
  }

  /// 单挑：英雄开池（溜入）、AI 补到 100，翻后 AI 先过牌、英雄按
  /// [frac] 池下注，统计 AI 在 [street] 面对下注的应对。
  ///
  /// 默认 [oop] = true：AI 坐大盲（没位置），这就是「过牌-加注」的那个
  /// 位置——AI 本街已经过了牌，再加注算过牌-加注。
  /// [oop] = false 时把按钮换给 AI（有位置），底池构成完全一样，只差位置，
  /// 用来对比同一个局面下有/没位置的差别。
  ({double fold, double call, double raise, int total}) aiVsCheckBet(
      String hole, String board, double frac,
      {Street street = Street.flop, int seeds = 150, bool oop = true}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('hero', '我')
        ..addPlayer('ai', 'AI');
      final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
      if (!oop) g.buttonIndex = 0; // startHand 里 +1 → 按钮换给 AI
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
            // 有位置的那一路让英雄过牌就好，两边底池构成一样（2bb），
            // 否则「翻前谁加注」会把范围强度也带进来，比不出位置的效果。
            if (oop) {
              g.apply('hero', ActionType.raise, amount: 300);
            } else {
              g.apply('hero', ActionType.check);
            }
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

  /// 单挑：AI 按钮开池 250、英雄跟注；翻牌英雄过牌，AI 一开火英雄就加注
  /// 到 AI 下注的 [mult] 倍（2.2 ≈ 最小加注，3.5 ≈ 正常加注），统计 AI
  /// 面对这个加注的应对。
  ///
  /// AI 自己过牌的那些手不算样本——量的是「我下注、被他加注」这个局面。
  ({double fold, double call, double raise, int total}) aiVsBetThenRaise(
      String hole, String board, double mult,
      {Street street = Street.flop, int seeds = 200}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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
        holeOverride: {'ai': _cs(hole), 'hero': _cs('4c 5d')},
        boardOverride: _cs(board),
      );
      g.apply('ai', ActionType.raise, amount: 250);
      g.apply('hero', ActionType.call);

      var guard = 0;
      var raised = false;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        if (pa.player.id == 'ai') {
          final d = ai.decide(g, pa.player);
          if (g.street == street && facing && raised) {
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
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        final canRaise = legal.any((a) => a.type == ActionType.raise);
        if (g.street == street && facing && !raised && canRaise) {
          raised = true;
          final la = legal.firstWhere((a) => a.type == ActionType.raise);
          g.apply(
              'hero',
              ActionType.raise,
              amount: (g.currentBet * mult)
                  .round()
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        final want = facing ? ActionType.call : ActionType.check;
        g.apply(
            'hero', legal.any((a) => a.type == want) ? want : ActionType.check);
      }
    }
    final n = total;
    double r(int v) => n == 0 ? 0 : v / n;
    return (fold: r(fold), call: r(call), raise: r(raise), total: n);
  }

  t('面对下注：中等牌/弱成牌也会过牌-加注，不再只会跟或弃', () {
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
    // 实测第二对约 4%（以前是 0%）——弱成牌的过牌-加注是纯诈唬，
    // 频率压在有位置那一侧的水平上就够了，阈值取 2% 留出余量。
    expect(secondPair.raise, greaterThan(0.02),
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
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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

  t('面对过牌-加注：第二对不再一路跟，超对会有一部分 3bet', () {
    // 以前 AI 面对「加注」也按对手的整条跟注范围算胜率，第二对 100%
    // 跟注；现在加注线会把对手范围收窄、跟注门槛也跟着抬。
    const flop = 'Kd 8c 3h';
    final topPair = aiVsCheckRaise('Kh Qh', flop, 3.0, seeds: 200);
    final overPair = aiVsCheckRaise('Ah Ad', flop, 3.0, seeds: 200);
    final secondPair = aiVsCheckRaise('8h 7s', flop, 3.0, seeds: 200);
    final set = aiVsCheckRaise('8h 8s', flop, 3.0, seeds: 200);
    String pct(double v) => '${(100 * v).round()}%';

    expect(secondPair.total, greaterThan(_trialSeeds(50)));
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
    expect(set.raise, greaterThan(0.45),
        reason: '三条还是以再加为主，不能被一次加注吓住（加 ${pct(set.raise)}）');
    // 但不能 100% 再加：以前三条面对加注是「无条件再加」（探针实测 100%），
    // 「他一再加就是有大家伙」整条线写在脸上，对手拿顶对、拿听牌都会老远
    // 就弃掉，我们反而收不到价值；加注战也越打越高，最后只剩能打败我们的
    // 牌愿意继续放筹码。真人在这儿慢打是常态。
    expect(set.raise, lessThan(0.9),
        reason: '怪兽牌要有一部分慢打（加 ${pct(set.raise)} '
            '跟 ${pct(set.call)}）');

    // 尺度别一刀切：最小加注（约 2 倍）给的赔率好得多，第二对该多跟一些。
    final minRaise = aiVsCheckRaise('8h 7s', flop, 1.5, seeds: 200);
    expect(minRaise.fold, lessThan(secondPair.fold - 0.15),
        reason: '小加注不该弃得跟三倍加注一样多 '
            '（弃 ${pct(minRaise.fold)} vs ${pct(secondPair.fold)}）');
  });

  t('被加注：加注越大弃得越多，中间不许卡在布尔开关上', () {
    // 「我下注、被他加注」这条线上的门槛按加注量缩放，但缩放项里夹着两道
    // 布尔（[AiPlayer._facingBet] 的 `betSizeRel <= 0.6 ? 1.65 : 1.85`、
    // [AiPlayer._bluffRaiseChance] 的 `>= 0.8 ? 0.2 : 0.45`）。探针
    // （tool/ai_probe.dart 的「面对加注」一节：AI 先开一枪、英雄按池的 frac
    // 倍加回来，0.54~0.66 每 2% 池一格）量下来没有出现台阶，这里把它升级成
    // 门禁：第二对 87 被加注的弃牌率必须一路单调爬上去，任何一档都不许
    // 一步跳掉一大半（那正是「门槛挂到布尔上」的形状）。
    // 实测（200 手/点）：加注到 1.5 / 2 / 2.5 / 3 / 4 倍 → 弃
    // 0% / 0% / 9% / 50% / 96%。
    const flop = 'Kd 8c 3h';
    final curve = [
      for (final r in [1.5, 2.0, 2.5, 3.0, 4.0])
        aiVsCheckRaise('8h 7s', flop, r, seeds: 200),
    ];
    String pct(double v) => '${(100 * v).round()}%';
    expect(curve.first.total, greaterThan(_trialSeeds(50)),
        reason: '样本要够（${curve.first.total}）');
    // 最小加注给的价格好，第二对按赔率本来就够跟——这一端不该有弃牌。
    expect(curve.first.fold, lessThan(0.05),
        reason: '最小加注就让第二对弃牌（弃 ${pct(curve.first.fold)}）');
    // 真下重手的那一端要能脱身。
    expect(curve.last.fold, greaterThan(0.8),
        reason: '4 倍加注还不弃（弃 ${pct(curve.last.fold)}）');
    for (var i = 1; i < curve.length; i++) {
      expect(curve[i].fold, greaterThan(curve[i - 1].fold - 0.06),
          reason: '加注量变大反而弃得少（第 $i 档：'
              '${pct(curve[i - 1].fold)} → ${pct(curve[i].fold)}）');
      expect(curve[i].fold - curve[i - 1].fold, lessThan(0.6),
          reason: '这一档一步跳掉一大半（第 $i 档：'
              '${pct(curve[i - 1].fold)} → ${pct(curve[i].fold)}）——'
              '门槛又挂到某个布尔开关上了？');
    }
  });

  t('加注战：单街已经加过一手之后，空气不许再往上顶', () {
    // 单街「第 2 次加注」就是「我 c-bet、被他加注，我在考虑 3-bet」。
    // 空气在这儿往上顶是纯送：对手的范围已经是「愿意把筹码放进去」的，
    // 弃牌率极低，我们后面还有两条街要挨打。以前 AI 的诈唬加注、阻挡注
    // 反击、听牌半诈唬三条路都没有「这条街已经加过多少次」的闸门，
    // 探针实测（3 个种子 × 3000 手）单街第 3 次以上的加注里有 8.8% 是
    // 弱成牌/听牌——拿一对小牌甚至一把没成的听牌去做 4-bet，修完是 0。
    // 同时单街第 1 次加注的诈唬/半诈唬频率要基本不变，不能一刀切禁加。
    const flop = 'Kd 8c 3h';
    final air = aiVsCheckRaise('Qs Js', flop, 3.0, seeds: 200);
    expect(air.total, greaterThan(_trialSeeds(50)),
        reason: '样本要够（${air.total}）');
    expect(air.raise, 0,
        reason: '空气面对过牌-加注一次都不该再加 '
            '（加 ${(100 * air.raise).round()}%）');
    // 真牌照常 3-bet，闸门不是「谁都不许再加」。
    final overPair = aiVsCheckRaise('Ah Ad', flop, 3.0, seeds: 200);
    expect(overPair.raise, greaterThan(0.1),
        reason: '超对要有一部分 3bet（加 ${(100 * overPair.raise).round()}%）');
    // 听牌半诈唬（「听牌转诈唬」那条线）也不能被顺手砍掉：成花听面对
    // 一次加注依然要有一部分再加，不然加注范围里只剩成牌，一眼能读。
    final draw = aiVsCheckRaise('Qh Jh', 'Kh 8c 3h', 3.0, seeds: 200);
    expect(draw.raise, greaterThan(0.0),
        reason: '听牌面对一次加注还要保留半诈唬（加 ${(100 * draw.raise).round()}%）');
  });

  t('怪兽牌被加注：慢打要有，但湿面比干面加得多', () {
    // 被加注之后的再加注是**两极**的：要么他真有大家伙，要么他在诈唬。
    // 手里握着怪兽牌时，再加一次等于把对手范围里的诈唬和中等牌全部打走，
    // 留下的只有能打败我们的那一小撮——加注的收益全在「他弃牌」上，可我们
    // 手里恰恰是希望他继续留在底池里的牌。所以真人在这儿的慢打很常见，
    // 而慢打多少要看「加注保护得到什么」：干面上再加保护不到任何东西、
    // 还把牌力写得清清楚楚；湿面上听牌愿意付钱，就该收这一笔。
    String pct(double v) => '${(100 * v).round()}%';
    // 同一个牌面：88 中三条（干面 0.00），A♥K♥ 中坚果花（湿面 0.65）。
    final drySet = aiVsCheckRaise('8h 8s', 'Kd 8c 3h', 3.0, seeds: 200);
    final dryFlush = aiVsCheckRaise('Ah Kh', 'Qh Jh 2h', 3.0, seeds: 200);
    final wetFlush = aiVsCheckRaise('Ah Kh', '9h 8h 7h', 3.0, seeds: 200);
    expect(drySet.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(dryFlush.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(wetFlush.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    for (final r in [drySet, dryFlush, wetFlush]) {
      expect(r.fold, lessThan(0.05),
          reason: '怪兽牌不会弃给一次加注（弃 ${pct(r.fold)}）');
      expect(r.call, greaterThan(0.05),
          reason: '要有一档慢打（跟 ${pct(r.call)}）');
    }
    expect(wetFlush.raise, greaterThan(dryFlush.raise + 0.08),
        reason: '湿面上听牌愿意付钱，要收这一笔'
            '（湿面加 ${pct(wetFlush.raise)} vs 干面 ${pct(dryFlush.raise)}）');
    expect(wetFlush.call, lessThan(dryFlush.call - 0.08),
        reason: '干面上再把对手打走就没得打了'
            '（干面跟 ${pct(dryFlush.call)} vs 湿面 ${pct(wetFlush.call)}）');
  });

  t('怪兽牌面对下注：干面留一档慢打，湿面还是以加为主', () {
    // 中了大牌之后「加还是跟」也是会被读的线。以前干面湿面、翻牌河牌
    // 全都是「跟 11% / 加 89%」，同一个数字走到底——对手拿顶对、拿听牌
    // 看到我们一加就弃，我们反而收不到价值；而且这条线跟牌面完全脱钩，
    // 等于把「加注 = 我有大家伙」写在了脸上。
    String pct(double v) => '${(100 * v).round()}%';
    final drySet = aiVsFlopBet('8h 8s', 'Ks 8c 3d', 0.66);
    // 同一手牌（A♥K♥），只差牌面：Q♥J♥2♥ 是「两张同花 + 高张」的普通面（0.35），
    // 9♥8♥7♥ 是三张同花＋两头顺的湿面（0.65）。
    final dryFlush = aiVsFlopBet('Ah Kh', 'Qh Jh 2h', 0.66);
    final wetFlush = aiVsFlopBet('Ah Kh', '9h 8h 7h', 0.66);
    expect(drySet.n, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(dryFlush.n, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(wetFlush.n, greaterThan(_trialSeeds(50)), reason: '样本要够');
    for (final r in [drySet, dryFlush, wetFlush]) {
      expect(r.fold, lessThan(0.02),
          reason: '怪兽牌不会弃给一次下注（弃 ${pct(r.fold)}）');
      expect(r.raise, greaterThan(r.call),
          reason: '主体还是加注（加 ${pct(r.raise)} 跟 ${pct(r.call)}）');
    }
    expect(drySet.call, greaterThan(0.2),
        reason: '干面上加注保护不到东西，要留一档慢打'
            '（跟 ${pct(drySet.call)}）');
    expect(wetFlush.raise, greaterThan(dryFlush.raise + 0.08),
        reason: '湿面上听牌愿意付钱，就该收这一笔'
            '（湿面加 ${pct(wetFlush.raise)} vs 干面 ${pct(dryFlush.raise)}）');
    expect(wetFlush.call, lessThan(dryFlush.call - 0.08),
        reason: '湿面上慢打明显变少'
            '（干面跟 ${pct(dryFlush.call)} vs 湿面 ${pct(wetFlush.call)}）');
  });

  /// 单挑：AI 按钮位开 3bb、英雄跟注；翻牌/转牌双方都过牌，河牌英雄下
  /// [frac] 倍池，统计 AI 的反应（其余街全部钉死）。这就是
  /// tool/ai_probe.dart「怪兽牌」那一节的量法：翻前钉住之后底池只剩河牌
  /// 那一注，SPR 固定在 11 上下，量到的就只剩「成色 × 尺度 → 加注率」。
  ({double fold, double call, double raise, int total}) aiVsRiverBetScripted(
      String hole, String board, double frac, {int seeds = 1000}) {
    var fold = 0, call = 0, raise = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          if (g.street == Street.preflop) {
            g.apply('ai', ActionType.raise, amount: 300);
            continue;
          }
          if (g.street != Street.river) {
            g.apply('ai', ActionType.check);
            continue;
          }
          final d = ai.decide(g, p);
          if (!facing) break; // 英雄没下注的手不算样本
          total++;
          switch (d.type) {
            case ActionType.fold:
              fold++;
            case ActionType.call:
              call++;
            default:
              raise++;
          }
          break; // 量到河牌这一下就够，后面的街不用打完
        }
        if (g.street == Street.preflop) {
          g.apply('hero', ActionType.call);
          continue;
        }
        if (g.street != Street.river) {
          g.apply('hero', ActionType.check);
          continue;
        }
        if (!facing && legal.any((a) => a.type == ActionType.bet)) {
          final la = legal.firstWhere((a) => a.type == ActionType.bet);
          final pot = g.potTotal();
          g.apply('hero', ActionType.bet,
              amount: (p.streetBet + (pot * frac).round())
                  .clamp(la.minAmount, la.maxAmount));
          continue;
        }
        g.apply('hero', canCheck ? ActionType.check : ActionType.call);
      }
    }
    final n = total;
    double r(int v) => n == 0 ? 0 : v / n;
    return (fold: r(fold), call: r(call), raise: r(raise), total: n);
  }

  /// 同一个局面（AI 按钮开 3bb、英雄跟、翻牌/转牌都过牌），但河牌英雄
  /// **过牌**：量 AI 主动下注的尺码分布。超池那条线（[AiPlayer] 里 1.2 倍
  /// 池那一下）是不是只留给坚果级的牌，就看这一格。
  ({double check, double overbet, double value, int total})
      aiRiverOverbetScripted(String hole, String board, {int seeds = 600}) {
    var check = 0, overbet = 0, value = 0, total = 0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          if (g.street == Street.preflop) {
            g.apply('ai', ActionType.raise, amount: 300);
            continue;
          }
          if (g.street != Street.river) {
            g.apply('ai', ActionType.check);
            continue;
          }
          final potBefore = g.potTotal();
          final d = ai.decide(g, p);
          if (!recorded) {
            recorded = true;
            total++;
            if (d.type == ActionType.check || d.type == ActionType.fold) {
              check++;
            } else {
              final frac = ((d.amountTo ?? 0) - p.streetBet) / potBefore;
              if (frac >= 1.0) {
                overbet++;
              } else {
                value++;
              }
            }
          }
          g.apply('ai', d.type, amount: d.amountTo);
          break;
        }
        if (g.street == Street.preflop) {
          g.apply('hero', ActionType.call);
          continue;
        }
        g.apply('hero', canCheck ? ActionType.check : ActionType.call);
      }
    }
    final n = total;
    double r(int v) => n == 0 ? 0 : v / n;
    return (check: r(check), overbet: r(overbet), value: r(value), total: n);
  }

  t('三张同花面：顺子/三条/两对弃得比顶对少，不能是同一条线', () {
    // [HandTier] 只有五档，[_tierOf] 把三张同花面上的顺子/三条/两对整档降到
    // 强牌，注释里写的意图是「以跟注为主、不会无脑打光」。可强牌那一档在
    // 河牌还挂着一条 strongFoldVsBigBet（注越大弃得越多）——降档的副作用是
    // 这些牌跟顶对顶踢共用同一条弃牌线。探针实测三张方片牌面上面对 1.5 倍池：
    // 顺子弃 56%、三条弃 57%、两对弃 52%，顶对顶踢弃 58%，四档几乎一样。
    // 顺子已经打赢了对手范围里的两对/三条/顶对，真人不会拿它像顶对那样弃。
    const flushBoard = 'Qd 7d 2c 5h 3d';
    String pct(double v) => '${(100 * v).round()}%';
    ({double fold, double call, double raise, int total}) at(String hole) =>
        aiVsRiverBetScripted(hole, flushBoard, 1.5, seeds: 600);
    final straight = at('6h 4h'); // 3-4-5-6-7 顺子
    final set = at('7h 7s'); // 三条
    final twoPair = at('Qs 7c'); // 两对
    final topPair = at('As Qh'); // 顶对顶踢
    for (final (name, r) in [
      ('顺子', straight),
      ('三条', set),
      ('两对', twoPair),
      ('顶对顶踢', topPair),
    ]) {
      expect(r.total, greaterThan(_trialSeeds(50)),
          reason: '$name 样本要够（${r.total}）');
    }
    // 四档按成色排开：顺子 < 三条 < 两对 < 顶对顶踢。相邻两档实测只差
    // 4~7 个点，所以那两处只留 0.02 的余量（够挡住种子抖动，塌回同一档
    // 一定报红）；和顶对之间差得远，留 0.05 的实打实余量。
    expect(straight.fold, lessThan(set.fold + 0.02),
        reason: '顺子该比三条更敢跟（顺子弃 ${pct(straight.fold)} '
            'vs 三条弃 ${pct(set.fold)}）');
    expect(set.fold, lessThan(twoPair.fold + 0.02),
        reason: '三条该比两对更敢跟（三条弃 ${pct(set.fold)} '
            'vs 两对弃 ${pct(twoPair.fold)}）');
    expect(twoPair.fold, lessThan(topPair.fold - 0.05),
        reason: '两对和顶对也要分开（两对弃 ${pct(twoPair.fold)} '
            'vs 顶对顶踢弃 ${pct(topPair.fold)}）');
    // 降档的意图是「跟注为主」，所以这三手都必须过半数跟注。
    for (final (name, r) in [
      ('顺子', straight),
      ('三条', set),
      ('两对', twoPair),
    ]) {
      expect(r.call, greaterThan(0.55),
          reason: '$name 在三张同花面上要以跟注为主（跟 ${pct(r.call)}）');
    }
    // 但降档也没被抹平：成花还是照旧压着它们（成花从不弃）。
    final flush = at('Ad Kd');
    expect(flush.fold, lessThan(0.02),
        reason: '成花不会弃给一注（弃 ${pct(flush.fold)}）');
    expect(flush.call + flush.raise,
        greaterThan(straight.call + straight.raise + 0.15),
        reason: '成花仍要压过顺子一线'
            '（成花 ${pct(flush.call + flush.raise)} '
            'vs 顺子 ${pct(straight.call + straight.raise)}）');
  });

  t('强牌档内部：河牌面对超池，超对不能跟顶对顶踢一起弃', () {
    // [HandTier.strong] 把超对和顶对顶踢装成一档，而 AI 的强牌分支只看 tier：
    // [HandReading.overPair] 这个字段算出来了，可很长一段时间里除了
    // verify_engine 那句断言之外没人读它。于是同一块 Q♥7♦2♣5♥9♠ 面对 1.5 倍池，A♥Q♦
    // （顶对顶踢）和 K♥K♠（超对）走的是同一条弃牌线——拿超对跟顶对一起弃
    // 超池。超对打赢顶对（对手拿顶对就是被我们盖住），真人这两手不是一个
    // 打法：顶对顶踢面对超池以抓诈唬为主，超对是敢跟的那一手。
    const board = 'Qh 7d 2c 5h 9s';
    String pct(double v) => '${(100 * v).round()}%';
    ({double fold, double call, double raise, int total}) at(
            String hole, double frac) =>
        aiVsRiverBetScripted(hole, board, frac, seeds: 600);
    final topPair = at('Ah Qd', 1.5);
    final overPair = at('Kh Ks', 1.5);
    for (final (name, r) in [('顶对顶踢', topPair), ('超对', overPair)]) {
      expect(r.total, greaterThan(_trialSeeds(50)),
          reason: '$name 样本要够（${r.total}）');
    }
    // 主断言：1.5 倍池上超对要明显比顶对敢跟。实测 24 个点（顶对弃 39%
    // vs 超对弃 15%），所以留 0.12 的余量——塌回同一条线（两档相等）必报红。
    expect(overPair.fold, lessThan(topPair.fold - 0.12),
        reason: '超对不该跟顶对顶踢一起弃超池'
            '（超对弃 ${pct(overPair.fold)} vs 顶对弃 ${pct(topPair.fold)}）');
    expect(overPair.call, greaterThan(topPair.call + 0.12),
        reason: '超对该比顶对更多地跟注超池'
            '（超对跟 ${pct(overPair.call)} vs 顶对跟 ${pct(topPair.call)}）');
    // 超对也不是无脑跟：面对 1.5 倍池还得留一部分弃牌，不然对手拿两对以上
    // 随便超池就能白拿价值。
    expect(overPair.fold, greaterThan(0.05),
        reason: '超对也不是对超池照单全收（弃 ${pct(overPair.fold)}）');
    // 这条线只挂在「面对重注」上：一个底池那一档差别小（实测 13% vs 5%），
    // 半池那一档两边都基本只跟/加，超对没有变成另一套激进范围。
    final topPairPot = at('Ah Qd', 1.0);
    final overPairPot = at('Kh Ks', 1.0);
    expect(overPairPot.fold, lessThan(topPairPot.fold + 0.02),
        reason: '一个底池上超对至少不该比顶对弃得多'
            '（超对弃 ${pct(overPairPot.fold)} vs 顶对弃 '
            '${pct(topPairPot.fold)}）');
    for (final (name, hole) in [('顶对顶踢', 'Ah Qd'), ('超对', 'Kh Ks')]) {
      final small = at(hole, 0.5);
      expect(small.fold, lessThan(0.03),
          reason: '$name 对半池不该弃（弃 ${pct(small.fold)}）');
      expect(small.call + small.raise, greaterThan(0.9),
          reason: '$name 对半池要接着打（跟+加 ${pct(small.call + small.raise)}）');
    }
  });

  t('强牌档内部：翻牌被加注，超对比顶对顶踢更敢 3-bet', () {
    // 翻牌「自己下注 → 被对手加注」这条线。顶对顶踢加回去只被更好的牌跟，
    // 真人以跟为主；超对打赢对手范围里的顶对，照样会把一部分筹码推回去。
    // 可 [HandReading.overPair] 除了 verify_engine 那句断言一直没人读，探针实测
    // 翻牌拿 A♥Q♦ 和 K♥K♠ 面对同一个加注**逐字相同**（跟注 96%、再加 5%）。
    //
    // [AiPlayer._overPairFlopRaiseBonus] 给超对在翻牌被加注时加了一点 3-bet
    // 频率。这里钉住两件事：这一档要分开、而且不能顶到「见加注就推」。
    String pct(double v) => '${(100 * v).round()}%';
    for (final (mult, margin) in [(2.2, 0.05), (3.5, 0.04)]) {
      final topPair =
          aiVsBetThenRaise('Ah Qd', 'Qh 7d 2c', mult, seeds: 600);
      final overPair =
          aiVsBetThenRaise('Kh Ks', 'Qh 7d 2c', mult, seeds: 600);
      for (final (name, r) in [('顶对顶踢', topPair), ('超对', overPair)]) {
        expect(r.total, greaterThan(_trialSeeds(50)),
            reason: '$name 样本要够（${r.total}）');
      }
      expect(overPair.raise, greaterThan(topPair.raise + margin),
          reason: '翻牌被加到 $mult 倍，超对该比顶对顶踢更敢 3-bet'
              '（超对加 ${pct(overPair.raise)} vs 顶对加 ${pct(topPair.raise)}）');
      expect(overPair.raise, lessThan(0.55),
          reason: '翻牌被加到 $mult 倍，超对也不能见加注就推'
              '（超对加 ${pct(overPair.raise)}）');
      expect(overPair.fold, lessThan(0.05),
          reason: '翻牌被加注，超对不该弃（弃 ${pct(overPair.fold)}）');
    }
  });

  t('强牌档内部：翻牌面对下注，超对也比顶对顶踢更敢加', () {
    // 上一轮把「翻牌被加注」那条线分开了，可同一块 Q♥7♦2♣ 上**面对一注**
    // 那一格还是逐字相同：A♥Q♦（顶对顶踢）和 K♥K♠（超对）面对半池都是
    // 跟 57%、加 42%。超对打赢对手范围里的顶对，理论上该加得更多。
    //
    // 顶对顶踢那一侧不能往下压——门禁用例「3bet 底池：强牌面对下注留一点
    // 加注」钉着「单加池里顶对顶踢照样要加（>35%）」。所以只能在超对这
    // 一侧加量（[AiPlayer._overPairFlopRaiseBonus]，面对一注 0.08）。
    String pct(double v) => '${(100 * v).round()}%';
    for (final frac in [0.33, 0.5, 1.0]) {
      final top = aiVsFlopBet('Ah Qd', 'Qh 7d 2c', frac);
      final over = aiVsFlopBet('Kh Ks', 'Qh 7d 2c', frac);
      for (final (name, r) in [('顶对顶踢', top), ('超对', over)]) {
        expect(r.n, greaterThan(_trialSeeds(100)),
            reason: '$name 样本要够（${r.n}）');
        expect(r.fold, lessThan(0.03),
            reason: '$name 面对一注不该弃（弃 ${pct(r.fold)}）');
      }
      expect(over.raise, greaterThan(top.raise + 0.05),
          reason: '面对 $frac 池，超对该比顶对顶踢更敢加'
              '（超对加 ${pct(over.raise)} vs 顶对加 ${pct(top.raise)}）');
      expect(over.call, lessThan(top.call),
          reason: '面对 $frac 池，超对该更少纯跟'
              '（超对跟 ${pct(over.call)} vs 顶对跟 ${pct(top.call)}）');
    }
    // 加量没把超对变成「见注就加」：小注那一档也得留一部分跟注，
    // 大注那一档照样收手。
    final tiny = aiVsFlopBet('Kh Ks', 'Qh 7d 2c', 0.33);
    final big = aiVsFlopBet('Kh Ks', 'Qh 7d 2c', 1.0);
    expect(tiny.raise, lessThan(0.85),
        reason: '对 1/3 池超对也别加到见注就加（加 ${pct(tiny.raise)}）');
    expect(tiny.call, greaterThan(0.1),
        reason: '对 1/3 池超对也要留跟注（跟 ${pct(tiny.call)}）');
    expect(big.raise, lessThan(tiny.raise - 0.3),
        reason: '尺度越大加得越少这条线对超对也要成立'
            '（1/3 池加 ${pct(tiny.raise)} → 满池加 ${pct(big.raise)}）');
  });

  t('强牌档内部：转牌面对下注，超对也比顶对顶踢更敢加', () {
    // 上面两格把翻牌和河牌分开了（[AiPlayer._overPairFlopRaiseBonus]），
    // 可加成只挂翻牌时，转牌这一格又塌回一条线：同一块 Q♥7♦2♣5♥ 上，
    // A♥Q♦（顶对顶踢）和 K♥K♠（超对）面对 1/3 池和半池都是逐字相同。
    // 转牌的优势本来比翻牌小（加的幅度也收了一档：翻牌 0.08、转牌 0.06），
    // 但两档不能又变成同一个数——对手看到转牌加注就能读出我们手里是哪一档。
    String pct(double v) => '${(100 * v).round()}%';
    for (final frac in [0.33, 0.5, 1.0]) {
      final top = aiVsTurnBet('Ah Qd', 'Qh 7d 2c 5h', frac);
      final over = aiVsTurnBet('Kh Ks', 'Qh 7d 2c 5h', frac);
      for (final (name, r) in [('顶对顶踢', top), ('超对', over)]) {
        expect(r.n, greaterThan(_trialSeeds(150)),
            reason: '$name 样本要够（${r.n}）');
      }
      // 相邻两档实测差 4~7 个点，跟「三张同花面」那条一样只留 0.02 的余量：
      // 够挡住种子/事件流的抖动，塌回同一档一定报红。
      expect(over.raise, greaterThan(top.raise + 0.02),
          reason: '转牌面对 $frac 池，超对该比顶对顶踢更敢加'
              '（超对加 ${pct(over.raise)} vs 顶对加 ${pct(top.raise)}）');
      expect(over.fold, lessThan(0.05),
          reason: '转牌面对 $frac 池，超对不该弃（弃 ${pct(over.fold)}）');
      expect(over.fold, lessThan(top.fold + 0.02),
          reason: '转牌面对 $frac 池，超对至少不该比顶对弃得多'
              '（超对弃 ${pct(over.fold)} vs 顶对弃 ${pct(top.fold)}）');
    }
    // 加量没把转牌的超对变成「见注就加」，也没把尺度那条线拉平。
    final tiny = aiVsTurnBet('Kh Ks', 'Qh 7d 2c 5h', 0.33);
    final big = aiVsTurnBet('Kh Ks', 'Qh 7d 2c 5h', 1.0);
    expect(tiny.raise, lessThan(0.6),
        reason: '转牌对 1/3 池超对也别加到见注就加（加 ${pct(tiny.raise)}）');
    expect(big.raise, lessThan(tiny.raise - 0.25),
        reason: '尺度越大加得越少这条线对超对也要成立'
            '（1/3 池加 ${pct(tiny.raise)} → 满池加 ${pct(big.raise)}）');
  });

  t('强牌档内部的听牌：顶对 + 坚果花听比纯顶对更爱加注', () {
    // [HandTier.strong] 把「顶对顶踢」和「顶对顶踢 + 坚果花听」装成一档，
    // 而强牌分支的两条线（下注尺度走 [_valueFrac]、加注频率走
    // [_strongRaiseChance]）都只看 tier、没读 [HandReading.hasDraw]：探针实测
    // 同一块 Q♦7♦2♣ 上 A♦Q♦ 和 A♠Q♦（只差底牌花色，牌面逐字相同）三格读数
    // **逐字相同**，连下注频率都一模一样。真人拿顶对 + 坚果花听被跟了还有一条
    // 街的出路，加回去的频率明显更高。现在这格差落在
    // [AiPlayer._strongDrawRaiseBonus] 和 [AiPlayer._strongDrawSizeScale]。
    //
    // 两手必须同牌面只换底牌：A♠Q♦（一张方片）才刚好没有花听，换牌面就等于
    // 同时改了纹理，差的就不再只是「有没有听牌」这一个变量。
    String pct(double v) => '${(100 * v).round()}%';
    // 实测（600 手）：面对 1/3 池纯顶对加 65%、顶对 + 坚果花听加 71%，
    // 差 6 个点，所以留 0.03 的余量——塌回同一条线（两档相等）必报红。
    for (final (frac, margin) in [(0.33, 0.03), (0.5, 0.03)]) {
      final plain = aiVsFlopBet('As Qd', 'Qd 7d 2c', frac, seeds: 600);
      final draw = aiVsFlopBet('Ad Qd', 'Qd 7d 2c', frac, seeds: 600);
      for (final (name, r) in [('纯顶对', plain), ('顶对+坚果花听', draw)]) {
        expect(r.n, greaterThan(_trialSeeds(100)),
            reason: '$name 样本要够（${r.n}）');
        expect(r.fold, lessThan(0.05),
            reason: '$name 面对一注不该弃（弃 ${pct(r.fold)}）');
      }
      expect(draw.raise, greaterThan(plain.raise + margin),
          reason: '面对 $frac 池，顶对 + 坚果花听该比纯顶对更敢加'
              '（听牌加 ${pct(draw.raise)} vs 纯顶对加 ${pct(plain.raise)}）');
      expect(draw.call, lessThan(plain.call),
          reason: '面对 $frac 池，听牌那一侧该更少纯跟'
              '（听牌跟 ${pct(draw.call)} vs 纯顶对跟 ${pct(plain.call)}）');
    }
    // 转牌也得分：加的幅度是收了一档（翻牌 0.06、转牌 0.05），但不能又塌成
    // 同一个数——对手看到转牌加注就能读出我们手里是不是带听牌。
    final turnPlain = aiVsTurnBet('As Qd', 'Qd 7d 2c 5h', 0.5, seeds: 600);
    final turnDraw = aiVsTurnBet('Ad Qd', 'Qd 7d 2c 5h', 0.5, seeds: 600);
    expect(turnDraw.n, greaterThan(_trialSeeds(100)),
        reason: '转牌样本要够（${turnDraw.n}）');
    // 转牌加的幅度收了一档（0.05），实测差 4 个点上下，余量跟着收到 0.02。
    expect(turnDraw.raise, greaterThan(turnPlain.raise + 0.02),
        reason: '转牌面对半池，顶对 + 坚果花听也要比纯顶对更敢加'
            '（听牌加 ${pct(turnDraw.raise)} vs 纯顶对加 '
            '${pct(turnPlain.raise)}）');
    // 加成没把这手变成「见注就加」，尺度越大加得越少那条线也还在。
    final tiny = aiVsFlopBet('Ad Qd', 'Qd 7d 2c', 0.33, seeds: 600);
    final big = aiVsFlopBet('Ad Qd', 'Qd 7d 2c', 1.0, seeds: 600);
    expect(tiny.raise, lessThan(0.8),
        reason: '对 1/3 池也别加到见注就加（加 ${pct(tiny.raise)}）');
    expect(big.raise, lessThan(tiny.raise - 0.25),
        reason: '尺度越大加得越少这条线对听牌也要成立'
            '（1/3 池加 ${pct(tiny.raise)} → 满池加 ${pct(big.raise)}）');
  });

  t('怪兽牌成色：河牌被过牌到，超池只留给三条/顺子', () {
    // 超池（1.2 倍池）是「坚果或空气」的尺寸：AI 的诈唬那一侧只有坚果花
    // 阻断 / A 阻断那条线会用它（见 [AiPlayer] 里那段纯诈唬的分支），
    // 价值这一侧以前却只看 tier——探针实测河牌被过牌到，拿两对、三条、
    // 顺子的下注分布**逐字相同**（超池桶都占 38%）。真人拿薄两对在河牌
    // 做的是正常尺寸的价值注，超池是拿它去撞两对以上的范围。
    const board = 'Qh 9d 7c 5h 2s';
    String pct(double v) => '${(100 * v).round()}%';
    final twoPair = aiRiverOverbetScripted('9h 7d', board);
    final set = aiRiverOverbetScripted('9h 9c', board);
    final straight = aiRiverOverbetScripted('8h 6h', board);
    for (final (name, r) in [
      ('两对', twoPair),
      ('三条', set),
      ('顺子', straight),
    ]) {
      expect(r.total, greaterThan(_trialSeeds(50)),
          reason: '$name 样本要够（${r.total}）');
    }
    expect(twoPair.overbet, lessThan(set.overbet - 0.08),
        reason: '两对不该跟三条一样乱超池'
            '（两对超池 ${pct(twoPair.overbet)} vs 三条超池 ${pct(set.overbet)}）');
    expect(set.overbet, lessThan(straight.overbet - 0.05),
        reason: '三条和顺子也要分档'
            '（三条超池 ${pct(set.overbet)} vs 顺子超池 ${pct(straight.overbet)}）');
    // 分档不是「薄怪物不许下注」：两对还是得做正常尺寸的价值注，
    // 顺子也要有正常尺寸那一半，不然尺度就变回一条明线。
    expect(twoPair.value, greaterThan(twoPair.overbet),
        reason: '两对要以正常尺寸的价值注为主'
            '（正常 ${pct(twoPair.value)} vs 超池 ${pct(twoPair.overbet)}）');
    for (final (name, r) in [
      ('两对', twoPair),
      ('三条', set),
      ('顺子', straight),
    ]) {
      expect(r.value, greaterThan(0.2),
          reason: '$name 还是要有一部分正常尺寸的价值注（${pct(r.value)}）');
    }
  });

  t('怪兽牌成色：河牌面对大注，两对比三条/顺子更收手', () {
    // [HandTier.monster] 只有一档，把两对、三条、顺子、同花、葫芦全压在一起，
    // 而 AI 的怪兽分支以前只吃 tier、看不到 category：探针实测河牌拿 99
    // （三条）和拿 97（两对）对着 1.5 倍池的读数**逐字相同**（跟 62% / 加
    // 38%）——对手从「他加不加」里读不出我们拿着哪一档，我们自己也拿薄两对
    // 跟三条一样猛。真人拿两对面对超池更接近抓诈唬，拿三条/顺子是敢把筹码
    // 放进去的那一手。
    //
    // 同一个牌面 Q♥9♦7♣5♥2♠，只换底牌：
    //   9h 7d = 两对、9h 9c = 三条(set)、8h 6h 补成 5-6-7-8-9 顺子。
    const board = 'Qh 9d 7c 5h 2s';
    String pct(double v) => '${(100 * v).round()}%';
    final twoPair = aiVsRiverBetScripted('9h 7d', board, 1.5);
    final set = aiVsRiverBetScripted('9h 9c', board, 1.5);
    final straight = aiVsRiverBetScripted('8h 6h', board, 1.5);
    for (final (name, r) in [
      ('两对', twoPair),
      ('三条', set),
      ('顺子', straight),
    ]) {
      expect(r.total, greaterThan(_trialSeeds(50)),
          reason: '$name 样本要够（${r.total}）');
      expect(r.fold, lessThan(0.05),
          reason: '怪兽牌不会弃给一次下注（$name 弃 ${pct(r.fold)}）');
    }
    expect(twoPair.raise, lessThan(set.raise - 0.05),
        reason: '两对不该跟三条一样猛'
            '（两对加 ${pct(twoPair.raise)} vs 三条加 ${pct(set.raise)}）');
    expect(set.raise, lessThan(straight.raise - 0.03),
        reason: '三条和顺子也要分档'
            '（三条加 ${pct(set.raise)} vs 顺子加 ${pct(straight.raise)}）');
    // 分档不是把两对钉成「永不加注」：小注照样要收价值，而且尺度越大加得
    // 越少这条线（三档成色各自）都得成立。
    final twoPairSmall = aiVsRiverBetScripted('9h 7d', board, 0.5);
    expect(twoPairSmall.raise, greaterThan(twoPair.raise + 0.1),
        reason: '两对对着半池还是要加注收价值'
            '（半池加 ${pct(twoPairSmall.raise)} vs 1.5 倍池加 '
            '${pct(twoPair.raise)}）');
    for (final (name, small, big) in [
      ('两对', twoPairSmall, twoPair),
      ('三条', aiVsRiverBetScripted('9h 9c', board, 0.5), set),
      ('顺子', aiVsRiverBetScripted('8h 6h', board, 0.5), straight),
    ]) {
      expect(big.raise, lessThan(small.raise - 0.1),
          reason: '$name 的加注率要随尺度往下走'
              '（半池加 ${pct(small.raise)} → 1.5 倍池加 ${pct(big.raise)}）');
    }
  });

  t('面对加注：最小加注不该交牌，重加注照样收手', () {
    // 加注的代价要看「加得多大」：最小加注只多花约 0.4 倍池（赔率反而更好），
    // 底对/第二对按赔率本来就够跟；重加注（≈1 倍池起）才是「一抬就送」。
    // 以前不分大小一律乘 1.85，探针里底对面对最小加注弃 77%、第二对转牌
    // 弃 55%——对手随便拿两张牌最小加注一下就能白拿底池。
    String pct(double v) => '${(100 * v).round()}%';
    const flop = 'Ks 7d 3c';
    final small = aiVsBetThenRaise('4h 3h', flop, 2.2, seeds: 200);
    final big = aiVsBetThenRaise('4h 3h', flop, 3.5, seeds: 200);
    expect(small.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(small.fold, lessThan(0.6),
        reason: '底对面对最小加注不该交牌（弃 ${pct(small.fold)}）');
    expect(big.fold, greaterThan(small.fold + 0.2),
        reason: '重加注要明显更少跟（弃 ${pct(big.fold)} vs ${pct(small.fold)}）');

    final secondPair = aiVsBetThenRaise('8h 7s', 'Kh 8d 3c 2s', 2.2,
        street: Street.turn, seeds: 200);
    expect(secondPair.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(secondPair.fold, lessThan(0.5),
        reason: '转牌第二对面对最小加注要跟一部分（弃 ${pct(secondPair.fold)}）');
  });

  t('河牌高牌：小注要抓，大注照样弃', () {
    // A 高、K 高没成牌但有摊牌价值：对着 1/4、1/3 池的小注跟一张是常规
    // 操作（小注大半是没把握的薄价值/阻挡注）。以前这里一律弃牌（探针：
    // 面对 1/4 池弃 83%），对手拿任意两张牌小注一下就能白拿底池。
    String pct(double v) => '${(100 * v).round()}%';
    const river = 'Qd 7d 2c 5h 9s';
    final small = aiVsHeroBet('Ad Kd', river, 0.25,
        street: Street.river, seeds: 200);
    final big = aiVsHeroBet('Ad Kd', river, 1.0,
        street: Street.river, seeds: 200);
    expect(small.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(small.call, greaterThan(0.25),
        reason: 'A 高面对 1/4 池小注要抓一部分（跟 ${pct(small.call)}）');
    expect(big.fold, greaterThan(0.9),
        reason: 'A 高面对一个底池的大注照样弃（弃 ${pct(big.fold)}）');
  });

  t('河牌高牌：小注档的跟注率随尺度连续下降，0.4 池两侧不许跳崖', () {
    // 以前小注折扣是一道硬门槛：≤0.4 池才给门槛打 0.7 折，再大一点点
    // 就完全不打折。探针实测 A 高面对 0.4 池跟 7%、0.42 池直接 0%——
    // 对手把注抬 2% 就能把我们的抓诈唬范围整个关掉，这条线在牌桌上一眼
    // 就能读出来。另半边的问题是范围模型对河牌空气的权重写死成 0.12、
    // 完全不吃下注尺度，同一手 A 高对 1/4 池和 1/2 池算出的胜率一模一样，
    // 于是「A 高抓不抓小注」只剩门槛那一个开关。
    //
    // 这条用例钉两件事：0.4 池两侧连得上（差得不超过 20 个点），以及
    // 整体方向仍然单调（注越大跟得越少）。
    String pct(double v) => '${(100 * v).round()}%';
    const river = 'Qd 7d 2c 5h 9s';
    final small = aiVsHeroBet('Ad Kd', river, 0.4,
        street: Street.river, seeds: 200);
    final justOver = aiVsHeroBet('Ad Kd', river, 0.42,
        street: Street.river, seeds: 200);
    final half = aiVsHeroBet('Ad Kd', river, 0.5,
        street: Street.river, seeds: 200);
    final pot = aiVsHeroBet('Ad Kd', river, 1.0,
        street: Street.river, seeds: 200);
    for (final r in [small, justOver, half, pot]) {
      expect(r.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    }
    expect(small.call, greaterThan(0.3),
        reason: 'A 高面对 0.4 池要抓（跟 ${pct(small.call)}）');
    expect(justOver.call, greaterThan(small.call - 0.2),
        reason: '0.4 池 → 0.42 池不许跳崖：'
            '${pct(small.call)} → ${pct(justOver.call)}');
    expect(half.call, lessThanOrEqualTo(small.call + 0.05),
        reason: '注变大不许跟得更多：'
            '${pct(small.call)} → ${pct(half.call)}');
    expect(pot.fold, greaterThan(0.9),
        reason: 'A 高面对一个底池的大注照样弃（弃 ${pct(pot.fold)}）');
  });

  t('河牌底对：小注要按赔率跟，大注照弃', () {
    // 河牌的小注（1/4、1/3 池）是宽范围，范围模型只按牌型给权重、不看这一
    // 注下得多小，算出来的胜率偏悲观：底对面对 1/4 池只算到 16.6%（赔率
    // 20%），以前 100% 弃牌——对手拿任意两张牌小注一下就能白拿底池。
    String pct(double v) => '${(100 * v).round()}%';
    const river = 'Qd 7d 2c 5h 9s';
    final small = aiVsHeroBet('Ah 2d', river, 0.25,
        street: Street.river, seeds: 200);
    final big = aiVsHeroBet('Ah 2d', river, 1.0,
        street: Street.river, seeds: 200);
    expect(small.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(small.call, greaterThan(0.4),
        reason: '底对面对 1/4 池要按赔率跟（跟 ${pct(small.call)} '
            '弃 ${pct(small.fold)}）');
    expect(big.fold, greaterThan(0.9),
        reason: '底对面对一个底池的大注照样弃（弃 ${pct(big.fold)}）');
  });

  t('河牌尺度：对手打越大，一对牌弃得越多，曲线不许翻回来', () {
    // 这一条锁的是「弃牌率随下注尺度单调递增」这个不变量。
    //
    // 以前跟注门槛里有一档「SPR 很低就别想了，自动跟」——对手把筹码
    // 打进来反而会把我的 SPR 压到 1.2 以下、正好踩中它。结果同一个中等
    // 牌档面对 1 倍池弃六成、面对 1.5 倍池一个都不弃：下注尺度这个变量
    // 在河牌被整个翻了过来，对手打多大都没区别、打得更狠反而更容易被跟。
    // 真人不会因为对手打得更重就跟得更多，这条曲线必须是单调的。
    String pct(double v) => '${(100 * v).round()}%';
    const board = '9d 5c 2h 8d Jd';
    // (1) 连开三枪这条线（对手翻牌/转牌都在开火），手里是第二对（弱成牌）：
    //     弃牌率必须随尺度往上走，而且小注那端不能一路弃到八成以上——对手
    //     拿任意两张牌打个半池就能把第二对清出去，等于白送。
    final half = aiVsRiverBet('Kc 8h', board, 0.5, barrel: true);
    final twoThird = aiVsRiverBet('Kc 8h', board, 0.66, barrel: true);
    final pot = aiVsRiverBet('Kc 8h', board, 1.0, barrel: true);
    for (final r in [half, twoThird, pot]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    expect(twoThird.fold, greaterThan(half.fold + 0.1),
        reason: '2/3 池要比 1/2 池弃得多（弃 ${pct(twoThird.fold)} vs '
            '${pct(half.fold)}）');
    expect(pot.fold, greaterThan(twoThird.fold + 0.05),
        reason: '满池要比 2/3 池弃得多（弃 ${pct(pot.fold)} vs '
            '${pct(twoThird.fold)}）');
    expect(half.fold, lessThan(0.8),
        reason: '1/2 池这条线上第二对要留一部分来看（弃 ${pct(half.fold)}）');

    // (2) 翻前造了个大池之后，河牌的超池会把 SPR 压到 1 以下——那一档
    //     「自动跟」当年就是在这里翻车的：中等牌（顶对）面对一个满池弃
    //     97%，面对 1.5 倍池反而一个都不弃。超池是两极化的线，不硬接。
    final big = aiVsRiverBet('Ac 9h', board, 1.0,
        barrel: true, preflopRaiseTo: 300);
    final over = aiVsRiverBet('Ac 9h', board, 1.5,
        barrel: true, preflopRaiseTo: 300);
    expect(big.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(over.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(over.fold, greaterThanOrEqualTo(big.fold - 0.02),
        reason: '超池不该比满池更容易被跟（超池弃 ${pct(over.fold)} vs '
            '满池弃 ${pct(big.fold)}）');
  });

  t('转牌防守范围比翻牌窄，没位置收得更紧', () {
    // 翻牌跟注之后还有两张牌可看、对手也还可能收手；转牌跟完就只剩一条
    // 街、对手多半还会再开一枪——同样 2/3 池的开火线，翻牌该跟的牌到了
    // 转牌就该放掉一部分。以前跟注门槛在翻牌/转牌/河牌一模一样（探针：
    // 第二对面对 2/3 池，翻牌跟 96%、转牌还是跟 95%），一整条街的差别都
    // 看不出来；位置对跟注的影响也顺带被这条线放大（没位置转牌还得先挨
    // 一枪）。
    String pct(double v) => '${(100 * v).round()}%';
    final flopOop = aiVsCheckBet('8h 7s', 'Kh 8d 3c', 0.66,
        street: Street.flop, seeds: 200);
    final turnOop = aiVsCheckBet('8h 7s', 'Kh 8d 3c 5s', 0.66,
        street: Street.turn, seeds: 200);
    final turnIp = aiVsCheckBet('8h 7s', 'Kh 8d 3c 5s', 0.66,
        street: Street.turn, oop: false, seeds: 200);
    expect(turnOop.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(turnIp.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(turnOop.fold, greaterThan(flopOop.fold + 0.15),
        reason: '转牌要比翻牌明显收窄（翻牌弃 ${pct(flopOop.fold)}、'
            '转牌弃 ${pct(turnOop.fold)}）');
    expect(turnOop.fold, lessThan(0.7),
        reason: '但也别一被开第二枪就扔（转牌弃 ${pct(turnOop.fold)}）');
    expect(turnIp.fold, lessThan(turnOop.fold - 0.1),
        reason: '同样两条街，有位置该跟得多得多'
            '（有位置弃 ${pct(turnIp.fold)} vs 没位置 ${pct(turnOop.fold)}）');
  });

  t('转牌防守范围比翻牌窄（有位置）：翻前加注过的池里，英雄连开两枪', () {
    // 上面那条量的是「没位置」那一侧。有位置这一侧原本看不出来：翻前加注
    // 过的池里英雄连开两枪，第二对 87 面对 2/3 池在翻牌跟 96%、转牌还是
    // 跟 95%（探针 tool/ai_probe.dart 的「翻牌 vs 转牌」那一节）。
    //
    // 根因不在 [_facingBet] 里那些余量，而在「弱成牌封顶」：一对牌的跟注
    // 门槛会被赔率兑现率封顶（见 realizationCap），到 2/3 池这个尺度上封顶
    // 就是全部——按余量乘出来的门槛整个被丢掉。而封顶里的街道项以前只是
    // 统一乘 1.1，翻牌跟转牌几乎同一个数；改成有位置 1.3→1.62、没位置
    // 1.6→1.78 之后，这条线上两条街才真的分得开。
    String pct(double v) => '${(100 * v).round()}%';
    // 两边是同一套摆局（AI 开池 250、英雄跟注、英雄下注 2/3 池），只差量
    // 哪条街：翻牌那侧只有一枪，转牌那侧英雄翻牌也先开了一枪（连开两枪）。
    final flop = aiVsFlopBet('8h 7s', 'Kh 8d 3c', 0.66, seeds: 200);
    final turn = aiVsTurnBet('8h 7s', 'Kh 8d 3c 5s', 0.66,
        barrel: true, seeds: 200);
    expect(turn.n, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(flop.fold, lessThan(0.1),
        reason: '翻牌上第二对不该扔（弃 ${pct(flop.fold)}）');
    expect(turn.fold, greaterThan(flop.fold + 0.15),
        reason: '转牌要比翻牌明显收窄（翻牌弃 ${pct(flop.fold)}、'
            '转牌弃 ${pct(turn.fold)}）');
    expect(turn.fold, lessThan(0.6),
        reason: '但也别一被开第二枪就扔（转牌弃 ${pct(turn.fold)}）');
    // 1/2 池那一档不许跟着一起收：价格好、对手那条线的范围也宽，一对牌
    // 在这个尺度上还是要跟（收窄全落在 2/3 池往上）。
    final half = aiVsTurnBet('8h 7s', 'Kh 8d 3c 5s', 0.5,
        barrel: true, seeds: 200);
    expect(half.fold, lessThan(0.15),
        reason: '1/2 池的第二枪还是要跟（弃 ${pct(half.fold)}）');
  });

  t('翻牌面对满池：弱成牌不能把够本的牌全扔掉', () {
    // 跟注门槛是几项余量相乘出来的（对手线强 × 大注 × 没位置），乘到
    // 1.8~2.8 倍赔率就过头了：封顶前探针实测翻牌面对一个满池，弱成牌的门槛
    // 中位 0.61，而同一批牌对着范围算出的胜率中位是 0.41（赔率只要 0.33）
    // ——只有 6% 过门槛，等于「拿到正确价格还把自己的牌扔掉」，对手拿任意
    // 两张牌满池一抡就白拿底池。现在按胜率兑现率把门槛封在赔率的 1.3 倍
    // （没位置 1.6），底对面对满池从弃 99% 回到弃三成半（跟六成半）。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh 7d 2c'; // 干燥面：底对在这里就是纯抓诈唬
    // 底牌不能撞：aiVsHeroBet 里英雄固定拿着 3c 2h，所以这里用 A♦2♦。
    final small = aiVsHeroBet('Ad 2d', board, 0.33, seeds: 200);
    final pot = aiVsHeroBet('Ad 2d', board, 1.0, seeds: 200);
    final over = aiVsHeroBet('Ad 2d', board, 1.5, seeds: 200);
    expect(pot.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(pot.call, greaterThan(0.3),
        reason: '底对面对一个满池也要按赔率抓一部分'
            '（跟 ${pct(pot.call)} 弃 ${pct(pot.fold)}）');
    expect(pot.fold, lessThan(0.75),
        reason: '不能一被抡满池就全扔（弃 ${pct(pot.fold)}）');
    expect(pot.fold, greaterThan(small.fold),
        reason: '注越大还是弃得越多（1/3 池弃 ${pct(small.fold)}、'
            '满池弃 ${pct(pot.fold)}）');
    // 封顶只管「正常尺度」：超池那条线是两极的，弱对子照旧弃——不然就从
    // 「一打就弃」变成「怎么打都跟」，那是同一个毛病换了个方向。
    expect(over.fold, greaterThan(0.8),
        reason: '超池面前弱对子照旧弃（弃 ${pct(over.fold)}）');
  });

  t('面对下注：尺度是连续的，不在「超池」那道门槛上跳崖', () {
    // 上面那条封顶的反面：封顶写成 `betSizeRel < 1.15` 之后，门槛两边成了
    // 两个世界。探针实测（同一手牌、同一张牌面，只改对手下注的大小）：
    //
    //   第二对 87 有位置     1.14 池弃 9%   →  1.16 池弃 99%
    //   两头顺 98  有位置     1.14 池弃 0%   →  1.16 池弃 91%
    //   顶对弱踢 A8 没位置    1.14 池弃 0%   →  1.16 池弃 98%
    //
    // 中间没有任何过渡：对手拿任意两张牌下 1.16 池就能白拿底池，而下 1.14
    // 池又几乎必被跟——下注尺度成了「AI 弃不弃」的开关。真人这条曲线是连续
    // 的，所以把门槛换成线性过渡（[AiPlayer._capRelease]）。
    //
    // 过渡区间一开始只铺 1.0~1.2 池，测出来还是台阶：1.00 池跟 97%、
    // 1.05 池跟 75%、1.10 池跟 30%、1.15 池跟 2%——97 个点全挤在 0.15 池
    // 里，因为胜率估算自身的散布就有 ±3~4 个点，区间比散布带还窄就等于没
    // 铺。拉开到 1.0~2.0 池之后才真的每一步都在动（下面这些断言量的就是
    // 「整段都有坡度」）。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Kh 8d 3c'; // 第二对 87：暗三条没中，也够不上顶对
    ({double fold, double call, double raise, int total}) at(double f) =>
        aiVsHeroBet('8s 7d', board, f, seeds: 200);
    final full = at(1.0);
    final mid = at(1.1);
    final just = at(1.14);
    final after = at(1.16);
    final over = at(1.2);
    final big = at(1.5);
    final deep = at(2.0);
    for (final r in [full, mid, just, after, over, big, deep]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    // 大方向不变：注越大弃得越多，封顶之外照旧弃。
    expect(after.fold, greaterThan(full.fold),
        reason: '1.16 池要比 1 池弃得多（1 池弃 ${pct(full.fold)}、'
            '1.16 池弃 ${pct(after.fold)}）');
    expect(over.fold, greaterThan(just.fold),
        reason: '1.2 池要比 1.14 池弃得多（1.14 池弃 ${pct(just.fold)}、'
            '1.2 池弃 ${pct(over.fold)}）');
    expect(big.fold, greaterThan(0.8),
        reason: '真超池照旧以弃为主（1.5 池弃 ${pct(big.fold)}）');
    expect(deep.fold, greaterThan(0.9),
        reason: '2 池基本交牌（2 池弃 ${pct(deep.fold)}）');
    // 关键：门槛那一步要么没了，要么小到读不出来。改之前这一跳是 90 个点。
    expect((after.fold - just.fold).abs(), lessThan(0.35),
        reason: '1.14→1.16 池之间不该有悬崖'
            '（1.14 池弃 ${pct(just.fold)}、1.16 池弃 ${pct(after.fold)}）');
    // 坡度要铺满整段，不能只在 1.14/1.16 那两点上看着连续。上一版过渡区
    // 只到 1.2 池，1.2 就已经弃 99% 了——「1.2~2 池」那一整段其实是平的，
    // 悬崖只是被挪到了 1.0~1.15。
    expect(over.fold, greaterThan(mid.fold + 0.15),
        reason: '1.1→1.2 池要有坡度（1.1 池弃 ${pct(mid.fold)}、'
            '1.2 池弃 ${pct(over.fold)}）');
    expect(big.fold, greaterThan(over.fold + 0.15),
        reason: '1.2→1.5 池要有坡度（1.2 池弃 ${pct(over.fold)}、'
            '1.5 池弃 ${pct(big.fold)}）');
    // 也不能反过来「怎么打都跟」：过渡段要看得见上升，而不是 1.2 池之前
    // 整段都一样（那等于把悬崖换成了一个平台）。
    expect(mid.fold, greaterThan(full.fold + 0.03),
        reason: '过渡段要有坡度（1 池弃 ${pct(full.fold)}、'
            '1.1 池弃 ${pct(mid.fold)}）');
  });

  t('听牌：从「跟」到「弃」要摊在一个尺度区间里，不在某一点上关掉', () {
    // 上面那条管的是成牌（封顶怎么松开）；听牌走的是另一条线
    // （[AiPlayer._drawCallOrFold] 里混合范围模型胜率的那一段），缺口也不在
    // 同一个位置。探针实测两头顺 98 on 762：
    //
    //   1.14 池跟 49%  1.16 池跟 39%  1.18 池跟 31%  1.2 池跟 0%
    //
    // 1.18→1.2 只有 0.02 池，却掉了 31 个点。根因在 [_callMix] 的斜坡：
    // `0.5 + edge / 0.08 * 0.5` 分母少乘了一个 2，带宽边界上还剩 0.25 的
    // 跟注率，被上面那两句 if 直接切成 0。也就是说同一手牌在两个相邻的尺度
    // 上会「还有三成在跟」紧接着「一个都不跟」——对手把注抬 1% 就能把这个
    // 牌力的跟注整个关掉。斜坡改成在带宽边界上正好走到 0 之后，同一段是
    // 53 / 39 / 31 / 22%，1.14~1.6 池整段都有坡度。上面那条第二对的用例
    // 走的是封顶那条线，量不到这里。
    String pct(double v) => '${(100 * v).round()}%';
    const board = '7s 6h 2d';
    ({double fold, double call, double raise, int total}) at(double f) =>
        aiVsHeroBet('9h 8h', board, f, seeds: 200);
    final a = at(1.14);
    final b = at(1.16);
    final c = at(1.18);
    final d = at(1.2);
    final e = at(1.5);
    final f = at(1.7);
    for (final r in [a, b, c, d, e, f]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    // 相邻两点之间不许有悬崖：每抬 0.02 池，跟注率掉的不该超过 20 个点。
    expect(b.call, greaterThan(a.call - 0.2),
        reason: '1.14→1.16 池不该跳崖（${pct(a.call)} → ${pct(b.call)}）');
    expect(c.call, greaterThan(b.call - 0.2),
        reason: '1.16→1.18 池不该跳崖（${pct(b.call)} → ${pct(c.call)}）');
    expect(d.call, greaterThan(c.call - 0.2),
        reason: '1.18→1.2 池不该跳崖（${pct(c.call)} → ${pct(d.call)}）');
    // 坡度得摊开在整段上，不能只是把两个点凑在一起、别处还是台阶。
    expect(a.call, greaterThan(d.call + 0.1),
        reason: '1.14→1.2 池要有坡度（${pct(a.call)} → ${pct(d.call)}）');
    expect(d.call, greaterThan(e.call),
        reason: '1.2→1.5 池要有坡度（${pct(d.call)} → ${pct(e.call)}）');
    // 两端照旧：正常尺度该跟一部分，真超池照旧弃。
    expect(a.call, greaterThan(0.3),
        reason: '两头顺面对 1.14 池要跟一部分（跟 ${pct(a.call)}）');
    expect(f.fold, greaterThan(0.9),
        reason: '两头顺面对 1.7 池以弃为主（弃 ${pct(f.fold)}）');
  });

  t('听牌：坚果花听面对大注也是连续下降，不在 1.2 池那道门槛上关掉', () {
    // 上面那条量的是两头顺（8 outs）：它「数 outs」的胜率和「对着范围算」
    // 的胜率差得不多，所以过渡带够用。坚果花听 + 两张高张完全是另一回事
    // ——范围模型会把 A/K 那 6 个出路也算进来，两种估值差出 0.25 以上，
    // [_drawCallOrFold] 里那份「信不信范围模型」的权重一陡，整条曲线就跟着陡。
    //
    // 探针实测（AhKh on Qh7h4c，翻牌面对下注，800 手一格）：
    //
    //   改前  1.14 池跟 91% → 1.16 池 91% → 1.18 池 77% → 1.20 池 52%
    //   改后  1.14 池 91% → 1.20 池 91% → 1.30 池 91% → 1.40 池 91%
    //         → 1.50 池 78% → 1.70 池 38%
    //
    // 改前那 0.06 池掉 39 个点，等于对手把注从 1.14 挪到 1.20 就能把这手
    // 坚果花听从「永远跟」变成「一半以上弃」；改后坡度摊到 0.7 池宽上，
    // 两头照旧（正常尺度该跟的照样跟，真超池照样收手）。根因和改法都在
    // [_drawCallOrFold] 那段注释里（权重改成按尺度自适应衰减，补贴也跟着
    // 超池缩水）。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh 7h 4c';
    ({double fold, double call, double raise, int total}) at(double f) =>
        aiVsHeroBet('Ah Kh', board, f, seeds: 200);
    final small = at(0.66);
    final a = at(1.14);
    final b = at(1.20);
    final c = at(1.30);
    final d = at(1.5);
    final e = at(1.7);
    for (final r in [small, a, b, c, d, e]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    // 改前这条必红：1.14→1.20 掉 39 个点。
    expect(b.call, greaterThan(a.call - 0.2),
        reason: '坚果花听在 1.14→1.20 池之间不许跳崖'
            '（${pct(a.call)} → ${pct(b.call)}）');
    expect(c.call, greaterThan(b.call - 0.2),
        reason: '1.20→1.30 池之间不许跳崖（${pct(b.call)} → ${pct(c.call)}）');
    // 坡度得真的存在，不能只是「上面平、下面一刀切」。
    expect(a.call, greaterThan(d.call),
        reason: '1.14 池要比 1.5 池跟得多（${pct(a.call)} → ${pct(d.call)}）');
    expect(d.call, greaterThan(e.call),
        reason: '1.5 池要比 1.7 池跟得多（${pct(d.call)} → ${pct(e.call)}）');
    // 两头照旧：正常尺度不该弃，真超池以弃为主。
    expect(small.fold, lessThan(0.1),
        reason: '坚果花听面对 2/3 池不该弃（弃 ${pct(small.fold)}）');
    expect(e.fold, greaterThan(0.5),
        reason: '坚果花听面对 1.7 池以弃为主（弃 ${pct(e.fold)}）');
  });

  t('听牌面对连开两枪：半诈唬加注要收手，不能比翻牌面对一枪还凶', () {
    // 半诈唬加注这一档以前是整个文件里唯一不看「对手的线有多强」的加注频率
    // （其它每个加注频率都算），于是出现了一个方向反了的读数：同一手坚果花听
    // （Ad Kd on Qd7d2c），翻牌面对一枪 1/2 池加 23%，转牌面对「1/2 池 + 2/3
    // 池」这条两枪线反而加到 34%——对手的线强了一整档，我们的加注频率涨了
    // 五成。真人拿听牌在这里明显更愿意先跟一手看河牌（隐含赔率还在、被 3-bet
    // 更难受），加注留在翻牌那一档。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qd 7d 2c 5h';
    // 同样的转牌 2/3 池下注，唯一的差别是翻牌英雄先开过一枪（连开两枪）。
    final single = aiVsTurnBet('Ad Kd', board, 0.66, seeds: 200);
    final barrels =
        aiVsTurnBet('Ad Kd', board, 0.66, barrel: true, seeds: 200);
    expect(single.n, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(barrels.n, greaterThan(_trialSeeds(40)),
        reason: '两枪线样本要够（${barrels.n}）');
    expect(single.raise, greaterThan(0.12),
        reason: '单个下注面前听牌该有一部分加注（加 ${pct(single.raise)}）');
    // 改之前这两个数只差 6 个点（38% vs 32%），所以界不能只要「低一点」：
    // 连开两枪的加注率得掉到单个下注的六成以下，才说明这一维真的生效。
    expect(barrels.raise, lessThan(single.raise * 0.6),
        reason: '连开两枪面前加注要明显更少（${pct(barrels.raise)} vs '
            '${pct(single.raise)}）');
    expect(barrels.call, greaterThan(0.5),
        reason: '这条线主体还是跟注看河牌（跟 ${pct(barrels.call)}）');
  });

  t('面对大注：强牌不会「一到 0.7 池就永远不加注」', () {
    // 上面两条讲的是「跟不跟」，这一条是同一个尺度变量在「加不加」上的
    // 版本——而且更糟：加注频率被 `bigBet`（≥0.7 池）**整条**切掉。探针
    // 实测（同一手牌、同一张牌面，只改对手下注的大小）：
    //
    //   强牌 顶对顶踢 翻牌  0.69 池加 31%  →  0.71 池加 0%
    //   强牌 顶对顶踢 转牌  0.69 池加 19%  →  0.71 池加 0%
    //   强牌 顶对顶踢 河牌  0.69 池加 10%  →  0.71 池加 0%
    //
    // 而且 0.71 池往上一直到超池都是 0。对手试出「打大注不会被加」，拿
    // 任意两张牌打大注就能白抢底池；反过来 0.69 池总会被加——尺度成了
    // 「AI 加不加注」的开关。真人对大注也还留一点加注（不加的话加注范围
    // 里全是怪物，一眼就读得出来），所以现在按尺度连续压到两成。
    String pct(double v) => '${(100 * v).round()}%';
    ({double fold, double call, double raise, int total}) at(double f) =>
        aiVsHeroBet('Ah Qd', 'Qh 7d 2c', f, seeds: 200);
    final half = at(0.5);
    final just = at(0.69);
    final after = at(0.71);
    final pot = at(1.0);
    for (final r in [half, just, after, pot]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    expect(after.raise, greaterThan(0.05),
        reason: '0.71 池不是「永远不加注」（加 ${pct(after.raise)}）');
    expect((after.raise - just.raise).abs(), lessThan(0.15),
        reason: '0.69→0.71 池之间不该有悬崖'
            '（${pct(just.raise)} → ${pct(after.raise)}）');
    // 方向不变：注越大加得越少，大注还是以跟为主。
    expect(half.raise, greaterThan(after.raise + 0.05),
        reason: '0.5 池该比 0.71 池加得多（0.5 池加 ${pct(half.raise)}、'
            '0.71 池加 ${pct(after.raise)}）');
    expect(pot.raise, lessThan(after.raise),
        reason: '满池比 0.71 池更少加（0.71 池加 ${pct(after.raise)}、'
            '满池加 ${pct(pot.raise)}）');
    expect(pot.raise, lessThan(0.25),
        reason: '大注还是以跟为主（满池加 ${pct(pot.raise)}）');
    // 尺度折扣的那两个分界点（1/3 池、2/3 池）以前也是台阶：1.2 / 0.9 / 0.6
    // 三档常量，跨过 0.35 或 0.6 就掉一大格（探针实测 0.35 池加 65%、
    // 0.37 池只剩 48%）。现在这两段线性过渡。
    final third = at(0.34);
    final pastThird = at(0.36);
    final wide = at(0.59);
    final pastWide = at(0.61);
    for (final r in [third, pastThird, wide, pastWide]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    expect((pastThird.raise - third.raise).abs(), lessThan(0.15),
        reason: '1/3 池那道分界不该是台阶（0.34 池加 ${pct(third.raise)}、'
            '0.36 池加 ${pct(pastThird.raise)}）');
    expect((pastWide.raise - wide.raise).abs(), lessThan(0.15),
        reason: '2/3 池那道分界不该是台阶（0.59 池加 ${pct(wide.raise)}、'
            '0.61 池加 ${pct(pastWide.raise)}）');
  });

  t('听牌半诈唬加注：不在 0.8 池那道门槛上跳崖', () {
    // 这一条是「面对大注」那条在听牌档的版本：`_semiBluffRaiseChance` 里
    // 「大注不硬凑」原来也是 `betSizeRel >= 0.8` 的布尔（0.79 池乘 1.0、
    // 0.80 池乘 0.4）。探针实测坚果花听（AdKd on Qd7d2c）面对下注：
    // 0.79 池加 20%、0.80 池 12%、0.81 池 7%——加注率在门槛上一步掉 13 个
    // 点，对手把尺度卡在 0.79 池就必被加、卡到 0.81 池就稳收底池，而听牌
    // 的加注范围正是「他有牌没牌」最难读的那一半。现在按尺度连续收到 0.4。
    String pct(double v) => '${(100 * v).round()}%';
    ({double fold, double call, double raise, int total}) at(double f) =>
        aiVsHeroBet('Ad Kd', 'Qd 7d 2c', f, seeds: 300);
    final half = at(0.5);
    final just = at(0.79);
    final after = at(0.81);
    final pot = at(1.0);
    for (final r in [half, just, after, pot]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    expect((after.raise - just.raise).abs(), lessThan(0.08),
        reason: '0.79→0.81 池之间不该有悬崖'
            '（${pct(just.raise)} → ${pct(after.raise)}）');
    // 方向不变：注越大加得越少，但大注不是「永远不加」。
    expect(half.raise, greaterThan(pot.raise),
        reason: '半池该比满池加得多（半池加 ${pct(half.raise)}、'
            '满池加 ${pct(pot.raise)}）');
    expect(pot.raise, greaterThan(0.04),
        reason: '满池也不是完全不拿听牌加注（加 ${pct(pot.raise)}）');
    // 破花听在河牌那一份（[_bluffRaiseChance]）原来也有同一道台阶：
    // 0.74 池加 8%、0.75 池只剩 3%。河牌没有下一条街，这条线尤其不能
    // 在某个尺度上「啪」地关掉。
    ({double fold, double call, double raise, int total}) river(double f) =>
        aiVsHeroBet('Ah Jh', 'Kh 7h 2c 9s 3d', f,
            street: Street.river, seeds: 300);
    final justBelow = river(0.74);
    final justAbove = river(0.76);
    for (final r in [justBelow, justAbove]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    expect((justAbove.raise - justBelow.raise).abs(), lessThan(0.06),
        reason: '河牌 0.74→0.76 池之间不该有悬崖'
            '（${pct(justBelow.raise)} → ${pct(justAbove.raise)}）');
  });

  t('听牌面对加注：加得越大越不往上顶', () {
    // 「听牌转诈唬」这条线在**面对加注**时漏掉了尺度这一维。
    // [_semiBluffRaiseChance] 里那道「大注不硬凑」的斜坡是照**下注**的量纲定
    // 的（0.6 池起、1.0 池封顶），可 [betSizeRel] 在加注线上是另一套数：加注
    // 要先把对手那一注配上，同样「加到 2.2 倍」摊到相对底池只有 0.18~0.31 池，
    // 3.5 倍也只有 0.37~0.65 池——整条斜坡落在 0.6 以下，等于死的。探针实测
    // （tool/ai_vs_raise_probe.dart，牌面已钉死）同一手坚果花听（AdKd on
    // Qd7d2c）面对 2.2 倍和 3.5 倍的再加注率逐字相同（转牌 13%/13%、卡顺
    // 4%/4%），而同一块牌面上的强牌老老实实随尺度往下走（顶对顶踢 19% → 11%、
    // 超对 29% → 17%）——「他加到 3.5 倍」这个信息在听牌这一档完全没进决策。
    // 真人这时很少再拿听牌往上顶：加到 3.5 倍的人范围实得多、弃牌率低得多，
    // 顶上去被跟就被压着打。所以加注侧按实测分布重定锚点（0.25 池起、0.6 池
    // 封顶、压到 0.45），面对下注那一侧一个点不动。
    String pct(double v) => '${(100 * v).round()}%';
    for (final (street, board, hole, label) in [
      (Street.flop, 'Qd 7d 2c', 'Ad Kd', '翻牌坚果花听'),
      (Street.turn, 'Qd 7d 2c 5h', 'Ad Kd', '转牌坚果花听'),
    ]) {
      final small =
          aiVsBetThenRaise(hole, board, 2.2, street: street, seeds: 400);
      final big =
          aiVsBetThenRaise(hole, board, 3.5, street: street, seeds: 400);
      expect(small.total, greaterThan(_trialSeeds(100)),
          reason: '$label 样本要够（${small.total}）');
      expect(big.total, greaterThan(_trialSeeds(100)),
          reason: '$label 样本要够（${big.total}）');
      // 最小加注给的价格好，听牌照样要保留半诈唬——不能顺手把这一档一起关掉。
      expect(small.raise, greaterThan(0.05),
          reason: '$label 面对最小加注还要有半诈唬（再加 ${pct(small.raise)}）');
      // 3.5 倍的人范围实得多：再加注率要明显低于最小加注那一档。
      expect(big.raise, lessThan(small.raise - 0.03),
          reason: '$label 加到 3.5 倍要明显少顶'
              '（2.2 倍 ${pct(small.raise)} → 3.5 倍 ${pct(big.raise)}）');
      // 收手不是清零：听牌一手都不加，加注范围里就只剩成牌，一眼能读。
      expect(big.raise, greaterThan(0.01),
          reason: '$label 3.5 倍也不是完全不顶（再加 ${pct(big.raise)}）');
    }
    // 幅度扫描：原来 1.8~3.5 倍是一条平线（13%/13%/13%/13%），现在中间既不许
    // 翻回来，也不许在某个尺度上一步跳下去。
    final curve = [
      for (final mult in [1.8, 2.2, 2.8, 3.5])
        aiVsBetThenRaise('Ad Kd', 'Qd 7d 2c 5h', mult,
            street: Street.turn, seeds: 400),
    ];
    for (var i = 1; i < curve.length; i++) {
      expect(curve[i].raise, lessThan(curve[i - 1].raise + 0.03),
          reason: '加注量变大反而顶得更凶（'
              '${pct(curve[i - 1].raise)} → ${pct(curve[i].raise)}）');
    }
    expect(curve.last.raise, lessThan(curve.first.raise - 0.04),
        reason: '整段要真的往下走'
            '（1.8 倍 ${pct(curve.first.raise)} → 3.5 倍 ${pct(curve.last.raise)}）');
  });

  t('河牌抓诈唬：真对子不会被一次下注清空', () {
    // 河牌只剩一次决策：门槛只该比赔率高一点点。以前河牌沿用翻牌那套
    // 1.35 倍余量，第二对对着河牌 2/3 池有 31.3% 胜率、赔率只要 28.6%
    // （够本）却被卡掉，弃 92%——对手拿任意两张牌下 2/3 池都能白拿底池，
    // 我们的跟注范围也只剩顶对以上、一眼读得出来。
    String pct(double v) => '${(100 * v).round()}%';
    const river = 'Kh 8d 4c 5h 9s';
    final small = aiVsHeroBet('8h 7s', river, 0.25,
        street: Street.river, seeds: 200);
    final mid = aiVsHeroBet('8h 7s', river, 0.66,
        street: Street.river, seeds: 200);
    expect(mid.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(small.call, greaterThan(0.8),
        reason: '第二对面对 1/4 池本来就不该弃（跟 ${pct(small.call)}）');
    expect(mid.call, greaterThan(0.25),
        reason: '第二对面对 2/3 池要抓一部分（跟 ${pct(mid.call)} '
            '弃 ${pct(mid.fold)}）');
    expect(mid.call, lessThan(small.call),
        reason: '注越大抓得越少（1/4 池跟 ${pct(small.call)}、'
            '2/3 池跟 ${pct(mid.call)}）');
    expect(mid.call, lessThan(0.9),
        reason: '但也不能跟得太满（2/3 池跟 ${pct(mid.call)}）');
  });

  t('河牌尺度：范围模型要读下注大小，注越大跟得越少', () {
    // 范围模型以前完全不吃下注尺度：同一个牌面上的 1/4 池和一个满池被
    // 当成同一条线，算出来的胜率一模一样，「注越大跟得越少」只能靠跟注
    // 门槛去补；补不动的时候就成了第二对面对 2/3 池跟 52%、面对一个满池
    // 还是跟 53%——尺度这个变量在河牌的跟注上等于不存在，对手打多大我们
    // 都一样跟。现在把尺度算进对手范围（大注里诈唬的比例更低），跟注率
    // 重新随尺度递减。
    String pct(double v) => '${(100 * v).round()}%';
    // 无听牌的河牌：8h7s 是干净的第二对，走「弱成牌抓诈唬」那一档。
    const river = 'Kd 8c 2h 10s 4d';
    final quarter =
        aiVsHeroBet('8h 7s', river, 0.25, street: Street.river, seeds: 200);
    final twoThirds =
        aiVsHeroBet('8h 7s', river, 0.66, street: Street.river, seeds: 200);
    final pot =
        aiVsHeroBet('8h 7s', river, 1.0, street: Street.river, seeds: 200);
    expect(quarter.total, greaterThan(_trialSeeds(50)), reason: '样本要够');
    expect(quarter.call, greaterThan(0.8),
        reason: '1/4 池的小注要按赔率抓（跟 ${pct(quarter.call)}）');
    expect(twoThirds.call, lessThan(quarter.call - 0.2),
        reason: '2/3 池要明显收（跟 ${pct(twoThirds.call)} '
            'vs ${pct(quarter.call)}）');
    expect(pot.call, lessThan(twoThirds.call),
        reason: '满池比 2/3 池还该少跟（跟 ${pct(pot.call)} '
            'vs ${pct(twoThirds.call)}）');
    expect(pot.call, lessThan(0.5),
        reason: '第二对面对满池河牌不该跟满（跟 ${pct(pot.call)}）');
  });

  t('位置反转：没位置不该比有位置更爱加注', () {
    // 面对下注时「没位置」这一侧本来就该更少加注：加完还要在不利位置打
    // 后面两条街，被 3-bet 也更难受。以前过牌-加注的倍率对所有牌力一视
    // 同仁（强牌 ×1.5、弱成牌也照吃），结果是没位置的加注率反过来压过
    // 有位置——翻牌顶对顶踢 78% vs 56%、转牌底对 8% vs 2%，方向是反的。
    String pct(double v) => '${(100 * v).round()}%';
    const flop = 'Kd 8c 3h';

    // 强牌（顶对顶踢）：两边都该有一半上下的加注，差距要收在 10 个点内。
    final tpIp = aiVsCheckBet('Ah Kd', flop, 0.5, seeds: 200, oop: false);
    final tpOop = aiVsCheckBet('Ah Kd', flop, 0.5, seeds: 200);
    expect(tpIp.total, greaterThan(_trialSeeds(100)), reason: '有位置样本要够');
    expect(tpOop.total, greaterThan(_trialSeeds(50)), reason: '没位置样本要够（n=${tpOop.total}）');
    expect(tpIp.raise, greaterThan(0.3),
        reason: '顶对顶踢该有一部分反击（有位置加 ${pct(tpIp.raise)}）');
    // 改前是 78% vs 56%（没位置反而高出 22 个点）；现在两边都在六成上下、
    // 没位置略高一点（过牌-加注本来就是没位置一方的武器），差距收进 15 点。
    expect(tpOop.raise, lessThan(tpIp.raise + 0.15),
        reason: '没位置不该加得比有位置还凶 '
            '（${pct(tpOop.raise)} vs ${pct(tpIp.raise)}）');

    // 一对弱牌：两边都只能留一点点反击频率——拿底对去过牌-加注打走的是
    // 更差的牌、留下的都是更好的牌，等于把有摊牌价值的牌变成纯诈唬。
    final weakIp = aiVsCheckBet('8h 7s', flop, 0.5, seeds: 200, oop: false);
    final weakOop = aiVsCheckBet('8h 7s', flop, 0.5, seeds: 200);
    expect(weakOop.total, greaterThan(_trialSeeds(50)), reason: '没位置样本要够');
    expect(weakIp.raise, lessThan(0.08),
        reason: '有位置的第二对也只是混一点反击（加 ${pct(weakIp.raise)}）');
    expect(weakOop.raise, lessThan(0.08),
        reason: '没位置的第二对别乱加（加 ${pct(weakOop.raise)}）');
    expect(weakOop.call, greaterThan(weakOop.raise * 4),
        reason: '弱成牌面对下注主体还是跟注（跟 ${pct(weakOop.call)}）');
  });

  t('多人底池：顶对顶踢收着加，不再单挑多人一个频率', () {
    // 池里的人越多，顶对顶踢被两对/三条压住的概率越大，各家的继续范围
    // 也更强——还按单挑的频率加注，就是拿一手「能摊牌、但扛不住反击」
    // 的牌去打大底池。以前这个分支完全不看人数：探针实测 2/3/4 人池
    // 全是 55%（A8 在 8♣5♠4♠ 上的顶对顶踢）。
    String pct(double v) => '${(100 * v).round()}%';

    final heads = aiVsBetMultiway('Ah 8d', '8h 5s 4s', seeds: 200);
    final three = aiVsBetMultiway('Ah 8d', '8h 5s 4s', callers: 1, seeds: 200);
    final five = aiVsBetMultiway('Ah 8d', '8h 5s 4s', callers: 3, seeds: 200);

    expect(heads.n, greaterThan(_trialSeeds(100)), reason: '单挑样本要够');
    expect(five.n, greaterThan(_trialSeeds(100)), reason: '多人池样本要够');
    expect(heads.raise, greaterThan(0.4),
        reason: '单挑里顶对顶踢该有一部分反击（加 ${pct(heads.raise)}）');
    expect(three.raise, lessThan(heads.raise - 0.1),
        reason: '三人池要明显收着加（${pct(three.raise)} vs 单挑 ${pct(heads.raise)}）');
    expect(five.raise, lessThan(three.raise + 0.1),
        reason: '池里五个人只会更少加（${pct(five.raise)}）');
    expect(five.call, greaterThan(0.6),
        reason: '多人池主体是跟注看牌，不是加注（跟 ${pct(five.call)}）');
  });

  t('多人池：大注不能因为中间有人跟注就被当成小注', () {
    String pct(double v) => '${(100 * v).round()}%';
    // 河牌 1.5 倍池，中间的人先跟注：分母要把他们的钱扣掉，不然这个重注
    // 会被读成小注。改之前单挑弃 43%，三人池 / 四人池反而只弃 0%（跟注
    // 95% 以上，还偶尔加注）——人越多越敢跟重注，方向正好反了。
    const board = 'Qh 7d 2c 5h 9s';
    final heads = aiVsRiverBetMultiway('Ah Qd', board, 1.5, seeds: 200);
    final three =
        aiVsRiverBetMultiway('Ah Qd', board, 1.5, callers: 1, seeds: 200);
    final four =
        aiVsRiverBetMultiway('Ah Qd', board, 1.5, callers: 2, seeds: 200);

    expect(heads.total, greaterThan(_trialSeeds(100)), reason: '单挑样本要够');
    expect(four.total, greaterThan(_trialSeeds(100)), reason: '四人池样本要够');
    expect(three.fold, greaterThan(0.25),
        reason: '三人池面对 1.5 倍池，顶对顶踢要挑着弃（弃 ${pct(three.fold)}）');
    expect(four.fold, greaterThan(0.25),
        reason: '四人池只会更该弃（弃 ${pct(four.fold)}）');
    expect(four.fold, lessThan(0.8),
        reason: '但不能弃成一堵墙（弃 ${pct(four.fold)}）');
    expect(three.raise, lessThan(0.1),
        reason: '大注面前不拿一对反加（加 ${pct(three.raise)}）');
    expect(four.raise, lessThan(0.1),
        reason: '多人池更不反加（加 ${pct(four.raise)}）');
  });

  t('河牌防守：同一档的几手一对牌，多人池里要按牌力分开弃', () {
    // 这一条锁的是「抓诈唬范围不能塌成一个常数」。河牌防守下限
    // （[AiPlayer] 的 `riverDefendFloor`）存在的理由是 MDF——手里真有成牌就不能
    // 把整档都扔掉；但它原来是个跟手牌无关的定值，于是只要胜率掉到门槛以下，
    // 决定权就整块交给下限，整档的弃牌率变成同一个数。探针实测
    // （tool/ai_multi_probe.dart 的 C 节，河牌四人池、对手打 1/2 池）第二对 87、
    // 被盖口袋 66、底对 43 三手牌弃牌率逐字相同（35/35/35、73/73/73、97/97/97），
    // 而这三手牌对着同一个范围算出来的胜率差十几倍——对手把尺度卡在「弱成牌
    // 刚好够不到门槛」的位置，我们的整个抓诈唬范围就成了一个常数，手里拿的是
    // 什么牌再也读不出来。
    //
    // 下限按「这手牌够到自己门槛的几成」打折之后，三手牌在同一格上分开了，
    // 而且方向是「越强的牌守得越多」。下面量的是牌子最硬的那一格（四人池、
    // 1/2 池）：改之前三条断言全红（三个数一样）。
    String pct(double v) => '${(100 * v).round()}%';
    const dry = 'Kh 8d 3c 5h 9s';
    final second = aiVsRiverBetMultiway('8h 7s', dry, 0.5, callers: 2);
    final underPair = aiVsRiverBetMultiway('6h 6d', dry, 0.5, callers: 2);
    final bottom = aiVsRiverBetMultiway('4h 3d', 'Ks 7c 3c 5h 9s', 0.5,
        callers: 2);
    for (final r in [second, underPair, bottom]) {
      expect(r.total, greaterThan(_trialSeeds(100)), reason: '样本要够');
    }
    expect(underPair.fold, greaterThan(second.fold + 0.05),
        reason: '被盖过的口袋对要比第二对弃得多（弃 ${pct(underPair.fold)} vs '
            '${pct(second.fold)}）');
    expect(bottom.fold, greaterThan(underPair.fold + 0.05),
        reason: '底对要比被盖的口袋对弃得多（弃 ${pct(bottom.fold)} vs '
            '${pct(underPair.fold)}）');
    expect(second.fold, lessThan(0.8),
        reason: '第二对是抓诈唬的主力，不能整档交出去（弃 ${pct(second.fold)}）');
    expect(bottom.fold, greaterThan(0.5),
        reason: '底对在这种局面上该让路（弃 ${pct(bottom.fold)}）');
  });

  /// 多人池：AI 在按钮（最后说话），前面所有人过牌到它，量它在 [street] 圈
  /// 的选择——下注率 / 过牌率 / 平均尺度（下注额 ÷ 下注前底池）。
  ({double bet, double check, double avgFrac, int n}) aiCheckedToMultiway(
      String hole, String board,
      {int callers = 0,
      Street street = Street.flop,
      int seeds = 200,
      bool forcePreflopCall = false}) {
    var bet = 0, check = 0, n = 0;
    var fracSum = 0.0;
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
      final rnd = Random(seed);
      final g = GameEngine(
        config: const GameConfig(
            startingStack: 10000, smallBlind: 50, bigBlind: 100),
        random: rnd,
      )
        ..addPlayer('ai', 'AI')
        ..addPlayer('hero', '我');
      for (var i = 0; i < callers; i++) {
        g.addPlayer('c$i', 'C$i');
      }
      final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
      g.startHand(
        holeOverride: {'ai': _cs(hole), 'hero': _cs('3c 2c')},
        boardOverride: _cs(board)
            .take(street == Street.flop ? 3 : 4)
            .toList(),
      );
      var guard = 0;
      while (!g.handOver && guard++ < 300) {
        final pa = g.pendingAction();
        final p = pa.player;
        final legal = pa.actions;
        final facing = legal.any((a) => a.type == ActionType.call);
        final canCheck = legal.any((a) => a.type == ActionType.check);
        if (p.id == 'ai') {
          // [forcePreflopCall]：把翻前钉成同一个场景（所有人都溜入、AI 补齐），
          // 只让「池里有几家」这一维动。默认关——多数格子即使让 AI 自己决定
          // 翻前也够样本，而且那些格子的阈值就是按老规矩标定的，一动全漂。
          //
          // 要开它的场合：数到第三家溜入往上，AI 会把 87o 这类牌直接扔掉
          // （实测四人池 600 手只剩 127 手、五人池几乎全军覆没），剩下的样本
          // 是「AI 翻前加过注」的局面，跟人少那几格根本不是同一个翻后场景，
          // 拿来比「人越多越收着」是拿两个变量在比。规矩跟
          // tool/ai_multi_probe.dart 的 probeCheckedTo 一致，两边的数字才能
          // 对拍。
          if (forcePreflopCall && g.street == Street.preflop) {
            g.apply('ai', legal.any((a) => a.type == ActionType.call)
                ? ActionType.call
                : ActionType.check);
            continue;
          }
          final d = ai.decide(g, p);
          if (g.street == street && !facing) {
            n++;
            if (d.type == ActionType.bet) {
              bet++;
              fracSum += (d.amountTo ?? 0) / max(1, g.potTotal());
            } else {
              check++;
            }
            break;
          }
          g.apply('ai', d.type, amount: d.amountTo);
          continue;
        }
        g.apply(p.id,
            facing ? ActionType.call : (canCheck ? ActionType.check : legal.first.type));
      }
    }
    double r(int v) => n == 0 ? 0 : v / n;
    return (bet: r(bet), check: r(check), avgFrac: bet == 0 ? 0 : fracSum / bet, n: n);
  }

  t('多人池：被过牌到不再一定下注，人数越多越收着', () {
    // 强牌档原来的四条过牌档（翻牌没位置 / 转牌非空白牌 / 河牌 / 河牌超池）
    // 全都挂着 !multiway，于是三人池以上是「过牌到我 = 一定下注」：探针实测
    // 翻牌被过牌到，顶对顶踢和超对在 2/3/4/5 人池里都是 100% 下注，尺度还
    // 随人数往上抬（0.63 → 0.78 倍池）。真人拿一对在五人湿面上不会每手都
    // 开火——后面还坐着三家，两对/三条/听牌都在，被加注就得弃；更要命的是
    // 我们的过牌范围从此清一色是没牌，一过牌对手拿任意两张牌就能收走底池。
    String pct(double v) => '${(100 * v).round()}%';
    const board = '8h 5s 4s'; // 顶对顶踢 + 两张同花 + 顺子可能，湿面

    final heads = aiCheckedToMultiway('Ah 8d', board);
    final three = aiCheckedToMultiway('Ah 8d', board, callers: 1);
    final five = aiCheckedToMultiway('Ah 8d', board, callers: 3);
    for (final r in [heads, three, five]) {
      expect(r.n, greaterThan(_trialSeeds(100)), reason: '样本要够');
    }
    // 单挑还是照打：位置好、后面只剩一家，顶对顶踢就是价值注。
    expect(heads.bet, greaterThan(0.95),
        reason: '单挑被过牌到还是该打（下注 ${pct(heads.bet)}）');
    // 三人池开始收着，五人池收得更多——而且要单调，不能又变成拍脑袋的常数。
    expect(three.bet, lessThan(0.97),
        reason: '三人池不该还是 100% 下注（下注 ${pct(three.bet)}）');
    expect(five.bet, lessThan(three.bet - 0.08),
        reason: '五人池要比三人池收得更明显'
            '（五人 ${pct(five.bet)} vs 三人 ${pct(three.bet)}）');
    expect(five.bet, lessThan(0.85),
        reason: '五人湿面上拿一对不能每手都开火（下注 ${pct(five.bet)}）');
    expect(five.check, greaterThan(0.15),
        reason: '至少要留一部分过牌回去（过牌 ${pct(five.check)}）');

    // 对照：干面上强牌该打得更勤（湿面才有那么多能反超我们的牌），
    // 别把这条修成「人一多就不敢下注」。
    final dryFive = aiCheckedToMultiway('9h 9d', '8c 5d 2h', callers: 3);
    expect(dryFive.bet, greaterThan(five.bet),
        reason: '干面上该比湿面打得多'
            '（干 ${pct(dryFive.bet)} vs 湿 ${pct(five.bet)}）');

    // 但上面这格（顶对顶踢）恰好走的是另一条本来就按人数连续下走的线，
    // 看不出「人多」这一维其实从第三家起就停住了：[_manyTail] 之前，多人池
    // 的折扣写的是 `opponents >= 3 ? 常数 : ...`，四个人、五个人、六个人的
    // 池子在我们眼里**完全一样**。探针实测（tool/ai_multi_probe.dart 的 B
    // 节）第二对 87 在 3 / 4 / 5 人池里都是下注 24%，花听 AKs 在 4 / 5 人
    // 池都是 37%，空气 87 在 4 / 5 人池都是 4%——逐字相同。真人不会在第三家
    // 上停下来：后面每多一家，「一注打走所有人」的概率往下走、被反超的概率
    // 往上走，两个方向都指向收着打。
    //
    // 薄价值这一档最容易看出来（第二对 87 on K84，所有人都过牌到按钮的 AI），
    // 钉的是 3 → 4 → 5 人池每一步都在掉，不是只有第一段在掉。改之后实测
    // 下注 23% / 18% / 13%（改之前是 23% / 23% / 23%，逐字相同，这条必红）。
    //
    // 三格都开 [forcePreflopCall]：不然数到第三家溜入，87o 会被翻前直接扔掉
    // （四人池 600 手只剩 127 手、五人池几乎没有），剩下的还是「AI 翻前加过
    // 注」的局面——那样量出来的差里混着翻前动作，不是纯粹的「人多人少」。
    final w3 = aiCheckedToMultiway('8h 7d', 'Kh 8s 4s',
        callers: 1, seeds: 600, forcePreflopCall: true);
    final w4 = aiCheckedToMultiway('8h 7d', 'Kh 8s 4s',
        callers: 2, seeds: 600, forcePreflopCall: true);
    final w5 = aiCheckedToMultiway('8h 7d', 'Kh 8s 4s',
        callers: 3, seeds: 600, forcePreflopCall: true);
    for (final r in [w3, w4, w5]) {
      expect(r.n, greaterThan(_trialSeeds(200)), reason: '样本要够');
    }
    expect(w4.bet, lessThan(w3.bet - 0.04),
        reason: '第二对：四人池要比三人池收着（${pct(w3.bet)} → ${pct(w4.bet)}）');
    expect(w5.bet, lessThan(w4.bet - 0.03),
        reason: '第二对：五人池还要接着收（${pct(w4.bet)} → ${pct(w5.bet)}）');
  });

  t('多人池：花听照样开火，不能和空气一个频率', () {
    // 听牌转诈唬这条线以前在多人池里被一刀砍平：_semiBluffChance 里那个
    // 「人越多越收」的折扣（3 人以上 ×0.3）对所有听牌一视同仁，于是花听
    // （8 outs 以上，有成牌概率兜底）和卡顺（纯靠弃牌率才成立）被压到了
    // 同一个频率。探针实测（花听 AKs on Qh7h4c、所有人都过牌到按钮的 AI）：
    // 4 人池只下注 22%，跟「纯空气」那一格的 5% 只差一档——真人拿坚果花听
    // 在多人池里是该打的；不打的话开火范围里清一色是成牌，对手一见我们
    // 过牌就知道没东西。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh 7h 4c 2s 9d'; // 两张同花：Ah Kh 是坚果花听

    final heads = aiCheckedToMultiway('Ah Kh', board);
    final four = aiCheckedToMultiway('Ah Kh', board, callers: 2);
    final air = aiCheckedToMultiway('8h 7d', 'As Kd Qc 2h 5s', callers: 2);

    expect(four.n, greaterThan(_trialSeeds(100)), reason: '样本要够');
    expect(heads.bet, greaterThan(0.75),
        reason: '单挑被过牌到，坚果花听该照常开火（下注 ${pct(heads.bet)}）');
    expect(four.bet, greaterThan(0.3),
        reason: '4 人池里花听也该打（下注 ${pct(four.bet)}）');
    expect(four.bet, greaterThan(air.bet + 0.15),
        reason: '花听要和空气拉开差距——听牌才配开火'
            '（花听 ${pct(four.bet)} vs 空气 ${pct(air.bet)}）');
  });

  t('薄价值：底对的下注频率要低于第二对', () {
    // 以前这两档在「无人下注」时共用同一个频率（0.42），探针里「翻牌/转牌/
    // 河牌 第二对（无人下注）」和对应的「底对（无人下注）」连下注尺度的分布
    // 都逐桶一样——同一份随机数、同一个概率，牌力在薄价值这条线上等于没有
    // 刻度。底对只赢诈唬，打出去被跟注基本就是白付钱，不该和第二对一个频率。
    String pct(double v) => '${(100 * v).round()}%';

    final spFlop = aiCheckedToMultiway('8h 7s', 'Kh 8d 3c');
    final bpFlop = aiCheckedToMultiway('Ah 4h', 'Qc 7d 4s');
    final spTurn =
        aiCheckedToMultiway('8h 7s', 'Kh 8d 3c 5h', street: Street.turn);
    final bpTurn =
        aiCheckedToMultiway('Ah 4h', 'Qc 7d 4s 5h', street: Street.turn);
    final spRiver =
        aiCheckedToMultiway('8h 7s', 'Kh 8d 3c 5h 9s', street: Street.river);
    final bpRiver =
        aiCheckedToMultiway('Ah 4h', 'Qc 7d 4s 5h 9d', street: Street.river);

    for (final r in [spFlop, bpFlop, spTurn, bpTurn, spRiver, bpRiver]) {
      expect(r.n, greaterThan(_trialSeeds(100)), reason: '样本要够');
    }
    expect(bpFlop.bet, lessThan(spFlop.bet + 0.02),
        reason: '翻牌底对不能比第二对还爱打'
            '（底对 ${pct(bpFlop.bet)} vs 第二对 ${pct(spFlop.bet)}）');
    expect(bpTurn.bet, lessThan(spTurn.bet - 0.06),
        reason: '转牌底对要收得更明显（第二对是薄价值，底对基本是摊牌牌）'
            '（底对 ${pct(bpTurn.bet)} vs 第二对 ${pct(spTurn.bet)}）');
    expect(bpRiver.bet, lessThan(spRiver.bet - 0.03),
        reason: '河牌同理（底对 ${pct(bpRiver.bet)} vs 第二对 ${pct(spRiver.bet)}）');
  });

  t('低 SPR：单挑可以推全下，池里人多就只跟注', () {
    // 跟注/全下的分界看 SPR（筹码 ÷ 底池），以前这条线对所有人数都是
    // 1.5：五人池里人人跟一注底池就涨到 SPR≈1.3，A8 这种顶对顶踢于是
    // 整叠推出去——被跟上的范围里两对/三条已经占多数，等于只被更好的
    // 牌跟。现在门槛按人数收紧（1 人 1.5 / 2 人 1.15 / 3 人以上 0.85），
    // 人多的池里先跟注控池，筹码反正跑不掉。
    String pct(double v) => '${(100 * v).round()}%';

    final heads = aiVsBetMultiway('Ah 8d', '8h 5s 4s', seeds: 200);
    final five = aiVsBetMultiway('Ah 8d', '8h 5s 4s', callers: 3, seeds: 200);

    expect(five.n, greaterThan(_trialSeeds(100)), reason: '多人池样本要够');
    // 深筹码时两边都不该无脑全下；真正要盯的是五人池里那一堆
    // 「底池已经涨起来」的牌局——以前那里 85% 是把筹码推光的。
    expect(five.jam, lessThan(0.15),
        reason: '五人池的顶对顶踢别把整叠推出去（全下 ${pct(five.jam)}）');
    expect(heads.jam, lessThan(0.15),
        reason: '深筹码单挑也不该随便全下（全下 ${pct(heads.jam)}）');
  });

  /// 单挑：翻牌/转牌都过牌，河牌没人下注时量 AI 的选择——
  /// 过牌率 / 下注率 / 平均尺度（下注额 ÷ 下注前底池）/ 超池率。
  /// [oop] 为真时 AI 在大盲位（河牌先说话）。
  ({double bet, double check, double avgFrac, double overbet, int n})
      aiRiverCheckedTo(String hole, String board,
          {bool oop = false, int seeds = 200}) {
    var bet = 0, check = 0, over = 0, n = 0;
    final fracs = <double>[];
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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

  t('河牌尺度：超池不再是「只有坚果」的独家信号', () {
    const board = 'Kd 8c 3h 2s 5d';
    final set = aiRiverCheckedTo('8h 8s', board);
    final over = aiRiverCheckedTo('Ah Ad', board);
    final secondPair = aiRiverCheckedTo('8h 7s', board);
    String pct(double v) => '${(100 * v).round()}%';

    expect(set.n, greaterThan(_trialSeeds(100)));
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

  t('河牌顶对：不会 100% 下注，留一档过牌护住自己的过牌范围', () {
    // 翻牌（没位置的强牌）和转牌（非空白牌）都有「拿强牌过牌控池」这一档，
    // 只有河牌是漏的：探针实测「河牌顶对（无人下注）」下注 100%、过牌 0%。
    // 对手看到我们河牌一过牌就知道手里没东西，随便一枪就能把底池收走；
    // 我们的强牌也永远只有「下注 → 被跟注」这一种结局，对手的诈唬和薄
    // 价值没有机会自己送上门——一手牌的三条街必须是同一套逻辑。
    String pct(double v) => '${(100 * v).round()}%';
    // 9s 既没配对面的公对，也没凑出第三张同花：标准的空白河牌。
    final blank = aiRiverCheckedTo('Ah Qd', 'Qh 7d 2c 5h 9s');
    // 9h 凑出第三张同花，对手的过牌-加注就藏在这张牌后面。
    final flushed = aiRiverCheckedTo('Ah Qd', 'Qh 7d 2c 5h 9h');
    expect(blank.n, greaterThan(_trialSeeds(100)), reason: '样本要够');
    expect(flushed.n, greaterThan(_trialSeeds(100)), reason: '样本要够');
    expect(blank.check, greaterThan(0.08),
        reason: '顶对在河牌要抽一部分过牌（过牌 ${pct(blank.check)}）');
    expect(blank.bet, greaterThan(0.6),
        reason: '但主体还是价值下注，别把顶对打过成抓诈唬牌'
            '（下注 ${pct(blank.bet)}）');
    expect(flushed.check, greaterThan(blank.check - 0.05),
        reason: '牌面凑出第三张同花时收手不能更少'
            '（过牌 ${pct(flushed.check)} vs 空白牌 ${pct(blank.check)}）');
  });

  t('河牌重注：顶对要挑着弃，两对不弃但也是以跟为主', () {
    // 强牌档以前是「面对大注一律跟」：探针实测顶对面对 1 倍池跟 100%、
    // 面对 1.5 倍池跟 99%，而「连开三枪 + 超池」那条线上有一半牌局是直接
    // 推出去的。顶对在河牌是**抓诈唬**的牌：对手抡大注要么是坚果要么是
    // 空气，全跟等于把自己整个跟注范围压成「只有他打不赢的牌才跟」；再加
    // 就更亏——把对手的诈唬打走、只留下能打败我们的牌。
    // 现在按尺度挑着弃，但留够抓诈唬的那部分；两对（怪兽档）不受影响。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh 7d 2c 5h 9s';
    final half = aiVsRiverBet('Ah Qd', board, 0.5);
    final pot = aiVsRiverBet('Ah Qd', board, 1.0);
    final over = aiVsRiverBet('Ah Qd', board, 1.5);
    final barrel = aiVsRiverBet('Ah Qd', board, 1.5, barrel: true);
    for (final r in [half, pot, over, barrel]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    // 半池是正常价值注/薄价值，按赔率就该跟，没有弃的道理。
    expect(half.fold, lessThan(0.05),
        reason: '半池不该弃（弃 ${pct(half.fold)}）');
    // 满池开始挑着弃，但主体还是跟——留下的那部分才是抓诈唬的。
    expect(pot.fold, greaterThan(0.04),
        reason: '满池要挑着弃（弃 ${pct(pot.fold)}）');
    expect(pot.fold, lessThan(0.35),
        reason: '满池不能弃成弃牌机器（弃 ${pct(pot.fold)}）');
    // 尺度越大弃得越多，而且要看得出来。
    expect(over.fold, greaterThan(pot.fold + 0.15),
        reason: '超池要比满池弃得多（超池弃 ${pct(over.fold)} vs '
            '满池弃 ${pct(pot.fold)}）');
    expect(over.call, greaterThan(0.35),
        reason: '超池也得留一部分抓诈唬（跟 ${pct(over.call)}）');
    // 加注在这儿是错的：等于把对手的诈唬打走、把能打败我们的牌请进来。
    expect(over.raise, lessThan(0.1),
        reason: '面对超池不该再加（加 ${pct(over.raise)}）');
    // 对手连开三枪之后的超池，范围比「前面全过牌再抡」实得多，弃牌率不该掉回去。
    expect(barrel.fold, greaterThan(0.25),
        reason: '连开三枪的超池更该弃（弃 ${pct(barrel.fold)}）');

    // 筹码快套进去时（翻前造个大池、河牌超池把 SPR 压到 1 出头）也是同一个
    // 道理，而且更极端：这一格改之前是 100% 推全下——拿顶对把剩下整叠筹码
    // 推给一条两极的线，对手的诈唬会跑掉、能打败我们的牌全跟进来。
    final shallow =
        aiVsRiverBet('Ah Qd', board, 1.5, preflopRaiseTo: 1200);
    expect(shallow.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(shallow.raise, lessThan(0.1),
        reason: '河牌超池不该把顶对推出去（加 ${pct(shallow.raise)}）');
    expect(shallow.fold, greaterThan(0.15),
        reason: 'SPR 压到 1 出头也还该挑着弃（弃 ${pct(shallow.fold)}）');

    // 对照：两对是真正的价值牌，不该跟顶对一样被打成弃牌——同一个超池
    // 面前它一手都不弃、加注频率也比顶对高一大截。但「不弃」不等于
    // 「往上顶」：超池那条线是两极的，拿两对加注只会把诈唬打走、把更好的
    // 牌请进来，所以它在这一格也是以跟为主（见下一条用例）。
    final twoPair = aiVsRiverBet('9h 7d', 'Qh 9d 7c 5h 2s', 1.5);
    expect(twoPair.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(twoPair.fold, lessThan(0.05),
        reason: '两对不该弃（弃 ${pct(twoPair.fold)}）');
    expect(twoPair.raise, greaterThan(over.raise + 0.2),
        reason: '两对还是比顶对凶（两对加 ${pct(twoPair.raise)} vs '
            '顶对加 ${pct(over.raise)}）');
    expect(twoPair.call, greaterThan(twoPair.raise),
        reason: '超池面前两对以跟为主（加 ${pct(twoPair.raise)} 跟 '
            '${pct(twoPair.call)}）');
  });

  t('怪兽牌：对手下得越大，加注越少（超池主要是跟）', () {
    // 真人对小注加注、对大注跟注。对手下得越大，他的范围越两极化——转牌/
    // 河牌的重注（尤其是超池）不是坚果就是空气，我们的加注只会把诈唬打走、
    // 把能打败我们的牌请进来；而且他真有大牌时，我们的加注等于自己把筹码
    // 送进去。以前这一档完全不看尺度：实测河牌拿两对，对着 0.5 倍池加
    // 76%、对着 1.5~2 倍池反而加到 95%（多出来的部分全是低 SPR 的自动推），
    // 「对手下得越大我们加得越凶」——正好反了，对手拿任意两张牌超池抡一下
    // 就能把我们的加注范围读成「全是大家伙」。
    //
    // 翻牌圈不吃这一档（[aiVsHeroBet] 那两行）：那时候加注是「收听牌的
    // 钱」，对手下得大说明底池涨得快、更要保护，真人对小注大注都愿意加。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh 9d 7c 5h 2s';
    final small = aiVsRiverBet('9h 7d', board, 0.5);
    final pot = aiVsRiverBet('9h 7d', board, 1.0);
    final over = aiVsRiverBet('9h 7d', board, 1.5);
    final huge = aiVsRiverBet('9h 7d', board, 2.0);
    for (final r in [small, pot, over, huge]) {
      expect(r.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
      expect(r.fold, lessThan(0.05),
          reason: '怪兽牌不会弃（弃 ${pct(r.fold)}）');
    }
    expect(small.raise, greaterThan(0.6),
        reason: '小注是价值注，照旧以加为主（加 ${pct(small.raise)}）');
    expect(pot.raise, lessThan(small.raise - 0.1),
        reason: '满池比小注少加（${pct(small.raise)} → ${pct(pot.raise)}）');
    expect(over.raise, lessThan(pot.raise - 0.1),
        reason: '超池比满池少加（${pct(pot.raise)} → ${pct(over.raise)}）');
    expect(huge.raise, lessThan(small.raise - 0.3),
        reason: '2 倍池跟小注要拉开差距（小注 ${pct(small.raise)} vs '
            '2 倍池 ${pct(huge.raise)}）');
    expect(huge.call, greaterThan(huge.raise),
        reason: '超大注面前以跟为主（加 ${pct(huge.raise)} 跟 '
            '${pct(huge.call)}）');

    // 转牌同一条线（后面还有一条街，收了一点折扣，但方向一样）。
    final turnSmall = aiVsTurnBet('9h 7d', 'Qh 9d 7c 5h', 0.66);
    final turnOver = aiVsTurnBet('9h 7d', 'Qh 9d 7c 5h', 1.5);
    expect(turnSmall.n, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(turnOver.n, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(turnSmall.raise, greaterThan(turnOver.raise + 0.15),
        reason: '转牌同样是「下得越大加得越少」'
            '（0.66 池 ${pct(turnSmall.raise)} vs 1.5 池 ${pct(turnOver.raise)}）');

    // 翻牌圈是另一条线：加大注是为了收听牌的钱，尺度不该改变动机
    // （以前翻牌/转牌/河牌共用一个尺度的线，河牌才会出现「越大越加」）。
    final flopSmall =
        aiVsHeroBet('9h 7d', 'Qh 9d 7c', 0.5, street: Street.flop);
    final flopBig =
        aiVsHeroBet('9h 7d', 'Qh 9d 7c', 1.2, street: Street.flop);
    expect(flopSmall.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(flopBig.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
    expect(flopSmall.raise, greaterThan(0.4),
        reason: '翻牌拿两对该加（加 ${pct(flopSmall.raise)}）');
    expect(flopBig.raise, greaterThan(0.4),
        reason: '翻牌面对大注也照样加（加 ${pct(flopBig.raise)}）');
  });

  t('转牌重注：顶对也要挑着弃，但收得比河牌晚', () {
    // 河牌那条「重注要挑着弃」的档现在也管转牌，只是打个折：后面还有一条
    // 街、还有补牌，真人在这儿收得比河牌晚。改之前探针实测转牌顶对面对
    // 1 倍池 / 1.5 倍池都是 100% 跟，「连开两枪超池」那条线还有两成是把
    // 筹码直接推出去的——和河牌是同一个毛病，只少了一条街。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'Qh 7d 2c 5s';
    final half = aiVsTurnBet('Ah Qd', board, 0.5);
    final pot = aiVsTurnBet('Ah Qd', board, 1.0);
    final over = aiVsTurnBet('Ah Qd', board, 1.5);
    final barrels = aiVsTurnBet('Ah Qd', board, 1.5, barrel: true);
    for (final r in [half, pot, over, barrels]) {
      expect(r.n, greaterThan(_trialSeeds(40)), reason: '样本要够');
    }
    // 半池是正常价值注，按赔率就该跟，没有让它掉一半的道理。
    expect(half.fold, lessThan(0.05),
        reason: '转牌半池不该弃（弃 ${pct(half.fold)}）');
    // 满池开始挑着弃，超池弃得更多；但转牌整体上还是以跟为主。
    expect(pot.fold, greaterThan(0.02),
        reason: '转牌满池要挑着弃（弃 ${pct(pot.fold)}）');
    expect(over.fold, greaterThan(pot.fold + 0.08),
        reason: '同一个牌力，超池比满池弃得多'
            '（超池弃 ${pct(over.fold)} vs 满池弃 ${pct(pot.fold)}）');
    expect(over.raise, lessThan(0.05),
        reason: '转牌超池不该再加（加 ${pct(over.raise)}）');
    // 连开两枪的超池：对手的范围更实，弃得更多；而且不该往上推（改之前
    // 这条线上有 26% 是把顶对推出去的）。
    expect(barrels.fold, greaterThan(over.fold + 0.08),
        reason: '连开两枪的超池更该弃'
            '（弃 ${pct(barrels.fold)} vs 单枪超池弃 ${pct(over.fold)}）');
    expect(barrels.raise, lessThan(0.05),
        reason: '连开两枪的转牌超池不该再加（加 ${pct(barrels.raise)}）');

    // 对照：同一手牌、同一个尺度，河牌要比转牌收得更紧——转牌的顶对还留着
    // 补牌和摊牌价值，河牌已经没有下一条街了。
    final riverPot = aiVsRiverBet('Ah Qd', 'Qh 7d 2c 5h 9s', 1.0);
    final riverOver = aiVsRiverBet('Ah Qd', 'Qh 7d 2c 5h 9s', 1.5);
    expect(riverPot.fold, greaterThan(pot.fold),
        reason: '满池：河牌弃得比转牌多'
            '（河牌弃 ${pct(riverPot.fold)} vs 转牌弃 ${pct(pot.fold)}）');
    expect(riverOver.fold, greaterThan(over.fold + 0.15),
        reason: '超池：河牌弃得比转牌多'
            '（河牌弃 ${pct(riverOver.fold)} vs 转牌弃 ${pct(over.fold)}）');
  });

  t('河牌下注被加注：顶对不再推回去，只跟', () {
    // 「AI 自己下注 → 被对手过牌-加注」这条线。改之前强牌档会踩中
    // 「SPR ≤ 1.5 就把筹码推出去」那一档：河牌下注-被加注之后 SPR 正好掉到
    // 1.2 上下，于是顶对顶踢有 94% 的牌局又 3-bet 回去。河边加注是最后一个
    // 信号，一对牌被抬起来还往上推，等于对手拿任意两张牌加一下就白拿——
    // 我们只留下能打败我们的牌，把他所有诈唬打走。
    String pct(double v) => '${(100 * v).round()}%';
    const board = 'As 7c 2d 5h 9s';
    for (final mult in [2.2, 3.5]) {
      final top = aiVsBetThenRaise('Ah Kd', board, mult, street: Street.river);
      final over = aiVsBetThenRaise('9h 9d', '7s 4h 2d 5h 3c', mult,
          street: Street.river);
      expect(top.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
      expect(over.total, greaterThan(_trialSeeds(40)), reason: '样本要够');
      expect(top.raise, lessThan(0.25),
          reason: '河牌被加到 $mult 倍，顶对顶踢不该 3-bet'
              '（再加 ${pct(top.raise)}）');
      expect(top.call, greaterThan(0.6),
          reason: '河牌被加到 $mult 倍，顶对顶踢该以跟为主'
              '（跟 ${pct(top.call)}）');
      expect(over.raise, lessThan(0.25),
          reason: '河牌被加到 $mult 倍，超对不该 3-bet'
              '（再加 ${pct(over.raise)}）');
    }
    // 对照：同一条「下注-被加注」的线在翻牌还得能加回去。翻牌的顶对还远没到
    // 抓诈唬那一步，被抬一手就只会跟，对手拿听牌随便加一下就能把我们的强牌
    // 变成纯跟注站（那时候我们前面那条加注战闸门才刚修好）。
    final flop =
        aiVsBetThenRaise('Ah Kd', 'As 7c 2d', 2.2, street: Street.flop);
    expect(flop.total, greaterThan(_trialSeeds(40)));
    expect(flop.raise, greaterThan(0.25),
        reason: '翻牌该留 3-bet，别把整条线一起收没了（再加 ${pct(flop.raise)}）');
  });

  t('位置差异：浮牌是位置的特权，没位置不拿空气乱跟', () {
    // 同一手（A高 + 后门花）、同一个 1/3 池翻牌下注、同一个底池构成，
    // 只差有没有位置。以前两边频率一模一样（探针：有位置 25% vs 没位置
    // 26%），等于「位置」这个变量在跟注决策里根本不存在——没位置的 AI
    // 一样爱浮牌，跟一张之后还得在不利位置打后面两条街，成牌也榨不出价值。
    String pct(double v) => '${(100 * v).round()}%';
    const hole = 'Ad 10d';
    const board = '9d 7c 2c';
    final ip = aiVsCheckBet(hole, board, 0.33, seeds: 200, oop: false);
    final oop = aiVsCheckBet(hole, board, 0.33, seeds: 200);

    expect(ip.total, greaterThan(_trialSeeds(100)), reason: '有位置样本要够（n=${ip.total}）');
    expect(oop.total, greaterThan(_trialSeeds(100)), reason: '没位置样本要够（n=${oop.total}）');
    expect(ip.call, greaterThan(0.2),
        reason: '有位置的 A 高 + 后门花该浮牌（跟 ${pct(ip.call)}）');
    expect(oop.call, lessThan(ip.call - 0.15),
        reason: '没位置浮牌要明显更少（跟 ${pct(oop.call)} vs '
            '${pct(ip.call)}）');
    expect(oop.fold, greaterThan(ip.fold + 0.1),
        reason: '没位置更多直接放弃（弃 ${pct(oop.fold)} vs '
            '${pct(ip.fold)}）');
  });

  t('浮牌：后门花 + 两张高张不会见注就弃', () {
    // 8-7-2 这种小牌面：A 高配后门花是真人最爱跟一张的浮牌。
    const board = '8h 7d 2s';
    // 有位置：后门花该跟一张看转牌，纯高张（没后门）就该收手。
    final float = aiVsCheckBet('As Qs', board, 0.5, seeds: 150, oop: false);
    final dry = aiVsCheckBet('As Qd', board, 0.5, seeds: 150, oop: false);
    String pct(double v) => '${(100 * v).round()}%';

    expect(float.call, greaterThan(dry.call + 0.08),
        reason: '有后门花才值得跟一张看转牌 '
            '(${pct(float.call)} vs ${pct(dry.call)})');
    // 但浮牌是少数派：主体还是弃牌。
    expect(float.fold, greaterThan(0.2),
        reason: '浮牌只是混入的频率，主体还是弃牌（弃 ${pct(float.fold)}）');
    // 没位置：浮牌是位置的特权，同样的牌别乱跟。
    final floatOop = aiVsCheckBet('As Qs', board, 0.5, seeds: 150);
    expect(floatOop.fold, greaterThan(0.8),
        reason: '没位置不该拿 A 高乱浮牌（弃 ${pct(floatOop.fold)}）');
  });

  t('弱听牌：注从 0.41 池涨到 0.6 池，跟注率连续收窄而不是断崖', () {
    // 听牌那一档以前只有**强听牌**在门槛上用过渡带混着打，弱听牌走的是
    // 裸 `drawEq >= need`——卡顺的出路数不随尺度变（4 outs 就是固定的
    // 4/47），门槛却随尺度线性爬，两条线交叉的那一点就把跟注整档切掉。
    // 探针实测（JT on Q82 翻牌面对下注，400 手一格）：40.5% 池跟 93%、
    // 41% 池直接弃 93%，半个百分点的池差换一次决定；对手把尺度挪半格就
    // 能把这手牌的跟注关掉。现在是门槛以下 0.035 的斜坡、门槛以上不动
    // （见 [AiPlayer._drawCallOrFold]）。
    //
    // 斜坡本身也修过一次：[AiPlayer._callMix] 的 [h]band: 0[h] 那一档
    // （「门槛以上一律跟」）走的是下坡从 0.5 起算的通用式子，而上方那条
    // 斜坡在 band 为 0 时只剩一个点、取值是 1.0——门槛两侧于是留着整整
    // 0.5 的台阶。探针实测：40.5% 池跟 93%、41% 池只剩 44%，比修之前
    // 好一点，可还是「半个百分点的池差换掉一半跟注率」。门的上下都得是
    // 1.0，斜坡才连得上。
    String pct(double v) => '${(100 * v).round()}%';
    final cheap = aiVsHeroBet('Jh 10h', 'Qd 8d 2c', 0.40, seeds: 400);
    final justBelow = aiVsHeroBet('Jh 10h', 'Qd 8d 2c', 0.405, seeds: 400);
    final edge = aiVsHeroBet('Jh 10h', 'Qd 8d 2c', 0.41, seeds: 400);
    final mid = aiVsHeroBet('Jh 10h', 'Qd 8d 2c', 0.46, seeds: 400);
    final big = aiVsHeroBet('Jh 10h', 'Qd 8d 2c', 0.60, seeds: 400);
    for (final r in [cheap, justBelow, edge, mid, big]) {
      expect(r.total, greaterThan(_trialSeeds(200)),
          reason: '样本太少（n=${r.total}）');
    }
    // 门槛以上（这是占了便宜的价格）照旧跟满，斜坡不许往上摊。
    expect(cheap.call, greaterThan(0.8),
        reason: '0.40 池就丢牌了（跟 ${pct(cheap.call)}）——斜坡铺到门槛上面去了？');
    // 门槛（约 0.405 池，胜率减门槛归零的那一点）两侧不许有台阶：
    // 修之前这里是「跟 93%」紧接着「跟 44%」。
    expect((justBelow.call - edge.call).abs(), lessThan(0.12),
        reason: '0.405→0.41 池之间掉了一大截'
            '（${pct(justBelow.call)} → ${pct(edge.call)}）——'
            '斜坡的起点不是 1.0？');
    // 门槛以下是渐变的：0.41 池还在跟，但已经不是跟满。
    expect(edge.call, greaterThan(0.6),
        reason: '0.41 池就整档关掉（跟 ${pct(edge.call)}）——又退回裸阈值了？');
    expect(edge.call, lessThan(0.95),
        reason: '0.41 池还是跟满（跟 ${pct(edge.call)}）——斜坡没生效？');
    // 收窄必须是单调的：注越大跟得越少，中间不许反弹。
    expect(edge.call, greaterThan(mid.call),
        reason: '0.41 → 0.46 池没有继续收窄（${pct(edge.call)} → ${pct(mid.call)}）');
    expect(mid.call, greaterThan(big.call),
        reason: '0.46 → 0.60 池没有继续收窄（${pct(mid.call)} → ${pct(big.call)}）');
    // 大注那一端还是要收手。
    expect(big.call, lessThan(0.05),
        reason: '0.6 池还拿着卡顺在跟（跟 ${pct(big.call)}）');
    expect(big.fold, greaterThan(0.8),
        reason: '0.6 池弃得不够干净（弃 ${pct(big.fold)}）');
  });

  t('浮牌：便宜的价格要多浮，0.25~0.6 池不许是一条水平线', () {
    // 这一档改过两次。先是修掉 `betSizeRel > 0.6 就不浮` 那道硬门槛；
    // 第二次（这一条）修的是斜坡留下的常量区间——大注侧铺上斜坡之后，
    // 「0.6 池以内逐点不变」自己变成了新的破绽：探针 tool/ai_probe.dart
    // 实测 0.25 / 0.30 / 0.35 / 0.40 / 0.50 / 0.55 / 0.60 池那七格的跟注率
    // 逐字相同（都是 21%），对手把注从 0.6 池收小到 0.25 池，浮牌率一点
    // 没变——「便宜的价格更值得跟一张」这个真人最基本的判断在这一段根本
    // 不存在，他大可以照 0.6 池的价格收价值。便宜那侧现在也有斜坡了
    // （见 [AiPlayer._floatChance]），这一条量的就是它。
    // 用 [aiVsHeroBet] 这条线：AI 翻前先加注（它才是主动方，浮牌的入口
    // 挂在「我开过火」的线上），翻牌面对英雄的下注。AI 拿 A♥Q♥ 在
    // 8♦7♣2♠ 上（两张高张、没有后门花），走的正是浮牌那一档。
    const board = '8d 7c 2s';
    String pct(double v) => '${(100 * v).round()}%';
    final tiny = aiVsHeroBet('Ah Qh', board, 0.25, seeds: 400);
    final small = aiVsHeroBet('Ah Qh', board, 0.35, seeds: 400);
    final half = aiVsHeroBet('Ah Qh', board, 0.5, seeds: 400);
    final edge = aiVsHeroBet('Ah Qh', board, 0.6, seeds: 400);
    for (final r in [tiny, small, half, edge]) {
      expect(r.total, greaterThan(_trialSeeds(150)),
          reason: '样本太少（n=${r.total}）');
    }
    // 注越小浮得越多，中间不许反弹。
    expect(tiny.call, greaterThanOrEqualTo(small.call),
        reason: '0.25 → 0.35 池没有多浮（${pct(tiny.call)} → '
            '${pct(small.call)}）——便宜那侧的斜坡没生效？');
    expect(small.call, greaterThanOrEqualTo(half.call),
        reason: '0.35 → 0.50 池没有继续收窄（${pct(small.call)} → '
            '${pct(half.call)}）');
    expect(half.call, greaterThanOrEqualTo(edge.call),
        reason: '0.50 → 0.60 池没有继续收窄（${pct(half.call)} → '
            '${pct(edge.call)}）');
    // 拉开的那一截要看得见：改之前这两格都是 21%，差 0 个点。
    expect(tiny.call - edge.call, greaterThan(0.06),
        reason: '0.25 池和 0.6 池浮得几乎一样多（${pct(tiny.call)} vs '
            '${pct(edge.call)}）——常量区间又回来了？');
    // 便宜这一端要真的抬起来：改之前 0.25 / 0.35 / 0.5 / 0.6 池四格都是
    // 跟 21%（同一批种子、逐字相同）。
    expect(tiny.call, greaterThan(0.24),
        reason: '0.25 池没有比原来多浮（跟 ${pct(tiny.call)}，改前 21%）');
    // 0.6 池是两条斜坡的接点，便宜侧的改动不该把它抬起来（改前改后都是
    // 21%，见 [AiPlayer._floatChance] 里两个 clamp 的锚点）。
    expect(edge.call, lessThan(0.26),
        reason: '0.6 池那个锚点被便宜侧的斜坡抬起来了（${pct(edge.call)}）');
  });

  t('浮牌：注从 0.6 池涨到 1 池，浮牌率连续收窄而不是整档关掉', () {
    // 见下面那条（便宜的价格要多浮）：这一条管大注那半段，0.6 池是两条
    // 斜坡的接点，所以它的读数一个点都不该被便宜侧的改动抬起来。
    // 浮牌以前挂在一条硬门槛上（`betSizeRel > 0.6 直接返回 0`）：探针实测
    // 同一手「后门花 + 两张高张」，0.55 池浮 21%、0.62 池一手都不浮。
    // 而且这一档一关，浮牌登记的那条半诈唬线整条消失——转牌对手过牌后
    // 「接着开火」的频率挂在它上面，对手把注抬过 0.6 池就能同时关掉两条
    // 街的诈唬。现在是 0.6~1.2 池的线性斜坡（见 [AiPlayer._floatChance]）。
    const board = '8h 7d 2s';
    String pct(double v) => '${(100 * v).round()}%';
    final mid = aiVsCheckBet('As Qs', board, 0.6, seeds: 250, oop: false);
    final big = aiVsCheckBet('As Qs', board, 0.7, seeds: 250, oop: false);
    final huge = aiVsCheckBet('As Qs', board, 1.0, seeds: 250, oop: false);
    expect(mid.total, greaterThan(_trialSeeds(100)),
        reason: '样本太少（n=${mid.total}）');
    // 0.6 池那一档不许被整档关掉：它得跟 0.5 池同一量级。
    expect(mid.call, greaterThan(0.1),
        reason: '0.6 池就整档不浮了（跟 ${pct(mid.call)}）——又退回硬门槛了？');
    // 收窄必须是连续的：0.6 → 0.7 只掉一点，不许一步掉光。
    expect(mid.call - big.call, lessThan(0.08),
        reason: '0.6 → 0.7 池之间出现台阶（${pct(mid.call)} → ${pct(big.call)}）');
    // 大注那端照旧收手（斜坡跑满那一头）。
    expect(huge.call, lessThan(mid.call - 0.05),
        reason: '1 池还跟 0.6 池一样爱浮（${pct(huge.call)} vs ${pct(mid.call)}）');
  });

  t('翻牌 c-bet：干面是范围小注（不看牌力都打），湿面才挑牌', () {
    // 干面 K-8-3 / 9-5-2：翻前加注者在这儿打的是「范围小注」——对手同样
    // 很难有牌，真人是拿 1/3 池的小注把整个范围铺出去，不看自己手里
    // 有没有后路。以前这里完全跟着牌力走（什么都没沾的牌只开火两成多），
    // 等于把对手最容易弃牌的牌面让出去，而且下注范围一眼就能被读出牌力。
    final dryNothing =
        aiBetRateWhenCheckedTo('9h 8h', 'Kd 2c 3s', Street.flop, seeds: 200);
    final dryOneOver =
        aiBetRateWhenCheckedTo('Ah 5h', 'Kd 2c 3s', Street.flop, seeds: 200);
    final dryTwoOver =
        aiBetRateWhenCheckedTo('Qs Jd', '9s 5d 2c', Street.flop, seeds: 200);
    final dryBdFlush =
        aiBetRateWhenCheckedTo('Qs Js', '9s 5d 2c', Street.flop, seeds: 200);
    String pct(double v) => '${(100 * v).round()}%';
    for (final (name, r) in [
      ('纯垃圾', dryNothing),
      ('一张高张', dryOneOver),
      ('两张高张', dryTwoOver),
    ]) {
      expect(r, greaterThan(0.5),
          reason: '干面上「$name」也要按范围小注打（${pct(r)}）');
    }
    // 范围小注的意思就是「选牌的差距很小」：干面上后门花多的牌
    // 不比纯垃圾多打多少，因为两者都在同一个下注范围里。
    expect(dryBdFlush - dryNothing, lessThan(0.25),
        reason: '干面是范围小注，不该按后路挑牌 '
            '(${pct(dryBdFlush)} vs ${pct(dryNothing)})');

    // 湿面 Q-9-8（连着 + 两张同花）：牌面本身什么都有可能，这时候才是
    // 真的要挑牌——有听牌的敢打，什么都没沾的老实过牌。
    final wetDraw =
        aiBetRateWhenCheckedTo('Jc 10c', 'Qh 9h 8c', Street.flop, seeds: 200);
    final wetNothing =
        aiBetRateWhenCheckedTo('5d 4d', 'Qh 9h 8c', Street.flop, seeds: 200);
    expect(wetDraw, greaterThan(wetNothing + 0.3),
        reason: '湿面上有听牌的才开火，什么都没沾的收手 '
            '(${pct(wetDraw)} vs ${pct(wetNothing)})');
    expect(wetNothing, lessThan(0.45),
        reason: '湿面上纯空气不该无脑开火（${pct(wetNothing)}）');
    // 再湿的牌面也还是要留一点开火频率：有弃牌率、有对手读数时得有这一手。
    expect(wetNothing, greaterThan(0.08),
        reason: '纯空气也要留一点开火频率（${pct(wetNothing)}）');
  });

  /// 单挑/多人：AI 在按钮位开池，其他人都过牌/跟注，量 AI 翻牌圈
  /// 「下注额 ÷ 下注前底池」的平均值（只看它真的下注的那些手）。
  /// 注意：`board` 目前**没有**传给引擎（历史遗留），量到的是随机牌面。
  /// 要钉住牌面量尺度用 [aiCheckedToMultiway]（它的 avgFrac 同口径）。
  ({double frac, int n}) aiFlopBetFrac(String hole, String board,
      {int others = 0, int seeds = 250}) {
    final all = <double>[];
    for (var seed = 0; seed < _trialSeeds(seeds); seed++) {
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

  t('下注尺度：诈唬和价值不能分成两档（不然小注就是明牌）', () {
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

  t('下注尺度：顶对 + 坚果花听比纯顶对下得更大', () {
    // [AiPlayer._strongDrawSizeScale] 的另一半：被过牌到时，强牌档里的
    // 成牌 + 强听该比纯成牌下得更大（真人拿它既收价值也保护，被跟了还有
    // 一条街的出路）。同一块 Q♦7♦2♣，只换底牌——A♠Q♦ 一张方片刚好没有
    // 花听，牌面纹理一模一样，差的只有「有没有这 9 张出路」。
    final plain = aiCheckedToMultiway('As Qd', 'Qd 7d 2c', seeds: 600);
    final draw = aiCheckedToMultiway('Ad Qd', 'Qd 7d 2c', seeds: 600);
    expect(plain.n > _trialSeeds(60) && draw.n > _trialSeeds(60), isTrue,
        reason: '两手的下注样本都要够（${plain.n}/${draw.n}）');
    // 实测 0.44 vs 0.39 倍池（差 0.047），留 0.03 的余量：塌回同一条线
    // （两档相等）必报红。
    expect(draw.avgFrac, greaterThan(plain.avgFrac + 0.03),
        reason: '顶对 + 坚果花听该比纯顶对下得更大'
            '（${draw.avgFrac.toStringAsFixed(2)} vs '
            '${plain.avgFrac.toStringAsFixed(2)} 倍池）');
    // 抬的是尺度不是把下注范围清空：两手都得以价值下注为主。
    expect(plain.avgFrac, greaterThan(0.3),
        reason: '纯顶对照样要做正常价值下注（${plain.avgFrac.toStringAsFixed(2)}）');
    expect(draw.avgFrac, lessThan(0.75),
        reason: '听牌那一侧也别抬成超池明线（${draw.avgFrac.toStringAsFixed(2)}）');
  });

  t('存档：一局的桌面快照能原样存回来，坏存档不会崩', () async {
    final file = File('${Directory.systemTemp.path}/poker_session_test.json');
    final store = TableSessionStore(file);
    await store.clear();
    expect(await store.load() == null, isTrue, reason: '没存过就读到 null');

    final session = TableSession(
      id: 'table-1',
      label: '实战 6人桌 · 50/100',
      name: '实战 6人桌',
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
  }, fast: true);

  t('存档：按钮位拨回上一手后，下一手照常前移', () {
    final g = GameEngine(config: const GameConfig(), random: Random(5))
      ..addPlayer('a', 'A')
      ..addPlayer('b', 'B')
      ..addPlayer('c', 'C');
    g.buttonIndex = 1;
    g.startHand();
    expect(g.buttonIndex, 2);
    expect(g.handOver, isFalse);
  }, fast: true);

  t('存档：按快照重建的牌桌，座位/筹码/按钮位都照原样', () {
    final session = TableSession(
      id: 'table-2',
      label: '单挑 · 松凶',
      name: '单挑 · 松凶',
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
  }, fast: true);

  t('存档：关掉再打开，回来还是同一张桌、同一批筹码', () async {
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
        name: '实战 6人桌', config: config, playerCount: 6);
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

  t('引擎快照：打到一半存下来，恢复后接着打完一模一样', () {
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

  t('存档：牌局打到一半退出，回来接着把这一手打完', () async {
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
        name: '实战 单挑', config: config, playerCount: 2);
    // 打几个动作，停在手牌中途（没打完就「退出 App」）。
    var steps = 0;
    while (!first.engine.handOver && steps++ < 3) {
      if (first.heroToAct) first.heroAct(ActionType.call);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // 等牌桌安静下来再读状态。英雄动作之后 AI 还会异步接一手（下注轮打完就
    // 翻牌/转牌），在它行进中间读出来的 `engine.board` 是「半截」的，而这一刻
    // 盘上的存档还停在上一个动作——两边对不上，用例就假失败。连续几拍都轮到
    // 英雄行动 = 没人还在思考，此时引擎和存档才停在同一个点上。
    var quiet = 0;
    while (quiet < 3 && !first.engine.handOver) {
      quiet = first.heroToAct ? quiet + 1 : 0;
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
    // 自动落盘是异步的，这里等「**跟当前牌桌完全一致**的那一版」写进文件为止：
    // 光等 `hand != null` 可能抓到更早一次动作的旧快照，后面逐项比对就会假失败。
    final live = first.engine.toSnapshotJson();
    final raw = await _readSessionWhen(
        file, (j) => jsonEncode(j['hand']) == jsonEncode(live));
    expect(raw, isNotNull,
        reason: '打到一半也要落盘（文件里没有与当前牌桌一致的快照）');
    expect(raw!['hand'] != null, isTrue, reason: '打到一半也要落盘');

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
  }, fast: true);

  t('存档：一手打完后不再存这半截，下一手照常重新发牌', () async {
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
        name: '实战 单挑', config: config, playerCount: 2);
    var guard = 0;
    while (!first.engine.handOver && guard++ < 400) {
      if (first.heroToAct) first.heroAct(ActionType.fold);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(first.engine.handOver, isTrue);
    final finishedId = first.engine.lastHand!.id;
    final handsAfter = first.handsPlayed;
    // 结算后写下的那版不该再带半截手牌。等它落到盘上——固定 sleep 20ms 在忙的
    // 机器上会读到「还在打」的旧快照。
    final raw = await _readSessionWhen(file, (j) => j['hand'] == null);
    expect(raw, isNotNull, reason: '结算后要落盘');
    expect(raw!['hand'] == null, isTrue, reason: '两手之间不存半截手牌');

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
  }, fast: true);

  t('对局标题：桌名不带盲注，本手输赢跟着筹码走', () {
    final t = TableController(random: Random(7), aiThinkTime: Duration.zero);
    t.startRealTable(
      name: '实战 单挑',
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      playerCount: 2,
    );
    // 大厅卡片和存档继续带盲注级别，导航栏标题用不带盲注的桌名。
    expect(t.tableLabel, '实战 单挑 · 50/100');
    expect(t.tableName, '实战 单挑');
    // 单挑：英雄坐按钮 = 小盲，一开局就投了 50。
    expect(t.heroHandNet, -50, reason: '盲注已经出去了');

    // 弃牌走完这一手：导航栏的数字要和结算条里的「本手输赢」对得上。
    t.heroAct(ActionType.fold);
    expect(t.engine.handOver, isTrue, reason: '英雄弃牌后本手结束');
    expect(t.heroHandNet, -50);
    expect(t.heroHandNet, t.lastHand!.netResult[TableController.heroId],
        reason: '标题里的数字必须等于结算数值');
    expect(t.handsPlayed, 1);
  }, fast: true);

  t('继续上局：标题桌名跟着存档回来，不带盲注', () async {
    final dir = Directory.systemTemp.createTempSync('pt_session_name');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/session.json');
    const config =
        GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

    final first = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(31),
      aiThinkTime: Duration.zero,
    );
    // 大厅/存档用带盲注的完整标签，对局页标题只用桌名。
    first.startRealTable(name: '实战 9人桌', config: config, playerCount: 3);
    expect(first.tableLabel, '实战 9人桌 · 50/100');
    expect(first.tableName, '实战 9人桌');
    await first.persistSession();

    // 存档里单独存了不带盲注的桌名，恢复时不至于拿 label 当标题。
    final raw =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['name'], '实战 9人桌');
    expect(raw['label'], '实战 9人桌 · 50/100');

    final cold = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(32),
      aiThinkTime: Duration.zero,
    );
    await cold.loadSession();
    expect(cold.resumeSession(), isTrue);
    expect(cold.tableName, '实战 9人桌', reason: '续局后标题还是不带盲注');
    expect(cold.tableLabel, '实战 9人桌 · 50/100',
        reason: '大厅卡片仍然要能看到盲注');

    // 老存档没有 'name' 字段：从 label 里把盲注后缀剪掉，别让标题带上 50/100。
    final legacy = Map<String, Object?>.from(raw)..remove('name');
    await file.writeAsString(jsonEncode(legacy));
    final legacyCold = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(33),
      aiThinkTime: Duration.zero,
    );
    await legacyCold.loadSession();
    expect(legacyCold.savedSession!.name, '实战 9人桌');
    expect(legacyCold.resumeSession(), isTrue);
    expect(legacyCold.tableName, '实战 9人桌');
  }, fast: true);

  t('本局累计：本手跟着筹码走，本局跟着存档走', () async {
    final dir = Directory.systemTemp.createTempSync('pt_session_net');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/session.json');
    const config =
        GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);
    final t = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(11),
      aiThinkTime: Duration.zero,
    );
    t.startRealTable(name: '实战 单挑', config: config, playerCount: 2);

    // 单挑英雄坐按钮 = 小盲：本手 -50，本局也刚开始，等于本手。
    expect(t.heroHandNet, -50);
    expect(t.heroSessionNet, -50);
    t.heroAct(ActionType.fold);
    expect(t.heroSessionNet, -50, reason: '本手结算后不能再重复加一次实时值');
    await t.persistSession();
    expect(t.savedSession!.heroNet, -50, reason: '本局累计要落盘');

    // 冷启动恢复：本局累计跟着存档回来（不会从 0 重新数）。
    final cold = TableController(
      sessionStore: TableSessionStore(file),
      random: Random(12),
      aiThinkTime: Duration.zero,
    );
    await cold.loadSession();
    expect(cold.resumeSession(), isTrue);
    expect(cold.heroSessionNet, lessThanOrEqualTo(-100),
        reason: '恢复后本局要带上之前那 -50，再算上这一手刚投的盲注 '
            '(实际 ${cold.heroSessionNet})');

    // 补码是把钱补进桌上，不是赢来的钱：补满之后本局还是负的。
    cold.hero.stack = 0;
    cold.heroRebuy();
    expect(cold.heroSessionNet, lessThan(0),
        reason: '补码不能被算成赢钱（实际 ${cold.heroSessionNet}）');
  }, fast: true);

  t('补码：补满至起始买入', () {
    final g = GameEngine(random: Random(1))..addPlayer('hero', '我');
    g.players[0].stack = 100;
    expect(g.topUp('hero'), 9900);
    expect(g.players[0].stack, 10000);
    expect(g.topUp('hero'), 0);
  }, fast: true);
}
