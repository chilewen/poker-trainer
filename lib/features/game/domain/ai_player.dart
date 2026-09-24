import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/game.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../../trainer/odds.dart';
import 'hand_strength.dart';

/// AI 风格：
/// - 紧凶：打得少打得凶，会用听牌和空气持续施压；
/// - 松被动：跟注站，什么牌都便宜跟，很少主动加注；
/// - 松凶：入池宽但攻击性强，半诈唬与诈唬压得最凶。
enum AiStyle {
  tightAggressive('紧凶'),
  loosePassive('松被动'),
  looseAggressive('松凶');

  const AiStyle(this.label);
  final String label;

  /// 风格参数表：三种风格共用同一套决策逻辑，区别只在这组数字。
  _Profile get _profile => switch (this) {
        AiStyle.tightAggressive => _tightProfile,
        AiStyle.loosePassive => _passiveProfile,
        AiStyle.looseAggressive => _looseAggressiveProfile,
      };
}

/// 一种风格的参数表。抽出来是为了让风格差异可解释、可微调，
/// 而不是散落在决策代码里的 `_tag ? a : b`。
class _Profile {
  const _Profile({
    required this.openBase,
    required this.openByPosition,
    required this.limpLine,
    required this.threeBetLine,
    required this.lightThreeBet,
    required this.callBase,
    required this.callByPosition,
    required this.openSizeBb,
    required this.positionSensitivity,
    required this.bluffScale,
    required this.semiBluffScale,
    required this.aggressionScale,
    required this.semiBluffRaiseScale,
    required this.bluffRaiseScale,
    this.lightThreeBetAnyPosition = false,
    this.limpsAnyPrice = false,
  });

  /// 开池加注的 Chen 阈值 = [openBase] - [openByPosition] × 位置系数。
  final double openBase;
  final double openByPosition;

  /// 无人加注时的溜入阈值。
  final double limpLine;

  /// 价值 3bet（再加注）的 Chen 阈值。
  final double threeBetLine;

  /// 轻 3bet 的频率（0 = 不做）。
  final double lightThreeBet;
  final bool lightThreeBetAnyPosition;

  /// 面对加注的冷跟阈值 = [callBase] - [callByPosition] × 位置系数。
  final double callBase;
  final double callByPosition;

  /// 开池加注的基准大小（bb）。
  final double openSizeBb;

  /// 位置对开火频率的影响程度：1 = 很在意位置（紧凶），
  /// 0 = 完全不在意（松凶在哪个位置都敢压）。
  final double positionSensitivity;

  /// 纯诈唬频率倍率。
  final double bluffScale;

  /// 听牌半诈唬频率倍率。
  final double semiBluffScale;

  /// 强牌加注 / 中等牌薄价值下注的频率倍率。
  final double aggressionScale;

  /// 听牌半诈唬「加注」的频率倍率。
  final double semiBluffRaiseScale;

  /// 诈唬加注（含河牌最后一枪）的频率倍率。
  final double bluffRaiseScale;

  /// 跟注站特性：溜入时不看价格。
  final bool limpsAnyPrice;
}

const _tightProfile = _Profile(
  openBase: 8.6,
  openByPosition: 3.2,
  limpLine: 4.5,
  threeBetLine: 11.5,
  lightThreeBet: 0.12,
  callBase: 9.6,
  callByPosition: 1.6,
  openSizeBb: 3,
  positionSensitivity: 1.0,
  bluffScale: 1.0,
  semiBluffScale: 1.0,
  aggressionScale: 1.0,
  semiBluffRaiseScale: 1.0,
  bluffRaiseScale: 1.0,
);

const _passiveProfile = _Profile(
  openBase: 11.5,
  openByPosition: 2.0,
  limpLine: 1.5,
  threeBetLine: 13.5,
  lightThreeBet: 0.0,
  callBase: 6.0,
  callByPosition: 1.0,
  openSizeBb: 2,
  positionSensitivity: 1.0,
  bluffScale: 0.45,
  semiBluffScale: 0.55,
  aggressionScale: 0.7,
  semiBluffRaiseScale: 0.5,
  bluffRaiseScale: 0.6,
  limpsAnyPrice: true,
);

const _looseAggressiveProfile = _Profile(
  openBase: 8.2,
  openByPosition: 3.0,
  limpLine: 3.0,
  threeBetLine: 10.5,
  lightThreeBet: 0.22,
  lightThreeBetAnyPosition: true,
  callBase: 7.6,
  callByPosition: 1.4,
  openSizeBb: 3,
  positionSensitivity: 0.4,
  bluffScale: 1.6,
  semiBluffScale: 1.25,
  aggressionScale: 1.2,
  semiBluffRaiseScale: 1.3,
  bluffRaiseScale: 1.6,
);

/// AI 的一次决策结果。
class AiDecision {
  const AiDecision(this.type, {this.amountTo});

  final ActionType type;

  /// bet/raise 时「下到」的本街总额；null 表示按引擎最小额度。
  final int? amountTo;

  @override
  String toString() =>
      '${type.label}${amountTo != null ? ' $amountTo' : ''}';
}

/// 跨街诈唬线：让诈唬能像真人一样延续（半诈唬 → 第二枪 → 河牌放弃/再开火）。
///
/// 只要中间没人把这条线打断（我们没选择过牌），下一条街就会以更高
/// 频率继续开火；一旦过牌就说明诈唬放弃，整条线作废。
enum _PlanKind { semiBluff, pureBluff }

class _Plan {
  _Plan(this.street, this.kind);

  final Street street;
  final _PlanKind kind;
}

/// 规则型 AI：翻牌前用 Chen 公式给起手牌打分，翻牌后「读牌 + 读人」。
/// 风格差异全部通过 [_Profile] 参数体现。
///
/// 决策流程：
/// 1. 先读出自己手里是什么（[HandTier] 成牌层级 + 听牌 outs）；
/// 2. 用「受限对手范围」的蒙特卡洛胜率代替「对随机牌」的胜率，
///    再和底池赔率、隐含赔率、位置、下注尺度结合；
/// 3. 听牌主动半诈唬（有弃牌率也保有成牌概率），没成牌就按计划
///    在转牌/河牌决定继续开火还是放弃，而不是无脑跟注到底。
class AiPlayer {
  AiPlayer(this.style, {Random? random}) : _random = random ?? Random() {
    // 同一风格的每个 AI 也有自己的性格，避免所有人打成一模一样。
    _aggression = 0.85 + _random.nextDouble() * 0.3;
    _bluffiness = 0.7 + _random.nextDouble() * 0.6;
    _looseness = 0.9 + _random.nextDouble() * 0.25;
  }

  final AiStyle style;
  final Random _random;

  /// 性格参数：同风格的不同 AI 也会有细微差异。
  late final double _aggression;
  late final double _bluffiness;
  late final double _looseness;

  _Profile get _p => style._profile;

  String? _planHandId;
  _Plan? _plan;

  /// 登记一次诈唬开火：延续上一条街的诈唬线，或开一条新的。
  void _registerFire(Street street, _PlanKind kind) {
    final p = _plan;
    if (p != null && p.kind == kind) return; // 同一条线继续打，保留起始街
    _plan = _Plan(street, kind);
  }

  AiDecision decide(GameEngine game, PlayerState me) {
    final legal = game.legalActions(me);
    final handId = game.lastHand?.id;
    if (handId != _planHandId) {
      _planHandId = handId;
      _plan = null; // 换手牌 = 计划作废
    }
    final spot = _Spot.of(game, me);
    final raw = game.street == Street.preflop
        ? _preflop(game, me, spot)
        : _postflop(game, me, spot);
    return _sanitize(raw, legal, game, me);
  }

  bool _roll(double p) => _random.nextDouble() < p;

  // ---------- 翻牌前：Chen 公式 + 位置 + 前面动作 ----------

  /// Chen 公式打分。大致对应：AA=20，KK=16，AKs≈12，22≈5，72o=0。
  static double preflopScore(List<Card> hole) {
    assert(hole.length == 2);
    final a = hole[0];
    final b = hole[1];
    double cardPoints(Rank r) => switch (r) {
          Rank.ace => 10,
          Rank.king => 8,
          Rank.queen => 7,
          Rank.jack => 6,
          _ => r.value / 2,
        };
    var score = max(cardPoints(a.rank), cardPoints(b.rank));
    if (a.rank == b.rank) {
      score = max(5, score * 2); // 对子翻倍，最低 5
    }
    if (a.suit == b.suit) score += 2;
    // 只有非对子才计算间隔扣分：对子没有 gap，之前会被错误扣掉 5 分，
    // 导致 22~88 这些小对子被当成垃圾牌，永远不会进翻牌买三条。
    if (a.rank != b.rank) {
      final gap = (a.rank.value - b.rank.value).abs() - 1;
      score -= switch (gap) { 0 => 0, 1 => 1, 2 => 2, 3 => 4, _ => 5 };
      // 连张/隔一张的顺子加成（高牌低于 Q 时）。
      if (gap <= 1 && max(a.rank.value, b.rank.value) < Rank.queen.value) {
        score += 1;
      }
    }
    return max(0.0, score);
  }

  AiDecision _preflop(GameEngine game, PlayerState me, _Spot spot) {
    final score = preflopScore(me.holeCards);
    final bb = game.config.bigBlind;
    final toCall = spot.toCall;
    final pos = spot.position; // 0（最差）~1（庄位）
    final raises = spot.preflopRaises; // 前面的加注次数
    final pocketPair =
        me.holeCards[0].rank == me.holeCards[1].rank;
    final shortStack = me.stack <= bb * 20;

    // ---- 无人加注：开池拉升，或便宜溜入看翻牌 ----
    if (raises == 0) {
      final openLine = _p.openBase - _p.openByPosition * pos;
      final openThreshold = openLine * (2 - _looseness);
      if (score >= openThreshold && me.stack > 0) {
        return AiDecision(ActionType.raise,
            amountTo: _openSize(game, bb, spot.limpers));
      }
      if (toCall == 0) return const AiDecision(ActionType.check); // 大盲免费
      // 溜入：位置越好越愿意；跟注站几乎什么牌都便宜跟。
      final cheap = toCall <= bb;
      if (score >= _p.limpLine * _looseness && (cheap || _p.limpsAnyPrice)) {
        return const AiDecision(ActionType.call);
      }
      return const AiDecision(ActionType.fold);
    }

    // ---- 面对 3bet 及以上：只有顶端牌力继续 ----
    if (raises >= 2) {
      if (score >= 12.0 || (shortStack && score >= 11.0)) {
        if (toCall >= me.stack || shortStack) {
          return const AiDecision(ActionType.raise); // 全下
        }
        return AiDecision(ActionType.call);
      }
      return const AiDecision(ActionType.fold);
    }

    // ---- 面对单个开池加注 ----
    final jam = toCall >= me.stack || (shortStack && score >= 11.0);
    if (score >= _p.threeBetLine || (jam && score >= 10.5)) {
      if (jam) return const AiDecision(ActionType.raise);
      final size = spot.inPosition ? 3 : 4;
      return AiDecision(ActionType.raise, amountTo: game.currentBet * size);
    }
    // 轻 3bet（位置 + 阻断牌）：真人也会用 A5s、KQo 这类牌保护范围。
    if (_p.lightThreeBet > 0 &&
        (_p.lightThreeBetAnyPosition || spot.inPosition) &&
        raises == 1 &&
        score >= 8.0 &&
        _roll(_p.lightThreeBet * _bluffiness)) {
      return AiDecision(ActionType.raise, amountTo: game.currentBet * 3);
    }

    // 冷跟：位置越好、越便宜越愿意跟；小对子深筹码可以买三条。
    final callLine = _p.callBase - _p.callByPosition * pos;
    final setMine = pocketPair &&
        toCall <= me.stack / 12 &&
        me.stack > bb * 25 &&
        toCall > 0;
    if ((score >= callLine * (2 - _looseness) && toCall <= me.stack / 2) ||
        setMine) {
      return const AiDecision(ActionType.call);
    }
    // 大盲位便宜的补注：放宽一点点。
    if (toCall <= bb && score >= callLine - 2) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 开池加注到 ~3bb（跟注站 2bb；每多一个溜入者多加 1bb）。
  int _openSize(GameEngine game, int bb, int limpers) =>
      (bb * (_p.openSizeBb + limpers)).round();

  // ---------- 翻牌后：读牌 → 读人 → 下注/跟注/加注 ----------

  AiDecision _postflop(GameEngine game, PlayerState me, _Spot spot) {
    final read = HandReading.of(me.holeCards, game.board);
    final opponents = max(1, spot.opponents);
    // 胜率模拟比较贵，只有真的要拿它做决定时才跑（懒加载）。
    double? cached;
    double equity() => cached ??= Odds.equityVsRange(
          heroHole: me.holeCards,
          board: game.board,
          opponents: opponents,
          inRange: _rangeFilter(game, me, spot),
          trials: _trials(opponents),
          random: _random,
        ).share(opponents);

    if (spot.facingBet) {
      return _facingBet(game, me, spot, read, equity);
    }
    return _checkedTo(game, me, spot, read);
  }

  /// 多人底池少跑几次模拟，保证手机上每次决策都在毫秒级。
  int _trials(int opponents) =>
      opponents >= 5 ? 130 : (opponents >= 3 ? 180 : (opponents == 2 ? 240 : 400));

  /// 对手范围模型：翻前动作定下限，翻后激进程度收紧弱牌比例。
  RangePredicate _rangeFilter(GameEngine game, PlayerState me, _Spot spot) {
    var minChen = switch (spot.preflopRaises) {
      0 => 1.5, // 溜入底池：范围很宽
      1 => 6.0, // 开池加注
      _ => 10.0, // 3bet 及以上
    };
    if (spot.isPreflopAggressor && spot.preflopRaises >= 1) {
      minChen = max(minChen, 5.5); // 对手是跟我们的加注：范围也不会太差
    }
    final street = game.street;
    final tightness = spot.villainTightness;
    return (hole, score) {
      if (preflopScore(hole) < minChen) return 0.0;
      final cat = score.category.rank;
      final keep = switch (cat) {
        >= 5 => 1.0, // 同花以上
        >= 3 => 1.0, // 三条以上
        >= 2 => 0.95, // 两对
        1 => street == Street.flop
            ? 0.75
            : (street == Street.turn ? 0.6 : 0.45),
        _ => street == Street.flop
            ? 0.4
            : (street == Street.turn ? 0.25 : 0.12),
      };
      return (keep * tightness).clamp(0.0, 1.0);
    };
  }

  // ---------- 无人下注：价值 / 半诈唬 / 控池 / 诈唬 ----------

  AiDecision _checkedTo(
      GameEngine game, PlayerState me, _Spot spot, HandReading read) {
    final multiway = spot.opponents >= 2;
    final texture = read.texture;

    // 1) 怪兽牌：偶尔慢打（干面 + 单挑），其余大注收价值。
    if (read.tier == HandTier.monster) {
      if (texture.isDry && !multiway && _roll(0.22)) {
        return const AiDecision(ActionType.check);
      }
      return _bet(game, me, 0.75);
    }
    // 2) 强牌：价值下注，湿面加大尺度保护。
    if (read.tier == HandTier.strong) {
      return _bet(game, me, texture.wetness > 0.55 ? 0.7 : 0.6);
    }
    // 3) 听牌：半诈唬（听牌转诈唬的第一步）。
    //    有弃牌率，被跟注也还有 outs，比纯空气诈唬合理得多。
    if (read.hasDraw && read.tier <= HandTier.medium) {
      if (_roll(_semiBluffChance(read, spot))) {
        _registerFire(game.street, _PlanKind.semiBluff);
        return _bet(game, me, 0.6);
      }
      _plan = null; // 听牌也选择过牌：放弃这条线的诈唬
      return const AiDecision(ActionType.check);
    }
    // 4) 中等牌：单挑时小注拿薄价值/保护，多人时控池过牌。
    if (read.tier == HandTier.medium) {
      final thin = (multiway ? 0.2 : 0.45) *
          _aggression *
          _p.aggressionScale *
          (texture.wetness > 0.6 ? 0.6 : 1.0);
      if (_roll(thin)) return _bet(game, me, 0.45);
      return const AiDecision(ActionType.check);
    }
    // 5) 没牌力：按计划延续诈唬，或找机会开火。
    if (_roll(_bluffChance(game, spot, read))) {
      _registerFire(game.street, _PlanKind.pureBluff);
      return _bet(game, me, game.street == Street.river ? 0.7 : 0.55);
    }
    _plan = null; // 过牌 = 放弃这条诈唬线
    return const AiDecision(ActionType.check);
  }

  /// 位置调整：紧凶很在意位置，松凶在哪个位置都敢压。
  double _positionFactor(_Spot spot, double inPos, double outPos) {
    final base = spot.inPosition ? inPos : outPos;
    return 1 + (base - 1) * _p.positionSensitivity;
  }

  /// 半诈唬频率：听牌越强、位置越好、人越少越敢打。
  double _semiBluffChance(HandReading read, _Spot spot) {
    var base = switch (read.drawOuts) {
      >= 12 => 0.72, // 花顺双听
      >= 8 => 0.55, // 花听 / 两头顺
      >= 4 => 0.26, // 卡顺
      _ => 0.0,
    };
    if (read.nutFlushDraw) base += 0.06;
    base *= _p.semiBluffScale;
    base *= _bluffiness;
    base *= _positionFactor(spot, 1.15, 0.85);
    if (spot.opponents >= 3) {
      base *= 0.3; // 多人底池弃牌率低
    } else if (spot.opponents == 2) {
      base *= 0.6;
    }
    return base.clamp(0.02, 0.9);
  }

  /// 纯诈唬频率：位置、人数、牌面、对手牌线、是否延续计划。
  double _bluffChance(GameEngine game, _Spot spot, HandReading read) {
    final river = game.street == Street.river;
    var base = (river ? 0.22 : 0.36) * _p.bluffScale;
    base *= _bluffiness;
    // 有摊牌价值（弱成牌）别乱开火；中等牌更不该演空气。
    if (read.tier == HandTier.weak) base *= 0.35;
    if (read.tier >= HandTier.medium) base *= 0.1;
    base *= _positionFactor(spot, 1.2, 0.85);
    if (spot.opponents >= 3) {
      base *= 0.35;
    } else if (spot.opponents == 2) {
      base *= 0.65;
    }
    // 翻前加注者的持续下注：翻牌圈频率更高（这也是真人的 c-bet），
    // 干燥牌面更容易打走对手，频率再往上提。
    if (game.street == Street.flop && spot.isPreflopAggressor) {
      base *= read.texture.isDry ? 2.0 : 1.4;
    }
    // 诈唬线延续：前一条街已经开过火，河牌没成牌也要能再开一枪。
    final plan = _plan;
    if (plan != null && game.street.index > plan.street.index) {
      base *= plan.kind == _PlanKind.semiBluff ? 2.0 : 1.4;
    }
    if (spot.checkedThrough) base *= 1.3; // 前一条街都过牌，牌面更可能没人要
    base *= 1 - 0.4 * spot.villainStrength;
    return base.clamp(0.0, 0.8);
  }

  // ---------- 面对下注：加注 / 按赔率跟注 / 放弃 ----------

  AiDecision _facingBet(GameEngine game, PlayerState me, _Spot spot,
      HandReading read, double Function() equity) {
    final potOdds = Odds.potOdds(pot: spot.pot, toCall: spot.toCall);
    final bigBet = spot.betSizeRel >= 0.7;
    final smallBet = spot.betSizeRel <= 0.35;
    final canRaise = spot.canRaise && spot.toCall < me.stack;

    // 1) 怪兽牌：价值加注；加注战里已经打太多就转为跟注。
    if (read.tier == HandTier.monster) {
      if (!canRaise || spot.raisesThisStreet >= 3) {
        return const AiDecision(ActionType.call);
      }
      return _raise(game, me, 0.85);
    }
    // 2) 强牌：加注频率随街道递减（真人不会拿顶对在河牌乱加），
    //    面对大注/强线时以控池跟注为主，湿面偶尔也要懂得放手。
    if (read.tier == HandTier.strong) {
      if (bigBet || spot.villainStrength > 0.8) {
        if (bigBet &&
            spot.villainStrength > 0.85 &&
            read.texture.wetness > 0.6 &&
            _roll(0.25)) {
          return const AiDecision(ActionType.fold);
        }
        return const AiDecision(ActionType.call);
      }
      final base = switch (game.street) {
        Street.flop => 0.55,
        Street.turn => 0.35,
        _ => 0.18,
      };
      if (canRaise &&
          spot.raisesThisStreet <= 1 &&
          _roll(base *
              _aggression *
              _p.aggressionScale *
              (read.texture.wetness > 0.6 ? 0.8 : 1.0))) {
        return _raise(game, me, 0.8);
      }
      return const AiDecision(ActionType.call);
    }
    // 3) 听牌：半诈唬加注 or 按（隐含）赔率跟注 or 放弃。
    if (read.hasDraw) {
      if (canRaise && _roll(_semiBluffRaiseChance(read, spot))) {
        _registerFire(game.street, _PlanKind.semiBluff);
        return _raise(game, me, 0.75);
      }
      return _drawCallOrFold(game, me, spot, read, potOdds);
    }
    // 4) 中等牌：按赔率跟注，面对大注/强线弃牌；小注时偶尔反击。
    if (read.tier == HandTier.medium) {
      var need = potOdds * (spot.villainStrength > 0.7 ? 1.3 : 1.1);
      if (bigBet) need *= 1.2;
      final scary = bigBet &&
          spot.villainStrength > 0.8 &&
          read.texture.wetness > 0.6;
      if (equity() >= need && !scary) return const AiDecision(ActionType.call);
      if (canRaise &&
          smallBet &&
          spot.opponents == 1 &&
          _roll(0.15 * _aggression * _p.aggressionScale)) {
        return _raise(game, me, 0.7); // 对手像是在打阻挡注
      }
      return const AiDecision(ActionType.fold);
    }
    // 5) 弱牌/空气：弃牌为主，极少数情况诈唬加注。
    if (canRaise && _roll(_bluffRaiseChance(game, spot, read))) {
      _registerFire(game.street, _PlanKind.pureBluff);
      return _raise(game, me, 0.8);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 听牌面对下注：跟注要跟得上「隐含赔率」，跟不动就弃。
  AiDecision _drawCallOrFold(GameEngine game, PlayerState me, _Spot spot,
      HandReading read, double potOdds) {
    if (spot.toCall <= 0) return const AiDecision(ActionType.check);
    // 河牌听牌已死：不再跟注买牌，改为小频率诈唬（有阻断牌时更合理）。
    if (game.street == Street.river) {
      if (spot.canRaise && _roll(_bluffRaiseChance(game, spot, read))) {
        _registerFire(game.street, _PlanKind.pureBluff);
        return _raise(game, me, 0.75);
      }
      return const AiDecision(ActionType.fold);
    }
    final streets = game.street == Street.flop ? 2 : 1;
    final deep = me.stack > spot.pot * 1.5;
    // 隐含赔率：坚果花听/组合听牌成牌后还能再赢一笔。
    final implied = (read.nutFlushDraw || read.isComboDraw) ? 0.07 : 0.035;
    final drawEq = read.drawEquity(streets) + (deep ? implied : 0);
    var need = potOdds * (spot.villainStrength > 0.75 ? 1.25 : 1.05);
    if (spot.betSizeRel >= 0.7) need *= 1.1;
    if (drawEq >= need) return const AiDecision(ActionType.call);
    // 便宜的小注：弱听牌也可以跟一张看转牌。
    if (spot.betSizeRel <= 0.3 &&
        read.drawOuts >= 4 &&
        drawEq >= need * 0.75) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 听牌加注（半诈唬加注）的频率。
  double _semiBluffRaiseChance(HandReading read, _Spot spot) {
    if (!spot.inPosition && spot.opponents > 1) return 0.03;
    var base = read.isComboDraw
        ? 0.35
        : (read.drawOuts >= 8 ? 0.22 : 0.08);
    base *= _p.semiBluffRaiseScale;
    base *= _bluffiness * _aggression;
    if (spot.opponents >= 2) base *= 0.4;
    if (spot.betSizeRel >= 0.8) base *= 0.4; // 大注不硬凑
    return base.clamp(0.0, 0.5);
  }

  /// 诈唬加注（含河牌未成牌的最后一枪）的频率。
  double _bluffRaiseChance(GameEngine game, _Spot spot, HandReading read) {
    if (spot.opponents > 1) return 0.0;
    var base = (game.street == Street.river ? 0.06 : 0.05) *
        _p.bluffRaiseScale;
    base *= _bluffiness;
    if (spot.betSizeRel <= 0.35) base *= 2.0; // 对手小注 = 牌力偏弱
    if (spot.betSizeRel >= 0.75) base *= 0.35; // 大注通常是真牌，别硬顶
    if (spot.villainStrength > 0.7) base *= 0.4;
    if (spot.inPosition) base *= 1.3;
    if (read.hasAceBlocker) base *= 1.2;
    return base.clamp(0.0, 0.2);
  }

  // ---------- 下注/加注额度 ----------

  /// 下注到本街总额：底池的 [frac]。
  AiDecision _bet(GameEngine game, PlayerState me, double frac) {
    final pot = game.potTotal();
    final add = max(game.config.bigBlind, (pot * frac).round());
    return AiDecision(ActionType.bet, amountTo: me.streetBet + add);
  }

  /// 加注到本街总额：在当前最高注上再加一个底池比例（至少补足最小加注）。
  AiDecision _raise(GameEngine game, PlayerState me, double frac) {
    final pot = game.potTotal();
    final minRaise = game.minRaiseTo - game.currentBet;
    final add = max(minRaise, (pot * frac).round());
    return AiDecision(ActionType.raise, amountTo: game.currentBet + add);
  }

  // ---------- 合法化 ----------

  /// 把「理想决策」收敛到引擎允许的合法动作上，防止越界额度。
  AiDecision _sanitize(
      AiDecision d, List<LegalAction> legal, GameEngine game, PlayerState me) {
    bool has(ActionType t) => legal.any((a) => a.type == t);
    LegalAction find(ActionType t) => legal.firstWhere((a) => a.type == t);
    AiDecision fallback() {
      if (has(ActionType.check)) return const AiDecision(ActionType.check);
      if (has(ActionType.call)) return const AiDecision(ActionType.call);
      return const AiDecision(ActionType.fold);
    }

    switch (d.type) {
      case ActionType.bet:
      case ActionType.raise:
        // 「下注」和「加注」在引擎里按当前下注状态互斥，自动换类型。
        var type = d.type;
        if (!has(type)) {
          type = type == ActionType.bet ? ActionType.raise : ActionType.bet;
        }
        if (!has(type)) return fallback();
        final a = find(type);
        final to = (d.amountTo ?? a.minAmount).clamp(a.minAmount, a.maxAmount);
        return AiDecision(type, amountTo: to);
      case ActionType.call:
        return has(ActionType.call) ? d : fallback();
      case ActionType.check:
        return has(ActionType.check) ? d : fallback();
      case ActionType.fold:
        return d;
    }
  }
}

/// 单次决策的桌面快照：位置、底池、对手的动作线。
class _Spot {
  _Spot({
    required this.toCall,
    required this.pot,
    required this.opponents,
    required this.position,
    required this.inPosition,
    required this.facingBet,
    required this.isPreflopAggressor,
    required this.checkedThrough,
    required this.betSizeRel,
    required this.raisesThisStreet,
    required this.preflopRaises,
    required this.limpers,
    required this.villainStrength,
    required this.villainTightness,
    required this.canRaise,
  });

  final int toCall;
  final int pot;
  final int opponents;

  /// 位置系数：0（最差）~1（庄位）。
  final double position;
  final bool inPosition;
  final bool facingBet;
  final bool isPreflopAggressor;
  final bool checkedThrough;

  /// 对手本街下注额 / 下注前底池，用来读下注尺度。
  final double betSizeRel;
  final int raisesThisStreet;
  final int preflopRaises;
  final int limpers;

  /// 对手这条线的强度（0~1）与由此推出的范围紧凑度。
  final double villainStrength;
  final double villainTightness;
  final bool canRaise;

  static _Spot of(GameEngine game, PlayerState me) {
    final bb = game.config.bigBlind;
    final n = game.players.length;
    final pot = game.potTotal();
    final toCall = game.currentBet - me.streetBet;
    final actions = game.lastHand?.actions ?? const <ActionRecord>[];

    var preflopRaises = 0;
    var limpers = 0;
    String? lastPreflopRaiser;
    for (final a in actions) {
      if (a.street != Street.preflop) continue;
      if (a.type == ActionType.raise) {
        preflopRaises++;
        lastPreflopRaiser = a.actorId;
      } else if (a.type == ActionType.call) {
        limpers++;
      }
    }
    final isPreflopAggressor = lastPreflopRaiser == me.id;

    var raisesThisStreet = 0;
    var villainAgg = 0;
    for (final a in actions) {
      if (a.street != game.street) continue;
      final aggressive = a.type == ActionType.raise ||
          (a.type == ActionType.bet && game.street != Street.preflop);
      if (!aggressive) continue;
      raisesThisStreet++;
      if (a.actorId != me.id) villainAgg++;
    }

    // 位置：按座位顺序算，庄位最好，盲注位压到最低。
    final meIdx = game.players.indexOf(me);
    final rel = (meIdx - game.buttonIndex + n) % n;
    double position;
    if (n <= 2) {
      position = rel == 0 ? 1.0 : 0.5;
    } else {
      position = 0.25 + 0.75 * (((rel - 1 + n) % n) / (n - 1));
    }
    var inPosition = true;
    for (var d = 1; d < n; d++) {
      final other = game.players[(meIdx + d) % n];
      if (other.id == me.id || other.folded) continue;
      inPosition = false;
      break;
    }

    // 前一条街是否全部过牌（没人下注）——转牌/河牌判断对手牌线时用。
    var checkedThrough = false;
    if (game.street == Street.turn || game.street == Street.river) {
      final prev = game.street == Street.turn ? Street.flop : Street.turn;
      checkedThrough = !actions.any((a) =>
          a.street == prev &&
          (a.type == ActionType.raise || a.type == ActionType.bet));
    }

    final betSizeRel =
        toCall > 0 ? toCall / max(bb, pot - toCall) : 0.0;

    var vs = switch (preflopRaises) {
      0 => 0.25,
      1 => 0.5,
      _ => 0.85,
    };
    if (isPreflopAggressor && preflopRaises >= 1) vs -= 0.1;
    vs += 0.12 * villainAgg;
    if (betSizeRel >= 0.9) vs += 0.1;
    final villainStrength = vs.clamp(0.1, 1.0);

    return _Spot(
      toCall: toCall,
      pot: pot,
      opponents: game.active.length - 1,
      position: position.clamp(0.0, 1.0),
      inPosition: inPosition,
      facingBet: toCall > 0,
      isPreflopAggressor: isPreflopAggressor,
      checkedThrough: checkedThrough,
      betSizeRel: betSizeRel,
      raisesThisStreet: raisesThisStreet,
      preflopRaises: preflopRaises,
      limpers: limpers,
      villainStrength: villainStrength,
      villainTightness: (0.55 + 0.45 * villainStrength).clamp(0.5, 1.0),
      canRaise: me.stack > toCall,
    );
  }
}
