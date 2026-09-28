import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../../trainer/odds.dart';
import 'hand_analysis.dart';
import 'hand_strength.dart';
import 'preflop_ranges.dart';

/// 失误的类型。文案是给玩家看的，不是给日志看的——复盘要能一眼读懂。
enum MistakeKind {
  preflopTooLoose('翻前入池过宽', '拿着开池范围外的牌主动投钱'),
  preflopTooTight('翻前弃牌过紧', '能开池的牌没人加注却先弃了'),
  badCall('跟注没有赔率', '赔率不够、又没听牌，还是跟了'),
  badFold('弃牌太紧', '强牌面对便宜的下注却弃了');

  const MistakeKind(this.label, this.detail);

  final String label;
  final String detail;
}

/// 一次失误：落在哪条街、当时是第几个动作（对回历史里的下标）。
class Mistake {
  const Mistake({
    required this.kind,
    required this.street,
    required this.decisionIndex,
    required this.detail,
  });

  final MistakeKind kind;
  final Street street;

  /// `hand.actions` 里的下标，复盘页要拿它定位到那一行。
  final int decisionIndex;

  /// 具体到这手牌的一句话（比如「A♥7♦ 面对 400，保本 34%」）。
  final String detail;
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

  /// 贵到什么程度算「没赔率」：保本 ≥30% 的跟注，配空气/弱成牌基本是送钱。
  ///
  /// 阈值刻意保守。探针拿 300 手 6 人桌 AI 对局当样本（AI 当「英雄」跑
  /// [HandGrade]）：只标出 2.9% 的手，且几乎全是翻前范围漏，翻后这条基本
  /// 不误报。宁可漏掉边角，也别把「弱成牌跟 1/4 池」这种正常防守算成失误。
  static const steepPotOdds = 0.30;

  /// 便宜到什么程度算「弃了可惜」：保本 ≤22%（约 4.5:1）时，强牌不该弃。
  static const cheapPotOdds = 0.22;

  static List<Mistake> _mistakesOf(
    HandAnalysis a, {
    required Seat? seat,
    required bool inOpen,
    required bool inLimp,
    required List<Card> board,
  }) {
    final out = <Mistake>[];
    final hero = a.heroDecisions;
    if (hero.isEmpty) return out;

    // ---------- 翻前：只在「没人在我前面加注」时评开池 ----------
    // 面对加注时要查的是防守/再加注范围，那是另一套表，这里不拍脑袋。
    final first = hero.first;
    if (first.street == Street.preflop && seat != null && seat != Seat.bb) {
      // 大盲从来没机会「先开池」，跳过；大小盲的防守范围也不在这张表里。
      //
      // 「前面有没有人加注」不能看 toCall：盲注在记录里也是 bet，英雄一坐下
      // 面对的大盲就 >= 一个大盲，但那是盲注不是加注。真正的加注只有 raise。
      final facedRaise = a.hand.actions
          .take(first.index)
          .any((x) => x.street == Street.preflop && x.type == ActionType.raise);
      final inBlinds = seat == Seat.sb;
      if (!facedRaise && !inBlinds) {
        if (first.type == ActionType.fold && inOpen) {
          out.add(Mistake(
            kind: MistakeKind.preflopTooTight,
            street: Street.preflop,
            decisionIndex: first.index,
            detail: '${a.heroPosition}的 ${_holeText(a.heroHole)} '
                '在前面没人加注时可以直接开池',
          ));
        }
        if ((first.type == ActionType.call || first.type == ActionType.raise) &&
            !inOpen &&
            !inLimp) {
          out.add(Mistake(
            kind: MistakeKind.preflopTooLoose,
            street: Street.preflop,
            decisionIndex: first.index,
            detail: '${_holeText(a.heroHole)} 不在${a.heroPosition}的开池范围里',
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
      if (d.type == ActionType.call) {
        final weakNoDraw = reading.tier.index <= HandTier.weak.index &&
            !reading.hasDraw;
        if (weakNoDraw && need >= steepPotOdds) {
          out.add(Mistake(
            kind: MistakeKind.badCall,
            street: d.street,
            decisionIndex: d.index,
            detail: '${_holeText(a.heroHole)} 是${reading.tier.label}、没有听牌，'
                '面对 ${d.amountIn} 要跟注得赢 $pct% 才保本',
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
          ));
        }
      }
    }
    return out;
  }

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
