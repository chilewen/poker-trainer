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
    required this.fourBetScale,
    this.callSlack = 0.0,
    this.slowPlay = 0.12,
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

  /// 面对 3bet 时「再加注回去」的倾向。
  ///
  /// 紧凶是标准频率；松凶压得更凶；松被动几乎不 4bet——真人里松被动
  /// 那一档就是拿 QQ+/AK 一路跟到底（把最强的牌全慢打），这也是他们
  /// 最好剥削的地方之一。
  final double fourBetScale;

  /// 听牌半诈唬频率倍率。
  final double semiBluffScale;

  /// 强牌加注 / 中等牌薄价值下注的频率倍率。
  final double aggressionScale;

  /// 听牌半诈唬「加注」的频率倍率。
  final double semiBluffRaiseScale;

  /// 诈唬加注（含河牌最后一枪）的频率倍率。
  final double bluffRaiseScale;

  /// 抓诈唬的宽松度：跟注门槛按 (1 - callSlack) 打折。
  ///
  /// 跟注站就是这么输钱的：赔率差一点它照样跟，一对小牌也能跟你三条街。
  /// 以前这个门槛只由底池赔率和「读人」决定，三种风格面对下注的弃牌率
  /// 几乎一样（松被动 20% vs 紧凶 19%）——牌桌上最黏的那类人反而比谁都
  /// 果断，一眼假。
  final double callSlack;

  /// 拿了怪兽牌先跟一手的频率（慢打 / 设陷阱）。
  ///
  /// 被动玩家最明显的招牌：中了也不加注，等着对手自己往里塞钱。以前
  /// 三条/两对面对下注是三种风格一律 100% 加注，既不像真人，也让「加注」
  /// 这个动作在牌桌上完全没有风格差异。
  final double slowPlay;

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
  fourBetScale: 1.0,
  callSlack: 0.0,
  slowPlay: 0.12,
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
  fourBetScale: 0.3,
  limpsAnyPrice: true,
  wideLimp: true,
  callSlack: 0.28,
  slowPlay: 0.45,
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
  fourBetScale: 1.25,
  callSlack: 0.10,
  slowPlay: 0.18,
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
  int aggroActs = 0; // 翻后主动下注 / 加注的次数
  int passiveActs = 0; // 翻后过牌 / 跟注 / 弃牌的次数

  /// 翻后面对下注的弃牌率；样本太少时退回中性先验 0.45。
  double get foldToBet => seen < 4 ? 0.45 : folded / seen;

  /// 是不是「跟注站」：面对下注几乎不弃牌，还很少加注。
  bool get station => seen >= 6 && foldToBet <= 0.28 && raised <= seen * 0.15;

  /// 是不是「一压就跑」：面对下注弃得特别多。
  bool get folder => seen >= 6 && foldToBet >= 0.6;

  /// 自己主动开火的频率（翻后）：下注/加注 ÷ 全部动作。
  /// 样本少时退回中性 1/3，免得刚打两手就把对手读死。
  ///
  /// 实测：我们自己的三种风格大概落在 紧凶 0.25 / 松被动 0.22 / 松凶 0.40，
  /// 一个逮到机会就砸的疯子能到 0.5 以上，只会跟和弃的能低到 0.1 以下。
  double get aggroRate {
    final n = aggroActs + passiveActs;
    return n < 6 ? 0.33 : aggroActs / n;
  }
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
/// 4. 干面 + 翻前加注者 = 真人的「范围小注」：不看自己有没有后路，
///    都用 1/3 池把手里的牌整个铺出去（湿面才回到挑牌打）；
/// 5. 听牌主动半诈唬（有弃牌率也保有成牌概率），没成牌就按计划
///    在转牌/河牌决定继续开火还是放弃，而不是无脑跟注到底；
/// 6. 全程「读人」，而且两边都用：把每个对手翻后面对下注的弃牌/跟注/加注、
///    以及他自己主动开火的频率记进档案（[_VillainRead]）——
///    我们要下注时看他的弃牌倾向（对一压就跑的多诈唬、对跟注站少诈唬多收
///    价值），他下注我们要不要跟时看他的进攻性（爱开火的抓得宽，闷声的
///    突然开火就弃）——这才是真人最像人的那部分；
/// 7. 诈唬也会「选牌」：只挑挡掉对手强牌的那几张去开火
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
          r.passiveActs++;
          if (facedBet) {
            r.seen++;
            r.folded++;
          }
        case ActionType.call:
          r.passiveActs++;
          if (facedBet) {
            r.seen++;
            r.called++;
          }
        case ActionType.raise:
          r.aggroActs++;
          r.raised++;
          if (facedBet) r.seen++;
        case ActionType.bet:
          r.aggroActs++;
        case ActionType.check:
          r.passiveActs++;
      }
    }
  }

  /// 对某个对手的观察摘要：一起打过多少手、翻后面对下注弃了几次、
  /// 弃牌率是多少。供调试与「教练界面」显示用，不参与决策。
  ({int hands, int seen, double foldToBet, double aggroRate})? readOf(
      String playerId) {
    final r = _reads[playerId];
    if (r == null) return null;
    return (
      hands: r.hands,
      seen: r.seen,
      foldToBet: r.foldToBet,
      aggroRate: r.aggroRate,
    );
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
      // 「一压就跑」的对手值得拿任何两张牌开火（真人这时候是真敢打），
      // 跟注站则基本别浪费筹码——两边的区分度要拉得够开，
      // 不然「读人」这条线在实战里看不出来。
      sum += r.station
          ? 0.42
          : (r.folder ? 1.85 : 0.55 + 0.9 * r.foldToBet);
    }
    return (sum / reads.length).clamp(0.35, 1.9);
  }

  /// 对手的进攻性怎么影响我们的跟注门槛：
  /// 爱开火的对手手里可能全是诈唬（跟宽一点，弃太多会被剥削）；
  /// 闷不吭声的对手突然下注，多半是真牌（该弃就弃）。
  ///
  /// 做成连续因子而不是「疯子/岩石」两档：真人对付不同脾气的人是渐变的，
  /// 而且这样不会因为一个人恰好在阈值边上就突然改变打法。
  double _callVsReadFactor(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    if (reads.isEmpty) return 1.0;
    var sum = 0.0;
    for (final r in reads) {
      // 中性 1/3 → 1.0 倍；0.1 的岩石 → 1.28 倍；0.5 的疯子 → 0.80 倍。
      sum += (1 + (0.33 - r.aggroRate) * 1.2).clamp(0.8, 1.3);
    }
    return sum / reads.length;
  }

  /// 对手是不是「逮到机会就往里砸」的那种：拿强牌时别被他一个超池吓跑。
  bool _facingManiac(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    return reads.length == 1 && reads.first.aggroRate >= 0.45;
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
      // 短筹码（≤ 15bb）：这里真人打的是「推 / 弃」，而不是开 2~3bb
      // 再弃给别人的 3bet——那样既白送筹码，又把该拿的弃牌率让掉了。
      if (stackBb <= 15 && toCall < me.stack) {
        final shove =
            PreflopRanges.shoveOpen(seat, stackBb).shifted(_p.openShift + w);
        if (shove.contains(hand)) return _jam(me);
        // 大盲不用补钱，牌烂也别扔（免费看翻牌）；其余位置直接放弃。
        return toCall > 0
            ? const AiDecision(ActionType.fold)
            : const AiDecision(ActionType.check);
      }
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
      final premium = hand.isPair && hand.high >= Rank.king.value; // AA / KK
      // 已经是 4bet 及以上的底池（我们 4bet 被 5bet，或者对手直接 4bet
      // 过来）：这里只有 AA/KK 还值得继续。拿 QQ/AK 去跟 4bet 是白送——
      // 对手敢 4bet，范围里已经没有它们能压住的东西了。
      if (raises >= 3) {
        if (!premium) return const AiDecision(ActionType.fold);
        if (toCall >= me.stack || shortStack || toCall >= me.stack * 0.55) {
          return _jam(me);
        }
        return const AiDecision(ActionType.call);
      }
      final fourBet = PreflopRanges.valueFourBet.shifted(_p.threeBetShift + w);
      if (fourBet.contains(hand)) {
        if (toCall >= me.stack || shortStack) {
          return _jam(me); // 真的是全下（以前这里只是最小加注）
        }
        // 真人拿 QQ+/AK 面对方 3bet，大部分时候会再加注回去：4bet 才拿得到
        // 弃牌率，也给对手的 3bet 定个价。一路只跟（把最强的牌全慢打）是最
        // 典型的鱼味打法——对手发现我们 3bet 后面永远只是跟注，就可以拿
        // 任意两张牌 3bet 抢盲。AA/KK 会留一部分跟注去保护自己的跟注范围，
        // 松被动的玩家更爱慢打，松凶更爱压回去。
        // 范围边缘的牌（JJ/AQs 这种靠风格偏移带进来的）别打太满：
        // 4bet 是「底端要么打得少、要么打得狠」，全 4bet 会把自己的
        // 4bet 范围撑得太宽，遇到对手 5bet 又只能弃。
        final core = PreflopRanges.valueFourBet.contains(hand);
        final chance = (premium ? 0.62 : (core ? 0.75 : 0.45)) *
            _p.fourBetScale *
            (0.9 + 0.2 * (_aggression - 0.85));
        if (_roll(chance)) {
          return AiDecision(ActionType.raise,
              amountTo: _fourBetSize(game, spot, me));
        }
        return const AiDecision(ActionType.call);
      }
      // 轻 4bet：A5s~A2s 面对 3bet 是压回去而不是跟注
      // （见 PreflopRanges.isLightFourBetHand）。频率比轻 3bet 高一档：
      // 这些牌在 3bet 底池里翻后没有摊牌价值，「跟注」是纯亏的打法，
      // 压回去才换得到弃牌率 + 阻断牌的价值（紧凶约三成、松凶约五成）。
      if (_p.lightThreeBet > 0 &&
          toCall < me.stack * 0.4 &&
          PreflopRanges.isLightFourBetHand(hand) &&
          _roll(_p.lightThreeBet * 2.5 * _bluffiness)) {
        return AiDecision(ActionType.raise,
            amountTo: _fourBetSize(game, spot, me));
      }
      // 22~88 那一档（买三条）只在极深的筹码里跟：3bet 底池的 SPR 低到
      // 100bb 深度中三条也赢不回 3bet 的价钱，真人这时要么弃、要么拿去
      // 4bet 诈唬，跟注是最差的选择。
      // 跟注站不看位置也不看深度：能玩的牌就进池（见 callThreeBetStation）。
      final station = _p.wideLimp || _p.limpsAnyPrice;
      // 3bet 是「最小加注到 4.7bb」还是「加 3 倍到 9bb」，跟注范围差得很远：
      // 前者跟 1.5bb 就能抢一个 6bb 的底池（约 20% 赔率 + 后面一大截隐含
      // 赔率），后者是真金白银的要价。以前这里一个门槛打天下，英雄最小加注
      // 到 4.7bb 时 99 都有 82% 直接弃牌——对手拿任意两张牌最小加注都是赚的。
      final threeBetBb = game.currentBet / bb;
      final smallThreeBet = threeBetBb <= 5.5 ||
          (spot.preflopOpenTo > 0 &&
              game.currentBet <= spot.preflopOpenTo * 2.2);
      // 其它风格：有位置才用整个跟注范围（含投机牌），没位置只跟有牌力的。
      final callRange = station
          ? PreflopRanges.callThreeBetStation
          : (smallThreeBet
              ? (spot.inPosition
                  ? PreflopRanges.callThreeBetSmall
                  : PreflopRanges.callThreeBetSmallOop)
              : (!spot.inPosition
                  ? PreflopRanges.callThreeBetOop
                  : (stackBb >= 200
                      ? PreflopRanges.callThreeBet
                      : PreflopRanges.callThreeBet.withoutSmallPairs())));
      final shifted = callRange.shifted(w);
      // 投机的那一半（小对子 / 同花连张）混着跟：真人对这些边缘牌不是
      // 每次都跟，一部分直接弃，跟注范围才不会宽到对手一开火就收走。
      // 松的性格跟得多一点（_looseness 0.9~1.15）。
      final specFreq =
          (station ? 0.6 : 0.45 + (_looseness - 0.9) * 2.0).clamp(0.3, 0.8);
      final deepCall = !shortStack &&
          stackBb >= 80 &&
          toCall <= me.stack / 3 &&
          shifted.contains(hand) &&
          (PreflopRanges.callThreeBetCore.contains(hand) || _roll(specFreq));
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
      if (toCall >= me.stack) return _jam(me);
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
        final light = _mixSize((game.currentBet * 3).toDouble()).round();
        return AiDecision(ActionType.raise, amountTo: light);
      }
    }
    // 短筹码：与其翻后打小球，不如直接推进去（弃牌率 + 摊牌胜率）。
    if (shortStack && toCall < me.stack && score >= 10.0) {
      return _jam(me);
    }
    // 冷跟防守：位置、加注规模、筹码深度全部由范围表决定。
    if (defense.call && toCall <= me.stack / 2) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 开池加注的尺度：位置好可以开小一点（省筹码、还能拿下盲注），
  /// 前位开大一点；每多一个溜入者多加 1bb（隔离他们，也把底池做大）。
  ///
  /// 最后再过一遍尺度混合：真人不会「按钮位永远 2.46bb、前位永远 3bb」，
  /// 而是在小一点/正常/大一点之间换档——固定尺度是最容易被对手读死的。
  int _openSize(GameEngine game, int bb, int limpers, Seat seat) {
    final base =
        bb * (_p.openSizeBb * PreflopRanges.openSizeFactor(seat) + limpers);
    return _mixSize(base).round();
  }

  /// 4bet 尺度：有位置约 2.2 倍 3bet、没位置 2.6 倍（没位置不加够就是
  /// 白送对手的跟注赔率）。算出来要是已经压进自己四成筹码，就别再留
  /// 什么后手了——4bet 完还想弃牌是最亏的打法，直接推到全下。
  int _fourBetSize(GameEngine game, _Spot spot, PlayerState me) {
    final base = game.currentBet * (spot.inPosition ? 2.2 : 2.6);
    final size = _mixSize(base).round();
    if (size - me.streetBet >= me.stack * 0.4) {
      return me.streetBet + me.stack;
    }
    return size;
  }

  /// 3bet / 挤压尺度：有位置约 3 倍开池、没位置 4 倍（没位置要加得
  /// 更多才能压掉对手的跟注赔率），每个已经进池的人再多加 1bb
  /// （挤压时不能让跟注者用便宜价格跟进来），但不低于 3 倍当前注。
  int _threeBetSize(GameEngine game, _Spot spot) {
    final potBased = game.currentBet * (spot.inPosition ? 3 : 4);
    final floor = game.currentBet * 3;
    final callers = game.config.bigBlind * spot.limpers;
    final size = max(max(potBased, floor) + callers, floor);
    // 同样换档，但 3 倍开池这条底线不能破（没位置时加不够就是白送赔率）。
    return max(floor, _mixSize(size.toDouble()).round());
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

  /// 模拟次数：对手越多，每个样本要评估的手数越多，就越少跑几次。
  ///
  /// [equityVsRange] 现在每个样本只评估「英雄 + 每个对手」这几手牌
  /// （以前翻后每个样本要扫二十多手候选），所以同样的时间预算能跑的
  /// 样本多了好几倍——这里的次数就是按这个新预算定的，边缘局面的
  /// 胜率估计更稳，不会同一个牌面一会儿跟一会儿弃。
  int _trials(int opponents) => opponents >= 5
      ? 320
      : (opponents >= 3 ? 480 : (opponents == 2 ? 640 : 900));

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

    // 读线：对手连着几条街开火，他范围里的「空气 / 弱对」就该大幅缩水——
    // 真人就是这么收窄范围的，而不是只看这一条街的下注大小。
    // 只开一枪的人范围里还有一堆弱牌；连开三枪的范围是两极的：
    // 真东西 + 少量诈唬，中间那些「随便跟一下」的一对牌基本没了。
    //
    // 下注和加注还得分开算：面对下注时对手范围里还有一大堆诈唬，空气
    // 只该收一点；面对加注（尤其过牌-加注）那是一条两极的强线——顶对和
    // 超对还在里面，但「跟一张看看」的中小对子、纯空气都得再砍一刀。
    // 不砍的话，第二对会以为自己面对的仍是那条「随便开一枪」的宽范围。
    final facingRaise = spot.villainRaisedThisStreet;
    final lineAgg = spot.priorAgg +
        (spot.facingBet ? 0.8 : 0.0) +
        (facingRaise ? 0.7 : 0.0);
    final airKeep = (1 - 0.22 * lineAgg).clamp(0.25, 1.0);
    /// 比顶对弱的一对牌（第二对、底对、被盖过的口袋对）在加注线里
    /// 还剩多少权重；顶对以下的对子基本只剩「他也在诈唬」那一小撮。
    final weakPairKeep =
        street == Street.flop ? 0.5 : (street == Street.turn ? 0.4 : 0.3);
    /// 加注线里的纯空气（诈唬/后门听牌）保留的权重。
    final airRaiseKeep = 0.6;
    final boardTop = game.board.isEmpty
        ? 0
        : game.board.map((c) => c.rank.value).reduce(max);

    return (hole, score) {
      final pre = preflopWeight(hole);
      if (pre <= 0.0) return 0.0;
      final cat = score.category.rank;
      double keep;
      if (cat >= 3) {
        keep = 1.0; // 三条以上：加注线的主角
      } else if (cat == 2) {
        keep = 0.95; // 两对
      } else if (cat == 1) {
        // 顶对/超对是加注线里的价值主力，第二对以下就没那么值钱了。
        final pairRank =
            score.tiebreakers.isEmpty ? 0 : score.tiebreakers.first;
        final topPair = pairRank >= boardTop;
        keep = (street == Street.flop
                ? 0.75
                : (street == Street.turn ? 0.6 : 0.45)) *
            airKeep *
            (facingRaise && !topPair ? weakPairKeep : 1.0);
      } else {
        keep = (street == Street.flop
                ? 0.4
                : (street == Street.turn ? 0.25 : 0.12)) *
            airKeep *
            (facingRaise ? airRaiseKeep : 1.0);
      }
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
      // 领先下注（donk）这条线例外：没位置、又不是翻前加注者，翻牌圈主动
      // 开火等于把主动权送出去——对手范围更强还有位置，一被加注就难受。
      // 真人拿三条/顺子在这儿多数先过牌，把筹码留到过牌-加注里。
      if (!multiway && _isDonkSpot(game, spot) && _roll(0.62)) {
        return const AiDecision(ActionType.check);
      }
      if (!river && texture.isDry && !multiway && _roll(0.22)) {
        return const AiDecision(ActionType.check);
      }
      // 河牌是最后一次收价值的机会：对手肯付钱就用超池（1.2 倍底池），
      // 对一压就跑的对手不超池——小注换来跟注更划算。
      // 没位置时河牌不必每手都打：碰上爱开火的人偶尔过牌钓一次——
      // 他河牌的诈唬才有落点，我们的过牌范围也才不会清一色是「我没东西」。
      // 对一直跟注的人就没这一手：过牌等于把最后一条街的价值白送出去。
      if (river &&
          !multiway &&
          !spot.inPosition &&
          _villainBetsALot(game, me) &&
          _roll(0.3)) {
        return const AiDecision(ActionType.check);
      }
      if (river && !multiway && !_villainFoldsALot(game, me) && _roll(0.5)) {
        return _bet(game, me, (1.2 * valueFactor).clamp(0.8, 1.5));
      }
      final frac = _valueFrac(spot, read, 0.62,
              rangeBet: game.street == Street.flop) *
          valueFactor;
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
        _roll(_isDonkSpot(game, spot)
            ? (texture.isDry ? 0.55 : 0.45)
            : (texture.isDry ? 0.3 : 0.18))) {
      return const AiDecision(ActionType.check);
    }
    if (read.tier == HandTier.strong) {
      // 转牌发出的牌帮到跟注方时（高张 / 第三张同花 / 公对面，也就是
      // [_isBlankCard] 判不出空白牌的那些），真人会有一部分在这儿收手
      // 控池：顶对/超对再开一枪，被加注就得弃；过牌看河牌还能抓到对手
      // 的诈唬，自己的过牌范围也不至于清一色是没牌。以前这条线完全不看
      // 转牌发的是什么，永远 100% 开枪——对手等一张高张过牌-加注，
      // 就能把我们的超对打走。
      if (game.street == Street.turn &&
          !multiway &&
          !_isBlankCard(game) &&
          _roll(spot.inPosition ? 0.35 : 0.22)) {
        return const AiDecision(ActionType.check);
      }
      // 河牌把「强牌」也混一点进超池里：以前超池清一色是怪兽牌，对手看到
      // 超池就弃、看到 0.6 池就敢跟——尺度等于把我们的牌报了出来。干面上
      // 顶对/超对本来就是这条线上最好的牌，超池去收才有人付钱。
      if (river &&
          !multiway &&
          texture.wetness <= 0.6 &&
          !_villainFoldsALot(game, me) &&
          _roll(0.25)) {
        return _bet(game, me, (1.15 * valueFactor).clamp(0.8, 1.4));
      }
      final frac = _valueFrac(spot, read, 0.62,
              rangeBet: game.street == Street.flop) *
          valueFactor;
      return _bet(game, me, frac.clamp(0.3, 1.1));
    }
    // 3) 干面 + 我是翻前加注者：真人的「范围小注」。
    //
    //    K-8-3 这种没人中的牌面上，对手同样很难有牌——真人这时候不看自己
    //    手里是什么，都拿同一个 1/3 池的小注把整个范围铺出去（尺度见
    //    [_stabFrac] 的 rangeBet 档）。这是最像人、也最容易漏掉的一枪：
    //    以前干面上的下注率完全跟着牌力走，什么都没沾的牌只开火两成多，
    //    等于把对手最容易弃牌的牌面白让出去；而且下注范围一眼就能被读出
    //    牌力（小注=顶对、不中=过牌）。
    //
    //    和牌力无关，所以放在这里统一处理：牌力只决定剩下的那部分
    //    （过牌回去的范围里，有后路/有摊牌价值的牌占多数）。
    if (game.street == Street.flop &&
        spot.isPreflopAggressor &&
        texture.isDry &&
        spot.opponents <= 2 &&
        read.tier <= HandTier.medium &&
        _roll(spot.opponents == 1 ? 0.55 : 0.45)) {
      _registerFire(
          game.street, read.hasDraw ? _PlanKind.semiBluff : _PlanKind.pureBluff);
      // 尺度就是「范围小注」本来的样子：频率高、但只用 1/3 池——范围
      // 铺得越宽，尺度就越要小，不然一被加注整条线就塌了。
      return _bet(
          game, me, _stabFrac(spot, read, 0.5, rangeBet: true).clamp(0.25, 0.4));
    }
    // 4) 听牌：半诈唬（听牌转诈唬的第一步）。
    //    有弃牌率，被跟注也还有 outs，比纯空气诈唬合理得多。
    if (read.hasDraw && read.tier <= HandTier.medium) {
      if (_roll(_semiBluffChance(read, spot, barrel) *
          _donkScale(game, spot))) {
        _registerFire(game.street, _PlanKind.semiBluff);
        return _bet(game, me,
            _stabFrac(spot, read, 0.6, rangeBet: game.street == Street.flop));
      }
      _plan = null; // 听牌也选择过牌：放弃这条线的诈唬
      return const AiDecision(ActionType.check);
    }
    // 5) 有摊牌价值的成牌：中等牌（顶对好踢 / 第二对好踢 / 中间对子）
    //    和弱成牌（顶对弱踢 / 底对 / 被盖过的口袋对）一起处理。
    //
    //    没人下注时以小注薄价值 / 保护为主，而不是当空气去诈唬——拿一对
    //    去诈唬就是「把更差的牌打走、只被更好的牌跟注」，真人不会这么打。
    //    频率按牌力分档（见 [_thinValueChance]）：以前是中等牌 45%、弱牌
    //    50%，结果既把顶对打得太少（顶对就是翻牌的主力价值牌，老过牌
    //    等于明牌告诉对手我没有东西），又让底对比第二对还敢打。
    if (read.tier == HandTier.medium || read.tier == HandTier.weak) {
      if (_roll(_thinValueChance(game, me, spot, read) *
          _donkScale(game, spot))) {
        // 薄价值的尺度也贴在「普通尺度」附近：比成牌主力小一点是应该的
        // （毕竟只是薄价值），但不能小到变成一个独立档位——那样对手一眼
        // 就能把「小注 = 顶对」对上号。
        final frac = read.tier == HandTier.medium ? 0.5 : 0.45;
        return _bet(
            game,
            me,
            _valueFrac(spot, read, frac, rangeBet: game.street == Street.flop) *
                valueFactor);
      }
      return const AiDecision(ActionType.check);
    }
    // 6) 没牌力：按计划延续诈唬，或找机会开火。
    if (_roll(_bluffChance(game, me, spot, read) * _donkScale(game, spot))) {
      _registerFire(game.street, _PlanKind.pureBluff);
      // 河牌拿着阻断牌时用超池诈唬：对手的强牌被我们挡掉，超池逼他弃牌
      // 最划算。坚果花阻断，或者 A 阻断 + 牌面三张同花，是真人最爱的两张
      // 超池诈唬牌；诈唬和怪兽牌的价值共用一个尺寸，对手才没法按尺度弃牌。
      final nutBluff = read.nutFlushBlocker ||
          (read.hasAceBlocker && read.texture.maxSuitCount >= 3);
      if (river && !multiway && nutBluff && _roll(0.35)) {
        return _bet(game, me, 1.25);
      }
      // 阻断牌够硬（挡掉坚果花 / 拿着 A）但没到「挡死对手」那一步：
      // 用偏重的尺度换弃牌率，收益比小注更高。
      if (river && !multiway && read.blockerScore >= 0.6 && _roll(0.2)) {
        return _bet(game, me, 1.15);
      }
      if (river && read.blockerScore >= 0.5 && _roll(0.4)) {
        return _bet(game, me, 0.9);
      }
      return _bet(
          game,
          me,
          _stabFrac(spot, read, river ? 0.7 : 0.55,
              rangeBet: game.street == Street.flop));
    }
    _plan = null; // 过牌 = 放弃这条诈唬线
    return const AiDecision(ActionType.check);
  }

  /// 是不是「领先下注」（donk）的场合：翻牌圈、我没位置、而且我是翻前
  /// 跟注方——有人加注过、我却先说话，翻前的加注者还压在我后面。
  /// （[hasRaiser] 这个条件是必要的：溜入底池里没人示过强，先打一枪就是
  /// 普通的「试探下注」，不算 donk，不该按这条降频。）
  bool _isDonkSpot(GameEngine game, _Spot spot) =>
      game.street == Street.flop &&
      !spot.inPosition &&
      !spot.isPreflopAggressor &&
      spot.raiserSeat != null;

  /// 领先下注的频率折扣。真人在大盲跟注后的翻牌圈很少主动开火：翻前加注
  /// 者的范围更强、还有位置，donk 一被加注就得做难受的决定。所以这条线上
  /// 价值牌以过牌-加注为主、听牌以过牌-跟为主，只有一部分继续领先打一枪。
  double _donkScale(GameEngine game, _Spot spot) =>
      _isDonkSpot(game, spot) ? 0.4 : 1.0;

  /// 新发的这张牌是不是「空白牌」：比前面牌面第二高的牌还小、没配成
  /// 公对、也没凑成第三张同花。这种牌几乎帮不到跟注方，是最适合继续
  /// 开火的一类牌。
  ///
  /// 判据用的是「第二高」而不是「最高」：K-8-3 面上发 Q，Q 虽然比 K 小，
  /// 可那是跟注方范围里（KQ / QJ / QT）实打实的一张牌，真人不会被这张
  /// 牌白送一个「空白牌」的继续开火理由。
  bool _isBlankCard(GameEngine game) {
    final board = game.board;
    if (board.length < 4) return false;
    final prev = board.sublist(0, board.length - 1);
    final card = board.last;
    if (prev.any((c) => c.rank == card.rank)) return false; // 公对面
    if (prev.where((c) => c.suit == card.suit).length >= 2) return false;
    final ranks = prev.map((c) => c.rank.value).toSet().toList()
      ..sort((a, b) => b - a);
    final second = ranks.length > 1 ? ranks[1] : ranks.first;
    return card.rank.value < second;
  }

  /// 第二枪 / 第三枪的选牌：新发出来的这张牌对谁更有利？
  ///
  /// - 空白牌（比前面第二高的牌都小）几乎没帮到跟注方 → 继续开火收益高；
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
    if (_isBlankCard(game)) f *= 1.45; // 空白牌
    // 比牌面都大的高张（尤其 A）：跟注方的范围里全是这种牌，
    // 转牌一发到就该收手——但也不能一见到高张就整条线扔了。
    // 以前这里是 0.6 倍，配上下面的系数，拿到空气的转牌第二枪只剩 13%，
    // 等于告诉对手「转牌出高张就随便跟」：他只要跟一张翻牌，就能白捡
    // 之后两条街的底池（我们的开火频率比真人的弃牌频率还低）。
    if (card.rank.value > prevMax) f *= 0.8;
    if (pairsPrev) f *= 0.8; // 公对面：不容易被相信
    if (read.texture.maxSuitCount >= 3) f *= 0.75; // 第三张同花
    if (read.hasDraw || read.tier >= HandTier.medium) f *= 1.15;
    return f.clamp(0.4, 1.5);
  }

  /// 对手翻后是不是爱主动开火：只有爱下注的人才值得在河牌钓他一次——
  /// 对一直跟注的对手过牌，就是白送掉最后一条街的价值。
  bool _villainBetsALot(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    if (reads.length != 1) return false; // 多人底池里总有人会跟注
    return reads.first.aggroRate >= 0.25;
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

  /// 有摊牌价值的成牌在「没人下注」时的价值下注频率。
  ///
  /// 真人的频率跟着牌力走：顶对（哪怕踢脚不大）在翻牌/转牌就是主力价值
  /// 牌，河牌才慢慢收成摊牌牌；第二对、底对则越来越像纯摊牌牌。
  /// 街越往后、人越多、牌面越湿，频率越低。
  double _thinValueChance(
      GameEngine game, PlayerState me, _Spot spot, HandReading read) {
    final river = game.street == Street.river;
    var f = switch (read.tier) {
      // 顶对好踢 / 第二对好踢 / 中间对子（超对被盖过的那种不算）
      HandTier.medium => read.topPair ? 0.78 : 0.50,
      // 顶对弱踢 / 底对 / 被盖过的口袋对
      _ => read.topPair ? 0.65 : 0.42,
    };
    if (river) f *= read.topPair ? 0.8 : 0.7; // 河牌后面没有牌了，收敛一点
    if (spot.opponents >= 2) f *= 0.55; // 多人底池：薄价值要收着打
    if (read.texture.wetness > 0.6) f *= 0.6; // 湿面：先把底池控制住
    f *= _aggression * _p.aggressionScale;
    f *= _exploitValueFactor(game, me);
    return f.clamp(0.0, 0.95);
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
    // 开火选牌的另一半是「后路」：一直开火的牌自己也得有成长空间。
    // 以前不看这一项，结果「两张高张配后门花」和「7 高什么都没配到」的
    // 频率一样——跟注方拿一对跟到底就能赢，我们开火范围里全是白送的牌。
    // 翻牌圈要把关最严（开火范围就是在这儿被垃圾塞满的）；转牌圈手里
    // 这些牌本来就已经筛过一轮，而且前面已经开过一枪，压得太狠等于把
    // 「第二枪」这条线整条砍掉。
    if (!river) {
      final floor = game.street == Street.flop ? 0.30 : 0.55;
      base *= floor + (1 - floor) * _backdoorScore(game, read);
    }
    if (spot.opponents >= 3) {
      base *= 0.35;
    } else if (spot.opponents == 2) {
      base *= 0.65;
    }
    // 翻前加注者的持续下注：翻牌圈频率更高（这也是真人的 c-bet），
    // 干燥牌面更容易打走对手，频率再往上提。（干面上真正的主力是
    // [_checkedTo] 里那条「范围小注」分支，这里管的是剩下的部分。）
    if (game.street == Street.flop && spot.isPreflopAggressor) {
      base *= read.texture.isDry ? 2.0 : 1.4;
    }
    // 3bet 底池：大家范围都很强、筹码又浅，硬诈唬的弃牌率明显更低。
    if (spot.isThreeBetPot) base *= 0.6;
    // 诈唬线延续：前一条街已经开过火，后面没成牌也要能再开一枪。
    // 纯诈唬这一档从 1.4 提到 1.7：翻牌 c-bet 被跟之后，真人转牌接着
    // 开的比例在四成上下（空白牌更多），以前只有三成出头，等于自己把
    // 「被跟了就放弃」写在了脸上——对手跟一张翻牌就能白捡后面两条街。
    final plan = _plan;
    if (plan != null && game.street.index > plan.street.index) {
      base *= plan.kind == _PlanKind.semiBluff ? 2.0 : 1.7;
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
    // 读人（面对下注这一侧）：对手是疯子就多跟，是岩石就少跟。
    final callFactor = _callVsReadFactor(game, me);
    final facingManiac = _facingManiac(game, me);
    // 面对的是「加注」而不是「简单开一枪」：加注线是两极的，中间牌力
    // 去跟就是在给别人价值下注付钱，跟注门槛得往上抬一档。
    final facingRaise = spot.villainRaisedThisStreet;

    // 1) 怪兽牌：价值加注；加注战里已经打太多就转为跟注。
    //    底池相对筹码已经很大时，加注就是全下。
    if (read.tier == HandTier.monster) {
      if (spot.spr <= 2.5 && canRaise) return _jam(me);
      if (!canRaise || spot.raisesThisStreet >= 3) {
        return const AiDecision(ActionType.call);
      }
      // 慢打：只是面对一次下注（不是加注战）时，先跟一手把对手留在底池里。
      // 被动风格最常这么干——「中了也不加」正是跟注站的招牌；加注战里
      // 就不慢打了，那边每一手都在往底池里塞钱。
      if (!facingRaise && _roll(_p.slowPlay)) {
        return const AiDecision(ActionType.call);
      }
      return _raise(game, me, 0.85);
    }
    // 2) 强牌 + 低 SPR：筹码已经套进去了，没有弃牌的道理。
    //    但「套进去」的门槛要看池里几个人：单挑 SPR 1.5 拿顶对顶踢推全下
    //    没问题（对手范围里还有更差的顶对和听牌），池里四五个人就不同了
    //    ——人人跟注之后底池涨得快，SPR 掉到 1.5 很容易，可跟上全下的
    //    范围里两对/三条已经占了多数，推出去等于只被更好的牌跟。人越多，
    //    越得先跟注控池（筹码反正也跑不掉，后面再推进去）。
    final jamSpr =
        spot.opponents >= 3 ? 0.85 : (spot.opponents == 2 ? 1.15 : 1.5);
    if (read.tier == HandTier.strong && spot.spr <= jamSpr) {
      if (canRaise) return _jam(me);
      return const AiDecision(ActionType.call);
    }
    // 2) 强牌：加注频率随街道递减（真人不会拿顶对在河牌乱加），
    //    面对大注/强线时以控池跟注为主，湿面偶尔也要懂得放手。
    //    自己先过牌再面对下注 = 过牌-加注，频率明显更高。
    if (read.tier == HandTier.strong) {
      if (bigBet || spot.villainStrength > 0.8) {
        // 疯子的大注不能当真的听：拿强牌被他吓跑是最亏的。
        if (!facingManiac &&
            bigBet &&
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
      // 多人底池要收着加：池里的人越多，顶对顶踢被两对/三条压住的机会越大，
      // 而且每一家的继续范围都比我单挑时面对的更强。以前这里完全不分人数，
      // 顶对顶踢在三人池、五人池里和单挑一样加 55%（探针实测：1/2/3 家
      // 都是 55%），牌桌上就成了「拿顶对一直加」。
      final manyWay = spot.opponents >= 3
          ? 0.3
          : spot.opponents == 2
              ? 0.55
              : 1.0;
      // 过牌-加注的倍率别拉满：强牌一路只会加注，跟注范围就全剩中等牌，
      // 对手随便开一枪都能把我们打走（反正我们加注他弃、我们跟注他继续开）。
      // 留一部分强牌只是跟注，对手的诈唬才有人抓、我们的过牌也才有人怕。
      // 自己 c-bet 也算这条街的一次进攻，所以 raisesThisStreet <= 2 时
      // 对手的加注正好给我们一次 3-bet 的机会——超对/顶对要是从来不加回去，
      // 对手拿听牌和空气随便抬我们一手就能把强牌打走。频率压一半，
      // 剩下的还是跟注，免得自己的跟注范围全是中等牌。
      //
      // 倍率只留一点点（1.5 → 1.2）：以前那个倍率等于「没位置的强牌一律
      // 比有位置更爱加」（实测翻牌顶对顶踢：没位置 78% vs 有位置 56%），
      // 位置差的方向正好反了——没位置的人加注之后还要在不利位置打后面
      // 两条街。留 1.2 是因为「先过牌再被下注」这条线上，加注本来就是
      // 没位置一方回收价值的主力，只是幅度不能像以前那么夸张。
      if (canRaise &&
          spot.raisesThisStreet <= 2 &&
          _roll(base *
              manyWay *
              _aggression *
              _p.aggressionScale *
              (read.texture.wetness > 0.6 ? 0.8 : 1.0) *
              (checkRaise ? 1.2 : 1.0) *
              (spot.villainRaisedThisStreet ? 0.5 : 1.0))) {
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
      // 跟注站的「黏」是对着下注的（一手小对陪你三条街），不是对着加注的：
      // 对面已经加注出来，中间牌力再跟就是在给价值下注付钱——风格再松也
      // 不该松这一档，不然三条同花面上拿第二对去接加注就变成「标准打法」。
      if (!facingRaise) need *= 1 - _p.callSlack;
      // 超池是两极的：真东西和空气都在里面，抓的时候要留个余量
      // （模型给的胜率是对着「宽范围」算的，被价值牌清空的风险没算进去）。
      if (bigBet) need *= spot.polarizedBet ? 1.12 : 1.2;
      if (facingRaise) need *= 1.25; // 面对加注：顶对也得收着点
      // 没位置的中等牌很难兑现胜率（后面还有人、也控制不了底池大小）。
      // 探针里同一个局面（同一张牌、同样尺度）有位置和没位置的跟注率
      // 只差 4 个点，等于位置这一维在跟注决策上几乎没生效——现在抬到
      // 能让「有位置薄跟、没位置收手」看得出来。
      if (!spot.inPosition) need *= 1.22;
      need *= callFactor; // 抓诈唬牌：对手越疯越要跟，越闷越要弃
      final scary = !facingManiac &&
          bigBet &&
          !spot.polarizedBet &&
          spot.villainStrength > 0.8 &&
          read.texture.wetness > 0.6;
      // 加注先于跟注：中等牌也要有自己的反击频率，不然加注范围里
      // 清一色是怪兽牌和听牌，对手一被加就知道我们是什么。
      if (canRaise &&
          !scary &&
          spot.raisesThisStreet <= 1 &&
          _roll(_valueRaiseChance(game, me, spot, read))) {
        return _raise(game, me, 0.75);
      }
      if (!scary && _callMix(equity(), need)) {
        return const AiDecision(ActionType.call);
      }
      if (canRaise &&
          smallBet &&
          spot.opponents == 1 &&
          _roll(0.15 * _aggression * _p.aggressionScale)) {
        return _raise(game, me, 0.7); // 对手像是在打阻挡注
      }
      return const AiDecision(ActionType.fold);
    }
    // 5) 弱成牌（一对但被压制：底对、第二对弱踢、顶对弱踢、被盖过的口袋对）：
    //    这是真人的「抓诈唬」主力。河牌跟注范围里大半就是这种一对牌——
    //    见注就弃等于告诉对手「你随便开火我都走」，会被诈到破产。
    //    所以按赔率抓，只是门槛比中等牌高：大注少抓、疯子多抓、岩石不抓。
    if (read.tier == HandTier.weak) {
      if (spot.spr <= 1.0) return const AiDecision(ActionType.call);
      // 抓诈唬的门槛 = 底池赔率 + 一点余量。对手前面那条街全过牌、这条街
      // 才突然砸出来的大注（[polarizedBet] / [checkedThrough]），范围里
      // 诈唬和半诈唬占了大头，我们的一对牌就是合格的抓牌——这种线只按
      // 赔率要一点溢价就够；反过来对手连开几枪的大注才按「大注 = 真牌」
      // 收紧。以前不分这两种线，一律把赔率乘 1.5 倍以上，结果第二对对着
      // 0.75 池的「过牌-过牌-重注」会 97% 弃牌，对手随便抡一枪我们就交牌。
      final stab = spot.polarizedBet || (spot.checkedThrough && bigBet);
      var need = potOdds * (spot.villainStrength > 0.7 ? 1.7 : 1.35);
      // 一对牌是抓诈唬的主力，跟注站抓得更宽（但面对加注照样收手）。
      if (!facingRaise) need *= 1 - _p.callSlack;
      if (bigBet) need *= stab ? 0.85 : 1.35;
      if (facingRaise) need *= 1.85; // 第二对去跟一个加注基本是送
      // 一对牌是「抓诈唬」的牌：没位置抓的人，后面还有一整条街要挨打，
      // 而且河牌拿不到薄价值，门槛本来就该比有位置高一档。
      if (!spot.inPosition) need *= 1.2;
      need *= callFactor; // 对手越爱开火越该抓、越闷越该走
      // 底对、第二对也能拿来反击：频率比中等牌低，但只要有这个频率，
      // 对手就不能拿「加注 = 大牌」来读我们，我们的跟注范围也才有掩护。
      if (canRaise &&
          spot.raisesThisStreet <= 1 &&
          _roll(_valueRaiseChance(game, me, spot, read))) {
        return _raise(game, me, 0.75);
      }
      if (_callMix(equity(), need)) return const AiDecision(ActionType.call);
      // 一对牌是拿来抓诈唬的，赔率不够就老实弃——拿它去加注诈唬等于
      // 把更差的牌打走、被更好的牌跟注（「有摊牌价值的牌不诈唬」）。
      if (canRaise && read.blockerScore >= 0.5 && _roll(0.04)) {
        _registerFire(game.street, _PlanKind.pureBluff);
        return _raise(game, me, 0.8);
      }
      return const AiDecision(ActionType.fold);
    }
    // 6) 空气：弃牌为主。但翻牌圈的「后门花 + 两张高张」（A 高、K 高这种）
    //    是真人最爱跟一张的浮牌（float）：转牌凑出花听/对子就有的打，
    //    对手过牌我们还能把底池收走。见注就弃的话，对手随便开一枪
    //    都能把我们清出去。
    if (_roll(_floatChance(game, spot, read))) {
      // 浮牌是「跟一张、下一街把底池拿走」的计划：登记成半诈唬线，
      // 转牌对手再过牌时就会延续开火（后门花真成了还能转成价值）。
      _registerFire(game.street, _PlanKind.semiBluff);
      return const AiDecision(ActionType.call);
    }
    // 极少数情况诈唬加注。
    if (canRaise && _roll(_bluffRaiseChance(game, me, spot, read))) {
      _registerFire(game.street, _PlanKind.pureBluff);
      return _raise(game, me, 0.8);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 边缘牌别一刀切：胜率和门槛挨得很近时按比例混合（真人也会
  /// 「这手跟、下手弃」），离得远就是干净的是/否。
  ///
  /// 河牌圈的胜率是蒙特卡洛估出来的，同一个牌线往往每次都差不多，
  /// 纯阈值判断会让 AI 在边缘局面上一律跟或一律弃——太机械了。
  bool _callMix(double equity, double need) {
    final edge = equity - need;
    if (edge >= 0.04) return true;
    if (edge <= -0.04) return false;
    return _roll(0.5 + edge / 0.08 * 0.5);
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
    final implied = (read.nutFlushDraw || read.isComboDraw) ? 0.08 : 0.06;
    final drawEq = read.drawEquity(streets) + (deep ? implied : 0);
    // 听牌的门槛只比裸赔率高一点点。以前在这上面再乘 1.25 × 1.1 的
    // 「安全余量」，等于要求 9 outs 的花听对着 1 倍池要有 46% 胜率才跟，
    // 结果 8~9 outs 的顺听/花听对着正常尺度一律弃掉——真人拿到这些牌
    // 几乎都会跟一张看两张牌（赔率够，成牌之后还有隐含赔率）。
    // 真正要防的是被更强的成牌清空，所以余量只留在「对手线很强」和
    // 「超池」这两项上。
    var need = potOdds * (spot.villainStrength > 0.75 ? 1.08 : 1.0);
    if (spot.betSizeRel >= 1.2) need *= 1.1;
    need *= _callVsReadFactor(game, me); // 疯子付得出隐含赔率，岩石付不出
    // 没位置的听牌不好兑现：跟注之后转牌还得先挨一枪，成牌了也很难
    // 在后面两条街收满价值（先说话的人收不到薄价值）。
    if (!spot.inPosition) need *= 1.08;
    if (!spot.villainRaisedThisStreet) {
      need *= 1 - 0.6 * _p.callSlack; // 跟注站连听牌都买得更便宜
    }
    if (drawEq >= need) return const AiDecision(ActionType.call);
    // 便宜的小注：弱听牌也可以跟一张看转牌。
    if (spot.betSizeRel <= 0.3 &&
        read.drawOuts >= 4 &&
        drawEq >= need * 0.75) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 有摊牌价值的成牌（中等牌 / 弱成牌）面对下注时的加注频率。
  ///
  /// 以前这两档只有「跟注或弃牌」：加注范围里清一色是怪兽牌和听牌，
  /// 对手只要看到加注就知道撞上大牌；反过来我们的跟注范围全是弱牌，
  /// 被大手牌打穿、也挡不住对手随便开火。真人拿顶对、第二对同样会用
  /// 来反击（尤其是先过牌再被下注的过牌-加注），一是保护自己的过牌范围，
  /// 二是让「加注」这个动作读不出牌力。
  double _valueRaiseChance(
      GameEngine game, PlayerState me, _Spot spot, HandReading read) {
    final medium = read.tier == HandTier.medium;
    var base = switch (game.street) {
      Street.flop => medium ? 0.24 : 0.15,
      Street.turn => medium ? 0.15 : 0.09,
      // 河牌加注只为价值，后面没有牌可发了：价值不够就老实跟注，
      // 别把「能跟注的牌」全拿去加注，跟注范围被打空更亏。
      _ => medium ? 0.06 : 0.03,
    };
    // 自己先过牌再被下注 = 过牌-加注，这是没位置时保护过牌范围的主力；
    // 没先过牌时（只是接着打）加注更容易撞上对手的真牌，频率要收着。
    //
    // 但过牌-加注是「强牌 + 听牌」的武器，不是一对弱牌的：拿底对/第二对
    // 去过牌-加注，打走的是更差的牌、留下来的全是更好的牌，等于把一手有
    // 摊牌价值的牌变成纯诈唬。以前这个倍率对所有牌力一视同仁，结果没位置
    // 的弱成牌加注率是有位置的 3 倍（实测转牌底对：没位置 8% vs 有位置
    // 2%），方向正好反了——没位置本来就该更少加注。
    if (!spot.checkedThisStreet || !medium) base *= 0.5;
    if (spot.opponents >= 2) base *= 0.35; // 多人底池别拿一对乱加
    if (spot.isThreeBetPot) base *= 0.7; // 3bet 底池大家范围都强
    base *= 1 - 0.6 * spot.villainStrength; // 对手线越强越少加
    // 对手小注更像阻挡注，值得抬回去；大注通常是真牌，别硬顶。
    base *= spot.betSizeRel >= 0.8 ? 0.45 : (spot.betSizeRel <= 0.35 ? 1.3 : 1.0);
    // 顶对是翻牌圈的主力价值牌，反击的频率本来就更高。
    if (read.topPair && game.street == Street.flop) base *= 1.3;
    base *= _aggression * _p.aggressionScale;
    return base.clamp(0.0, 0.5);
  }

  /// 后路分（0~1）：这手「现在没成牌」的牌还有多少成长空间。
  ///
  /// 真人不看「我现在是什么」，而看「我还能变成什么」——两张高张能长成
  /// 顶对，后门花能长成花听，转牌真到了就还能接着打；什么都没有的牌被
  /// 跟注就是纯亏。翻牌/转牌用它挑浮牌和开火牌，河牌没有后路（只有阻断
  /// 牌那一套），返回 0。
  double _backdoorScore(GameEngine game, HandReading read) {
    if (game.street == Street.river) return 0.0;
    var s = 0.0;
    if (read.overcards >= 2) {
      s += 0.45; // 六张 outs 成对，转牌还能继续打
    } else if (read.overcards == 1) {
      s += 0.15;
    }
    if (read.backdoorFlush) s += 0.35; // 后门花 = 转牌多一批「可打的牌」
    return s.clamp(0.0, 1.0);
  }

  /// 浮牌（float）频率：翻牌圈手里没有成牌、但还有后路时，不弃牌而是
  /// 跟一张看转牌的比例。松被动本来就很少浮，紧凶/LAG 才这么打。
  double _floatChance(GameEngine game, _Spot spot, HandReading read) {
    if (game.street != Street.flop) return 0.0;
    if (spot.opponents > 1) return 0.0; // 多人底池：后面还有人会加注
    if (spot.betSizeRel > 0.6) return 0.0; // 大注浮不动
    // 被人加注了还想浮牌：没位置时这是纯烧钱，直接放弃这条线。
    if (spot.villainRaisedThisStreet && !spot.inPosition) return 0.0;
    final back = _backdoorScore(game, read);
    if (back == 0) return 0.0;
    var f = 0.45 * back * _aggression * _p.aggressionScale;
    f *= 1 - 0.5 * spot.villainStrength;
    // 位置是浮牌的全部意义：有位置跟一张，转牌对手过牌就能把底池收走，
    // 成牌与否都能在后面两条街控池；没位置跟一张，是在不利位置陪人打
    // 后面两条街，成牌也榨不出价值。真人没位置几乎不浮牌（要么过牌-加
    // 注、要么直接放弃），之前两边频率完全一样（探针：有位置 25% vs
    // 没位置 26%），等于「位置」这个变量在这个决策里根本不存在。
    f *= spot.inPosition ? 1.4 : 0.25;
    return f.clamp(0.0, spot.inPosition ? 0.5 : 0.15);
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
  /// 价值下注的尺度。真人打价值不是只有一个尺寸：
  /// - 干面用小注（1/3 池那种），范围可以铺得很宽，也不怕被加；
  /// - 湿面用大注保护自己的成牌、同时收更多价值；
  /// - 多人底池往上抬（总有人会跟，价值要收满）；
  /// - 3bet 底池往回收（大家范围都很强、筹码又浅，小注分批把筹码放进去）。
  /// [rangeBet] 为真（翻牌圈）时干面才用「范围小注」；转牌河牌的干面
  /// 已经不需要再保护什么，真人会回到正常尺度收价值。
  double _valueFrac(_Spot spot, HandReading read, double frac,
      {bool rangeBet = false}) {
    var f = frac;
    if (read.texture.isDry) f *= rangeBet ? 0.62 : 0.85;
    // 人多加价，但别加太狠：加得太狠，同一局面下「价值牌下大注、诈唬下
    // 小注」就成了一条明线（对手看到小注就知道可以抬我们）。真人在多人
    // 底池是「下注频率收着、尺度照常」，不是靠尺度把牌力喊出来。
    f *= 1 + 0.08 * (spot.opponents - 1).clamp(0, 3);
    if (spot.isThreeBetPot) f *= 0.7;
    return f;
  }

  /// 诈唬 / 半诈唬的尺度：同样看牌面，但人多的时候要收敛
  /// （真人不会在一个五路底池里拿空气下大注）。
  double _stabFrac(_Spot spot, HandReading read, double frac,
      {bool rangeBet = false}) {
    var f = frac;
    if (read.texture.isDry) f *= rangeBet ? 0.7 : 0.9;
    // 人多了要收的是「诈唬的频率」，不是尺度：诈唬下得比价值小一大截，
    // 对手一眼就能从小注里读出「这枪是空的」。真人在多人底池里要么不诈唬，
    // 要么就用正常尺度诈唬。
    f *= 1 - 0.03 * (spot.opponents - 1).clamp(0, 3);
    if (spot.isThreeBetPot) f *= 0.6;
    return f;
  }

  /// 筹码全下（引擎会按合法动作自动变成下注或加注）。
  AiDecision _jam(PlayerState me) =>
      AiDecision(ActionType.bet, amountTo: me.streetBet + me.stack);

  /// 尺度混合：真人不会永远用一个尺寸——翻前开池、翻后下注都一样，
  /// 而是在「小一点 / 正常 / 大一点」之间换档。这既是真人的习惯，
  /// 也让对手没法靠下注尺度反推我们的牌力（固定尺度是最容易被抓的机器味）。
  ///
  /// 概率加权后平均是 ×1.015，所以整体尺度几乎不变，只是不再一条直线。
  double _mixSize(double frac) {
    final r = _random.nextDouble();
    if (r < 0.20) return frac * 0.85;
    if (r < 0.45) return frac * 1.18;
    return frac;
  }

  /// 下注到本街总额：底池的 [frac]（再按 [_mixSize] 换一次档）。
  AiDecision _bet(GameEngine game, PlayerState me, double frac) {
    final pot = game.potTotal();
    final add = max(game.config.bigBlind, (pot * _mixSize(frac)).round());
    return AiDecision(ActionType.bet, amountTo: me.streetBet + add);
  }

  /// 加注到本街总额：在当前最高注上再加一个底池比例（至少补足最小加注）。
  AiDecision _raise(GameEngine game, PlayerState me, double frac) {
    final pot = game.potTotal();
    final minRaise = game.minRaiseTo - game.currentBet;
    final add = max(minRaise, (pot * _mixSize(frac)).round());
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
    required this.villainRaisedThisStreet,
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
    required this.preflopOpenTo,
    required this.limpers,
    required this.priorAgg,
    required this.polarizedBet,
    required this.villainStrength,
    required this.villainTightness,
    required this.canRaise,
  });

  /// 我在什么位置（前位/中位/劫位/按钮/小盲/大盲）。
  final Seat seat;

  /// 翻前最后一个加注者在什么位置；没人加注时为 null。
  final Seat? raiserSeat;

  /// 这条街上对手主动加过注（不只是下注）。下注和加注是两码事：
  /// 只开一枪的人范围里还有一堆弱牌和诈唬，敢加注（尤其过牌-加注）的人
  /// 手里要么是很实的东西、要么是强听牌在打半诈唬——读范围时得分开算。
  final bool villainRaisedThisStreet;

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

  /// 翻前开池那一次的注额（「加注到」多少），拿不到时为 0。
  /// 判断第二个加注是「最小加注到 4bb」还是「真加注到 10bb」要用它：
  /// 只看绝对筹码分不出小 3bet 和大 3bet，而这两者的跟注范围差很远。
  final int preflopOpenTo;
  final int limpers;

  /// 对手在前面几条街已经在开火的累计强度（0~2）：
  /// 一条街一条街地砸过来，手里的东西和「只开一枪」完全不是一回事。
  final double priorAgg;

  /// 前面都过牌、这条街突然来的大注（转牌/河牌）：两极化的线，
  /// 大注在这里不代表牌力，跟注门槛不该按「大注 = 真牌」往上抬。
  final bool polarizedBet;

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
    var preflopOpenTo = 0;
    var limpers = 0;
    String? lastPreflopRaiser;
    for (final a in actions) {
      if (a.street != Street.preflop) continue;
      if (a.type == ActionType.raise) {
        // 第一次加注就是开池，记下它加到多少（AI 与英雄都会带上注额）。
        if (preflopRaises == 0 && a.amount > 0) preflopOpenTo = a.amount;
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
    var villainRaised = false;
    var checkedThisStreet = false;
    for (final a in actions) {
      if (a.street != game.street) continue;
      if (a.actorId == me.id && a.type == ActionType.check) {
        checkedThisStreet = true;
      }
      if (a.type == ActionType.raise && a.actorId != me.id) {
        villainRaised = true;
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

    // 读线：对手在前面几条街是不是一直在开火（每条街的价值递减，
    // 因为开火的人也可能是在连打三枪诈唬，但总体上范围强得多）。
    var priorAgg = 0.0;
    for (final a in actions) {
      if (a.street == Street.preflop || a.street == game.street) continue;
      if (a.actorId == me.id) continue;
      if (a.type != ActionType.bet && a.type != ActionType.raise) continue;
      priorAgg += a.street == Street.flop ? 1.0 : 1.3;
    }
    priorAgg = priorAgg.clamp(0.0, 2.0);

    // 转牌/河牌前面都没人开火，这条街突然砸一个大注：两极化的线
    // （坚果或空气），不能按「大注 = 真牌」去收紧跟注门槛——
    // 真人的超池一多半就是这么来的，拿中等牌抓他反而更划算。
    final polarizedBet = toCall > 0 &&
        priorAgg <= 0.01 &&
        betSizeRel >= 0.8 &&
        (game.street == Street.turn || game.street == Street.river);

    var vs = switch (preflopRaises) {
      0 => 0.25,
      1 => 0.5,
      _ => 0.85,
    };
    if (isPreflopAggressor && preflopRaises >= 1) vs -= 0.1;
    vs += 0.12 * villainAgg;
    vs += 0.07 * priorAgg; // 连着开火 = 这条线上真东西更多
    if (betSizeRel >= 0.9) vs += polarizedBet ? 0.02 : 0.1;
    final villainStrength = vs.clamp(0.1, 1.0);

    return _Spot(
      seat: PreflopRanges.seatOf(game, me),
      raiserSeat: raiserSeat,
      checkedThisStreet: checkedThisStreet,
      villainRaisedThisStreet: villainRaised,
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
      preflopOpenTo: preflopOpenTo,
      limpers: limpers,
      priorAgg: priorAgg,
      polarizedBet: polarizedBet,
      villainStrength: villainStrength,
      villainTightness: (0.55 + 0.45 * villainStrength).clamp(0.5, 1.0),
      canRaise: me.stack > toCall,
    );
  }
}
