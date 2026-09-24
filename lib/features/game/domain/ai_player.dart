import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/game.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../../trainer/odds.dart';
import 'hand_strength.dart';
import 'preflop_ranges.dart';

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
    required this.openShift,
    required this.limpShift,
    required this.defendShift,
    required this.threeBetShift,
    required this.lightThreeBet,
    required this.openSizeBb,
    required this.positionSensitivity,
    required this.bluffScale,
    required this.semiBluffScale,
    required this.aggressionScale,
    required this.semiBluffRaiseScale,
    required this.bluffRaiseScale,
    this.lightThreeBetAnyPosition = false,
    this.limpsAnyPrice = false,
    this.wideLimp = false,
  });

  /// 开池范围的整体偏移（正 = 比标准范围更紧，负 = 更松）。
  ///
  /// 标准范围来自 [PreflopRanges.open]（按位置分档），这里只做风格微调，
  /// 所以「前位紧、后位松」这个骨架是共用的。
  final int openShift;

  /// 溜入 / 补齐范围的偏移。
  final int limpShift;

  /// 面对加注时冷跟范围的偏移。
  final int defendShift;

  /// 价值再加注范围的偏移。
  final int threeBetShift;

  /// 轻 3bet 的频率（0 = 不做）。
  final double lightThreeBet;
  final bool lightThreeBetAnyPosition;

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

  /// 跟注站特性：溜入范围放宽到「非同花杂牌也跟」。
  final bool wideLimp;
}

const _tightProfile = _Profile(
  openShift: 0,
  limpShift: 1,
  defendShift: 0,
  threeBetShift: 0,
  lightThreeBet: 0.12,
  openSizeBb: 3,
  positionSensitivity: 1.0,
  bluffScale: 1.0,
  semiBluffScale: 1.0,
  aggressionScale: 1.0,
  semiBluffRaiseScale: 1.0,
  bluffRaiseScale: 1.0,
);

const _passiveProfile = _Profile(
  openShift: 5,
  limpShift: 0,
  defendShift: -3,
  threeBetShift: 3,
  lightThreeBet: 0.0,
  openSizeBb: 2,
  positionSensitivity: 1.0,
  bluffScale: 0.45,
  semiBluffScale: 0.55,
  aggressionScale: 0.7,
  semiBluffRaiseScale: 0.5,
  bluffRaiseScale: 0.6,
  limpsAnyPrice: true,
  wideLimp: true,
);

const _looseAggressiveProfile = _Profile(
  openShift: -2,
  limpShift: 2,
  defendShift: -2,
  threeBetShift: -1,
  lightThreeBet: 0.22,
  lightThreeBetAnyPosition: true,
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

/// 对某个对手的观察记录：只统计「公开信息」（翻后的下注/跟注/弃牌），
/// 每桌每个 AI 各存一份，跨手牌累积，用来做针对性的剥削调整。
class _VillainRead {
  int seen = 0; // 翻后面对下注的次数
  int folded = 0;
  int called = 0;
  int raised = 0;
  int hands = 0; // 一起打完的手牌数

  /// 翻后面对下注的弃牌率；样本太少时退回中性先验 0.45。
  double get foldToBet => seen < 4 ? 0.45 : folded / seen;

  /// 是不是「跟注站」：面对下注几乎不弃牌，还很少加注。
  bool get station => seen >= 6 && foldToBet <= 0.28 && raised <= seen * 0.15;

  /// 是不是「一压就跑」：面对下注弃得特别多。
  bool get folder => seen >= 6 && foldToBet >= 0.6;
}

/// 规则型 AI：翻牌前查「位置感知的范围表」（[PreflopRanges]），
/// 翻牌后「读牌 + 读人」。风格差异全部通过 [_Profile] 参数体现。
///
/// 决策流程：
/// 1. 翻前按座位（前位/中位/劫位/按钮/小盲/大盲）取开池、溜入、防守、
///    再加注的范围，风格只做整体松紧偏移；
/// 2. 翻后先读出自己手里是什么（[HandTier] 成牌层级 + 听牌 outs）；
/// 3. 用「受限对手范围」的蒙特卡洛胜率代替「对随机牌」的胜率
///    （对手范围同样按他翻前的位置与动作来收紧），
///    再和底池赔率、隐含赔率、位置、下注尺度结合；
/// 4. 听牌主动半诈唬（有弃牌率也保有成牌概率），没成牌就按计划
///    在转牌/河牌决定继续开火还是放弃，而不是无脑跟注到底；
/// 5. 全程「读人」：把每个对手翻后面对下注的弃牌/跟注/加注记进档案
///    （[_VillainRead]），遇到一压就跑的对手多诈唬，遇到跟注站就
///    少诈唬、下大注收价值——这才是真人最像人的那部分；
/// 6. 诈唬也会「选牌」：只挑挡掉对手强牌的那几张去开火
///    （[HandReading.blockerScore]：坚果花阻断 / 补顺的牌 / A 阻断），
///    拿什么都没挡到的牌就老实过牌——真人和按钮精灵最大的区别就在这。
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

  /// 对每个对手的观察（key = 玩家 id）。跨手牌累积，不重置。
  final Map<String, _VillainRead> _reads = {};

  List<ActionRecord>? _scanList; // 正在统计的那一手动作表（引擎会持续追加）
  int _readCursor = 0; // 已经统计到的位置
  final Map<Street, bool> _streetAggro = {};

  /// 把「公开动作」扫进对手档案：翻后谁面对下注弃了、跟了、加了。
  /// 只看动作，不看底牌——真人也是这么读人的。
  ///
  /// 注意：对手弃牌结束一手时，我们不会再有决策机会，那一手剩下的动作
  /// 靠 [_scanList] 记住的动作表在下一次决策时补扫，不然「一压就跑」
  /// 的对手永远攒不够样本。
  void _observe(GameEngine game, PlayerState me) {
    final hand = game.lastHand;
    if (hand == null) return;
    if (!identical(hand.actions, _scanList)) {
      final prev = _scanList;
      if (prev != null) _ingest(prev, me);
      _scanList = hand.actions;
      _readCursor = 0;
      _streetAggro.clear();
      for (final r in _reads.values) {
        r.hands++;
      }
    }
    _ingest(hand.actions, me);
  }

  void _ingest(List<ActionRecord> actions, PlayerState me) {
    if (actions.length <= _readCursor) return;
    final batch = actions.sublist(_readCursor);
    _readCursor = actions.length;
    for (final a in batch) {
      // 「是否面对下注」由这条街上谁先开的火决定——包括我们自己下的注。
      final facedBet = _streetAggro[a.street] ?? false;
      if (a.type == ActionType.bet || a.type == ActionType.raise) {
        _streetAggro[a.street] = true;
      }
      if (a.actorId == me.id) continue;
      if (a.street == Street.preflop) continue; // 翻前范围另有位置表
      final r = _reads.putIfAbsent(a.actorId, _VillainRead.new);
      switch (a.type) {
        case ActionType.fold:
          if (facedBet) {
            r.seen++;
            r.folded++;
          }
        case ActionType.call:
          if (facedBet) {
            r.seen++;
            r.called++;
          }
        case ActionType.raise:
          r.raised++;
          if (facedBet) r.seen++;
        case ActionType.bet:
        case ActionType.check:
          break;
      }
    }
  }

  /// 对某个对手的观察摘要：一起打过多少手、翻后面对下注弃了几次、
  /// 弃牌率是多少。供调试与「教练界面」显示用，不参与决策。
  ({int hands, int seen, double foldToBet})? readOf(String playerId) {
    final r = _reads[playerId];
    if (r == null) return null;
    return (hands: r.hands, seen: r.seen, foldToBet: r.foldToBet);
  }

  /// 当前底池里还在的对手（能弃牌的、能跟注的）。
  List<_VillainRead> _readsOf(GameEngine game, PlayerState me) => [
        for (final p in game.active)
          if (p.id != me.id) _reads[p.id],
      ].whereType<_VillainRead>().toList();

  /// 剥削因子：对手翻后爱弃牌就多诈唬，是跟注站就别装了。
  double _exploitBluffFactor(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    if (reads.isEmpty) return 1.0;
    var sum = 0.0;
    for (final r in reads) {
      sum += r.station
          ? 0.45
          : (r.folder ? 1.45 : 0.55 + 0.9 * r.foldToBet);
    }
    return (sum / reads.length).clamp(0.35, 1.6);
  }

  /// 价值因子：对手爱跟注（跟注站）就打得更大、更粘。
  double _exploitValueFactor(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    if (reads.isEmpty) return 1.0;
    var sum = 0.0;
    for (final r in reads) {
      sum += r.station ? 1.25 : (r.folder ? 0.9 : 1.0 + 0.3 * (0.45 - r.foldToBet));
    }
    return (sum / reads.length).clamp(0.85, 1.3);
  }

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
    _observe(game, me); // 顺手把对手的动作记进档案
    final spot = _Spot.of(game, me);
    final raw = game.street == Street.preflop
        ? _preflop(game, me, spot)
        : _postflop(game, me, spot);
    return _sanitize(raw, legal, game, me);
  }

  bool _roll(double p) => _random.nextDouble() < p;

  // ---------- 翻牌前：位置范围 + 前面动作 ----------

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

  /// 位置感知的翻前决策：开池 / 溜入 / 3bet / 防守全部查 [PreflopRanges]，
  /// 风格只在标准范围上做整体偏移。这样「前位紧、后位松、大盲防守最宽、
  /// 盲注位不轻易平跟」这些真人的骨架是三种风格共用的。
  AiDecision _preflop(GameEngine game, PlayerState me, _Spot spot) {
    final hand = PreflopHand.of(me.holeCards);
    final seat = spot.seat;
    final bb = game.config.bigBlind;
    final toCall = spot.toCall;
    final raises = spot.preflopRaises;
    final shortStack = me.stack <= bb * 20;
    final stackBb = me.stack / bb;
    final score = preflopScore(me.holeCards);
    // 性格带来的整体松紧（-1 / 0 / +1），让同风格的 AI 也不完全一样。
    final w = ((1.0 - _looseness) * 5).round();

    // ---- 无人加注：开池拉升，或便宜溜入看翻牌 ----
    if (raises == 0) {
      var openRange = PreflopRanges.open(seat).shifted(_p.openShift + w);
      // 前面已经有人溜入：非同花牌容易被后面压制，收紧一点。
      if (spot.limpers > 0) {
        openRange = openRange.shiftedOffsuit(spot.limpers >= 2 ? 2 : 1);
      }
      final openable = openRange.contains(hand);
      if (toCall == 0) {
        // 大盲免费看牌：前面有人溜入时用「隔离范围」加注（溜入者范围
        // 又宽又弱，拿强牌就该把他们打散、把底池做大），否则过牌。
        if (spot.limpers > 0) {
          final iso = PreflopRanges.isolateLimpers.shifted(_p.openShift + w);
          if (iso.contains(hand)) {
            return AiDecision(ActionType.raise,
                amountTo: _openSize(game, bb, spot.limpers, seat));
          }
        }
        return const AiDecision(ActionType.check);
      }
      if (openable && me.stack > 0) {
        return AiDecision(ActionType.raise,
            amountTo: _openSize(game, bb, spot.limpers, seat));
      }
      // 溜入 / 补齐：位置越好、价格越便宜越愿意；跟注站几乎什么都跟。
      final cheap = toCall <= bb;
      final limpBase = _p.wideLimp
          ? PreflopRanges.limpLoose(seat)
          : PreflopRanges.limp(seat);
      final limpRange = limpBase.shifted(_p.limpShift + w);
      if (limpRange.contains(hand) && (cheap || _p.limpsAnyPrice)) {
        return const AiDecision(ActionType.call);
      }
      return const AiDecision(ActionType.fold);
    }

    final raiserSeat = spot.raiserSeat ?? Seat.btn;

    // ---- 面对 3bet 及以上：只打顶端，深筹码+有位置才用跟注范围 ----
    if (raises >= 2) {
      final fourBet = PreflopRanges.valueFourBet.shifted(_p.threeBetShift + w);
      if (fourBet.contains(hand)) {
        if (toCall >= me.stack || shortStack) {
          return const AiDecision(ActionType.raise); // 全下
        }
        return const AiDecision(ActionType.call);
      }
      final deepCall = !shortStack &&
          stackBb >= 80 &&
          spot.inPosition &&
          toCall <= me.stack / 3 &&
          PreflopRanges.callThreeBet.shifted(w).contains(hand);
      if (deepCall) return const AiDecision(ActionType.call);
      return const AiDecision(ActionType.fold);
    }

    // ---- 面对单个开池加注 ----
    final defense = PreflopRanges.versusOpen(
      seat: seat,
      hand: hand,
      raiser: raiserSeat,
      inPosition: spot.inPosition,
      // 已经进池的人（溜入者 + 冷跟者）越多，我们的冷跟范围就要越紧。
      callers: spot.limpers,
      raiseBb: game.currentBet / bb,
      stackBb: stackBb,
      threeBetWidth: _p.threeBetShift + w,
      callWidth: _p.defendShift + w,
    );

    // 价值 3bet：没位置就加得重一点，压掉对手的跟注赔率。
    if (defense.valueThreeBet) {
      if (toCall >= me.stack) return const AiDecision(ActionType.raise);
      return AiDecision(ActionType.raise, amountTo: _threeBetSize(game, spot));
    }
    // 轻 3bet（A5s、KQo 这类有阻断牌/成牌潜力的牌）：针对后位偷盲，
    // 既保护自己的范围，也让对手不敢随便开池。范围表给出「能不能打」，
    // 频率由风格（松凶打得最凶）+ 性格决定。
    if (_p.lightThreeBet > 0 && _roll(_p.lightThreeBet * _bluffiness)) {
      final lateOpen = raiserSeat == Seat.co ||
          raiserSeat == Seat.btn ||
          raiserSeat == Seat.sb;
      // 松凶在哪个位置都敢压，别的风格只在有位置（或盲注位）时才打。
      final mayLight = defense.lightThreeBet ||
          (_p.lightThreeBetAnyPosition &&
              lateOpen &&
              PreflopRanges.isLightThreeBetHand(hand));
      if (mayLight) {
        return AiDecision(ActionType.raise, amountTo: game.currentBet * 3);
      }
    }
    // 短筹码：与其翻后打小球，不如直接推进去（弃牌率 + 摊牌胜率）。
    if (shortStack && toCall < me.stack && score >= 10.0) {
      return const AiDecision(ActionType.raise);
    }
    // 冷跟防守：位置、加注规模、筹码深度全部由范围表决定。
    if (defense.call && toCall <= me.stack / 2) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 开池加注的尺度：位置好可以开小一点（省筹码、还能拿下盲注），
  /// 前位开大一点；每多一个溜入者多加 1bb（隔离他们，也把底池做大）。
  int _openSize(GameEngine game, int bb, int limpers, Seat seat) =>
      (bb * (_p.openSizeBb * PreflopRanges.openSizeFactor(seat) + limpers))
          .round();

  /// 3bet / 挤压尺度：有位置约 3 倍开池、没位置 4 倍（没位置要加得
  /// 更多才能压掉对手的跟注赔率），每个已经进池的人再多加 1bb
  /// （挤压时不能让跟注者用便宜价格跟进来），但不低于 3 倍当前注。
  int _threeBetSize(GameEngine game, _Spot spot) {
    final potBased = game.currentBet * (spot.inPosition ? 3 : 4);
    final floor = game.currentBet * 3;
    final callers = game.config.bigBlind * spot.limpers;
    return max(max(potBased, floor) + callers, floor);
  }

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

  /// 对手范围模型：先用「位置感知的翻前范围」筛掉对手大概率没有的牌，
  /// 再按对手翻后的激进程度收紧弱牌比例。
  RangePredicate _rangeFilter(GameEngine game, PlayerState me, _Spot spot) {
    final raiserSeat = spot.raiserSeat ?? Seat.co;
    final street = game.street;
    final tightness = spot.villainTightness;

    /// 这手底牌出现在对手翻前范围里的权重（0~1）。
    double preflopWeight(List<Card> hole) {
      final h = PreflopHand.of(hole);
      if (spot.preflopRaises >= 2) {
        // 3bet 底池：要么是再加注的顶端牌力，要么是跟注 3bet 的投机牌。
        if (PreflopRanges.valueThreeBet(raiserSeat).contains(h)) return 1.0;
        return PreflopRanges.callThreeBet.contains(h) ? 0.3 : 0.06;
      }
      if (spot.preflopRaises == 1) {
        // 对手是主动开池的人 → 用开池范围；对手是跟注的人 → 用冷跟范围。
        final range = spot.isPreflopAggressor
            ? PreflopRanges.coldCallRange(seat: Seat.bb, inPosition: true)
            : PreflopRanges.open(raiserSeat);
        if (range.contains(h)) return 1.0;
        // 范围内侧一点点的牌（轻 3bet / 便宜跟注）还留一点点可能。
        return PreflopRanges.isLightThreeBetHand(h) ? 0.25 : 0.06;
      }
      return 0.65; // 溜入底池：范围宽得像个谜，但不是随机牌
    }

    return (hole, score) {
      final pre = preflopWeight(hole);
      if (pre <= 0.0) return 0.0;
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
      return (pre * keep * tightness).clamp(0.0, 1.0);
    };
  }

  // ---------- 无人下注：价值 / 半诈唬 / 控池 / 诈唬 ----------

  AiDecision _checkedTo(
      GameEngine game, PlayerState me, _Spot spot, HandReading read) {
    final multiway = spot.opponents >= 2;
    final texture = read.texture;

    // 读人：对手是跟注站就少诈唬、多打价值；一压就跑就多开火。
    final valueFactor = _exploitValueFactor(game, me);
    // 第二枪选牌：转牌/河牌这张新牌是不是适合继续开火。
    final barrel = _barrelFactor(game, read);
    final river = game.street == Street.river;

    // 0) 底池已经很大（SPR 很低）：强牌不用再分批下注，直接推进去。
    if (spot.spr <= 2.5 && read.tier == HandTier.monster) {
      return _jam(me);
    }
    if (spot.spr <= 1.5 && read.tier == HandTier.strong) {
      return _jam(me);
    }
    // 1) 怪兽牌：偶尔慢打（干面 + 单挑 + 不是河牌），其余大注收价值。
    if (read.tier == HandTier.monster) {
      if (!river && texture.isDry && !multiway && _roll(0.22)) {
        return const AiDecision(ActionType.check);
      }
      // 河牌是最后一次收价值的机会：对手肯付钱就用超池（1.2 倍底池），
      // 对一压就跑的对手不超池——小注换来跟注更划算。
      if (river && !multiway && !_villainFoldsALot(game, me) && _roll(0.5)) {
        return _bet(game, me, (1.2 * valueFactor).clamp(0.8, 1.5));
      }
      final frac =
          _valueFrac(spot, texture.wetness > 0.55 ? 0.7 : 0.6) * valueFactor;
      return _bet(game, me, frac.clamp(0.3, 1.1));
    }
    // 2) 强牌：价值下注，湿面加大尺度保护；3bet 底池用小注（范围都很强，
    //    下注是为了把筹码慢慢放进去，不是为了把人打跑）。
    //    对跟注站下得更大（他会付钱），对爱弃牌的人下小一点。
    //    没位置时有一部分要过牌：真人靠这些过牌保护自己的过牌范围，
    //    也让对手不敢随便在后面偷池——这些牌会在面对下注时转成过牌-加注。
    //    只在翻牌圈这么打：真人不会拿顶对连过两条街，把价值全漏掉。
    if (read.tier == HandTier.strong &&
        game.street == Street.flop &&
        !spot.inPosition &&
        !multiway &&
        _roll(texture.isDry ? 0.3 : 0.18)) {
      return const AiDecision(ActionType.check);
    }
    if (read.tier == HandTier.strong) {
      final frac =
          _valueFrac(spot, texture.wetness > 0.55 ? 0.7 : 0.6) * valueFactor;
      return _bet(game, me, frac.clamp(0.3, 1.1));
    }
    // 3) 听牌：半诈唬（听牌转诈唬的第一步）。
    //    有弃牌率，被跟注也还有 outs，比纯空气诈唬合理得多。
    if (read.hasDraw && read.tier <= HandTier.medium) {
      if (_roll(_semiBluffChance(read, spot, barrel))) {
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
          (texture.wetness > 0.6 ? 0.6 : 1.0) *
          valueFactor;
      if (_roll(thin)) return _bet(game, me, 0.45 * valueFactor);
      return const AiDecision(ActionType.check);
    }
    // 5) 没牌力：按计划延续诈唬，或找机会开火。
    if (_roll(_bluffChance(game, me, spot, read))) {
      _registerFire(game.street, _PlanKind.pureBluff);
      // 河牌拿着阻断牌（A / 坚果花阻断）时用超池诈唬：对手的强牌被
      // 我们的阻断牌挡掉，超池更容易逼他弃牌。
      // 坚果花阻断，或者 A 阻断 + 牌面三张同花：这两个是真人最爱的
      // 超池诈唬牌——对手的强牌被挡住，超池逼他弃牌最划算。
      final nutBluff = read.nutFlushBlocker ||
          (read.hasAceBlocker && read.texture.maxSuitCount >= 3);
      if (river && !multiway && nutBluff && _roll(0.35)) {
        return _bet(game, me, 1.25);
      }
      // 阻断牌够硬就用偏重的尺度：弃牌率换来的收益比小注更高。
      if (river && read.blockerScore >= 0.5 && _roll(0.4)) {
        return _bet(game, me, 0.9);
      }
      return _bet(game, me, river ? 0.7 : 0.55);
    }
    _plan = null; // 过牌 = 放弃这条诈唬线
    return const AiDecision(ActionType.check);
  }

  /// 第二枪 / 第三枪的选牌：新发出来的这张牌对谁更有利？
  ///
  /// - 空白牌（比前面任何牌都小）几乎没帮到跟注方 → 继续开火收益高；
  /// - 高张（尤其 A/K）更容易打中跟注方的范围 → 收手；
  /// - 公对面、第三张同花、顺子面 → 对手成牌的可能性变大，别硬开；
  /// - 自己这条街变强了（多了听牌或成了牌）→ 有底气接着打。
  double _barrelFactor(GameEngine game, HandReading read) {
    if (game.street != Street.turn && game.street != Street.river) return 1.0;
    final board = game.board;
    if (board.length < 4) return 1.0;
    final prev = board.sublist(0, board.length - 1);
    final card = board.last;
    final prevMax = prev.map((c) => c.rank.value).reduce(max);

    var f = 1.0;
    final pairsPrev = prev.any((c) => c.rank == card.rank);
    if (card.rank.value < prevMax && !pairsPrev) f *= 1.25; // 空白牌
    if (card.rank.value > prevMax + 1) f *= 0.7; // 高张打中跟注方
    if (pairsPrev) f *= 0.8; // 公对面：不容易被相信
    if (read.texture.maxSuitCount >= 3) f *= 0.75; // 第三张同花
    if (read.hasDraw || read.tier >= HandTier.medium) f *= 1.15;
    return f.clamp(0.4, 1.5);
  }

  /// 对手是不是「一压就跑」：对他们没必要把价值打太满。
  bool _villainFoldsALot(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    if (reads.length != 1) return false; // 多人底池里总有人会跟
    return reads.first.folder;
  }

  /// 位置调整：紧凶很在意位置，松凶在哪个位置都敢压。
  double _positionFactor(_Spot spot, double inPos, double outPos) {
    final base = spot.inPosition ? inPos : outPos;
    return 1 + (base - 1) * _p.positionSensitivity;
  }

  /// 半诈唬频率：听牌越强、位置越好、人越少越敢打。
  double _semiBluffChance(HandReading read, _Spot spot, double barrel) {
    var base = switch (read.drawOuts) {
      >= 12 => 0.72, // 花顺双听
      >= 8 => 0.55, // 花听 / 两头顺
      >= 4 => 0.26, // 卡顺
      _ => 0.0,
    };
    base *= barrel; // 转牌/河牌发出来的牌适不适合继续开火
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
  double _bluffChance(
      GameEngine game, PlayerState me, _Spot spot, HandReading read) {
    final river = game.street == Street.river;
    var base = (river ? 0.23 : 0.38) * _p.bluffScale;
    base *= _bluffiness;
    // 读人：对手翻后爱弃牌就多开火，是跟注站就别浪费筹码。
    base *= _exploitBluffFactor(game, me);
    // 有摊牌价值（弱成牌）别乱开火；中等牌更不该演空气。
    if (read.tier == HandTier.weak) base *= 0.35;
    if (read.tier >= HandTier.medium) base *= 0.1;
    base *= _positionFactor(spot, 1.2, 0.85);
    // 诈唬选牌：真人不会拿「什么也没挡到」的牌乱开火。握着坚果花/顺子的
    // 阻断牌（[HandReading.blockerScore]）时对手接不动，才值得加大频率。
    base *= 0.85 + 0.5 * read.blockerScore;
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
    // 3bet 底池：大家范围都很强、筹码又浅，硬诈唬的弃牌率明显更低。
    if (spot.isThreeBetPot) base *= 0.6;
    // 诈唬线延续：前一条街已经开过火，河牌没成牌也要能再开一枪。
    final plan = _plan;
    if (plan != null && game.street.index > plan.street.index) {
      base *= plan.kind == _PlanKind.semiBluff ? 2.0 : 1.4;
    }
    // 第二枪选牌：发出来的牌对跟注方越没用，越值得接着开火。
    base *= _barrelFactor(game, read);
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
    // 我这条街先过了牌 → 现在的加注就是过牌-加注，频率要明显提上去。
    final checkRaise = spot.checkedThisStreet && canRaise;
    // 转牌/河牌发出来的牌适不适合继续开火。
    final barrel = _barrelFactor(game, read);

    // 1) 怪兽牌：价值加注；加注战里已经打太多就转为跟注。
    //    底池相对筹码已经很大时，加注就是全下。
    if (read.tier == HandTier.monster) {
      if (spot.spr <= 2.5 && canRaise) return _jam(me);
      if (!canRaise || spot.raisesThisStreet >= 3) {
        return const AiDecision(ActionType.call);
      }
      return _raise(game, me, 0.85);
    }
    // 2) 强牌 + 低 SPR：筹码已经套进去了，没有弃牌的道理。
    if (read.tier == HandTier.strong && spot.spr <= 1.5) {
      if (canRaise) return _jam(me);
      return const AiDecision(ActionType.call);
    }
    // 2) 强牌：加注频率随街道递减（真人不会拿顶对在河牌乱加），
    //    面对大注/强线时以控池跟注为主，湿面偶尔也要懂得放手。
    //    自己先过牌再面对下注 = 过牌-加注，频率明显更高。
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
              (read.texture.wetness > 0.6 ? 0.8 : 1.0) *
              (checkRaise ? 1.8 : 1.0))) {
        return _raise(game, me, 0.8);
      }
      return const AiDecision(ActionType.call);
    }
    // 3) 听牌：半诈唬加注 or 按（隐含）赔率跟注 or 放弃。
    if (read.hasDraw) {
      if (canRaise && _roll(_semiBluffRaiseChance(read, spot, barrel))) {
        _registerFire(game.street, _PlanKind.semiBluff);
        return _raise(game, me, 0.75);
      }
      return _drawCallOrFold(game, me, spot, read, potOdds);
    }
    // 4) 中等牌：按赔率跟注，面对大注/强线弃牌；小注时偶尔反击。
    if (read.tier == HandTier.medium) {
      if (spot.spr <= 1.2) return const AiDecision(ActionType.call);
      var need = potOdds * (spot.villainStrength > 0.7 ? 1.3 : 1.1);
      if (bigBet) need *= 1.2;
      // 没位置的中等牌很难兑现胜率（后面还有人、也控制不了底池大小）。
      if (!spot.inPosition) need *= 1.12;
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
    if (canRaise && _roll(_bluffRaiseChance(game, me, spot, read))) {
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
      if (spot.canRaise && _roll(_bluffRaiseChance(game, me, spot, read))) {
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
  double _semiBluffRaiseChance(HandReading read, _Spot spot, double barrel) {
    if (!spot.inPosition && spot.opponents > 1) return 0.03;
    var base = read.isComboDraw
        ? 0.35
        : (read.drawOuts >= 8 ? 0.22 : 0.08);
    base *= _p.semiBluffRaiseScale;
    base *= _bluffiness * _aggression;
    if (spot.opponents >= 2) base *= 0.4;
    if (spot.betSizeRel >= 0.8) base *= 0.4; // 大注不硬凑
    // 第二枪选牌：发出来的牌帮不到对手才值得用听牌加注施压。
    base *= barrel;
    // 先过牌再对下注加注（过牌-加注）本来就是没位置时打听牌的主力。
    if (spot.checkedThisStreet) base *= 1.5;
    return base.clamp(0.0, 0.5);
  }

  /// 诈唬加注（含河牌未成牌的最后一枪）的频率。
  double _bluffRaiseChance(
      GameEngine game, PlayerState me, _Spot spot, HandReading read) {
    if (spot.opponents > 1) return 0.0;
    var base = (game.street == Street.river ? 0.06 : 0.05) *
        _p.bluffRaiseScale;
    base *= _bluffiness;
    base *= _exploitBluffFactor(game, me);
    if (spot.betSizeRel <= 0.35) base *= 2.0; // 对手小注 = 牌力偏弱
    if (spot.betSizeRel >= 0.75) base *= 0.35; // 大注通常是真牌，别硬顶
    if (spot.villainStrength > 0.7) base *= 0.4;
    if (spot.inPosition) base *= 1.3;
    // 诈唬选牌：阻断牌越硬，被跟注的概率越低。
    base *= 1 + 0.4 * read.blockerScore;
    return base.clamp(0.0, 0.2);
  }

  // ---------- 下注/加注额度 ----------

  /// 价值下注的尺度：3bet 底池用小注（小 SPR，分批把筹码放进去）。
  double _valueFrac(_Spot spot, double frac) =>
      spot.isThreeBetPot ? frac * 0.7 : frac;

  /// 筹码全下（引擎会按合法动作自动变成下注或加注）。
  AiDecision _jam(PlayerState me) =>
      AiDecision(ActionType.bet, amountTo: me.streetBet + me.stack);

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
    required this.seat,
    required this.raiserSeat,
    required this.checkedThisStreet,
    required this.spr,
    required this.isThreeBetPot,
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

  /// 我在什么位置（前位/中位/劫位/按钮/小盲/大盲）。
  final Seat seat;

  /// 翻前最后一个加注者在什么位置；没人加注时为 null。
  final Seat? raiserSeat;

  /// 我在这条街上已经过牌了：此时面对下注再加注就是「过牌-加注」，
  /// 是没位置时最有力的武器（真人靠它保护自己的过牌范围）。
  final bool checkedThisStreet;

  /// 筹码底池比：我的筹码 / 当前底池。SPR 越小越该「一把梭」，
  /// 越大越该用位置和小注慢慢来。
  final double spr;

  /// 翻前被 3bet 及以上（含自己 3bet 被抓）的底池：范围都很强，
  /// 诈唬的弃牌率明显更低，尺度也要相应调整。
  final bool isThreeBetPot;

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

    // 加注者的位置决定了对手范围有多强（前位开池 vs 按钮偷盲差别很大）。
    Seat? raiserSeat;
    if (lastPreflopRaiser != null) {
      for (final p in game.players) {
        if (p.id == lastPreflopRaiser) {
          raiserSeat = PreflopRanges.seatOf(game, p);
          break;
        }
      }
    }

    var raisesThisStreet = 0;
    var villainAgg = 0;
    var checkedThisStreet = false;
    for (final a in actions) {
      if (a.street != game.street) continue;
      if (a.actorId == me.id && a.type == ActionType.check) {
        checkedThisStreet = true;
      }
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
    // 翻后行动顺序是「按钮的下家先动、按钮最后动」。谁后面还有活人，
    // 谁就没位置。注意不能按座位序号简单往后扫：单挑时按钮位在大盲
    // 「前面」，那样会把按钮位算成没位置（其实它闭圈、最有利）。
    final myOrder = rel == 0 ? n : rel; // 按钮位 = 最后一个行动
    var inPosition = true;
    for (var i = 0; i < n; i++) {
      final other = game.players[i];
      if (other.id == me.id || other.folded) continue;
      final otherRel = (i - game.buttonIndex + n) % n;
      if ((otherRel == 0 ? n : otherRel) > myOrder) {
        inPosition = false;
        break;
      }
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
    final spr = me.stack / max(pot, 1);

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
      seat: PreflopRanges.seatOf(game, me),
      raiserSeat: raiserSeat,
      checkedThisStreet: checkedThisStreet,
      spr: spr,
      isThreeBetPot: preflopRaises >= 2,
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
