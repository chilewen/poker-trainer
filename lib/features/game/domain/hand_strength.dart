import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/hand_evaluator.dart';

/// 翻后牌力分层：从「没牌力」到「坚果级」。
///
/// AI 需要像真人一样先看清自己手里是什么牌，再决定价值下注、
/// 半诈唬、控池还是放弃，所以把成牌强度粗分成五档。
enum HandTier {
  junk(0, '空气'),
  weak(1, '弱成牌'),
  medium(2, '中等牌'),
  strong(3, '强牌'),
  monster(4, '怪兽牌');

  const HandTier(this.rank, this.label);

  final int rank;
  final String label;

  bool operator >(HandTier other) => rank > other.rank;
  bool operator >=(HandTier other) => rank >= other.rank;
  bool operator <(HandTier other) => rank < other.rank;
  bool operator <=(HandTier other) => rank <= other.rank;
}

/// 公共牌面特征：干湿程度、是否成对、同花/顺子可能。
class BoardTexture {
  const BoardTexture({
    required this.paired,
    required this.maxSuitCount,
    required this.highRank,
    required this.straightDanger,
    required this.wetness,
  });

  factory BoardTexture.of(List<Card> board) {
    final rankCounts = <int, int>{};
    final suitCounts = <Suit, int>{};
    for (final c in board) {
      rankCounts.update(c.rank.value, (v) => v + 1, ifAbsent: () => 1);
      suitCounts.update(c.suit, (v) => v + 1, ifAbsent: () => 1);
    }
    final ranks = rankCounts.keys.toList()..sort();
    final paired = rankCounts.values.any((v) => v >= 2);
    final maxSuitCount = suitCounts.values.fold(0, max);
    final highRank = ranks.isEmpty ? 0 : ranks.last;

    // 顺子危险度：任意 5 个连续点数里已经出现 3 张以上。
    var straightDanger = false;
    for (var low = 2; low + 4 <= 14 && !straightDanger; low++) {
      var seen = 0;
      for (var r = low; r < low + 5; r++) {
        seen += rankCounts[r] ?? 0;
      }
      if (seen >= 3) straightDanger = true;
    }
    if (!straightDanger && rankCounts.containsKey(Rank.ace.value)) {
      var seen = rankCounts[Rank.ace.value] ?? 0; // A 也可以当 1 用
      for (var r = 2; r <= 5; r++) {
        seen += rankCounts[r] ?? 0;
      }
      if (seen >= 3) straightDanger = true;
    }

    var wet = 0.0;
    if (paired) wet += 0.15;
    if (maxSuitCount >= 3) {
      wet += 0.35;
    } else if (maxSuitCount == 2) {
      wet += 0.15;
    }
    if (straightDanger) wet += 0.3;
    if (board.length >= 4) wet += 0.05;

    return BoardTexture(
      paired: paired,
      maxSuitCount: maxSuitCount,
      highRank: highRank,
      straightDanger: straightDanger,
      wetness: wet.clamp(0.0, 1.0),
    );
  }

  final bool paired;
  final int maxSuitCount;
  final int highRank;
  final bool straightDanger;
  final double wetness;

  /// 干燥牌面：不容易成顺成花，适合持续下注与慢打。
  bool get isDry => wetness < 0.35;
}

/// 我方底牌在给定公共牌下的读牌结果：成牌层级 + 听牌信息。
class HandReading {
  const HandReading._({
    required this.texture,
    required this.category,
    required this.tier,
    required this.pocketPair,
    required this.pairRank,
    required this.kicker,
    required this.topPair,
    required this.overPair,
    required this.flushOuts,
    required this.straightOuts,
    required this.drawOuts,
    required this.nutFlushDraw,
    required this.backdoorFlush,
    required this.hasAceBlocker,
    required this.overcards,
  });

  factory HandReading.of(List<Card> hole, List<Card> board) {
    final texture = BoardTexture.of(board);
    final category = board.length < 3
        ? HandCategory.highCard
        : HandEvaluator.bestOf([...hole, ...board]).category;

    final holeRanks = hole.map((c) => c.rank.value).toList();
    final boardRanks = board.map((c) => c.rank.value).toList();
    final sortedBoard = [...boardRanks]..sort((a, b) => b - a);
    final boardMax = sortedBoard.isEmpty ? 0 : sortedBoard.first;
    final pocketPair = hole.length == 2 && holeRanks[0] == holeRanks[1];

    // 与公共牌成对的那张底牌（0 表示没中公共牌）。
    var pairRank = 0;
    if (pocketPair) {
      pairRank = holeRanks[0];
    } else {
      for (final r in holeRanks) {
        if (boardRanks.contains(r)) pairRank = r;
      }
    }
    final kicker = pocketPair
        ? holeRanks[0]
        : (holeRanks[0] == pairRank ? holeRanks[1] : holeRanks[0]);
    final holePairsBoard =
        holeRanks.where((r) => boardRanks.contains(r)).toList();

    final tier = _tierOf(
      category: category,
      texture: texture,
      pocketPair: pocketPair,
      pairRank: pairRank,
      kicker: kicker,
      sortedBoard: sortedBoard,
      holePairsBoard: holePairsBoard,
    );

    // ---------- 听牌 ----------
    var flushOuts = 0;
    var nutFlushDraw = false;
    var backdoorFlush = false;
    if (board.length == 3 || board.length == 4) {
      final suitCount = <Suit, int>{};
      for (final c in [...hole, ...board]) {
        suitCount.update(c.suit, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final e in suitCount.entries) {
        if (e.value != 4) continue;
        if (!hole.any((c) => c.suit == e.key)) continue;
        flushOuts = 9;
        nutFlushDraw =
            hole.any((c) => c.suit == e.key && c.rank == Rank.ace);
        break;
      }
      if (flushOuts == 0 && board.length == 3) {
        for (final e in suitCount.entries) {
          if (e.value == 3 && hole.any((c) => c.suit == e.key)) {
            backdoorFlush = true;
            break;
          }
        }
      }
    }

    // 顺子听牌：看每个「五点窗口」里已经拿到几张，缺的那张就是 outs。
    final ranks = <int>{...holeRanks, ...boardRanks};
    final missing = <int>{};
    var madeStraight = false;
    for (final window in _straightWindows) {
      var have = 0;
      for (final r in window) {
        if (ranks.contains(r)) have++;
      }
      if (have == 5) madeStraight = true;
      if (have == 4) {
        for (final r in window) {
          if (!ranks.contains(r)) missing.add(r);
        }
      }
    }
    final straightOuts =
        (board.length >= 5 || madeStraight) ? 0 : min(8, missing.length * 4);

    final drawOuts = flushOuts > 0 && straightOuts > 0
        ? flushOuts + straightOuts - 2 // 花顺双听有重叠（同花顺 outs）
        : flushOuts + straightOuts;

    return HandReading._(
      texture: texture,
      category: category,
      tier: tier,
      pocketPair: pocketPair,
      pairRank: pairRank,
      kicker: kicker,
      topPair: !pocketPair && pairRank != 0 && pairRank == boardMax,
      overPair: pocketPair && pairRank > boardMax,
      flushOuts: flushOuts,
      straightOuts: straightOuts,
      drawOuts: drawOuts,
      nutFlushDraw: nutFlushDraw,
      backdoorFlush: backdoorFlush,
      hasAceBlocker: hole.any((c) => c.rank == Rank.ace) &&
          !boardRanks.contains(Rank.ace.value),
      overcards:
          board.isEmpty ? 0 : hole.where((c) => c.rank.value > boardMax).length,
    );
  }

  static const List<List<int>> _straightWindows = [
    [14, 2, 3, 4, 5],
    [2, 3, 4, 5, 6],
    [3, 4, 5, 6, 7],
    [4, 5, 6, 7, 8],
    [5, 6, 7, 8, 9],
    [6, 7, 8, 9, 10],
    [7, 8, 9, 10, 11],
    [8, 9, 10, 11, 12],
    [9, 10, 11, 12, 13],
    [10, 11, 12, 13, 14],
  ];

  static HandTier _tierOf({
    required HandCategory category,
    required BoardTexture texture,
    required bool pocketPair,
    required int pairRank,
    required int kicker,
    required List<int> sortedBoard,
    required List<int> holePairsBoard,
  }) {
    final boardMax = sortedBoard.isEmpty ? 0 : sortedBoard.first;
    switch (category) {
      case HandCategory.straightFlush:
      case HandCategory.quads:
      case HandCategory.fullHouse:
      case HandCategory.flush:
      case HandCategory.straight:
        return HandTier.monster;
      case HandCategory.trips:
        // 口袋对中三条 = set，比「底牌配公共对」的三条强得多。
        return pocketPair ? HandTier.monster : HandTier.strong;
      case HandCategory.twoPair:
        if (holePairsBoard.length >= 2) return HandTier.monster; // 两张底牌都中
        if (pocketPair && texture.paired) {
          return pairRank > boardMax ? HandTier.strong : HandTier.medium;
        }
        if (!pocketPair && holePairsBoard.isNotEmpty) {
          // 底牌 + 公共对：小对子两对在成对牌面上价值下降。
          final highBoardPair = sortedBoard.length > 1 ? sortedBoard[1] : boardMax;
          return pairRank >= highBoardPair
              ? HandTier.strong
              : HandTier.medium;
        }
        return HandTier.strong;
      case HandCategory.pair:
        if (pocketPair) {
          if (pairRank > boardMax) return HandTier.strong; // 超对
          if (sortedBoard.length > 1 && pairRank > sortedBoard[1]) {
            return HandTier.medium; // 中间对子
          }
          return HandTier.weak; // 被盖过的口袋对
        }
        if (pairRank == boardMax) {
          if (kicker >= 13) return HandTier.strong; // 顶对顶踢
          return kicker >= 10 ? HandTier.medium : HandTier.weak;
        }
        if (sortedBoard.length > 1 && pairRank == sortedBoard[1]) {
          return kicker >= 12 ? HandTier.medium : HandTier.weak; // 第二对
        }
        return HandTier.weak; // 底对
      case HandCategory.highCard:
        return HandTier.junk;
    }
  }

  final BoardTexture texture;
  final HandCategory category;
  final HandTier tier;
  final bool pocketPair;
  final int pairRank;
  final int kicker;
  final bool topPair;
  final bool overPair;

  /// 同花听牌 outs（0 表示没有）。
  final int flushOuts;

  /// 顺子听牌 outs（4 = 卡顺，8 = 两头顺）。
  final int straightOuts;

  /// 综合听牌 outs（花顺双听会扣掉重叠）。
  final int drawOuts;
  final bool nutFlushDraw;
  final bool backdoorFlush;

  /// 手上是否有 A（挡掉对手 AA/AK，做诈唬时的阻断牌）。
  final bool hasAceBlocker;
  final int overcards;

  bool get hasFlushDraw => flushOuts > 0;
  bool get hasStraightDraw => straightOuts > 0;
  bool get hasDraw => drawOuts >= 4;
  bool get isComboDraw => flushOuts > 0 && straightOuts > 0;

  /// 听牌成牌概率（二四法则的精确版）：[streets] 为剩余街数。
  double drawEquity(int streets) {
    if (drawOuts <= 0) return 0;
    if (streets <= 1) return (drawOuts / 46).clamp(0.0, 1.0);
    final missTurn = 1 - drawOuts / 47;
    final missRiver = 1 - drawOuts / 46;
    return (1 - missTurn * missRiver).clamp(0.0, 1.0);
  }

  @override
  String toString() {
    final buf = StringBuffer('${tier.label}/${category.label}');
    if (hasFlushDraw) buf.write(nutFlushDraw ? ' ·坚果花听' : ' ·花听');
    if (hasStraightDraw) buf.write(' ·顺听$straightOuts');
    buf.write(' outs=$drawOuts');
    return buf.toString();
  }
}
