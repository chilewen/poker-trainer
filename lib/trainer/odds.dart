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
  /// 而是按 [inRange] 给出的权重抽样（权重高的底牌出现得多）。
  ///
  /// 真人玩家不会把对手当随机牌来算胜率——对手没弃牌，
  /// 说明他的范围本来就偏向强牌，这个偏置让胜率估计更接近实战。
  static EquityResult equityVsRange({
    required List<Card> heroHole,
    List<Card> board = const [],
    int opponents = 1,
    required RangePredicate inRange,
    int trials = 400,
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

    // 河牌圈公共牌已发完：对手的组合权重整套都是固定的，
    // 先算一次「权重表」，之后每次模拟直接从表里抽，省掉重复评估。
    //
    // 表里必须是**所有**两张组合（C(45,2)=990 手）。按 `i += 2` 把
    // 相邻两张配成一手是错的：牌堆按花色/点数排列，那样只会剩下
    // 「同花色 + 相邻点数」那十几手牌，范围失真得离谱——河牌顶对
    // 会算出 86% 胜率（几乎等于「对随机牌」），跟注自然就过宽了。
    List<List<Card>>? riverPairs;
    List<double>? riverWeights;
    var riverTotal = 0.0;
    if (needBoard == 0) {
      riverPairs = [];
      riverWeights = [];
      for (var i = 0; i < unknown.length; i++) {
        for (var j = i + 1; j < unknown.length; j++) {
          final cand = [unknown[i], unknown[j]];
          final w = inRange(cand, HandEvaluator.bestOf([...cand, ...board]));
          if (w <= 0) continue;
          riverPairs.add(cand);
          riverWeights.add(w);
          riverTotal += w;
        }
      }
    }

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
        // 按权重抽对手的底牌：范围里权重低的牌就按比例少出现。
        // （以前是「试几次不中就随便拿一手」，那等于把对手的范围
        // 掺成随机牌，会系统性高估我方胜率、导致跟注过宽。）
        List<Card> chosen;
        HandScore chosenScore;
        final fixed = needBoard == 0 && o == 0 ? riverPairs : null;
        if (fixed != null && riverTotal > 0) {
          chosen = _pickWeighted(fixed, riverWeights!, riverTotal, rng);
          chosenScore = HandEvaluator.bestOf([...chosen, ...runout]);
        } else {
          final pairs = <List<Card>>[];
          final weights = <double>[];
          var total = 0.0;
          for (var i = 0; i + 1 < rest.length; i += 2) {
            final cand = [rest[i], rest[i + 1]];
            final w = inRange(cand, HandEvaluator.bestOf([...cand, ...runout]));
            if (w <= 0) continue;
            pairs.add(cand);
            weights.add(w);
            total += w;
          }
          if (total <= 0) {
            // 范围里一手都没有（正常的范围谓词不会这样）：退化成随机牌。
            chosen = [rest[0], rest[1]];
          } else {
            chosen = _pickWeighted(pairs, weights, total, rng);
          }
          chosenScore = HandEvaluator.bestOf([...chosen, ...runout]);
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

  /// 按权重从候选组合里抽一组（权重越高越可能出现）。
  static List<Card> _pickWeighted(
      List<List<Card>> pairs, List<double> weights, double total, Random rng) {
    var r = rng.nextDouble() * total;
    for (var i = 0; i < weights.length; i++) {
      r -= weights[i];
      if (r <= 0) return pairs[i];
    }
    return pairs.last;
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
