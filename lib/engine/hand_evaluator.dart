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
  static HandScore bestOf(List<Card> cards) {
    if (cards.length < 5 || cards.length > 7) {
      throw ArgumentError('bestOf 支持 5~7 张牌，收到 ${cards.length}');
    }
    var best = evaluate5(cards.sublist(0, 5));
    for (var a = 0; a < cards.length; a++) {
      for (var b = a + 1; b < cards.length; b++) {
        for (var c = b + 1; c < cards.length; c++) {
          for (var d = c + 1; d < cards.length; d++) {
            for (var e = d + 1; e < cards.length; e++) {
              final score = evaluate5(
                  [cards[a], cards[b], cards[c], cards[d], cards[e]]);
              if (score > best) best = score;
            }
          }
        }
      }
    }
    return best;
  }
}
