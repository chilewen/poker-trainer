import 'dart:math';

import '../engine/card.dart';
import '../engine/hand_evaluator.dart';

/// 胜率模拟结果。
class EquityResult {
  const EquityResult({
    required this.win,
    required this.tie,
    required this.trials,
  });

  /// 胜率（0~1），平局按 1/对手数 计入。
  final double win;

  /// 平局率（0~1）。
  final double tie;
  final int trials;

  double get lose => 1 - win - tie;

  /// 计入平局摊分后的「底池份额」：多人底池里这是真正的期望份额。
  double share(int opponents) => win + tie / (opponents + 1);

  @override
  String toString() =>
      'win ${(win * 100).toStringAsFixed(1)}% / '
      'tie ${(tie * 100).toStringAsFixed(1)}% / '
      'lose ${(lose * 100).toStringAsFixed(1)}% (n=$trials)';
}

/// 对手范围的权重函数：返回该底牌组合落在估计范围内的概率（0~1）。
typedef RangePredicate = double Function(List<Card> hole, HandScore score);

/// 概率工具：胜率模拟、outs、底池赔率。
class Odds {
  Odds._();

  /// 蒙特卡洛模拟：给定我方底牌、公共牌与对手数量，估算胜率。
  ///
  /// - [heroHole] 恰好 2 张。
  /// - [board] 0~5 张公共牌；不足 5 张时随机补齐。
  /// - [opponents] 未知底牌的对手数量（1~8）。
  /// - [trials] 模拟次数，越多越准但越慢；手机上 2000~5000 足够。
  static EquityResult equity({
    required List<Card> heroHole,
    List<Card> board = const [],
    int opponents = 1,
    int trials = 2000,
    Random? random,
  }) {
    if (heroHole.length != 2) {
      throw ArgumentError('heroHole 需要恰好 2 张牌');
    }
    if (board.length > 5) {
      throw ArgumentError('board 最多 5 张');
    }
    if (opponents < 1 || opponents > 8) {
      throw ArgumentError('opponents 需在 1~8 之间');
    }
    final rng = random ?? Random();
    final known = {...heroHole, ...board};
    final unknown = [
      for (final suit in Suit.values)
        for (final rank in Rank.values)
          if (!known.contains(Card(rank, suit))) Card(rank, suit),
    ];
    final needBoard = 5 - board.length;

    var wins = 0;
    var ties = 0;
    for (var t = 0; t < trials; t++) {
      // 无放回抽样：先洗未知牌，再依次取。
      final pool = List<Card>.of(unknown)..shuffle(rng);
      final runout = [
        ...board,
        ...pool.take(needBoard),
      ];
      var cursor = needBoard;
      final heroScore =
          HandEvaluator.bestOf([...heroHole, ...runout]);
      var heroWins = true;
      var heroTies = false;
      for (var o = 0; o < opponents; o++) {
        final oppHole = [pool[cursor], pool[cursor + 1]];
        cursor += 2;
        final oppScore =
            HandEvaluator.bestOf([...oppHole, ...runout]);
        if (oppScore > heroScore) {
          heroWins = false;
          heroTies = false;
          break;
        } else if (oppScore == heroScore) {
          heroTies = true;
        }
      }
      if (heroWins && !heroTies) {
        wins++;
      } else if (heroTies) {
        ties++;
      }
    }
    return EquityResult(
      win: wins / trials,
      tie: ties / trials,
      trials: trials,
    );
  }

  /// 带对手范围限制的蒙特卡洛胜率：对手的底牌不再完全随机，
  /// 而是按 [inRange] 给出的概率筛选（弃牌重抽有限次）。
  ///
  /// 真人玩家不会把对手当随机牌来算胜率——对手没弃牌，
  /// 说明他的范围本来就偏向强牌，这个偏置让胜率估计更接近实战。
  static EquityResult equityVsRange({
    required List<Card> heroHole,
    List<Card> board = const [],
    int opponents = 1,
    required RangePredicate inRange,
    int trials = 400,
    int maxResample = 4,
    Random? random,
  }) {
    if (heroHole.length != 2) {
      throw ArgumentError('heroHole 需要恰好 2 张牌');
    }
    if (board.length > 5) {
      throw ArgumentError('board 最多 5 张');
    }
    if (opponents < 1 || opponents > 8) {
      throw ArgumentError('opponents 需在 1~8 之间');
    }
    final rng = random ?? Random();
    final known = {...heroHole, ...board};
    final unknown = [
      for (final suit in Suit.values)
        for (final rank in Rank.values)
          if (!known.contains(Card(rank, suit))) Card(rank, suit),
    ];
    final needBoard = 5 - board.length;

    var wins = 0;
    var ties = 0;
    for (var t = 0; t < trials; t++) {
      final pool = List<Card>.of(unknown)..shuffle(rng);
      final runout = [...board, ...pool.take(needBoard)];
      final heroScore = HandEvaluator.bestOf([...heroHole, ...runout]);
      final rest = pool.sublist(needBoard);

      var heroWins = true;
      var heroTies = false;
      for (var o = 0; o < opponents; o++) {
        // 在剩余牌里从前向后试组合：落到范围内就用，试满次数就用第一个。
        var chosen = <Card>[rest[0], rest[1]];
        var chosenScore =
            HandEvaluator.bestOf([...chosen, ...runout]);
        var weight = inRange(chosen, chosenScore);
        for (var k = 1; k <= maxResample; k++) {
          if (weight >= 1.0 || rng.nextDouble() < weight) break;
          final i = k * 2;
          if (i + 1 >= rest.length) break;
          final cand = [rest[i], rest[i + 1]];
          final candScore = HandEvaluator.bestOf([...cand, ...runout]);
          chosen = cand;
          chosenScore = candScore;
          weight = inRange(cand, candScore);
        }
        rest.remove(chosen[0]);
        rest.remove(chosen[1]);

        if (chosenScore > heroScore) {
          heroWins = false;
          heroTies = false;
          break;
        } else if (chosenScore == heroScore) {
          heroTies = true;
        }
      }
      if (heroWins && !heroTies) {
        wins++;
      } else if (heroTies) {
        ties++;
      }
    }
    return EquityResult(
      win: wins / trials,
      tie: ties / trials,
      trials: trials,
    );
  }

  /// 翻牌后 outs 数：听牌成牌张数。
  ///
  /// 统计能让 hero 牌型跃升为「三条及以上」（set、顺子、同花、葫芦、
  /// 四条、同花顺）的剩余未知牌数量——即经典教学中听花 9 outs、
  /// 两头听顺 8 outs 的口径。单纯配对（高牌→对子、对子→两对）
  /// 不算在内，因为它们通常不够赢。河牌圈恒为 0。
  static int outs({
    required List<Card> heroHole,
    required List<Card> board,
  }) {
    if (board.length < 3 || board.length > 4) {
      throw ArgumentError('outs 仅支持翻牌(3)或转牌(4)圈');
    }
    final known = {...heroHole, ...board};
    final current =
        HandEvaluator.bestOf([...heroHole, ...board]);
    final currentRank = current.category.rank;
    var count = 0;
    for (final suit in Suit.values) {
      for (final rank in Rank.values) {
        final c = Card(rank, suit);
        if (known.contains(c)) continue;
        final next =
            HandEvaluator.bestOf([...heroHole, ...board, c]);
        final nextRank = next.category.rank;
        final makesTrips =
            currentRank < HandCategory.trips.rank &&
                nextRank == HandCategory.trips.rank;
        final makesStraightOrBetter =
            nextRank >= HandCategory.straight.rank && next > current;
        if (makesTrips || makesStraightOrBetter) count++;
      }
    }
    return count;
  }

  /// 底池赔率：跟注 [toCall] 去赢 [pot]，需要的最低胜率。
  ///
  /// 例如 pot=300、toCall=100 → 0.25，即胜率 ≥25% 时跟注不亏。
  static double potOdds({required int pot, required int toCall}) {
    if (toCall <= 0) return 0;
    return toCall / (pot + toCall);
  }

  /// 粗略的「二四法则」：outs 数换算成下一条街（×2）或两条街（×4）的成牌概率。
  static double ruleOfTwoFour(int outs, {bool twoStreets = false}) =>
      (outs * (twoStreets ? 4 : 2) / 100).clamp(0.0, 1.0);
}
