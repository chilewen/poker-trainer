import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../../trainer/odds.dart';
import 'hand_analysis.dart';
import 'hand_strength.dart';
import 'table_position.dart';
import 'preflop_ranges.dart';

/// 失误的类型。文案是给玩家看的，不是给日志看的——复盘要能一眼读懂。
///
/// [detail] 说的是「刚才发生了什么」，[advice] 说的是「下次怎么打」。牌桌上那个
/// 提醒弹窗两样都要：只讲错了什么，玩家看完还是不知道该怎么改。
enum MistakeKind {
  preflopTooLoose(
    '翻前入池过宽',
    '拿着开池范围外的牌主动投钱',
    '这类牌先扔掉。位置越靠后开池可以越宽，但宽也得是翻后接得上的牌。',
  ),
  preflopTooTight(
    '翻前弃牌过紧',
    '能开池的牌没人加注却先弃了',
    '前面没人加注时这种牌可以直接开池。一直弃等于把盲注白送出去。',
  ),
  preflopColdCallTooWide(
    '翻前跟加注过宽',
    '面对加注，用范围外的牌跟注',
    '面对加注先问自己：这手能中什么、中了能不能赢回来。跟不动的牌就再加注或直接弃。',
  ),
  badCall(
    '跟注没有赔率',
    '赔率不够、又没听牌，还是跟了',
    '跟之前先问一句：我这手牌靠什么赢？没成牌又没听牌，赔率不够就该弃。',
  ),
  badFold(
    '弃牌太紧',
    '强牌面对便宜的下注却弃了',
    '该跟就得跟。牌已经成了、价格又便宜，弃掉是最亏的一种打法。',
  );

  const MistakeKind(this.label, this.detail, this.advice);

  final String label;
  final String detail;

  /// 一句话建议：这手之后该怎么改。
  final String advice;
}

/// 一次失误：落在哪条街、当时是第几个动作（对回历史里的下标）。
class Mistake {
  const Mistake({
    required this.kind,
    required this.street,
    required this.decisionIndex,
    required this.detail,
    required this.fix,
  });

  final MistakeKind kind;
  final Street street;

  /// `hand.actions` 里的下标，复盘页要拿它定位到那一行。
  final int decisionIndex;

  /// 具体到这手牌的一句话（比如「A♥7♦ 面对 400，保本 34%」）。
  final String detail;

  /// 具体到这手牌的建议。
  ///
  /// 和 [MistakeKind.advice] 的分工：那边是「这类毛病以后怎么办」的通例，
  /// 一句话贴给所有同类失误，看多了就是复读；这里带上这手的位置、牌力、
  /// 赔率和实际胜率，换个手牌换个数，才像是刚才那把的复盘。
  final String fix;
}

/// 单手牌的「教学视角」：起手牌在不在范围里、翻前胜率多少、有没有失误。
///
/// 和 [HandAnalysis] 分开：那里只做「把历史翻译成事实」，这里做「判断好不好」。
/// 判断是有价值观的（松紧的阈值、什么算强牌），所以单独放，改口径不会动到
/// 那些纯事实的用例。
class HandGrade {
  const HandGrade._({
    required this.seat,
    required this.preflopLabel,
    required this.inOpenRange,
    required this.inLimpRange,
    required this.mistakes,
    required this.analysis,
  });

  final HandAnalysis analysis;

  /// 英雄的位置桶（翻前范围是按它查的）；位置不明时为 null。
  final Seat? seat;

  /// 英雄起手牌的文字，如 `A♥7♦` 的「A7s」；没底牌时为 null。
  final String? preflopLabel;

  /// 起手牌在不在「这个位置的开池范围」里。
  final bool inOpenRange;

  /// 在不在「这个位置的跛入范围」里。
  final bool inLimpRange;

  /// 这手所有失误，按发生顺序。
  final List<Mistake> mistakes;

  bool get hasMistake => mistakes.isNotEmpty;

  /// 翻前对 [opponents] 个随机对手的胜率（0~1）。
  ///
  /// 蒙特卡洛，固定种子：同一手牌算几遍都是同一个数——复盘上的数字不能一开
  /// 一变。没底牌时返回 null。
  double? preflopEquity({int opponents = 1, int trials = 1500, int seed = 11}) {
    final hole = analysis.heroHole;
    if (hole.length != 2) return null;
    return Odds.equity(
      heroHole: hole,
      opponents: opponents < 1 ? 1 : (opponents > 8 ? 8 : opponents),
      trials: trials,
      random: Random(seed),
    ).win;
  }

  /// 走到 [d] 这步决策时的底池份额（0~1）：赢的牌 + 平局摊分。
  ///
  /// 对手底牌按随机牌算（多人池里他们也确实常常是宽范围），人数取「还没弃牌
  /// 的人」——比固定成满桌准。固定种子，同一个决策点算几遍都一样。
  double? equityAt(DecisionPoint d, {int trials = 900}) {
    final hole = analysis.heroHole;
    if (hole.length != 2) return null;
    final board = _boardThrough(analysis.hand.board, d.street);
    if (board.length > 5) return null;
    final opp = _liveOpponents(d.index);
    if (opp < 1) return null;
    return Odds.equity(
      heroHole: hole,
      board: board,
      opponents: opp,
      trials: trials,
      random: Random(1000 + d.index),
    ).share(opp);
  }

  /// 跟注这一步的即时 EV（筹码）：份额 × 跟注后的底池 − 跟注额。
  ///
  /// 「即时」= 只算这一注、假设后面不再下注。非全下时是个近似，但方向对：
  /// 正的就该接着玩，负的就是在扔钱。正负比绝对值可信。
  double? callEv(DecisionPoint d, {int trials = 900}) {
    if (!d.facingBet || d.toCall <= 0) return null;
    final share = equityAt(d, trials: trials);
    if (share == null) return null;
    return share * (d.potBefore + d.toCall) - d.toCall;
  }

  /// 到第 [beforeIndex] 步之前还没弃牌、且不是英雄本人的对手数。
  int _liveOpponents(int beforeIndex) {
    final folded = <String>{};
    for (final d in analysis.decisions) {
      if (d.index >= beforeIndex) break;
      if (d.type == ActionType.fold) folded.add(d.actorId);
    }
    return analysis.order
        .where((id) => id != analysis.heroId && !folded.contains(id))
        .length;
  }

  static HandGrade of(HandAnalysis analysis) {
    final seat = seatOfPosition(analysis.heroPosition);
    final hole = analysis.heroHole;
    PreflopHand? hand;
    var inOpen = false;
    var inLimp = false;
    if (seat != null && hole.length == 2) {
      hand = PreflopHand.of(hole);
      inOpen = PreflopRanges.open(seat).contains(hand);
      inLimp = PreflopRanges.limp(seat).contains(hand);
    }
    return HandGrade._(
      analysis: analysis,
      seat: seat,
      preflopLabel: hand?.label,
      inOpenRange: inOpen,
      inLimpRange: inLimp,
      mistakes: _mistakesOf(
        analysis,
        seat: seat,
        hole: hand,
        inOpen: inOpen,
        inLimp: inLimp,
        board: analysis.hand.board,
      ),
    );
  }

  /// 中文位置名 → 翻前位置桶。两个「后位」名（关煞/嗨加）都归劫位。
  static Seat? seatOfPosition(String? position) => switch (position) {
        '庄位' => Seat.btn,
        '小盲' => Seat.sb,
        '大盲' => Seat.bb,
        '枪口' => Seat.ep,
        '中位' => Seat.mp,
        '关煞' || '嗨加' => Seat.co,
        _ => null,
      };

  /// 贵到什么程度算「没赔率」：保本 ≥25%（半池起）的跟注，配空气/弱成牌
  /// 就是送钱。
  ///
  /// 一开始卡在 30%（约四分之三池）是怕误报，结果探针跑下来 600 手 6 人桌
  /// 只标出 2 处翻后失误——训练器宁可漏、也不能没有。放宽到 25%（半池）
  /// 后同一批样本标出 19 处，其中 8 手会真的弹提醒；这正是真人最常犯的
  /// 一档：拿高张/底对跟一个半池，看着便宜，成牌率其实撑不起来。仍然不理
  /// 「弱成牌跟 1/4 池」这种正常防守。
  static const steepPotOdds = 0.25;

  /// 便宜到什么程度算「弃了可惜」：保本 ≤22%（约 4.5:1）时，强牌不该弃。
  static const cheapPotOdds = 0.22;

  static List<Mistake> _mistakesOf(
    HandAnalysis a, {
    required Seat? seat,
    required PreflopHand? hole,
    required bool inOpen,
    required bool inLimp,
    required List<Card> board,
  }) {
    final out = <Mistake>[];
    final hero = a.heroDecisions;
    if (hero.isEmpty) return out;

    // ---------- 翻前 ----------
    final first = hero.first;
    final holeText = _holeText(a.heroHole);
    if (first.street == Street.preflop && seat != null) {
      // 「前面有没有人加注」不能看 toCall：盲注在记录里也是 bet，英雄一坐下
      // 面对的大盲就 >= 一个大盲，但那是盲注不是加注。真正的加注只有 raise。
      final raisesBefore = [
        for (final x in a.hand.actions.take(first.index))
          if (x.street == Street.preflop && x.type == ActionType.raise) x,
      ];
      final facedRaise = raisesBefore.isNotEmpty;

      if (facedRaise) {
        // 面对加注查的是防守范围（另一张表），不是开池范围。
        //
        // 只挑「连庄位开池都进不去」的牌说：真人防守宽一点很正常，
        // 拿 72o 跟加注才是真漏，这条界线两边不挨着。
        if (first.type == ActionType.call &&
            hole != null &&
            !PreflopRanges.coldCallRange(
              seat: seat,
              inPosition: _inPositionVs(a, a.heroId, raisesBefore.last.actorId),
            ).contains(hole) &&
            !PreflopRanges.open(Seat.btn).contains(hole)) {
          out.add(Mistake(
            kind: MistakeKind.preflopColdCallTooWide,
            street: Street.preflop,
            decisionIndex: first.index,
            detail: '$holeText 连庄位的开池范围都进不去，'
                '却跟了${_raiserText(a, raisesBefore.last.actorId)}的加注',
            fix: '$holeText 这种牌跟进去，翻牌九成是「没中就走、中了也不一定赢」。'
                '面对加注要么再加注回去，要么直接弃——跟注是最差的第三条路。',
          ));
        }
      } else if (seat != Seat.bb && seat != Seat.sb) {
        // 开池这条只评「没人在我前面加注」且不在盲注位的情况：
        // 大盲从来没机会先开池，小盲的「投钱进池」本身就是盲注。
        if (first.type == ActionType.fold && inOpen) {
          out.add(Mistake(
            kind: MistakeKind.preflopTooTight,
            street: Street.preflop,
            decisionIndex: first.index,
            detail: '${a.heroPosition}的 $holeText 在前面没人加注时可以直接开池',
            fix: '$holeText 在${a.heroPosition}是能开的。前面没人加注就是白送的'
                '机会，一直弃等于每圈把盲注送给别人。',
          ));
        }
        if ((first.type == ActionType.call || first.type == ActionType.raise) &&
            !inOpen &&
            !inLimp) {
          final lateOpen = hole != null &&
              (PreflopRanges.open(Seat.btn).contains(hole) ||
                  PreflopRanges.open(Seat.co).contains(hole));
          out.add(Mistake(
            kind: MistakeKind.preflopTooLoose,
            street: Street.preflop,
            decisionIndex: first.index,
            detail: '$holeText 不在${a.heroPosition}的开池范围里',
            fix: lateOpen
                ? '$holeText 放到后面的位置是能开的，${a.heroPosition}就太早了：'
                    '后面还有一堆人没说话，先弃掉，等位置靠后再拿它进池。'
                : '$holeText 哪个位置都不在开池范围里，属于标准的垃圾牌。'
                    '这种牌越早弃越省钱，偶尔中一次也补不回平时投进去的。',
          ));
        }
      }
    }

    // ---------- 翻后：按「牌力 vs 底池赔率」判跟/弃 ----------
    for (final d in hero) {
      if (!d.facingBet || d.street == Street.preflop) continue;
      final boardNow = _boardThrough(board, d.street);
      if (boardNow.length < 3 || a.heroHole.length != 2) continue;
      final reading = HandReading.of(a.heroHole, boardNow);
      final need = d.potOdds;
      final pct = (need * 100).round();
      // 实际胜率（走到摊牌）：只有真的要报失误时才算——蒙特卡洛不便宜，
      // 正常的跟注不该为了一句提示付这笔钱。
      final share = _equityPct(a, d);
      if (d.type == ActionType.call) {
        final weakNoDraw =
            reading.tier.index <= HandTier.weak.index && !reading.hasDraw;
        if (weakNoDraw && need >= steepPotOdds) {
          out.add(Mistake(
            kind: MistakeKind.badCall,
            street: d.street,
            decisionIndex: d.index,
            detail: '${_holeText(a.heroHole)} 是${reading.tier.label}、没有听牌，'
                '面对 ${d.amountIn} 要跟注得赢 $pct% 才保本',
            fix: share == null || share >= pct
                ? '这手只剩 ${reading.tier.label}，靠它赢太难了。'
                    '${d.street.label}没成牌又没听牌时，弃牌不是软弱，是省钱。'
                : '要赢 $pct% 才保本，这手到摊牌大概只有 $share%——'
                    '差 ${pct - share} 个点，跟一次亏一次。',
          ));
        }
      } else if (d.type == ActionType.fold) {
        final strong = reading.tier.index >= HandTier.strong.index;
        if (strong && need <= cheapPotOdds) {
          out.add(Mistake(
            kind: MistakeKind.badFold,
            street: d.street,
            decisionIndex: d.index,
            detail: '${_holeText(a.heroHole)} 已经成${reading.tier.label}，'
                '只要 ${d.toCall} 就能看下一张（保本 $pct%），却弃了',
            fix: '牌已经成了${reading.tier.label}，花 ${d.toCall} 看牌只要赢 '
                '$pct% 就回本${share == null ? '' : '（这手约 $share%）'}——'
                '这种价格弃掉是整手牌里最亏的一步。',
          ));
        }
      }
    }
    return out;
  }

  /// 走到 [d] 这步时英雄的胜率（百分数）。口径和 [equityAt] 一致：
  /// 同一手、同一步，这里和复盘页显示的是同一个数。
  static int? _equityPct(HandAnalysis a, DecisionPoint d) {
    final hole = a.heroHole;
    if (hole.length != 2) return null;
    final board = _boardThrough(a.hand.board, d.street);
    if (board.length > 5) return null;
    final folded = <String>{};
    for (final x in a.decisions) {
      if (x.index >= d.index) break;
      if (x.type == ActionType.fold) folded.add(x.actorId);
    }
    final opp =
        a.order.where((id) => id != a.heroId && !folded.contains(id)).length;
    if (opp < 1) return null;
    final share = Odds.equity(
      heroHole: hole,
      board: board,
      opponents: opp,
      trials: 900,
      random: Random(1000 + d.index),
    ).share(opp);
    return (share * 100).round();
  }

  /// 翻后行动顺序里 [heroId] 是不是排在 [otherId] 后面（= 相对他有位置）。
  static bool _inPositionVs(HandAnalysis a, String heroId, String otherId) {
    final n = a.order.length;
    final btn = a.hand.buttonIndex;
    if (n < 2 || btn < 0) return false;
    // 单挑是特例：庄位（小盲）翻前先说话，翻后反而是最后说话的那个。
    if (n == 2) return a.order[btn % n] == heroId;
    int at(String id) => (a.order.indexOf(id) - btn + n) % n;
    return at(heroId) > at(otherId);
  }

  /// 「枪口的」这种前缀，拼进句子里用。
  static String _raiserText(HandAnalysis a, String raiserId) =>
      cnPosition(a.order, a.hand.buttonIndex, raiserId) ?? '对手';

  /// 走到这条街时桌面上应该有几张公共牌。
  static List<Card> _boardThrough(List<Card> board, Street street) {
    final n = switch (street) {
      Street.preflop => 0,
      Street.flop => 3,
      Street.turn => 4,
      Street.river || Street.showdown => 5,
    };
    return board.take(n).toList();
  }

  static String _holeText(List<Card> hole) =>
      hole.map((c) => c.pretty).join(' ');
}

/// 牌桌上值得打断一下的失误：这手输了，而且里面有失误。
class MistakeAlert {
  const MistakeAlert({
    required this.hand,
    required this.lost,
    required this.mistake,
    required this.others,
  });

  final HandHistory hand;

  /// 英雄这一手净输了多少（正数，界面上直接显示）。
  final int lost;

  /// 最该说的一条失误。
  final Mistake mistake;

  /// 同一手里其余的失误条数（0 表示只有这一条）。
  final int others;
}

/// 这手打完要不要在场面上提醒一下：**输了 + 有失误**。
///
/// 赢着也弹是噪音，输但没打错（被翻盘、被诈唬）更不该弹——那会把「结果差」和
/// 「打得差」混成一件事。一次只说最严重的一条（翻后把该跟/该弃做反了 > 翻前
/// 范围漏），其余只报个数：一次说一件事才记得住。
MistakeAlert? mistakeAlertOf(HandHistory hand, {required String heroId}) {
  final net = hand.netResult[heroId] ?? 0;
  if (net >= 0) return null;
  final grade = HandGrade.of(HandAnalysis.of(hand, heroId: heroId));
  if (grade.mistakes.isEmpty) return null;
  // 同权重时按发生顺序取——`List.sort` 不保证稳定，不加这一层的话
  // 一手里两条同档失误每次挑出来的可能不一样（弹窗内容会飘）。
  final ranked = [...grade.mistakes]..sort((a, b) {
      final byWeight = _weight(b.kind).compareTo(_weight(a.kind));
      return byWeight != 0
          ? byWeight
          : a.decisionIndex.compareTo(b.decisionIndex);
    });
  return MistakeAlert(
    hand: hand,
    lost: -net,
    mistake: ranked.first,
    others: ranked.length - 1,
  );
}

/// 排序用的轻重：翻后把该跟/该弃做反了是当场丢钱，比翻前的范围漏更该先说。
int _weight(MistakeKind kind) => switch (kind) {
      MistakeKind.badCall || MistakeKind.badFold => 3,
      MistakeKind.preflopColdCallTooWide => 2,
      MistakeKind.preflopTooLoose => 1,
      MistakeKind.preflopTooTight => 0,
    };

/// 逐手评估（handId → [HandGrade]），给总结页用。
///
/// 一次算好位置、底牌、失误，列表和汇总共用——两处各算一遍迟早对不上。
Map<String, HandGrade> gradeHands(
  Iterable<HandHistory> hands, {
  required String heroId,
}) =>
    {
      for (final h in hands)
        h.id: HandGrade.of(HandAnalysis.of(h, heroId: heroId)),
    };
