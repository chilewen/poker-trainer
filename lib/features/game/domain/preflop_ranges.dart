import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/game.dart';

/// 翻前位置桶：把 2~9 人的座位归成 6 类。
enum Seat {
  ep('前位'),
  mp('中位'),
  co('劫位'),
  btn('按钮'),
  sb('小盲'),
  bb('大盲');

  const Seat(this.label);
  final String label;
}

/// 一手起手牌的分类信息（点数用 2~14，14 = A）。
class PreflopHand {
  const PreflopHand._(this.high, this.low, this.suited);

  factory PreflopHand.of(List<Card> hole) {
    final a = hole[0].rank.value;
    final b = hole[1].rank.value;
    return PreflopHand._(
      max(a, b),
      min(a, b),
      hole[0].suit == hole[1].suit,
    );
  }

  /// 较大的点数 / 较小的点数 / 是否同花。
  final int high;
  final int low;
  final bool suited;

  bool get isPair => high == low;
  int get gap => high - low;
  bool get isAce => high == Rank.ace.value;

  /// 两张都是 T 以上的「大牌」。
  bool get isBroadway => low >= Rank.ten.value;
  bool get isConnector => gap == 1;
  bool get isOneGapper => gap == 2;

  String get label =>
      '${_rankText(high)}${_rankText(low)}${isPair ? '' : (suited ? 's' : 'o')}';

  static String _rankText(int v) => switch (v) {
        14 => 'A',
        13 => 'K',
        12 => 'Q',
        11 => 'J',
        10 => 'T',
        _ => '$v',
      };

  @override
  String toString() => label;
}

/// 一个翻前范围：按牌型类别给出最低要求，0 表示该类不包含。
///
/// 用「牌型类别 + 门槛」而不是单一分数，是因为真人的范围本来就是
/// 按牌型长的：前位是「对子 + 高张同花 + A 高张」，按钮位才会加入
/// 同花连张、隔张和一堆非同花杂牌。
class PreflopRange {
  const PreflopRange({
    this.pair = 0,
    this.smallPair = 0,
    this.suitedAce = 0,
    this.offsuitAce = 0,
    this.suitedBroadway = 0,
    this.offsuitBroadway = 0,
    this.suitedConnector = 0,
    this.suitedGapper = 0,
    this.suitedAny = 0,
    this.offsuitConnector = 0,
    this.offsuitAny = 0,
  });

  /// 对子下限（5 = 55+）。
  final int pair;

  /// 小对子上限（8 = 22~88）。深筹码跟注 3bet 这类「买三条」的位置用：
  /// 真人不会用 77 去跟 3bet 是因为它现在有摊牌价值，而是因为中三条能赢
  /// 一整个大底池——所以这条范围跟「对子下限」是两回事，不能用同一个门槛
  /// 表达（pair 只能一路放宽到 22，那等于连 22 都当中等对子打）。
  final int smallPair;

  /// A 带 x 同花 / 非同花的 x 下限。
  final int suitedAce;
  final int offsuitAce;

  /// 两张都是大牌时的低牌下限（10 = 全部大牌）。
  final int suitedBroadway;
  final int offsuitBroadway;

  /// 同花连张 / 同花隔一张的低牌下限。
  final int suitedConnector;
  final int suitedGapper;

  /// 其它同花牌（非同花连张、非同花杂牌）的低牌下限。
  final int suitedAny;
  final int offsuitConnector;
  final int offsuitAny;

  static bool _ok(int value, int threshold) =>
      threshold > 0 && value >= threshold;

  bool contains(PreflopHand h) {
    if (h.isPair) {
      // _ok(smallPair, h.high) = 点数不超过上界（22~smallPair）。
      return _ok(h.high, pair) || _ok(smallPair, h.high);
    }
    // 大牌（含 A 带高张）：同花/非同花各看自己的大牌门槛；
    // AQo 这类「A + 大牌」再额外用 A 的门槛兜底，避免被漏掉。
    if (h.isBroadway) {
      if (h.suited) {
        if (_ok(h.low, suitedBroadway)) return true;
        return h.isAce && _ok(h.low, suitedAce);
      }
      if (_ok(h.low, offsuitBroadway)) return true;
      return h.isAce && _ok(h.low, offsuitAce);
    }
    if (h.isAce) {
      return h.suited ? _ok(h.low, suitedAce) : _ok(h.low, offsuitAce);
    }
    if (h.suited) {
      if (h.gap <= 1) {
        return _ok(h.low, suitedConnector) || _ok(h.low, suitedAny);
      }
      if (h.gap == 2) {
        return _ok(h.low, suitedGapper) || _ok(h.low, suitedAny);
      }
      return _ok(h.low, suitedAny);
    }
    if (h.gap <= 1) {
      return _ok(h.low, offsuitConnector) || _ok(h.low, offsuitAny);
    }
    return _ok(h.low, offsuitAny);
  }

  /// 整体收紧（delta > 0）或放宽（delta < 0）。
  PreflopRange shifted(int delta) => PreflopRange(
        pair: _shift(pair, delta),
        smallPair: _shiftSmall(smallPair, delta),
        suitedAce: _shift(suitedAce, delta),
        offsuitAce: _shift(offsuitAce, delta),
        suitedBroadway: _shift(suitedBroadway, delta),
        offsuitBroadway: _shift(offsuitBroadway, delta),
        suitedConnector: _shift(suitedConnector, delta),
        suitedGapper: _shift(suitedGapper, delta),
        suitedAny: _shift(suitedAny, delta),
        offsuitConnector: _shift(offsuitConnector, delta),
        offsuitAny: _shift(offsuitAny, delta),
      );

  /// 只调整非同花部分（对手越多，被压制的非同花牌越不值钱）。
  PreflopRange shiftedOffsuit(int delta) => PreflopRange(
        pair: pair,
        smallPair: smallPair,
        suitedAce: suitedAce,
        offsuitAce: _shift(offsuitAce, delta),
        suitedBroadway: suitedBroadway,
        offsuitBroadway: _shift(offsuitBroadway, delta),
        suitedConnector: suitedConnector,
        suitedGapper: suitedGapper,
        suitedAny: suitedAny,
        offsuitConnector: _shift(offsuitConnector, delta),
        offsuitAny: _shift(offsuitAny, delta),
      );

  /// 只调整投机牌（对子、同花连张）：筹码越深越值钱，短筹码可以不要。
  PreflopRange shiftedSpeculative(int delta) => PreflopRange(
        pair: _shift(pair, delta),
        smallPair: _shiftSmall(smallPair, delta),
        suitedAce: suitedAce,
        offsuitAce: offsuitAce,
        suitedBroadway: suitedBroadway,
        offsuitBroadway: offsuitBroadway,
        suitedConnector: _shift(suitedConnector, delta),
        suitedGapper: _shift(suitedGapper, delta),
        suitedAny: _shift(suitedAny, delta),
        offsuitConnector: offsuitConnector,
        offsuitAny: offsuitAny,
      );

  /// 去掉买三条/买同花这类需要隐含赔率的牌。
  PreflopRange withoutSpeculative() => PreflopRange(
        smallPair: 0, // 买三条属于投机牌，这一档直接去掉
        suitedAce: suitedAce,
        offsuitAce: offsuitAce,
        suitedBroadway: suitedBroadway,
        offsuitBroadway: offsuitBroadway,
        offsuitConnector: offsuitConnector,
        offsuitAny: offsuitAny,
      );

  /// 只去掉「买三条」那一档（22~88），其它牌型原样保留。
  ///
  /// 3bet 底池的 SPR 只有三到五，100bb 深度中一次三条也赢不回 3bet 的
  /// 价钱，真人这时拿小对子要么直接弃、要么当 4bet 诈唬；只有筹码极深、
  /// 后手足够多的局才值得跟进去买。所以这个版本给「不够深」的场合用。
  PreflopRange withoutSmallPairs() => PreflopRange(
        pair: pair,
        suitedAce: suitedAce,
        offsuitAce: offsuitAce,
        suitedBroadway: suitedBroadway,
        offsuitBroadway: offsuitBroadway,
        suitedConnector: suitedConnector,
        suitedGapper: suitedGapper,
        suitedAny: suitedAny,
        offsuitConnector: offsuitConnector,
        offsuitAny: offsuitAny,
      );

  static int _shift(int value, int delta) =>
      value == 0 ? 0 : (value + delta).clamp(2, 14);

  /// 上界型门槛（小对子）：收紧（delta > 0）= 上限往下走，只能打更小的对子。
  static int _shiftSmall(int value, int delta) =>
      value == 0 ? 0 : (value - delta).clamp(2, 14);
}

/// 面对开池加注时的三档结论。
typedef OpenDefense = ({bool valueThreeBet, bool lightThreeBet, bool call});

/// 翻前范围表：位置感知的「开池 / 溜入 / 防守 / 再加注」范围。
class PreflopRanges {
  PreflopRanges._();

  /// 某玩家处于哪个位置桶（兼容 2~9 人桌）。
  static Seat seatOf(GameEngine game, PlayerState me) {
    final n = game.players.length;
    final rel = (game.players.indexOf(me) - game.buttonIndex + n) % n;
    if (n == 2) return rel == 0 ? Seat.btn : Seat.bb; // 单挑：按钮 = 小盲
    switch (rel) {
      case 0:
        return Seat.btn;
      case 1:
        return Seat.sb;
      case 2:
        return Seat.bb;
    }
    // rel 3 是第一个开口的位置（前位），rel n-1 是劫位。
    final spots = n - 3; // 非盲注、非按钮的座位数
    if (spots <= 1) return Seat.co;
    final t = (rel - 3) / (spots - 1);
    if (t < 0.34) return Seat.ep;
    if (t < 0.67) return Seat.mp;
    return Seat.co;
  }

  // ---------- 开池（无人加注时主动加注）----------

  /// 开池范围，括号里是 9 人桌的大致入池率。
  static PreflopRange open(Seat seat) => switch (seat) {
        // 44+ / A8s+ / 全部同花大牌 / 87s+ / ATo+ / KQo
        Seat.ep => const PreflopRange(
            pair: 4,
            suitedAce: 8,
            offsuitAce: 10,
            suitedBroadway: 10,
            offsuitBroadway: 12,
            suitedConnector: 8,
          ), // ~15%
        // 33+ / A7s+ / 全部同花大牌 / 76s+ / 75s+ / ATo+ / KJo+ / QJo
        Seat.mp => const PreflopRange(
            pair: 3,
            suitedAce: 7,
            offsuitAce: 10,
            suitedBroadway: 10,
            offsuitBroadway: 11,
            suitedConnector: 7,
            suitedGapper: 8,
          ), // ~21%
        // 任意对子 / 任意同花 A / ATo+ / 全部大牌 / 54s+ / 75s+ / 98o+
        Seat.co => const PreflopRange(
            pair: 2,
            suitedAce: 2,
            offsuitAce: 10,
            suitedBroadway: 10,
            offsuitBroadway: 10,
            suitedConnector: 5,
            suitedGapper: 5,
            suitedAny: 6,
            offsuitConnector: 8,
            offsuitAny: 9,
          ), // ~27%
        // 按钮位：任意对子 / 任意同花 A / A5o+ / 54s+ / 75s+ / 87o+ / QTo+
        Seat.btn => const PreflopRange(
            pair: 2,
            suitedAce: 2,
            offsuitAce: 5,
            suitedBroadway: 10,
            offsuitBroadway: 10,
            suitedConnector: 5,
            suitedGapper: 5,
            suitedAny: 4,
            offsuitConnector: 7,
            offsuitAny: 8,
          ), // ~45%
        // 小盲偷盲：比按钮略紧（翻后没位置），基本是「加注或弃牌」
        Seat.sb => const PreflopRange(
            pair: 2,
            suitedAce: 2,
            offsuitAce: 7,
            suitedBroadway: 10,
            offsuitBroadway: 10,
            suitedConnector: 5,
            suitedGapper: 6,
            suitedAny: 4,
            offsuitConnector: 7,
            offsuitAny: 8,
          ), // ~38%
        Seat.bb => const PreflopRange(), // 大盲不主动开池
      };

  /// 溜入/补齐范围（无人加注、但要多花钱进去时）。
  static PreflopRange limp(Seat seat) => switch (seat) {
        // 后位溜入：便宜看翻牌，玩同花牌和小对子。
        Seat.ep || Seat.mp || Seat.co || Seat.btn => const PreflopRange(
            pair: 2,
            suitedAce: 3,
            suitedBroadway: 10,
            suitedConnector: 5,
            suitedGapper: 6,
            suitedAny: 8,
            offsuitAce: 10,
          ),
        // 小盲补齐：便宜，范围可以宽一些。
        Seat.sb => const PreflopRange(
            pair: 2,
            suitedAce: 2,
            suitedBroadway: 10,
            suitedConnector: 5,
            suitedGapper: 5,
            suitedAny: 5,
            offsuitAce: 10,
            offsuitBroadway: 12,
          ),
        Seat.bb => const PreflopRange(),
      };

  /// 跟注站的溜入范围：标准溜入范围只玩「同花牌 + 对子 + A 高张」，
  /// 松被动玩家连非同花连张、非同花大牌都便宜跟，所以单独列一张表。
  static PreflopRange limpLoose(Seat seat) => switch (seat) {
        // 小盲补齐：先投了 0.5bb，补齐很便宜。
        Seat.sb => const PreflopRange(
            pair: 2,
            suitedAce: 2,
            suitedBroadway: 10,
            offsuitAce: 10,
            offsuitBroadway: 12,
            suitedConnector: 5,
            suitedGapper: 5,
            suitedAny: 5,
            offsuitConnector: 9,
            offsuitAny: 9,
          ),
        Seat.bb => const PreflopRange(),
        // 其它位置：几乎什么便宜牌都跟，只扔掉真正的垃圾。
        _ => const PreflopRange(
            pair: 2,
            suitedAce: 2,
            suitedBroadway: 9,
            offsuitAce: 8,
            offsuitBroadway: 10,
            suitedConnector: 3,
            suitedGapper: 4,
            suitedAny: 2,
            offsuitConnector: 7,
            offsuitAny: 8,
          ),
      };

  /// 大盲面对溜入者时的「隔离加注」范围：溜入的人范围又宽又弱，用一手
  /// 强而线性的牌把他们打散，顺便把底池做大、把主动权拿到自己手里。
  static const PreflopRange isolateLimpers = PreflopRange(
    pair: 4,
    suitedAce: 8,
    offsuitAce: 11,
    suitedBroadway: 10,
    offsuitBroadway: 12,
    suitedConnector: 8,
    suitedGapper: 9,
    suitedAny: 9,
  );

  /// 开池加注大小的位置系数：前位开得大一点（要保护、要隔离），
  /// 后位偷盲可以小一点（同样能拿下盲注，还省筹码）。
  static double openSizeFactor(Seat seat) => switch (seat) {
        Seat.ep => 1.0,
        Seat.mp => 0.95,
        Seat.co => 0.88,
        Seat.btn => 0.82,
        Seat.sb => 1.0, // 小盲没位置，照前位开
        Seat.bb => 1.0,
      };

  // ---------- 短筹码：推 / 弃 ----------

  /// 短筹码（≤ 15bb）的开池全下范围：真人这时候打的是「推 / 弃」，
  /// 不会开个小注、再弃给别人的 3bet——那样既白送筹码又漏掉弃牌率。
  ///
  /// 表里那一档对应 12bb：每浅 2bb 整体放宽一档，每深 2bb 收紧一档
  /// （15bb 就收一档）。位置越靠后（后面要过的人越少）范围越宽。
  static PreflopRange shoveOpen(Seat seat, double stackBb) {
    final steps = ((12 - stackBb) / 2).floor().clamp(-1, 4);
    final base = switch (seat) {
      // 55+ / ATs+ / AQo+ / 同花大牌 / QTs+  ≈ 10%
      Seat.ep => const PreflopRange(
          pair: 5,
          suitedAce: 10,
          offsuitAce: 12,
          suitedBroadway: 10,
          suitedGapper: 11,
        ),
      // 44+ / A9s+ / AQo+ / 同花大牌 / 98s+  ≈ 12%
      Seat.mp => const PreflopRange(
          pair: 4,
          suitedAce: 9,
          offsuitAce: 12,
          suitedBroadway: 10,
          suitedConnector: 9,
          suitedGapper: 11,
        ),
      // 33+ / A8s+ / ATo+ / KQo / 76s+ / T8s+  ≈ 17%
      Seat.co => const PreflopRange(
          pair: 3,
          suitedAce: 8,
          offsuitAce: 10,
          suitedBroadway: 10,
          offsuitBroadway: 12,
          suitedConnector: 8,
          suitedGapper: 10,
        ),
      // 22+ / A4s+ / A8o+ / KTo+ / 65s+ / 86s+ / 其它同花  ≈ 33%
      Seat.btn => const PreflopRange(
          pair: 2,
          suitedAce: 4,
          offsuitAce: 8,
          suitedBroadway: 10,
          offsuitBroadway: 10,
          suitedConnector: 6,
          suitedGapper: 7,
          suitedAny: 6,
          offsuitConnector: 8,
          offsuitAny: 11,
        ),
      // 小盲只需要过一个对手，可以推得比按钮还宽  ≈ 45%
      Seat.sb => const PreflopRange(
          pair: 2,
          suitedAce: 3,
          offsuitAce: 7,
          suitedBroadway: 10,
          offsuitBroadway: 10,
          suitedConnector: 5,
          suitedGapper: 6,
          suitedAny: 5,
          offsuitConnector: 7,
          offsuitAny: 10,
        ),
      // 大盲（对溜入者隔离全下）：后面还有人，范围要实
      Seat.bb => const PreflopRange(
          pair: 5,
          suitedAce: 10,
          offsuitAce: 12,
          suitedBroadway: 10,
          suitedConnector: 9,
          suitedGapper: 11,
        ),
    };
    return base.shifted(-steps);
  }

  // ---------- 面对加注 ----------

  /// 再加注（3bet）的价值范围，随加注者位置放宽。
  static PreflopRange valueThreeBet(Seat raiser) => switch (raiser) {
        Seat.ep => const PreflopRange(
            pair: 12, suitedAce: 13, offsuitAce: 13), // QQ+ / AKs / AKo
        Seat.mp => const PreflopRange(
            pair: 11, suitedAce: 12, offsuitAce: 13), // JJ+ / AQs+ / AKo
        _ => const PreflopRange(
            pair: 10,
            suitedAce: 11,
            offsuitAce: 13,
            offsuitBroadway: 12), // TT+ / AJs+ / AKo / KQo
      };

  /// 4bet 及以上只打顶端。
  static const PreflopRange valueFourBet = PreflopRange(
    pair: 12,
    suitedAce: 13,
    offsuitAce: 13,
  );

  /// 跟 3bet 的范围（位置好、筹码深才有）。
  ///
  /// [suitedBroadway] 这一档必须显式写：范围表的「大牌」分支是短路的——
  /// 同花大牌只查 suitedBroadway，查不到就直接判「不在范围内」，不会掉到
  /// 下面的同花连张/隔张档去。以前这里只有 suitedAce + suitedConnector，
  /// 结果 KQs/KJs/QJs 这些标准的跟注牌被当成垃圾弃掉，反倒是 87s 一路跟
  /// ——跟注范围长成了「有 A 的同花 + 小连张」，真人根本不是这么防守的。
  /// 同花连张这一档只留 T9s/98s：以前是 65s+，等于 76s/87s 面对 3bet 也
  /// 100% 跟注——这些牌在 3bet 底池里很难实现胜率（翻牌中一对都不够打），
  /// 真人拿它们基本是直接弃或者 4bet 诈唬，不会老实跟注。
  static const PreflopRange callThreeBet = PreflopRange(
    pair: 9,
    smallPair: 8, // 22~88：深筹码有位置时买三条，真人最爱这一手
    suitedAce: 11,
    suitedBroadway: 10, // KQs / KJs / QJs / JTs（同花大牌）
    suitedConnector: 8, // T9s / 98s
    offsuitBroadway: 12, // AQo / KQo
  );

  /// [callThreeBet] 里「有摊牌价值」的那一半（99+、ATs+、KQs~JTs、AQo/KQo）。
  /// 另一半（小对子、同花连张）是纯投机的，真人不会每次都跟——边缘的跟注
  /// 本来就是混着打的，跟得太满等于把跟注范围撑宽到对手随便开一枪就收走。
  static const PreflopRange callThreeBetCore = PreflopRange(
    pair: 9,
    suitedAce: 11,
    suitedBroadway: 10,
    offsuitBroadway: 12,
  );

  /// 没位置跟 3bet 的范围：只留有牌力的那一半（TT+ / AQs+ / AKo / KQs）。
  ///
  /// 靠位置的投机牌（小对子、同花连张、ATs 这类）没位置一律不跟——翻后
  /// 先行动、中一对也不够打，只会把筹码一条街一条街送出去。以前这里根本
  /// 没有这一档：没位置的人面对 3bet 除了 4bet 就是 100% 弃牌，连带 KK/QQ
  /// 都被扔了（紧凶还剩 4bet 兜底，跟注站连 4bet 都不打，直接弃）。
  /// 一条「永远不会用强牌跟注」的线，对手拿任意两张牌 3bet 都是赚的。
  static const PreflopRange callThreeBetOop = PreflopRange(
    pair: 10,
    suitedAce: 12, // AQs+
    suitedBroadway: 12, // KQs
    offsuitBroadway: 13, // AKo
  );

  /// 跟注站面对 3bet 的跟注范围：不看位置，把「有 A 的同花、同花连张、
  /// 对子」全带上。跟注站的区别不是「拿垃圾牌也跟」，而是它们不会因为
  /// 没位置、或者筹码不够深就把一手能玩的牌扔掉——面对 3bet 只有两个
  /// 反应：跟，或者真的没牌才弃。以前这里给它们的是「有位置 + 深筹码」
  /// 的紧凶范围，等于把跟注站打成了全场最紧的人。
  static const PreflopRange callThreeBetStation = PreflopRange(
    pair: 2, // 任何对子（跟注站也会拿 22 进去买三条）
    suitedAce: 2, // 任何同花 A（含 A5s~A2s）
    suitedBroadway: 10, // KQs~JTs
    offsuitBroadway: 11, // AJo+ / KQo
    suitedConnector: 6, // 76s+
    suitedGapper: 8, // T8s+
  );

  // 有位置防守：对子买三条 + 同花牌 + 高张，非同花杂牌不跟。
  static const _ipDefend = PreflopRange(
    pair: 2,
    suitedAce: 2,
    offsuitAce: 11,
    suitedBroadway: 10,
    offsuitBroadway: 11,
    suitedConnector: 5,
    suitedGapper: 6,
    suitedAny: 7,
  );

  // 没位置防守：更依赖牌力，少玩同花杂牌。
  static const _oopDefend = PreflopRange(
    pair: 2,
    suitedAce: 3,
    offsuitAce: 12,
    suitedBroadway: 10,
    offsuitBroadway: 12,
    suitedConnector: 6,
    suitedGapper: 8,
    suitedAny: 8,
  );

  // 大盲防守：价格最好，范围最宽（含大量同花牌和便宜的高张）。
  static const _bbDefend = PreflopRange(
    pair: 2,
    suitedAce: 2,
    offsuitAce: 6,
    suitedBroadway: 10,
    offsuitBroadway: 10,
    suitedConnector: 3,
    suitedGapper: 5,
    suitedAny: 2,
    offsuitConnector: 6,
    offsuitAny: 10,
  );

  // 小盲平跟：不关门又没位置，只用来买三条/买同花（还要有人跟注）。
  static const _sbDefend = PreflopRange(
    pair: 2,
    suitedAce: 4,
    suitedConnector: 5,
    suitedGapper: 6,
  );

  /// 「轻 3bet」（诈唬性再加注）的候选牌：有阻断牌或成牌潜力。
  static bool isLightThreeBetHand(PreflopHand h) {
    if (h.suited && h.isAce && h.low <= 5) return true; // A5s~A2s
    if (h.suited && !h.isAce && h.gap <= 1 && h.low >= 5 && h.low <= 9) {
      return true; // 54s~T9s
    }
    return !h.suited && h.high == 13 && h.low == 12; // KQo
  }

  /// 面对 3bet 可以拿来「轻 4bet」的牌：基本只有 A5s~A2s。
  ///
  /// 这些牌在 3bet 底池里翻后几乎没有摊牌价值（顶对都站不住），跟注等于
  /// 把筹码交给对手的强范围；它们的价值在于挡住 AA/AK（对手的 4bet/5bet
  /// 组合少掉一大半）加上翻牌还有坚果花和顺子潜力。真人这时是压回去，
  /// 不是跟注——以前这里没有这一档，A5s/A2s 面对 3bet 是 100% 弃牌，
  /// 对手可以毫无压力地拿任意两张牌 3bet 我们。
  static bool isLightFourBetHand(PreflopHand h) =>
      h.suited && h.isAce && h.low <= 5;

  /// 冷跟开池的范围（翻后给对手范围建模用）。
  static PreflopRange coldCallRange({
    required Seat seat,
    required bool inPosition,
  }) =>
      switch (seat) {
        Seat.bb => _bbDefend,
        Seat.sb => _sbDefend,
        _ => inPosition ? _ipDefend : _oopDefend,
      };

  /// 这个位置加注（开池或 3bet）时范围有多强：0 = 后位偷盲，2 = 前位好牌。
  static int raiserTightness(Seat raiser) => switch (raiser) {
        Seat.ep => 2,
        Seat.mp => 1,
        _ => 0,
      };

  /// 面对单个开池加注的应对。
  ///
  /// - [seat]/[raiser]：我在哪、加注者在哪；
  /// - [inPosition]：我翻后是否在加注者之后行动；
  /// - [callers]：我行动之前已经跟注进来的人数；
  /// - [raiseBb]/[stackBb]：加注大小与我的有效筹码（大盲数）。
  static OpenDefense versusOpen({
    required Seat seat,
    required PreflopHand hand,
    required Seat raiser,
    required bool inPosition,
    required int callers,
    required double raiseBb,
    required double stackBb,
    int threeBetWidth = 0,
    int callWidth = 0,
  }) {
    // 前面已经有人跟注：底池里的死钱更多，再加注（挤压）的收益更高，
    // 所以价值范围可以放宽一档——这是真人 squeeze 的由来。
    final squeeze = callers > 0;
    final value = valueThreeBet(raiser)
        .shifted(threeBetWidth + (squeeze ? -1 : 0));
    if (value.contains(hand)) {
      return (valueThreeBet: true, lightThreeBet: false, call: false);
    }

    // 轻 3bet 只针对后位开池（真正的偷盲），且位置不能太差；
    // 有人跟注时弃牌率虽然低一点，但死钱多，仍然值得偶尔挤一把。
    final late = raiser == Seat.co || raiser == Seat.btn || raiser == Seat.sb;
    final light = late &&
        (inPosition || seat == Seat.sb || seat == Seat.bb) &&
        isLightThreeBetHand(hand);

    var range = switch (seat) {
      // 大盲价格最好：已经投过 1bb，范围最宽；多人跟注后再收紧。
      Seat.bb => callers >= 2 ? _bbDefend.shifted(1) : _bbDefend,
      // 小盲不关门又没位置：没人跟注时就是「3bet 或弃牌」，
      // 有人跟注才有便宜的隐含赔率去买三条/买同花。
      Seat.sb => callers >= 1 ? _sbDefend : const PreflopRange(),
      _ => inPosition ? _ipDefend : _oopDefend,
    };
    // 加注者越靠前，范围越强：冷跟的牌力门槛跟着提高。
    range = range.shifted(raiserTightness(raiser));

    // 加注越大越贵：小注可以便宜看翻牌，大注要收紧。
    if (raiseBb <= 2.5) {
      range = range.shifted(-1);
    } else if (raiseBb >= 4.5) {
      range = range.shifted(raiseBb >= 8 ? 2 : 1);
    }
    // 前面已经有人跟注：非同花牌容易被压制，谨慎一点。
    if (callers > 0) {
      range = range.shiftedOffsuit(1);
    }
    // 筹码深度：短筹码没有买三条的隐含赔率，深筹码投机牌更值钱。
    if (stackBb < 30) {
      range = range.withoutSpeculative();
    } else if (stackBb > 120) {
      range = range.shiftedSpeculative(-1);
    }
    if (callWidth != 0) {
      range = range.shifted(callWidth);
    }

    return (
      valueThreeBet: false,
      lightThreeBet: light,
      call: range.contains(hand),
    );
  }
}
