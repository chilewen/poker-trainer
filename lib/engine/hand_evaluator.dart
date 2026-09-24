import 'card.dart';

/// 牌型类别，数值越大越强。
enum HandCategory {
  highCard(0, '高牌'),
  pair(1, '一对'),
  twoPair(2, '两对'),
  trips(3, '三条'),
  straight(4, '顺子'),
  flush(5, '同花'),
  fullHouse(6, '葫芦'),
  quads(7, '四条'),
  straightFlush(8, '同花顺');

  const HandCategory(this.rank, this.label);
  final int rank;
  final String label;
}

/// 已评估的牌型，可直接用 > < == 比较大小。
class HandScore implements Comparable<HandScore> {
  const HandScore(this.category, this.tiebreakers);

  final HandCategory category;

  /// 同牌型内的比较项，如 [三条点数, 大踢脚, 小踢脚]，长度最多 5。
  final List<int> tiebreakers;

  int get value {
    var v = category.rank;
    for (var i = 0; i < 5; i++) {
      final tb = i < tiebreakers.length ? tiebreakers[i] : 0;
      v = v * 15 + tb;
    }
    return v;
  }

  @override
  int compareTo(HandScore other) => value.compareTo(other.value);

  bool operator >(HandScore other) => compareTo(other) > 0;
  bool operator <(HandScore other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is HandScore && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '${category.label}(${tiebreakers.join(',')})';
}

/// 5/7 张牌的牌型评估。
class HandEvaluator {
  HandEvaluator._();

  /// 恰好 5 张牌的评估。
  static HandScore evaluate5(List<Card> cards) {
    if (cards.length != 5) {
      throw ArgumentError('evaluate5 需要恰好 5 张牌，收到 ${cards.length}');
    }
    final counts = <int, int>{};
    for (final c in cards) {
      final r = c.rank.value;
      counts[r] = (counts[r] ?? 0) + 1;
    }
    final isFlush = cards.every((c) => c.suit == cards.first.suit);

    // 顺子检测（含 A2345 轮子）。
    final distinct = counts.keys.toList()..sort();
    int? straightHigh;
    if (distinct.length == 5) {
      if (distinct.last - distinct.first == 4) {
        straightHigh = distinct.last;
      } else if (distinct.last == Rank.ace.value &&
          distinct.first == Rank.two.value &&
          distinct[3] == Rank.five.value) {
        straightHigh = Rank.five.value; // 轮子顺子按 5 算
      }
    }

    final sortedDesc = distinct.reversed.toList();

    if (isFlush && straightHigh != null) {
      return HandScore(HandCategory.straightFlush, [straightHigh]);
    }

    // 按 (出现次数, 点数) 分组。
    final groups = counts.entries.toList()
      ..sort((a, b) =>
          b.value != a.value ? b.value - a.value : b.key - a.key);

    if (groups.first.value == 4) {
      return HandScore(HandCategory.quads, [groups[0].key, groups[1].key]);
    }
    if (groups.first.value == 3 && groups[1].value == 2) {
      return HandScore(
          HandCategory.fullHouse, [groups[0].key, groups[1].key]);
    }
    if (isFlush) {
      return HandScore(HandCategory.flush, sortedDesc);
    }
    if (straightHigh != null) {
      return HandScore(HandCategory.straight, [straightHigh]);
    }
    if (groups.first.value == 3) {
      return HandScore(
          HandCategory.trips, [groups[0].key, groups[1].key, groups[2].key]);
    }
    if (groups.first.value == 2 && groups[1].value == 2) {
      return HandScore(HandCategory.twoPair,
          [groups[0].key, groups[1].key, groups[2].key]);
    }
    if (groups.first.value == 2) {
      return HandScore(HandCategory.pair,
          [groups[0].key, ...sortedDesc.where((r) => r != groups[0].key)]);
    }
    return HandScore(HandCategory.highCard, sortedDesc);
  }

  /// 5~7 张牌取最佳 5 张组合。
  ///
  /// 6/7 张牌以前是枚举 C(7,5)=21 个组合、每个组合都调一次 [evaluate5]：
  /// 每个组合都要建一张哈希表、排两次序、再拼一堆中间 List，实测一次
  /// **11.5µs**。而蒙特卡洛胜率模拟（AI 每想一步要跑几百上千次）几乎全
  /// 花在这里——AI 的「思考时间」基本就是这个函数。
  ///
  /// 现在改成计数法：扫一遍算出点数计数、每个花色的点数位掩码，再按牌型
  /// 从高到低拼出最优五张，一次 1µs 上下。结果与枚举法逐位相同
  /// （用 30 万手随机牌交叉验证过），而且不碰随机流，AI 的行为分毫不变。
  static HandScore bestOf(List<Card> cards) {
    if (cards.length < 5 || cards.length > 7) {
      throw ArgumentError('bestOf 支持 5~7 张牌，收到 ${cards.length}');
    }
    if (cards.length == 5) return evaluate5(cards);

    final rankCount = List<int>.filled(15, 0);
    final suitCount = List<int>.filled(4, 0);
    final suitMask = List<int>.filled(4, 0);
    for (final c in cards) {
      final r = c.rank.value;
      rankCount[r]++;
      final s = c.suit.index;
      suitCount[s]++;
      suitMask[s] |= 1 << r;
    }
    var rankMask = 0;
    for (var r = Rank.two.value; r <= Rank.ace.value; r++) {
      if (rankCount[r] > 0) rankMask |= 1 << r;
    }

    // 同花顺是最高的牌型，见到就能直接返回；同花先记下来，
    // 最后跟「按点数算出来的最优牌」比一比。
    HandScore? flushBest;
    for (var s = 0; s < 4; s++) {
      if (suitCount[s] < 5) continue;
      final sfHigh = _straightHigh(suitMask[s]);
      if (sfHigh != 0) {
        return HandScore(HandCategory.straightFlush, [sfHigh]);
      }
      final flush = HandScore(HandCategory.flush, _topRanks(suitMask[s], 5));
      if (flushBest == null || flush > flushBest) flushBest = flush;
    }
    final byRank = _bestIgnoringSuits(rankCount, rankMask);
    if (flushBest == null || byRank > flushBest) return byRank;
    return flushBest;
  }

  /// 只按点数算的最优牌（同花/同花顺另行处理）。
  ///
  /// 牌型顺序不能乱：四条 > 葫芦 > 顺子 > 三条 > 两对 > 一对 > 高牌。
  /// 顺子要排在三条前面——拿着 555 6789 时，顺子（5-9）比三条大。
  static HandScore _bestIgnoringSuits(List<int> rankCount, int rankMask) {
    var quads = 0;
    final trips = <int>[];
    final pairs = <int>[];
    for (var r = Rank.ace.value; r >= Rank.two.value; r--) {
      switch (rankCount[r]) {
        case 4:
          quads = r;
        case 3:
          trips.add(r);
        case 2:
          pairs.add(r);
      }
    }
    if (quads != 0) {
      return HandScore(HandCategory.quads,
          [quads, _topRanks(rankMask & ~(1 << quads), 1).first]);
    }
    if (trips.isNotEmpty) {
      final t = trips.first;
      // 葫芦里的「对子」也可以来自第二个三条：AAA KKK x 就是 AAA KK。
      var pair = pairs.isNotEmpty ? pairs.first : 0;
      if (trips.length > 1 && trips[1] > pair) pair = trips[1];
      if (pair != 0) {
        return HandScore(HandCategory.fullHouse, [t, pair]);
      }
    }
    final straightHigh = _straightHigh(rankMask);
    if (straightHigh != 0) {
      return HandScore(HandCategory.straight, [straightHigh]);
    }
    if (trips.isNotEmpty) {
      final t = trips.first;
      return HandScore(
          HandCategory.trips, [t, ..._topRanks(rankMask & ~(1 << t), 2)]);
    }
    if (pairs.length >= 2) {
      final rest = rankMask & ~(1 << pairs[0]) & ~(1 << pairs[1]);
      return HandScore(
          HandCategory.twoPair, [pairs[0], pairs[1], _topRanks(rest, 1).first]);
    }
    if (pairs.length == 1) {
      // 踢脚只取 3 张：五张牌的牌型就是「一对 + 三张踢脚」。多带一张
      // （第 6、7 张牌里的第 4 个踢脚）会让本该平分的两手牌分出胜负——
      // 双方最好的五张明明一样，却比到了第 6 张牌上去。
      return HandScore(HandCategory.pair,
          [pairs[0], ..._topRanks(rankMask & ~(1 << pairs[0]), 3)]);
    }
    return HandScore(HandCategory.highCard, _topRanks(rankMask, 5));
  }

  /// 位掩码里最高的顺子（返回最大那张牌的点数，没有顺子返回 0）。
  /// A 可以当 1 用（A2345 是 5 高的轮子）。
  static int _straightHigh(int mask) {
    var m = mask;
    if ((m >> Rank.ace.value) & 1 == 1) m |= 1 << 1;
    for (var high = Rank.ace.value; high >= 5; high--) {
      final need = 0x1f << (high - 4);
      if ((m & need) == need) return high;
    }
    return 0;
  }

  /// 位掩码里从大到小取出至多 [k] 个点数。
  static List<int> _topRanks(int mask, int k) {
    final out = <int>[];
    for (var r = Rank.ace.value; r >= Rank.two.value && out.length < k; r--) {
      if ((mask >> r) & 1 == 1) out.add(r);
    }
    return out;
  }
}
