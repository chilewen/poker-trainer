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
    this.overLimpMix = 0.0,
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

  /// 面对溜入者时，「边缘牌」改成跟着溜入（over-limp）而不是加注的比例。
  ///
  /// 真人在后面有人溜入时不是「加注或弃牌」两档：小对子、同花连张这类
  /// 有隐含赔率、但翻后不好打的牌，很多人宁可便宜看翻牌，把加注留给
  /// 真正能拿价值的牌。旧逻辑里紧凶/松凶在按钮位的跟注率是 0%（见
  /// [_openOverLimp]），对手读几手就能确定「他跟进池 = 他加注过 = 他牌很
  /// 强」；而跟注站反倒成了唯一会溜入的风格，一眼假。
  final double overLimpMix;

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
  overLimpMix: 0.60,
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
  callSlack: 0.42,
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
  overLimpMix: 0.40,
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

  /// 「对手有多疯」的连续量：0 = 闷不吭声/正常，1 = 逮到机会就往里砸。
  ///
  /// 跟 [_facingManiac] 共用 0.45 那条线（我们的松凶自己才 0.40，能过线的
  /// 就是真疯子），只是把布尔换成斜坡：河牌防守下限要跟着它连续回调，不能
  /// 在某一个进攻率上换一整套打法——真人对付不同脾气的人是渐变的。
  double _maniacWiden(GameEngine game, PlayerState me) {
    final reads = _readsOf(game, me);
    if (reads.isEmpty) return 0.0;
    var sum = 0.0;
    for (final r in reads) {
      sum += ((r.aggroRate - 0.45) / 0.15).clamp(0.0, 1.0);
    }
    return sum / reads.length;
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
      // 前面已经有人溜入：非同花牌容易被后面压制，溜进来的人越多收得越紧。
      //
      // 以前这里是一个布尔台阶（`>= 2 ? 2 : 1`）：1 家溜入收一档，2 家以上
      // 一刀两档，而且 2/3/4/5 家**全是同一个数**——对手把溜入人数从 2 加到 5，
      // 我们的开池范围一个字都不动。探针实测（tool/ai_preflop3bet_probe.dart
      // 第五节：8 人桌、AI 钉在按钮、桌子大小和座位固定，只让已溜入家数变）
      // 就是这个读数。现在按人数一档一档收，4 档封顶（再往后这些非同花牌
      // 本来也早出范围了）。
      if (spot.limpers > 0) {
        openRange = openRange.shiftedOffsuit(min(4, spot.limpers));
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
        // 边缘牌跟着溜入，而不是一律加注（见 [_Profile.overLimpMix]）。
        //
        // 探针实测（9 人桌按钮位、前面两家溜入、169 种起手牌各 60 手）：
        // 紧凶「加 54% / 跟 0% / 弃 46%」，松凶「加 74% / 跟 0% / 弃 26%」——
        // 两种风格在按钮位一次都不跟注，而唯一会溜入的松被动反过来成了
        // 异类。真人不是这样：22~66、54s~98s 这种牌在后面有人溜入时
        // 一半加注一半跟着看翻牌，这正是他们「范围读不出来」的原因。
        //
        // 加注留给真正该拿价值的那一段（大牌、88+ 的中大对子、A 带大
        // 踢脚，见 [_overLimpHand]）；其余的开池牌按比例改成补齐——
        // 小对子、同花连张、A2s~A7s、K9s 这类牌正是真人会便宜看翻牌的。
        if (spot.limpers > 0 &&
            _p.overLimpMix > 0 &&
            _overLimpHand(hand) &&
            _roll(_p.overLimpMix)) {
          return const AiDecision(ActionType.call);
        }
        return AiDecision(ActionType.raise,
            amountTo: _openSize(game, bb, spot.limpers, seat));
      }
      // 溜入 / 补齐：位置越好、价格越便宜越愿意；跟注站几乎什么都跟。
      // 但「开门溜入」（前面还没人进池）和「跟在别人后面溜入」是两个
      // 场合：前者的正确动作是加注或弃牌，标准风格只有小盲补齐值得做
      // （见 [PreflopRanges.limpOpen]）。本来就爱溜入的松被动照旧走宽范围。
      final cheap = toCall <= bb;
      final openLimp = spot.limpers == 0 && !_p.limpsAnyPrice;
      final standard = PreflopRanges.limp(seat).shifted(_p.limpShift + w);
      final midLimp = PreflopRanges.limpMid(seat).shifted(_p.limpShift + w);
      // 两家以上溜入、又不是跟注站：走「中间档」——标准表之外再把非同花
      // 连张 / 非同花大牌 / 弱 A 捞回来，让它们能用便宜价格补着看翻牌。
      // 1 家那一档照旧用标准表（锚点不动）。
      final useMid = !openLimp && !_p.wideLimp && spot.limpers >= 2;
      final limpRange = openLimp
          ? PreflopRanges.limpOpen(seat).shifted(_p.limpShift + w)
          : (_p.wideLimp
              ? PreflopRanges.limpLoose(seat).shifted(_p.limpShift + w)
              : (useMid ? midLimp : standard));
      if (limpRange.contains(hand) && (cheap || _p.limpsAnyPrice)) {
        // 中间档独有的那批牌（非同花连张 / 大牌 / 弱 A）只按比例进来：溜入
        // 的人越多越愿意补，但永远留一部分弃牌。不然它只是从「一律弃」换成
        // 「一律补」——台阶换了个位置，读起来还是一句话。
        //
        // 探针实测（同一节）：改之前这批牌在 2 家往上是一律弃（87o 弃 100%、
        // A8o/KQo 在 4 家也是弃 100%），而标准表里根本没有它们的位置。
        if (useMid && !standard.contains(hand)) {
          final midMix = (0.45 + 0.12 * (spot.limpers - 2)).clamp(0.0, 0.9);
          if (!_roll(midMix)) return const AiDecision(ActionType.fold);
        }
        return const AiDecision(ActionType.call);
      }
      return const AiDecision(ActionType.fold);
    }

    final raiserSeat = spot.raiserSeat ?? Seat.btn;

    // ---- 面对 3bet 及以上：只打顶端，深筹码+有位置才用跟注范围 ----
    if (raises >= 2) {
      final premium = hand.isPair && hand.high >= Rank.king.value; // AA / KK
      // 这一次 3bet 要价多少 bb。跟注范围和轻 4bet 两处都要用它看价格，
      // 提到这里算一次（下面「最小加注还是加三倍」那段用的是同一个值）。
      final threeBetBb = game.currentBet / bb;
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
      //
      // 但这个频率得跟着价格走。以前它是个常数，探针实测
      // （tool/ai_preflop3bet_probe.dart）A5s 对着 4.7 / 7.0 / 9.0 / 14.0bb
      // 一律「加注 28%」——9bb 和 14bb 那两行的弃牌率甚至逐字相同。对手
      // 只要把 3bet 加到 14bb，就能稳定地拿 AA/KK 从我们身上收下两成八个
      // 30bb 的 4bet：我们要投的筹码翻了三倍，而敢加到 14bb 的范围本身就实
      // 得多（弃给我们 4bet 的比例低得多），两头的期望一起往负的走。
      //
      // 锚点跟 [priceyShift] 用同一个「10bb 以上才算贵」的门槛：14bb 收到
      // 基频的两成——不归零是因为 A5s 的阻断牌价值不随价格消失，真人对着
      // 大 3bet 也会零星空压一把，只是不再是两成八。
      final lightFourBetPrice =
          0.2 + 0.8 * ((14.0 - threeBetBb) / 4.0).clamp(0.0, 1.0);
      // 但贵那侧收完之后，「10bb 以下不动」自己又成了常量区间：探针实测
      // （tool/ai_preflop3bet_probe.dart 第四节，四个点位逐字相同）A5s 对着
      // 4.7 / 6.2 / 8.0 / 10.0bb 一律「加注 28%」——三种风格全一样（紧凶
      // 28%、松凶 55%）。可 4.7bb 那档 4bet 出去只要投十几个 bb，14bb 那档
      // 要投三十个：上面那条「贵了要收」的理由（投进去的钱跟着价格翻倍）
      // 在便宜那头是反过来成立的，压回去的成本越低越该压。对手把 3bet 从
      // 5bb 加到 10bb、看我们的 4bet 频率一动不动，就能白拿到「3bet 更贵
      // 但还是一样的弃牌率」。
      //
      // 补法是「往上限靠」而不是乘系数：松凶实测已经在 55%（比上限还高），
      // 再乘一个 >1 的系数会把它顶到七八成。所以拿离 45% 上限的余量、
      // 按便宜程度补四成——紧凶那头 4.7bb 补到约 35%，松凶那头因为余量是
      // 负的（已经被 clamp 成 0）一个点不动。
      final lightCheapRamp = ((10.0 - threeBetBb) / 5.5).clamp(0.0, 1.0);
      final lightFourBetChance =
          _p.lightThreeBet * 2.5 * _bluffiness * lightFourBetPrice;
      final cheapHeadroom =
          (0.45 - lightFourBetChance).clamp(0.0, 1.0) * 0.4 * lightCheapRamp;
      // 但 14bb 往上又是一段平台：探针实测（tool/ai_preflop3bet_probe.dart
      // 第四节）A5s 对着 14 / 16 / 18 / 20bb 四行逐字相同的「加注 6%」——
      // 对手把 3bet 从 14bb 抬到 20bb，我们 4bet 出去要投的筹码从三十个涨到
      // 五十几个，敢加到 20bb 的范围又硬得多（弃给我们 4bet 的比例低得多），
      // 两头的期望一起往下走，频率却一个点不动。所以贵那侧接着收：
      //
      //   1 / (1 + 0.9 * (threeBetBb - 14) / 8)
      //
      // 故意用倒数，而不是「收到某个地板就夹住」：夹住等于在 22bb 又造一段
      // 平台，可 14bb 往上本来就是因为「越贵越该收」才动的，没理由在某个数
      // 上停下来。这条曲线一路往零收但收不到零——A5s 的阻断牌价值不随价格
      // 消失，真人对着再大的 3bet 也会零星空压一把。20bb 收到六成、22bb 收
      // 到一半、50bb 只剩两成；≤14bb 因子恒为 1，便宜侧那条斜坡和 14bb 这个
      // 锚点逐点不变。
      final lightExpensiveRamp =
          1 / (1 + 0.9 * ((threeBetBb - 14.0) / 8.0).clamp(0.0, 64.0));
      if (_p.lightThreeBet > 0 &&
          toCall < me.stack * 0.4 &&
          PreflopRanges.isLightFourBetHand(hand) &&
          _roll((lightFourBetChance + cheapHeadroom) * lightExpensiveRamp)) {
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
      // 「便宜的 3bet」这一档以前写成 `<=5.5bb 或者 <=2.2 倍开池` 两个硬条件
      // 的或，一过界就整档换范围。可开池尺度本身是混合的（同一个 3bet 到
      // 620，撞上 335 的开池只是 1.85 倍、撞上 242 的却是 2.56 倍），于是
      // 边界两边成了两个世界：探针实测同一手 KQo 对着 620 跟 82%、对着 640
      // 跟 37%，只差 20 个筹码。真人不会在某个 bb 数上换一整套跟注范围。
      //
      // 现在两个条件各自铺成斜坡、取更便宜的那一侧（原来那个「或」的
      // 等价写法）：[5.5, 6.5]bb 与 [2.2, 2.45] 倍开池。两个端点跟以前逐点
      // 一致——≤5.5bb、≤2.2 倍开池仍然是满便宜档，≥6.5bb 且 ≥2.45 倍开池
      // 仍然是正常档，只有中间这一小段从「便宜档」连续过渡到「正常档」。
      // （比例项用 [currentBet] 而不是 [toCall]：盲注位已经投过的钱不该在
      // 这里再算一次折扣，原来的条件比的就是 currentBet。）
      final cheapRamp = max(
        ((6.5 - threeBetBb) / 1.0).clamp(0.0, 1.0),
        spot.preflopOpenTo > 0
            ? ((2.45 - game.currentBet / spot.preflopOpenTo) / 0.25)
                .clamp(0.0, 1.0)
            : 0.0,
      );
      final smallThreeBet = cheapRamp >= 1.0;
      // 大 3bet 的另一头：加到 12bb 以上（或者要价超过 10bb）时，中等对子
      // 和同花大牌是负期望——跟 11bb 去抢一个 19bb 的底池要 37% 赔率，
      // 99/JTs 对着一个 4.7 倍的 3bet 范围、还没位置，根本实现不了这个
      // 胜率。收回两档正好落在 JJ+ / AKs / KQs / AKo。
      // 只有没位置才收这一档：面对盲注位的 3bet，对方的范围又宽又虚，
      // 大尺度说明不了什么，有位置照样该用整个跟注范围接。
      //
      // 但「收」不能是个开关。以前这里写成 `threeBetBb >= 12 || toCall >= 10bb`：
      // 那条件一过就整档收紧两档，于是 99 对着 11.9bb 的 3bet 跟 100%、
      // 对着 12.0bb 弃 100%——只差 10 个筹码，中间没有任何过渡。对手把
      // 3bet 加到门槛以上就能直接收走底池，压在门槛下面又几乎必被跟，
      // 跟注范围成了对手可以精确挑的开关（[ai_preflop3bet_probe] 扫 8~16bb
      // 量出来的就是这一刀）。真实玩家的跟注率是随价格连续往下走的。
      //
      // 现在把两个条件合成一把「实际要价」的尺子（盲注位已经投过钱，
      // toCall 比名义 3bet 小，所以要各自折成「站直了看这一注多少钱」）：
      // 旧门槛正好落在 priceBb = 12，过渡就铺在 10~12 这一段，从「不收」
      // （0 档）线性走到「收满」（2 档）——门槛那一点的值跟以前完全一样。
      // 整数部分直接收紧范围，小数部分按概率多收一档。priceBb <= 10 和
      // >= 12 跟以前逐点一致，只有那道门槛下面 2bb 的窄带变成斜坡。
      final priceBb = max(threeBetBb, toCall / bb + 2.0);
      final priceyShift = (!spot.inPosition && !smallThreeBet)
          ? (priceBb - 10.0).clamp(0.0, 2.0)
          : 0.0;
      final priceyFloor = priceyShift.floor();
      final priceyExtra = priceyShift - priceyFloor;
      // 多人池那一档（冷跟让买三条更值）用的还是旧门槛本身，不然它会跟
      // 上面那条过渡叠在一起、跳得比原来还狠。
      final pricey = !spot.inPosition && !smallThreeBet && priceBb >= 12.0;
      // 池里已经有别家跟注进了池（冷跟 3bet、或者跟了开池又没走）：我们是
      // **关着门**看翻牌、价格便宜、还多一家陪着进底池，投机牌（小对子买三
      // 条、同花连张）的隐含赔率比单挑好一截——真人这时候跟得明显比单挑宽。
      // 以前这一档完全不看人数：探针实测 22~88、98s 在单挑和四路底池里一模
      // 一样（都是弃 100%），开池方被 3bet 之后池里几家跟进对它毫无影响。
      // 小 3bet 那两档本来就宽到离谱，不动；[pricey] 的大 3bet 也不放宽。
      final multiwayCall = spot.coldCallers >= 1 && !pricey;
      // 其它风格：有位置才用整个跟注范围（含投机牌），没位置只跟有牌力的。
      final cheapRange = spot.inPosition
          ? PreflopRanges.callThreeBetSmall
          : PreflopRanges.callThreeBetSmallOop;
      final normalRange = multiwayCall
          ? PreflopRanges.callThreeBetMultiway
          : (!spot.inPosition
              ? PreflopRanges.callThreeBetOop
              : (stackBb >= 200
                  ? PreflopRanges.callThreeBet
                  : PreflopRanges.callThreeBet.withoutSmallPairs()));
      final callRange = station
          ? PreflopRanges.callThreeBetStation
          : (smallThreeBet ? cheapRange : normalRange);
      final shifted = callRange.shifted(w + priceyFloor);
      // 过渡区间里的那一小截按概率生效：有 [priceyExtra] 的机会按**再收紧
      // 一档**的范围判定，否则按 floor 那一档。这样边缘牌（99、KQs…）在
      // 10~14bb 之间是「越贵越少跟」，而不是到某个整数 bb 就整档消失。
      // （收紧档是 floor 档的子集，所以必须二选一，不能「先看宽的、再看窄
      // 的」——那样窄档永远被宽档盖住，等于没过渡。）
      // 斜坡带里的那一小截（[cheapRamp] 在 0~1 之间）：按这个概率拿便宜档
      // 的范围判定，两边都是连续的了。跟注站本来就不看价格，不参与。
      final inCallRange = !station &&
              !smallThreeBet &&
              cheapRamp > 0 &&
              _roll(cheapRamp)
          ? cheapRange.shifted(w).contains(hand)
          : (priceyExtra > 0 && _roll(priceyExtra)
              ? callRange.shifted(w + priceyFloor + 1).contains(hand)
              : shifted.contains(hand));
      // 投机的那一半（小对子 / 同花连张）混着跟：真人对这些边缘牌不是
      // 每次都跟，一部分直接弃，跟注范围才不会宽到对手一开火就收走。
      // 松的性格跟得多一点（_looseness 0.9~1.15）；池里每多一家进池，
      // 「买三条」这种牌就多值一点（这也是下面 [multiwayCall] 的另一半）。
      final specFreq = ((station ? 0.6 : 0.45 + (_looseness - 0.9) * 2.0) +
              0.2 * spot.coldCallers)
          .clamp(0.3, 0.95);
      final deepCall = !shortStack &&
          stackBb >= 80 &&
          toCall <= me.stack / 3 &&
          inCallRange &&
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

    // 范围表是按「正常人」排的：位置越靠后越宽，但总有个底。碰上被读成
    // 疯子的对手（见 [_maniacWiden]）这套卡尺就不适用了——他本来就会用
    // 任何两张牌开池/加注，范围之外那些牌不该只剩 0.06。这一项塌下去，
    // 后面 `lineAgg` 那一段把空气收得再松也补不回来：对手的范围里根本
    // 没有牌可以代表他在诈唬，算出来的胜率自然还是「他一路开火 = 我死」。
    //
    // 探针实测（tool/ai_river_defense_probe.dart，同一个 AI 连着打、读牌
    // 已生效）：光放开 `lineAgg` 之后，湿润面 2/3 池的 ★ 已经消失（弃 41%
    // vs 保本线 40%），但配对面 2/3 池还挂着 ★ +13pt——那一格 AI 手里是
    // 「弱成牌」档（42 手弃了 40 手），它们的胜率全是靠翻前范围表算出来的，
    // 而那张表里根本没有疯子会用 7x、8x 之外的垃圾开三枪这回事。
    //
    // 这一项单独跳出来量过，别只信默认的 6000 手（那点数不够，正负十来个点
    // 就把结论淹了）：`dart tool/ai_river_defense_probe.dart 30000`，河牌
    // 2/3 池、对手连开三枪，有/无这一项分别是 干燥 22% / 25%、湿润 32% / 42%、
    // 配对面 40% / 55%（不加这一项配对面就是 ★+16pt）。
    final maniacWiden = _maniacWiden(game, me);

    /// 这手底牌出现在对手翻前范围里的权重（0~1）。
    double preflopWeight(List<Card> hole) {
      final h = PreflopHand.of(hole);
      final double raw;
      if (spot.preflopRaises >= 2) {
        // 3bet 底池：要么是再加注的顶端牌力，要么是跟注 3bet 的投机牌。
        if (PreflopRanges.valueThreeBet(raiserSeat).contains(h)) {
          raw = 1.0;
        } else {
          raw = PreflopRanges.callThreeBet.contains(h) ? 0.3 : 0.06;
        }
      } else if (spot.preflopRaises == 1) {
        // 对手是主动开池的人 → 用开池范围；对手是跟注的人 → 用冷跟范围。
        final range = spot.isPreflopAggressor
            ? PreflopRanges.coldCallRange(seat: Seat.bb, inPosition: true)
            : PreflopRanges.open(raiserSeat);
        if (range.contains(h)) {
          raw = 1.0;
        } else {
          // 范围内侧一点点的牌（轻 3bet / 便宜跟注）还留一点点可能。
          raw = PreflopRanges.isLightThreeBetHand(h) ? 0.25 : 0.06;
        }
      } else {
        raw = 0.65; // 溜入底池：范围宽得像个谜，但不是随机牌
      }
      // 读牌越强，范围外的牌权重越往 1 靠（顶格时 0.06 → 0.48）。
      // 正常对手 maniacWiden = 0，逐点不变。
      return raw + (1.0 - raw) * 0.45 * maniacWiden;
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
    // 「连着几条街开火 = 真东西更多」这条读线也有前提：对手是个正常人。
    // 碰上被读成疯子的对手（见 [_maniacWiden]），他开三枪说明的东西少得多
    // ——这正是「读人」和「读牌」必须接上的那一处。
    //
    // 以前这两条是完全脱钩的：跟注门槛那边早就按 [read] 放宽了
    // （`_callVsReadFactor`），可胜率估计用的范围还是照「三枪 = 硬货」一路
    // 收紧。于是 AI 的行为成了「翻牌跟得宽、河牌算出来自己还是垃圾」——
    // 探针实测同一个对手连开三枪（读牌已生效、每格 heroAggro = 1.000），
    // 河牌面对 2/3 池照旧弃 53%、配对面 1/2 池照旧弃 50%，而对手拿任意
    // 两张的保本弃牌率只有 40% / 33%。
    //
    // 折扣比例跟 [floorShape] 那条斜率用同一个 0.7：都是「读成疯子之后，
    // 这条线上的信息量打掉七成」，免得两个地方各拍一个数、以后对不上。
    final lineAgg = (spot.priorAgg +
            (spot.facingBet ? 0.8 : 0.0) +
            (facingRaise ? 0.7 : 0.0)) *
        (1 - 0.7 * maniacWiden);
    // 下注尺度是单独一维信息，不能只靠「开过几枪」来收范围：真人看到大注
    // 会把对手的弱牌权重整个往下压（一个满池里诈唬的比例远低于 1/4 池），
    // 看到小注则留着那一整片弱范围去抓。以前范围模型完全不吃尺度——同一
    // 个牌面上的 1/4 池和满池被当成同一条线，算出来的胜率一模一样，于是
    // 「注越大跟得越少」只能靠跟注门槛去补；补不动的时候就成了探针里那种
    // 「第二对面对 2/3 池和面对满池的跟注率都是六成」。
    // 只在面对下注时算（面对加注已经有 [facingRaise] 那一维）。
    // [polarizedBet] 那条线要打折：前面几条街都没人开火、这条街突然砸出来
    // 的大注本来就是「坚果或空气」的两极线，范围里一半是诈唬，按尺度硬收
    // 就等于把自己最该抓的那条线一起收掉了。但也不能完全不收——真人的超池
    // 再两极，2 倍池里的诈唬比例还是低于刚够到这条线的 1 倍池，所以折扣
    // 随尺度递减（这也让「同一条线里注越大跟得越少」继续成立）。
    // 这个折扣和上面 `(betSizeRel - 0.35)` 的**饱和点必须对齐**：后者在
    // 1.2 池处封顶（0.85），折扣以前却一路掉到 0.10 的地板（2.13 池才停），
    // 两者的乘积从 1.2 池往上反而变小，也就是「注越大，对手范围里留的空气
    // 越多」——1.2 池留 0.50、1.5 池 0.58、2 池 0.71、2.5 池 0.74。一个
    // 2 倍池的两极线被读得比 1.2 倍池还弱，中等牌那一档因此面对任何超池都
    // 照跟（探针实测顶对好踢 0.4~2.5 池全是 99~100%，尺度这一维整个失效）。
    // 折扣只收到 1.2 池为止，两个乘子一起饱和，保留的空气才是单调的。
    final sizeDiscount = spot.polarizedBet
        ? 0.5 - 0.30 * (spot.betSizeRel - 0.8).clamp(0.0, 0.4)
        : 0.5;
    final sizeAgg = spot.facingBet
        ? (spot.betSizeRel - 0.35).clamp(0.0, 0.85) * sizeDiscount
        : 0.0;
    final airKeep = (1 - 0.22 * lineAgg - sizeAgg).clamp(0.18, 1.0);
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
        // 河牌那一档以前是死数 0.12，跟「这一注下得多大」完全无关：同一手
        // A 高算出来对 1/4 池和对 1/2 池的胜率一模一样（实测都在 0.12 上
        // 下），「注越小他越可能在诈唬」这条最直观的读牌信息根本没进模型。
        // 于是「A 高抓小注」只能靠跟注门槛那边打折扣去补，补不动的时候
        // 就成了「1/4 池跟四成、1/2 池一个都不跟」——对手把注抬一点点就能
        // 把我们的抓诈唬范围清空。
        //
        // 一个 1/4 池的河牌下注里，诈唬占的比例天然高于一个满池：前者要
        // 赢的正是「你弃牌」那一份，代价只有 1/4 池。所以空气权重按尺度
        // 连续给：1 倍池正好还是 0.12（跟以前逐点一致），往下线性加到
        // 0.24（0 池）。实测这一项把 A 高对 1/2 池的胜率从 0.12 抬到
        // 0.22 上下，跟 1/4 池那档终于不是同一个数了。
        final airBase = street == Street.flop
            ? 0.4
            : (street == Street.turn ? 0.25 : 0.12);
        final smallBetAirBonus =
            (street == Street.river && spot.facingBet && !facingRaise)
                ? 0.12 * ((1.0 - spot.betSizeRel) / 1.0).clamp(0.0, 1.0)
                : 0.0;
        keep = (airBase + smallBetAirBonus) *
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
    //    但门槛不能是一刀切，跟 [_facingBet] 里那两条同理：推的频率要跟
    //    SPR 连续。以前这里是两道硬门槛，探针把 stack 扫成一排 SPR 量到
    //    （3bet 池、河牌被过牌到、翻牌/转牌各下 1/2 池被跟）：
    //      · 顶对顶踢 SPR 0.89 全下 72%、1.25 全下 31%，SPR 1.75 一次都
    //        不推了（下注里最高只剩 125% 池、且不是全下）；
    //      · 两对 97 同一条线 SPR 2.35 还推 9%、2.85 完全收掉。
    //    推的频率在两个相邻 SPR 之间整段翻转，对手只要把底池控制在闸门
    //    两侧，就能稳定收到全下、或者永远收不到。
    //    改成斜坡之后，没推的那部分自然落回下面本来就有的价值下注线
    //    （怪兽大注 / 强牌 [_valueFrac]），加注频率基本不掉，只是不再用
    //    「全下」这个尺寸。
    //
    //    门槛不看人数（[_facingBet] 里那条会）：被过牌到时对手还没有露出
    //    牌力，能跟全下的范围比「面对下注」那条线宽得多，所以这里沿用单挑
    //    的 1.5。斜坡的形状跟 [_facingBet] 的 monsterJamRamp / jamRamp
    //    一致：加到只能算最小加注时满推，往上线性收到门槛处为 0。
    final checkedMonsterJam = ((2.5 - spot.spr) / 1.5).clamp(0.0, 1.0);
    if (spot.spr <= 2.5 &&
        read.tier == HandTier.monster &&
        _roll(checkedMonsterJam)) {
      return _jam(me);
    }
    final checkedStrongJam = ((1.5 - spot.spr) / 1.0).clamp(0.0, 1.0);
    if (spot.spr <= 1.5 &&
        read.tier == HandTier.strong &&
        _roll(checkedStrongJam)) {
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
      // 用不用超池还要看**成色**。超池是「坚果或空气」的尺寸：诈唬那一侧
      // 只有坚果花阻断 / A 阻断那条线会用（见 [_bluffChance] 后面那段），
      // 价值这一侧也该只留给三条/顺子这种被跟了也不心疼的牌——真人拿薄
      // 两对在河牌做的是正常尺寸的价值注，超池是拿它去撞两对以上的范围。
      // 以前这一档只看 tier，探针实测河牌被过牌到，拿两对、三条、顺子
      // 的下注分布**逐字相同**（超池桶都占 38%），对手看到超池读不出我们
      // 是两对还是顺子，我们自己也拿两对乱超池。以三条（0.6）为基准往外
      // 拉，跟 [HandReading.monsterGrade] 同一套取值。
      final overbetChance =
          (0.5 + 0.75 * (read.monsterGrade - 0.6)).clamp(0.15, 0.8);
      if (river &&
          !multiway &&
          !_villainFoldsALot(game, me) &&
          _roll(overbetChance)) {
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
      // 多人池里的控池档。
      //
      // 上面四条过牌档（翻牌没位置、转牌非空白牌、河牌、河牌超池）全都挂着
      // !multiway，于是三人池以上强牌是「过牌到我 = 100% 下注」——探针实测
      // 翻牌被过牌到，顶对顶踢/超对在 2/3/4/5 人池里都是 100% 下注，而且
      // 尺度还随人数往上抬（0.63 → 0.78 倍池）。加上这条控池档之后同一个
      // 探针（tool/ai_multi_probe.dart 的 B 节，翻前一律让 AI 补齐）量到
      // 顶对顶踢 100/90/79/71%、超对 100/94/90/85%，尺度 0.65 → 0.79 池。
      // 真人在五人湿面上拿一对不会
      // 每手都开火：后面还坐着三家，两对/三条/听牌都在，被加注就得弃；
      // 更要命的是我们的过牌范围从此清一色是没牌，一过牌对手拿任意两张牌
      // 都能收走底池，而过牌-加注这条线永远轮不到我们。
      //
      // 收的频率跟着「人越多、牌面越湿、越靠后」走；底池已经很大（SPR ≤ 3）
      // 或者对手爱弃牌时少收——那时候筹码该往里放。
      if (multiway) {
        var multiCheck = 0.10 * (spot.opponents - 1).clamp(0, 4) *
            (0.55 + 1.1 * texture.wetness);
        multiCheck *= switch (game.street) {
          Street.flop => 1.0,
          Street.turn => 0.65,
          _ => 0.5,
        };
        if (spot.spr <= 3) multiCheck *= 0.5;
        if (_villainFoldsALot(game, me)) multiCheck *= 0.6;
        if (_roll(multiCheck)) return const AiDecision(ActionType.check);
      }
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
      // 河牌也要留一档过牌。翻牌（没位置的强牌）和转牌（非空白牌）都已经
      // 有这一档，只有河牌是漏的：探针实测「河牌顶对（无人下注）」下注
      // 100%、过牌 0%。对手看到我们河牌一过牌就知道手里没东西，随便一枪
      // 就能把底池收走；我们的强牌也永远只有「下注 → 被跟注」这一种结局，
      // 对手的诈唬和薄价值没有机会自己送上门，过牌范围更是清一色空气。
      // 发出来的牌越像帮到跟注方（第三张同花 / 公对面 / 高张，也就是
      // [_isBlankCard] 判不出的那些），越该收手——那正是对手会过牌-加注
      // 我们的地方。
      if (river &&
          !multiway &&
          !_villainFoldsALot(game, me) &&
          _roll(_isBlankCard(game) ? 0.12 : 0.26)) {
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
          valueFactor *
          _strongDrawSizeScale(game, spot, read);
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

  /// 是不是「跟着溜入比加注更自然」的牌。
  ///
  /// 判据不是「牌力弱」而是「牌型不对」：真正该加注拿价值的那一段是
  /// 大牌（两张都 T 以上）、88+ 的中大对子、A 带大踢脚；剩下的开池牌
  /// （小对子、同花连张、A2s~A7s、K9s 这一类）在后面有人溜入时，真人
  /// 一半会加注、一半会便宜看翻牌——留一段跟着溜入，对手才读不出
  /// 「他没加注 = 他牌弱」。
  bool _overLimpHand(PreflopHand h) {
    if (h.isBroadway) return false;
    if (h.isPair) return h.high <= 7;
    if (h.isAce) return h.low <= 7;
    return true;
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
    // 多人底池这一刀砍的是「弃牌率」：人越多，一注打走所有人的概率越低，
    // 纯靠弃牌率才成立的半诈唬（卡顺）就越该收手。
    //
    // 但它不该对所有听牌一视同仁。8 outs 以上的花听/两头顺、花顺双听、
    // 坚果花听本身有成牌概率兜底——多人池里下注是在「按胜率把钱放进去」，
    // 被一两家跟注照样有利可图，走的是价值和留后路那条线，不是纯诈唬。
    // 以前这里统一砍到 0.3：探针实测（花听 AKs on Qh7h4c、所有人都过牌到
    // 按钮的 AI）4 人池只下注 22%。真人拿这种牌在多人池里照样要打——不打
    // 的话开火范围里清一色是成牌，对手一见我们过牌就知道没东西。
    final strongDraw =
        read.drawOuts >= 8 || read.isComboDraw || read.nutFlushDraw;
    if (spot.opponents >= 3) {
      // 第三家往后接着摊薄（见 [_manyTail]）：五家、六家池不该跟四家池
      // 一个频率。
      base *= (strongDraw ? 0.55 : 0.3) * _manyTail(spot.opponents, 3);
    } else if (spot.opponents == 2) {
      base *= strongDraw ? 0.8 : 0.6;
    }
    // 第二枪的「抵抗」折扣：翻牌开一枪被跟之后，对手的范围已经往「有牌」
    // 那边筛过一轮，这条线上的半诈唬要么被跟（outs 还在，但要按更差的
    // 价格买），要么被加注（更难接）。[villainCalls] 记的就是「我开火、
    // 他跟」的条数，[_bluffChance] 里早就按同样的 0.20/街 打过这个折，
    // 只有听牌这一条路一直没算。
    //
    // 2000 手对拍（破坚果花听 Ah Jh on Kh7h2c9s3d，英雄一路过牌/跟注，
    // 两条线只差「翻牌这一枪有没有被跟」）里，改前两行的转牌开火率是
    // **逐个数字相同**的 78%，花听+卡顺同样 85% 对 85%——对手跟没跟过
    // 在这条线上完全不进公式；而同一张牌面上顶对的价值下注是 79%：听牌
    // 和成牌在第二枪上并排，探针 150 手读数就是「转牌 80%、顶对 80%」。
    // 真人在这儿会收：转牌再开一枪被加注就得弃，outs 的价钱也比翻牌
    // 那一枪差（翻牌两张牌可看，转牌只剩一张）。
    //
    // 收 0.20/街之后（同 2000 手）花听从 78% 掉到 63%、花听+卡顺从 85%
    // 掉到 76%，顶对 79% 一动不动：听牌仍然明显比纯空气（探针 23%）敢打，
    // 但不再和成牌齐平，跟注方拿一对跟到底也不再是白赚。
    if (spot.villainCalls > 0) {
      base *= 1 - 0.20 * spot.villainCalls;
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
    // 底对得和「第二对 / 被盖过的口袋对」分开：底对在大多数牌面上只赢诈唬，
    // 河牌打出去被跟注基本就是白付钱。以前两档共用 0.42，探针实测「河牌
    // 第二对（无人下注）」和「河牌底对（无人下注）」连下注尺度的分布都逐桶
    // 一样（都是 30% 下注）——同一份随机数、同一个概率，牌力在这一档上等于
    // 没有刻度。给底对单独降一档，第二对留在原位。
    final boardMin = game.board.isEmpty
        ? 0
        : game.board.map((c) => c.rank.value).reduce(min);
    final bottomPair = !read.pocketPair && read.pairRank <= boardMin;
    var f = switch (read.tier) {
      // 顶对好踢 / 第二对好踢 / 中间对子（超对被盖过的那种不算）
      HandTier.medium => read.topPair ? 0.78 : 0.50,
      // 顶对弱踢 / 底对 / 被盖过的口袋对
      _ => read.topPair ? 0.65 : (bottomPair ? 0.30 : 0.42),
    };
    if (river) f *= read.topPair ? 0.8 : 0.7; // 河牌后面没有牌了，收敛一点
    // 「他一路跟过来」是这条街上最强的一条信息，薄价值却一直没读它：固定牌面
    // 实测（Qd 7d 2c 5h 9s、翻前我开池、翻牌/转牌我开不开枪由脚本钉死）中对 88
    // 的河牌下注率是「没跟过 29% / 被跟一条街 30% / 被跟两条街 30%」逐点相同
    // ——真人在那儿基本就是过牌：中对、底对打出去，更好的牌跟、更差的牌弃，等
    // 于白送一个底池。诈唬那一侧早就在按 [spot.villainCalls] 收（每跟一条
    // ×0.8），薄价值这侧接上同一条读数、只是收得更狠——被跟越多越该退成摊牌
    // 牌。顶对不在此列（见用例「第三枪：…（价值下注不动）」）；超对也进不到
    // 这一档（它是 HandTier.strong，走上面第 5 档那条成牌主力线）。翻牌街
    // [villainCalls] 恒为 0（只数翻牌/转牌），所以这一项只在转牌和河牌上动。
    if (!read.topPair) f *= 1 - 0.30 * spot.villainCalls;
    // 多人底池：薄价值要收着打，而且人越多越要收（第三家起接着往下走，
    // 见 [_manyTail]）。
    if (spot.opponents >= 2) {
      f *= 0.55 * _manyTail(spot.opponents, 2);
    }
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
    // 越往后这条越重要：被跟过两条街之后再开火，唯一说得通的理由就是
    // 「我挡掉了他能跟注的那部分牌」，所以阻断牌的权重跟 [villainCalls] 一起涨。
    base *= 0.85 + (0.5 + 0.35 * spot.villainCalls) * read.blockerScore;
    // 第二枪/第三枪的「抵抗」折扣：他跟了我几条街，我这条线就该缩多少。
    // 没被跟过（前面都过牌 / 我是刚接手的）不打折；被跟一条街略收；被跟
    // 两条街时纯空气只剩四成——真人这时候早就放弃了，只有最好的那几手
    // 破听牌（[HandReading.blockerScore] 高）还能靠上面那项把频率补回来。
    if (spot.villainCalls > 0) {
      base *= 1 - 0.20 * spot.villainCalls;
    }
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
      base *= 0.35 * _manyTail(spot.opponents, 3);
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

  /// 「超池档」的进度：0 = 普通下注，1 = 真超池。
  ///
  /// 这条线以前是一道硬门槛（`betSizeRel < 1.15`），门槛两边是两个世界。
  /// 探针实测（同一手牌、同一张牌面，只改对手下注的大小）：
  ///
  ///   第二对 87 有位置      1.14 池弃 9%    →  1.16 池弃 99%
  ///   两头顺 98  有位置      1.14 池弃 0%    →  1.16 池弃 91%
  ///   顶对弱踢 A8 没位置     1.14 池弃 0%    →  1.16 池弃 98%
  ///
  /// 中间没有任何过渡：对手拿任意两张牌下 1.16 池就能白拿底池，而下 1.14
  /// 池又几乎必被跟——下注尺度成了「AI 弃不弃」的开关，一眼就能被读出来。
  /// 真人的弃牌曲线是连续的，所以把这道门槛改成随尺度线性过渡：1 倍池以内
  /// 照旧按普通下注算，1.2 倍池以上（也就是原来的超池档）完全按超池算，
  /// 中间这一段线性插值。跑到 1.2 就到位是刻意的——1.2 池以上的行为跟
  /// 改动前逐点一致，改的只有「1.0~1.2 池」这条以前被硬门槛跳过去的路。
  ///
  /// 注意这条曲线只管「这算不算超池」这件事（听牌档拿它决定要不要相信
  /// 范围模型给的乐观胜率）。跟注门槛那边「封顶之后怎么松开」是另一条
  /// 曲线，见 [_capRelease]——两者的收尾速度完全不同，别合并。
  double _overbetProgress(_Spot spot) =>
      ((spot.betSizeRel - 1.0) / 0.2).clamp(0.0, 1.0);

  /// 「弱成牌封顶」的松开进度：0 = 完全按封顶算，1 = 完全按原始门槛算。
  ///
  /// 弱成牌（一对但被压制：底对、第二对弱踢……）的跟注门槛本来是「赔率 ×
  /// 若干余量」乘出来的，乘到赔率的 1.8~2.8 倍就过头了——拿到正确价格还把
  /// 牌扔掉，对手拿任意两张牌抡个大注就白拿底池。所以按胜率兑现率封顶
  /// （有位置赔率的 1.3 倍）。可封顶本身也是一道门槛：封顶之后「注越大跟得
  /// 越少」这条规律就没了，对手下多大我们都一样跟。于是让封顶随尺度逐步
  /// 松开，这条曲线就是那个「进度」。
  ///
  /// 区间有多宽是这条曲线成不成立的关键，不是随便挑的。第一版只铺
  /// 1.0~1.2 池（0.2 宽，跟 [_overbetProgress] 一样），看着「连续」，实测
  /// 还是道台阶——同一个第二对 87 有位置，探针（`tool/ai_probe.dart` 翻牌
  /// 尺度扫描）：
  ///
  ///   1.00 池跟 97%  →  1.05 池跟 75%  →  1.10 池跟 30%
  ///   →  1.15 池跟  2%  →  1.20 池跟  1%
  ///
  /// 97 个点还是全挤在 0.15 池里。原因不在插值本身：胜率是对着范围估出来
  /// 的，同一手牌在不同随机种子之间的散布就有 ±3~4 个百分点，过渡区间只要
  /// 跟这条散布带差不多宽，弃牌率就还是被整条穿过。拉开到 1.0~2.0 池
  /// （1.0 宽）之后同一条线上每一步都在动：
  ///
  ///   1.00 池 1% 弃  →  1.10 池 15%  →  1.20 池 47%
  ///   →  1.30 池 69%  →  1.50 池 96%  →  2.00 池 99%
  ///
  /// 代价是「1.2 池以上跟以前逐点一致」不再成立（现在 1.2 池从弃 99% 变成
  /// 弃 47%），换来的是整条曲线单调、没有一处能当开关用。1.5 池往上仍然是
  /// 干脆地弃（96%），所以「超池是两极的、不硬接」没有被放松，只是从
  /// 「1.2 池就到位」改成了「2 池才到位」。
  double _capRelease(_Spot spot) =>
      ((spot.betSizeRel - 1.0) / 1.0).clamp(0.0, 1.0);

  /// 河牌防守下限的「手牌折扣」：下限再乘上这一手牌自己的胜率份额。
  ///
  /// 下限（[riverDefendFloor]）存在的理由是 MDF——手里真有成牌就不能把整个
  /// 范围都扔掉。但它原来是个跟手牌无关的定值：只要胜率掉到门槛以下，整档
  /// 牌的防守份额就变成同一个常数。探针实测（tool/ai_multi_probe.dart 的 C 节，
  /// 河牌 4 人池、对手打 1/2 池）第二对 87 / 被盖口袋 66 / 底对 43 三手牌的
  /// 弃牌率逐字相同（35/35/35、73/73/73、97/97/97），而这三手牌对着同一个
  /// 范围算出来的胜率是 0.073 / 0.044 / 0.005——差了十几倍，AI 却打成一个数。
  /// 对手只要把尺度卡在「弱成牌刚好够不到门槛」的位置，就能把我们的整个
  /// 抓诈唬范围压成一个常数，手里拿的是什么牌再也读不出来。
  ///
  /// 折扣按「这手牌的胜率够到自己门槛的几成」给，到饱和点为止：胜率够到门槛
  /// 六成以上的牌照旧拿满下限（「被连开三枪」那条线的 `need` 里已经含了 1.25
  /// 的余量，落点基本都在这一段，所以用例钉住的那几个逐点不变），更弱的牌按
  /// 比例缩。equity 和 need 都是连续量，人数和尺度也都从它们里来，所以这个
  /// 折扣在尺度轴、人数轴上都跟着连续变，不会在哪一格上跳。
  ///
  /// 目前只有弱成牌那一档接了它。中等牌那一档（顶对好踢这类）的手按定义就压在
  /// 门槛附近、强弱跨度小得多，没量到同款的塌陷，而它那边的下限正被几条 MDF
  /// 用例钉着，先不动。
  double _riverFloorHedge(double equity, double need, double smallBetFade) {
    // 饱和点：胜率够到门槛这个比例的牌照旧拿满下限，见上面说明。
    const saturation = 0.6;
    final raw = (equity / (saturation * need)).clamp(0.0, 1.0);
    // 小注那档不参与打折：1/4~1/3 池的 MDF 是硬指标（对手拿任意两张按那个价
    // 开火，保本弃牌率只有 20~25%，整档都得守），[smallStabFade] 那几行的
    // 「小注面前按赔率抓」说的就是这件事。折扣从 1/3 池的零一路放到 0.55 池的
    // 足额，跟那条曲线同源，不是另拍的一道门。
    return 1.0 - (1.0 - smallBetFade) * (1.0 - raw);
  }

  // ---------- 面对下注：加注 / 按赔率跟注 / 放弃 ----------

  AiDecision _facingBet(GameEngine game, PlayerState me, _Spot spot,
      HandReading read, double Function() equity) {
    final potOdds = Odds.potOdds(pot: spot.pot, toCall: spot.toCall);
    final bigBet = spot.betSizeRel >= 0.7;
    final smallBet = spot.betSizeRel <= 0.35;
    // 河牌面对大注、手里还有筹码可加：这里不该加。这一档的强牌（顶对顶踢、
    // 超对、同花面上的顺子/三条）在河牌是**抓诈唬**的牌，加注只会把对手的
    // 诈唬打走、把能打败我们的牌请进来——探针里「连开三枪 + 超池」那一格
    // 有一半牌局是这样推出去的。筹码真套进去（SPR ≤ 1）就不算加注了，那
    // 时候加跟跟已经是一回事，照旧推。
    //
    // 转牌的超池同理（探针「连开两枪超池」那一格有 21% 是推出去的）：后面
    // 只剩一条街，把筹码压进一条两极的线一样是「把诈唬吓跑、只留下更好的
    // 牌」。只是尺度门槛要高一点——转牌 3/4 池左右的重注还能是价值注，
    // 1.2 倍池往上才是真正的超池。
    final noRaiseVsBigBet = bigBet &&
        spot.spr > 1.0 &&
        (game.street == Street.river ||
            (game.street == Street.turn && spot.betSizeRel >= 1.2));
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
    // 河牌的小注（1/4、1/3 池）是「宽范围」：为了 20% 的赔率去诈唬不划算，
    // 敢下这么小的人手里多半也是没把握的薄价值/阻挡注。而范围模型只按牌型
    // 给权重、不看这一注下得多小（一对 0.45 vs 空气只剩 0.12），小注面前
    // 算出来的胜率偏悲观——实测底对面对 1/4 池只算到 16.6%（赔率 20%），
    // 于是 100% 弃牌。下面几档跟注门槛统一按这个小注档打个折。
    // 这一档的折扣随尺度**连续**消失，不能停在 0.4 池那道门上：空气那一档
    // 早就这么改了（见下面 [_stabNeed]），弱成牌这一档当时漏了。探针实测
    // 第二对 87 面对连开三枪，0.4 池弃 1%、0.5 池就弃 36%——0.1 池的差距
    // 里藏着一整个跟注范围，对手把注抬一下就能让我们的抓诈唬归零。
    // ≤0.35 池给满（×0.7），≥0.55 池收干净（×1.0），中间线性。
    final smallStabFade =
        ((0.55 - spot.betSizeRel) / 0.2).clamp(0.0, 1.0);
    // 「后面还有街」的系数：只有转牌要额外收窄。翻牌跟注之后还有两张牌
    // 可看、对手也还可能先收手；转牌跟完就只剩一条街，而对手多半还会再
    // 开一枪——同样一个 2/3 池的注，翻牌该跟的牌到了转牌常常就该放了。
    // 真人这两条街的防守范围差别很明显，而以前 AI 的跟注门槛在翻牌/转牌/
    // 河牌完全一样：探针实测第二对面对 2/3 池，翻牌跟 96%、转牌还是跟
    // 95%，一整条街的差别都看不出来。河牌没有下一手，不调。
    //
    // 只在「面对下注」时用：面对加注时已经有专门的加注惩罚（对手那一下
    // 本身就说明范围强得多），再叠一层会把「最小加注也不该交牌」那条线
    // 又打回去。
    //
    // 注意这一项在弱成牌那一档基本会被「胜率兑现率封顶」吃掉（见下面的
    // realizationCap）：到 2/3 池这个尺度上，门槛已经被封顶压到很低，
    // 乘出来的项整个被丢掉。所以两条街真正的差别落在**封顶自己的街道项**
    // 上——这里这一项只在「1 倍池往上、封顶逐步松开」那一段还起作用。
    final streetCost = (!facingRaise && game.street == Street.turn) ? 1.2 : 1.0;
    // 河牌「最低防守」：手里有真成牌、面对的是一注（不是加注）时，不许把它
    // 接近 100% 扔掉，按尺度给一个混合跟注下限——真人的「算了，看一眼」
    // 就是这个东西。
    //
    // 为什么必须有：tool/ai_river_defense_probe.dart 让对手拿**任意两张**连开
    // 三枪，量 AI 在河牌第三枪上的弃牌率。改之前 AI 弃 87~100%，而对手拿空气
    // 开火不亏不赚的弃牌率（保本弃牌率 b/(p+b)，b 是他这一注、p 是含他这一注
    // 的池：0.5 倍池 33%、满池 50%）——对手随便两张牌一路抡能白赢三四十个点。
    // 真人拿成牌在这种地方总要抽一部分来看。
    //
    // 下限的斜率是这套东西的关键，不能随便写死：
    //   * 掉得太慢（比如 (0.55 - 0.22b) 那种）会把「注越大抓得越少」整条
    //     抹平——探针里底对面对一个满池从弃 90% 掉到 70%、面对超池反倒不弃
    //     了，而且打红两条既有用例（底对面对满池要照弃、第二对面对连开三枪
    //     要尊重）；
    //   * 掉得太快（比如 0.7 倍池直接归零）等于只在极小注上兜底，2/3 池那一
    //     档还是齐刷刷交牌。
    // 现在这条曲线（弱成牌）在 1/2 池抽四成、2/3 池两成出头、3/4 池一成、
    // 满池只剩个尾巴（真人也不会拿一对去接一个满池的三枪）；中等牌档在每
    // 一档上都更高一截——它上面还压着顶对/两对/三条，是这条街靠后的防守
    // 厚度，弃光它才是真的把底池白送。
    //
    // 下限的形状就是 MDF 本身，而不是一条拍脑袋的直线。以前写成
    // `1.02 - 1.2b`（弱成牌档），在 1/2 池只给出 0.42——可对手下 b 倍池，
    // 他的诈唬保本弃牌率是 b/(1+b) = 33%，也就是说我们至少得跟 67%
    // 才不让他拿任意两张白赚。这条下限低了 25 个点，下面那两条既有用例
    // 量不到（它们量的是「注越大弃得越多」，方向是对的），但
    // [ai_river_defense_probe] 一量就露：湿润面上河牌面对 1/2 池，我们的
    // 整体弃牌率 59%，保本线 33%——对手连开三枪的最后那一枪只要下到半池，
    // 拿空气就能赚 25 个点。（1/4 池那档本来就已经在守，探针里弃 0%。）
    //
    // 但 MDF 只对**小注**是硬指标：注越大，对手那条线里的价值牌越多
    // （范围模型也是这么收窄的），到了 3/4 池还照 MDF 防就是拿一对去接
    // 重注——那一段另有「连开三枪的重注要尊重（弃 85% 以上）」这条用例
    // 钉着。所以 1/2 池往上按 2.3 的斜率把这条下限收回去，接到原来的
    // 3/4 池附近（0.03），两端都是连续的：
    //   1/4 池 0.80、1/2 池 0.67、2/3 池 0.23、3/4 池 0.03、满池 0.03
    // （原来的满池/超池 0.03 逐点不变；中间那条 2.3 的斜率就是「1/2 池的
    // MDF 到 3/4 池的 0.03」这段直线，不是另拍的数）。
    //
    // 上面这条曲线管的是「整档的防守份额」，还得再按**这一手牌自己**的胜率
    // 打个折扣，不然同一档里强弱差十几倍的手会打出同一个数——见
    // [_riverFloorHedge]。
    final mdfFloor = 1 / (1 + spot.betSizeRel);
    // 那条 2.3 的斜率有个前提：注越大，他这条线里的价值牌越多——这是**一个
    // 正常对手**的性质。对手已经被读成「逮到机会就往里砸」（进攻率顶格、
    // callFactor 掉到 0.8 那道底）时，这个前提不成立：他的重注里一样大半
    // 是空气，还照「重注 = 真牌」把下限收到 0.03，等于同一个人先用读牌把
    // 我们翻牌/转牌的跟注范围放宽、再在河牌把多出来的那一整个范围原样扔掉
    // ——付了三条街的价钱去摊一次牌，最后那一下照旧交出去。
    //
    // 探针实测（tool/ai_river_defense_probe.dart）：让同一个 AI 连着打几千手
    // （真桌就是这么累积读牌的），对手连开三枪那条线上 heroAggro 顶到 1.00、
    // 疯子读牌生效，翻牌/转牌的跟注量直接翻倍（每格样本 47 → 100）；可河牌
    // 面对 2/3 池照旧弃 75%、满池弃 89%，按每 6000 手算的**绝对**弃牌数比
    // 读牌生效前还多了一倍——读牌只放宽了前两条街，河牌那一档原地不动。
    //
    // 所以斜率跟着读牌连续回调：对手越疯斜率越小，顶格时收掉七成
    // （2.3 → 0.69），下限就贴着 MDF 走；正常对手斜率逐点不变。用的是
    // [_maniacWiden]（跟 [_facingManiac] 同一条 0.45 线的斜坡）而不是再拍
    // 一个阈值，免得进攻率从 0.44 走到 0.46 就换一整套打法。
    final floorSlope = 2.3 * (1.0 - 0.7 * _maniacWiden(game, me));
    final floorShape =
        (mdfFloor - floorSlope * (spot.betSizeRel - 0.5).clamp(0.0, 1.0))
            .clamp(0.03, 0.8);
    // 超池段（1.0 倍池往上）连开三枪那条线的下限还得跟着尺度往下走。
    //
    // 上面那条 `floorShape` 在 0.73 倍池就被 0.03 那道地板夹住了，中等牌再
    // 加 0.10，于是从 0.95 倍池一直到 2.5 倍池，这一档的下限是一个**常数**。
    // 按 0.02 池铺满扫一遍（同一手顶对好踢、同一条连开三枪的线）：0.94 倍池
    // 弃 86%、1.00 倍池 86%、1.50 倍池 86%、2.50 倍池还是 86%——中间一个点
    // 都不动。对手拿任意两张牌在河牌抡超池，能拿到的弃牌率跟下 0.95 倍池完全
    // 一样（他保本只要 71%），我们这一档等于白送；尺度这一维在超池段整个失效，
    // 正是 [_facingBet] 里反复在修的那种毛病。
    //
    // 按超池段线性收掉 72%：1.0 倍池以内不设限（逐点不变，下面那些钉着
    // 「3/4 池照旧收手」「1/2 池按 MDF 守住」的用例都在这一段），2.5 倍池收到
    // 剩下的两成八（中等牌 0.13 → 0.036）。弱成牌那一档的下限本来就是 0.03，
    // 乘完被外面那道地板接住，逐点不变。
    //
    // 两极线（过牌-过牌-超池）不用这一项：它已经有 [overbetCap] 在压，而且
    // 「超池比连开三枪好抓」这条设计差异靠的就是两边的下限分开走。
    final overbetFloorFade = spot.polarizedBet
        ? 1.0
        : 1.0 - 0.72 * ((spot.betSizeRel - 1.0) / 1.5).clamp(0.0, 1.0);
    final riverDefendFloor = (game.street == Street.river &&
            !facingRaise &&
            (read.tier == HandTier.medium || read.tier == HandTier.weak))
        ? ((floorShape + (read.tier == HandTier.medium ? 0.10 : 0.0)) *
                overbetFloorFade)
            .clamp(0.03, 0.85)
        : 0.0;

    // 河牌面对重注：顶对（这一档含顶对顶踢、超对、同花面上的顺子/三条）
    // 是抓诈唬的牌，不能像以前那样面对满池/超池一路跟到底。探针实测改
    // 之前：顶对面对 1 倍池跟 100%、面对 1.5 倍池跟 99%——对手拿任意两张
    // 牌在河牌抡个大注就能把我们的跟注范围压成「只有他打不赢的牌才跟」，
    // 我们的强牌也永远只有「跟注 → 被更好的牌收走」这一种结局。真人拿顶对
    // 在河牌面对重注是要挑着弃的（超池那条线本来就是坚果或空气），只是不能
    // 弃成一堵墙——留下的那部分正是用来抓对手诈唬的。
    //
    // 弃多少由四项一起决定：
    //   * 尺度：0.75 倍池以下不弃（那是正常价值注/薄价值，按赔率也该跟），
    //     往上线性抬——1 倍池约一成半、1.5 倍池约四成。
    //   * 对手的线：前面几条街一路开火（priorAgg）说明范围实，多弃；
    //     「前面全过牌、这条街突然砸出来」是两极化的线，诈唬占比高，
    //     打个对折（少弃）——这条线和弱成牌档的判断保持一致。
    //   * 牌面：湿面上能打败顶对的成牌更多，多弃一点。
    //   * 人数：池里还有几家没弃牌。一对能不能跟一个大注，跟人几乎是反比
    //     的——多一个人就多一份「他也跟到了河牌」的范围，而一路跟下来的
    //     手牌里能打败一对的成牌占比高得多。这条以前完全没有：固定 SPR
    //     的多人探针里，河牌 1.5 倍池顶对顶踢单挑弃 43%、三人池还是 43%。
    //
    // 转牌是同一条线，但同一条曲线要打个折：后面还有一条街、也还有补牌，
    // 真人在这儿收得比河牌晚（探针里转牌 1.5 倍池弃两成上下、河牌四成半）。
    // 翻牌不参与：那儿的顶对还远没到「抓诈唬」那一步，老规矩（湿面 +
    // 对手线很实，偶尔放手）就够。
    final strongFoldStreet = game.street == Street.river
        ? 1.0
        : (game.street == Street.turn ? 0.5 : 0.0);
    final multiwayFold = (1 + 0.18 * (spot.opponents - 1)).clamp(1.0, 1.6);
    final strongFoldVsBigBet =
        (strongFoldStreet > 0 && bigBet && spot.spr > 1.0 && !facingManiac)
            ? ((((spot.betSizeRel - 0.75) *
                            (spot.polarizedBet ? 0.55 : 1.0) *
                            (read.texture.wetness > 0.6 ? 1.25 : 1.0) +
                        0.08 * spot.priorAgg +
                        (spot.villainStrength > 0.85 ? 0.10 : 0.0)) *
                    strongFoldStreet)
                .clamp(0.0, 0.6) *
                multiwayFold)
            .clamp(0.0, 0.85)
            : 0.0;

    // 1) 怪兽牌：价值加注；加注战里已经打太多就转为跟注。
    //    底池相对筹码已经很大时，加注就是全下。
    if (read.tier == HandTier.monster) {
      // 「筹码套进去就把剩下的推出去」这条对着**大注**要收住，理由跟给强牌
      // 的 [noRaiseVsBigBet] 一模一样：转牌/河牌的重注（尤其是超池）那条线
      // 是两极的，推出去只会把对手的诈唬全部打走、留下的正是能打败我们的
      // 那一小撮，而低 SPR 下推和跟的期望本来就差不了多少。以前这一档完全
      // 没接：实测河牌拿两对/三条，对着 0.5 倍池加 76%、对着 1.5~2 倍池
      // 反而加到 95%（多出来的全是低 SPR 自动推），「对手下得越大我们加得
      // 越凶」——真人正好相反，超池那条线上他们主要是跟。
      // 但这条也不能是「闸门下面一律推」。探针把 stack 扫成一排 SPR 量到
      // （3bet 池、两对 97 面对半池）：河牌 SPR 0.59~2.50 推 100%（闸门那
      // 一格推的是 215% 池），SPR 2.81 立刻掉成「85% 池加注 76% / 跟
      // 25%」；转牌同一条线，SPR 2.44 推 210% 池。也就是说加注尺度在
      // 215% 池和 85% 池之间没有任何中间档，对手把尺度卡在闸门上面就永远
      // 收不到超池尺寸，卡在下面又每次都被推。
      // 改成跟 SPR 连续的斜坡：加注量小到接近套进去（SPR ≤ 1）照样推，
      // 往上线性收到闸门（2.5）处为 0；没推的那部分落回下面那条常规价值
      // 加注（85% 池，尺度本身带混合）——加注频率基本不掉，只是不再用超池
      // 尺寸。唯一的变化是加注战里：以前那道推全下的分支绕过了「单街第 3
      // 次加注之后转为跟注」的封顶（见下），现在不绕了，四 bet 池里两对/
      // 三条会多跟一些、少推一些（探针里 4-bet+ 的加注从 18 掉到 3），
      // 这跟本分支开头写的意图一致：加注战打到那个份上，推出去只剩被更好
      // 的牌跟。
      final monsterJamRamp = ((2.5 - spot.spr) / 1.5).clamp(0.0, 1.0);
      if (spot.spr <= 2.5 &&
          canRaise &&
          !noRaiseVsBigBet &&
          _roll(monsterJamRamp)) {
        return _jam(me);
      }
      if (!canRaise || spot.raisesThisStreet >= 3) {
        return const AiDecision(ActionType.call);
      }
      // 大注（尤其是超池）以跟为主：留着他的诈唬，牌力也不写在脸上。
      // [_monsterTrap] 里那条尺度项会随 betSizeRel 往上抬，这里只是把
      // 「还能不能加」的上限跟着尺度压下来——注越大，加注的收益越只剩
      // 「他弃牌」那一点，而我们手里的牌恰恰希望他继续留在底池里。
      if (_roll(
          _monsterTrap(game, spot, read, facingRaise: facingRaise))) {
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
    // 「低 SPR 就把筹码推出去」这条只对着**下注**成立。对手已经**加注**回来
    // 了，那一下本身就说明他的范围强得多；这时候再加，只是把我们的诈唬全都
    // 打走、留下能打败我们的牌。河牌尤其不能推——后面没有牌了，一对牌被
    // 加注之后再加等于把自己变成诈唬。探针实测：AI 在河牌用顶对顶踢下注、
    // 被过牌-加注之后，有 94% 的牌局又推了回去（下注-被加注这条线 SPR 掉到
    // 1.2 上下、正好踩中「低 SPR 自动推」），对手拿任意两张牌加一下就白拿。
    // 筹码真套进去（能加的只剩一点点）不用管：那时候 canRaise 已经是 false，
    // 这里本来就走不到。
    // 「推」的频率还要跟 SPR 连续，不能停在 [jamSpr] 那道门上一刀切。
    // 加注量相对底池的大小差不多就是这个 SPR：SPR 越小，推出去越接近一次
    // 最小加注（对手范围里抓诈唬/听牌/更差的成牌全都得跟）；越接近闸门，
    // 推出去越像一次超池加注，能跟的只剩打败一对的牌。探针实测（3bet 池
    // 顶对顶踢 面对半池，临时把 stack 扫成一组 SPR）：翻牌 SPR 1.44 推
    // 100%、1.67 推 4%；转牌 1.33 推 100%、1.52 推 3%；河牌 1.15 推
    // 100%、1.52 推 2%——同一手牌、同一个尺度，落在闸门哪一侧完全是两个
    // 世界，对手只要把尺度调到闸门下面就能稳定收到全下、调上去又几乎收
    // 不到。真人这里的频率是跟着「这一推有多大」连续变化的。
    // 0.5 以下（加注量小到对手闭着眼就套进去了）保持满推，往上线性收到
    // 0；没推的那部分交给下面那条常规强牌线（它本来就会以低频率加个小
    // 注），推和加是混在一起的，而不是「推 or 只跟」二选一。
    final riverFacingRaise = facingRaise && game.street == Street.river;
    final jamRamp = ((jamSpr - spot.spr) / (jamSpr - 0.5)).clamp(0.0, 1.0);
    if (read.tier == HandTier.strong &&
        spot.spr <= jamSpr &&
        !noRaiseVsBigBet &&
        !riverFacingRaise) {
      if (!canRaise) return const AiDecision(ActionType.call);
      if (_roll(jamRamp)) return _jam(me);
    }
    // 2) 强牌：加注频率随街道递减（真人不会拿顶对在河牌乱加），
    //    面对大注/强线时以控池跟注为主，湿面偶尔也要懂得放手。
    //    自己先过牌再面对下注 = 过牌-加注，频率明显更高。
    //
    //    「对手的线很实」以前是一道硬开关（`villainStrength > 0.8 就 100%
    //    跟`），开关上面一个加注都没有。范围模型给 3bet 方的强度几乎总是
    //    0.97 那一档，于是探针里同一个「顶对顶踢/超对 面对半池」在单加池是
    //    加注 46%、进了 3bet 底池就成了加注 0%——同一手牌、同一个尺度，唯一
    //    的差别就是那个 0.97 卡在门的哪一侧。结果是 AI 在 3bet 池里的加注
    //    范围只剩两对以上，对手一眼读穿；可真人拿顶对/超对在 3bet 池里照样
    //    会加一部分（挡听牌，也让跟注范围有掩护），只是比单加池少。
    //
    //    现在改成从 0.72 到 0.95 线性压到两成、再往上一律两成：既跟
    //    [_valueRaiseChance] 里那条 `1 - 0.6 * villainStrength` 是同一套
    //    连续逻辑，门两侧也不再是两个世界。留两成而不是归零，理由跟
    //    [_strongRaiseChance] 里那条「大注也要留两成」一样——加注范围全被
    //    清空比频率低更糟，对手看到加注就知道撞上大家伙。
    if (read.tier == HandTier.strong) {
      //    起点放在 0.72 而不是 0.6：单加池里正常的强线（probe 实测 0.52
      //    那一档、过牌-加注局面 0.6 出头）都还在门下面，这一改只动范围模型
      //    开始饱和（0.9 以上、3bet 池固定 0.97）的那一段。
      final strengthScale =
          1 - 0.8 * ((spot.villainStrength - 0.72) / 0.23).clamp(0.0, 1.0);
      if (bigBet || spot.villainStrength > 0.8) {
        // 疯子的大注不能当真的听：拿强牌被他吓跑是最亏的。
        //
        // 转牌/河牌用上面那条跟尺度挂钩的档（以前河牌是「100% 跟」、转牌
        // 只有「湿面 + 对手线很实」这一档）；翻牌沿用老的那一档。
        // 超对、以及三张同花面上被降档的顺子/三条/两对，都不该跟顶对走
        // 同一条弃牌线：它们打赢对手范围里的两对/三条/顶对。见
        // [HandReading.strongFoldScale] 里那两组实测。
        final foldChance = (strongFoldVsBigBet > 0
                ? strongFoldVsBigBet
                : (!facingManiac &&
                        bigBet &&
                        spot.villainStrength > 0.85 &&
                        read.texture.wetness > 0.6
                    ? 0.25
                    : 0.0)) *
            read.strongFoldScale;
        if (foldChance > 0 && _roll(foldChance)) {
          return const AiDecision(ActionType.fold);
        }
        // 只是「这一注下得大」而已——那就把加注频率按尺度**连续**压下来，
        // 而不是一到 0.7 池就切成 0。为什么要这样，见 [_strongRaiseChance]。
        if (canRaise &&
            spot.raisesThisStreet <= 2 &&
            _roll((_strongRaiseChance(game, me, spot, read,
                        checkRaise: checkRaise) *
                    _bigBetRaiseScale(spot) *
                    strengthScale +
                _overPairFlopRaiseBonus(game, spot, read) +
                _strongDrawRaiseBonus(game, spot, read))
                .clamp(0.0, 1.0))) {
          return _raise(game, me, 0.8);
        }
        return const AiDecision(ActionType.call);
      }
      if (canRaise &&
          spot.raisesThisStreet <= 2 &&
          _roll((_strongRaiseChance(game, me, spot, read,
                      checkRaise: checkRaise) *
                  strengthScale +
              _overPairFlopRaiseBonus(game, spot, read) +
              _strongDrawRaiseBonus(game, spot, read))
              .clamp(0.0, 1.0))) {
        return _raise(game, me, 0.8);
      }
      return const AiDecision(ActionType.call);
    }
    // 3) 听牌：半诈唬加注 or 按（隐含）赔率跟注 or 放弃。
    if (read.hasDraw) {
      // 听牌可以主动做 3-bet（对面下注、我加注，这是半诈唬的主力），但对面
      // 再加回来就不该拿一把听牌去 4-bet——那是把筹码压在「他弃牌」上，而
      // 加注战里没人会弃。所以闸门放到 2，跟怪兽/强牌的刻度对齐。
      if (canRaise &&
          spot.raisesThisStreet <= 2 &&
          _roll(_semiBluffRaiseChance(read, spot, barrel))) {
        _registerFire(game.street, _PlanKind.semiBluff);
        return _raise(game, me, 0.75);
      }
      return _drawCallOrFold(game, me, spot, read, potOdds, equity);
    }
    // 4) 中等牌：按赔率跟注，面对大注/强线弃牌；小注时偶尔反击。
    if (read.tier == HandTier.medium) {
      // SPR 很低时人已经套进去了，中等牌愿意跟到底——但「套进去」不等于
      // 「什么价格都跟」。一个 1.5 倍池的重注要 37% 胜率，中等牌对着连开
      // 三枪的范围凑不出来；以前这里不看价格一律跟，探针里同一个中等牌档
      // 面对 1 倍池弃六成、面对 1.5 倍池反而一个都不弃——下注尺度这个变量
      // 在河牌被整个翻了过来。
      //
      // 这一档原来是「`spr <= 1.2` 且注 < 1.15 池就无脑跟」的硬闸门，
      // 上面那条历史说明的正是它的坏处：闸门只认 spr 不认价格，所以注越大
      // 反而越敢跟；后加的 `注 < 1.15 池` 只是把翻转挪到 1.15 池那道墙上，
      // 墙两侧还是两个世界（实测同一手顶对好踢、同一个浅筹码，1.0 池跟
      // 100%、1.5 池只剩 11%，中间没有任何过渡）。
      // 现在改成和弱成牌档同一套写法：spr 低就在这里把门槛连续打折，
      // 「套进去了要跟」留下，尺度这一维仍然由 sizePremium 接着管。
      // 判定用**下注前**的 spr，不跟这一注的大小挂钩：见弱成牌那一档的
      // [committed]——随这一注一起涨的折扣项会把价格项抵消掉。
      final potBeforeBetMed = max(1, spot.pot - spot.toCall);
      final committedMedium =
          ((1.8 - me.stack / potBeforeBetMed) / 1.8).clamp(0.0, 1.0);
      var need = potOdds *
          (spot.villainStrength > 0.7 ? 1.3 : 1.1) *
          (1.0 - 0.40 * committedMedium);
      // 跟注站的「黏」是对着下注的（一手小对陪你三条街），不是对着加注的：
      // 对面已经加注出来，中间牌力再跟就是在给价值下注付钱——风格再松也
      // 不该松这一档，不然三条同花面上拿第二对去接加注就变成「标准打法」。
      if (!facingRaise) need *= 1 - _p.callSlack;
      // 超池是两极的：真东西和空气都在里面，抓的时候要留个余量
      // （模型给的胜率是对着「宽范围」算的，被价值牌清空的风险没算进去）。
      // 这一项和弱成牌那一档的 [sizePremium] 同理，不能挂在
      // `bigBet = betSizeRel >= 0.7` 上：实测顶对好踢面对连开三枪，
      // 0.65 池跟 91%、0.70 池直接掉到 18%——同一手牌、同一个赔率，
      // 对手把最后那一枪从 0.69 池抬到 0.70 池就能把我们的跟注范围
      // 整段关掉。锚点保持原样：0.5 池以下不增不减（跟以前逐点一致），
      // 1.0 池爬到满档（非两极线 ×1.2、两极线 ×1.12），中间线性。
      final sizePremium = ((spot.betSizeRel - 0.5) / 0.5).clamp(0.0, 1.0);
      need *= 1.0 + (spot.polarizedBet ? 0.12 : 0.20) * sizePremium;
      // 超池段（1.0→2.5 池）两极线的折扣还得接着做。范围模型那边把「两极线
      // 保留的空气」修成随尺度单调之后（见 [_rangeFilter] 的 [sizeDiscount]），
      // 2 倍池那条线的范围实打实变强了，两条线的胜率差跟着缩小——门槛这一侧
      // 不补回来，「过牌-过牌-超池」与「连开三枪」的差距就会掉到设计要求的
      // 15 个点以内（实测 KsJd 对 2 倍池：24% vs 14%，而这条线必须领先 15 个
      // 点）。这一档只给两极线，连开三枪那条线原样不动——两条线要分得开，
      // 靠的就是这一正一反。
      //
      // 强度是按「把设计要求的差距补回来」调的，不是拍脑袋：0.10 让那条用例
      // 回到 34%（门槛 29%），0.06 时只剩 29% 上下，再小就骑在阈值上了。
      final overbetRamp = ((spot.betSizeRel - 1.0) / 1.5).clamp(0.0, 1.0);
      if (spot.polarizedBet) need *= 1.0 - 0.10 * overbetRamp;

      // 超池段还得给跟注率一个**上限**，光靠门槛管不住这一档。
      //
      // 门槛管的是「这手牌够不够」，可对手砸到 2 倍池往上时，我们这一档
      // （顶对好踢一直到第二对好踢）在他面前**全都只赢诈唬**——彼此之间
      // 的真实差距只有几个点。范围模型那边读尺度的乘子在 1.2 倍池就饱和
      // 了，胜率于是逐点相同，门槛又只跟着底池赔率慢慢爬，结果就是探针里
      // 那条水平线：顶对好踢对「过牌-过牌-超池」在 1.25/1.5/2.0/2.5 倍池
      // 的跟注率是 100/97/92/91%，而同一张牌面上的第二对只有 34%——两手
      // 真实差距没那么大的牌，差出 58 个点；对手把最后一枪从 1.25 倍池抬
      // 到 2.5 倍池，能拿到的弃牌率几乎没变（拿一对接 2.5 倍池本来是这个
      // 游戏里最典型的送钱方式）。
      //
      // 所以超池段直接给这条线一个随尺度下移的上限：1.2 倍池以内不设限
      // （逐点不变），往上收到「MDF 的 1.3 倍」。为什么以 MDF 为尺：上限
      // 是给**这一档**的（我们抓诈唬范围的上半截），不能压到整条范围的
      // MDF 保本线以下——对手下 2.5 倍池时保本弃牌率是 2.5/3.5 = 71%，
      // 也就是我们至少得跟 29%，上限收到这个量级之上才留着安全余量，
      // 再往下就是过弃、白送。
      //
      // 用上限而不是抬门槛，是因为它只该压住「赢面明显够」的那些牌：
      // 近门槛的牌（第二对）本来就落在上限下面，一抬门槛就正好把
      // 「过牌-过牌-超池 比 连开三枪 好抓」那条设计好的线一起压没了
      // （实测抬门槛到 0.20 时，那条线的差距从 20 个点掉到 2.5 个点；
      // 换成上限则一点不动）。实测这条线因此变成 1.25/1.5/2.0/2.5 倍池
      // 99/87/68/48%（含后面那 13% 的地板），单调、不再是一条水平线。
      final overbetCliff = ((spot.betSizeRel - 1.2) / 1.3).clamp(0.0, 1.0);
      final overbetCeiling = (1.3 / (1 + spot.betSizeRel)).clamp(0.25, 1.0);
      final overbetCap = spot.polarizedBet
          ? 1.0 - (1.0 - overbetCeiling) * overbetCliff
          : 1.0;
      if (facingRaise) need *= 1.25; // 面对加注：顶对也得收着点
      // 没位置的中等牌很难兑现胜率（后面还有人、也控制不了底池大小）。
      // 探针里同一个局面（同一张牌、同样尺度）有位置和没位置的跟注率
      // 只差 4 个点，等于位置这一维在跟注决策上几乎没生效——现在抬到
      // 能让「有位置薄跟、没位置收手」看得出来。
      if (!spot.inPosition) need *= 1.22;
      need *= streetCost * callFactor; // 街道成本 + 抓诈唬牌（越疯越要跟）

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
      // 弃牌侧放宽到 0.10（跟注侧照旧 0.04）。理由跟听牌那一档一样，只是
      // 中等牌这边更极端：这一档的门槛压在赔率线上，而**门槛和胜率两个
      // 量都随尺度在动**——探针实测连开三枪这条线，0.65→0.75 池之间门槛
      // 抬 0.034、模型胜率掉 0.054，合起来 0.09。一条 ±0.04 的窄带子会被
      // 这 0.09 整条穿过去，于是「从跟到弃」在一个采样点里就做完了（改前
      // 0.65 池跟 91%、0.70 池跟 18%）。带宽取 0.10 正好把这 0.09 包住，
      // 弃牌率就摊在 0.6~0.8 池这一整段上（改后 98 / 79 / 51 / 23 / 16%）。
      if (!scary &&
          _callMix(equity(), need, foldBand: 0.10, cap: overbetCap)) {
        return const AiDecision(ActionType.call);
      }
      if (canRaise &&
          smallBet &&
          spot.opponents == 1 &&
          spot.raisesThisStreet <= 1 &&
          _roll(0.15 * _aggression * _p.aggressionScale)) {
        return _raise(game, me, 0.7); // 对手像是在打阻挡注
      }
      if (_roll(riverDefendFloor)) return const AiDecision(ActionType.call);
      return const AiDecision(ActionType.fold);
    }
    // 5) 弱成牌（一对但被压制：底对、第二对弱踢、顶对弱踢、被盖过的口袋对）：
    //    这是真人的「抓诈唬」主力。河牌跟注范围里大半就是这种一对牌——
    //    见注就弃等于告诉对手「你随便开火我都走」，会被诈到破产。
    //    所以按赔率抓，只是门槛比中等牌高：大注少抓、疯子多抓、岩石不抓。
    if (read.tier == HandTier.weak) {
      // 抓诈唬的门槛 = 底池赔率 + 一点余量。对手前面那条街全过牌、这条街
      // 才突然砸出来的大注（[polarizedBet] / [checkedThrough]），范围里
      // 诈唬和半诈唬占了大头，我们的一对牌就是合格的抓牌——这种线只按
      // 赔率要一点溢价就够；反过来对手连开几枪的大注才按「大注 = 真牌」
      // 收紧。以前不分这两种线，一律把赔率乘 1.5 倍以上，结果第二对对着
      // 0.75 池的「过牌-过牌-重注」会 97% 弃牌，对手随便抡一枪我们就交牌。
      final stab = spot.polarizedBet || spot.checkedThrough;
      // 河牌只剩一次决策：门槛只比赔率高一点点就够了。前面几条街要留安全
      // 余量，是因为后面还有钱要投、胜率也得能兑现；河牌没有「下一枪」，
      // 按赔率跟就是对的。以前河牌和翻牌共用同一个 1.35 的余量——探针实测
      // 第二对对着河牌 2/3 池有 31.3% 胜率、赔率只要 28.6%（够本），却被
      // 38.4% 的门槛卡掉，弃 92%；面对 1 池弃 93%、底对更是 100%。这等于
      // 告诉对手「你随便两张牌下 2/3 池我都走」，谁来诈唬都能白拿底池，
      // 我们的河牌跟注范围也只剩顶对以上、一眼就能读出来。
      final margin = game.street == Street.river
          ? (spot.villainStrength > 0.7 ? 1.25 : 1.15)
          : (spot.villainStrength > 0.7 ? 1.7 : 1.35);
      var need = potOdds * margin;
      // 一对牌是抓诈唬的主力，跟注站抓得更宽（但面对加注照样收手）。
      if (!facingRaise) need *= 1 - _p.callSlack;
      // 「大注 = 真牌」的余量（以及「突然开火 = 两极线」的折扣）也得随尺度
      // 连续爬，不能挂在 `bigBet = betSizeRel >= 0.7` 这个布尔上：0.69 池
      // 乘 1.0、0.70 池乘 1.35，门槛一步跳 35%。探针实测连开三枪的河牌
      // 第二对 0.6 池弃 58%、0.7 池弃 89%；只砸一枪那条线 0.6 池弃 8%、
      // 0.7 池弃 30%——对手把尺度卡在 0.69 池就必被跟、卡在 0.70 池就稳
      // 收底池，同一手牌、同一个赔率。锚点保持原样：0.5 池以下不增不减
      // （跟以前逐点一致），1.0 池爬到满档（非 stab ×1.35、stab ×0.85）。
      final sizePremium = ((spot.betSizeRel - 0.5) / 0.5).clamp(0.0, 1.0);
      need *= 1.0 + (stab ? -0.15 : 0.35) * sizePremium;
      // 加注也分大小：最小加注只多花一点点（实测 toCall ≈ 0.4 倍池，底池
      // 赔率反而变好），底对/第二对按赔率本来就够跟；真正下重手的加注
      // （≈1 倍池起）才是「一抬就送」。以前不分大小一律乘 1.85，探针里
      // 底对面对最小加注弃 77%、第二对转牌弃 55%——对手随便拿两张牌
      // 最小加注一下就能白拿底池，和真人差得太远。
      //
      // 这条布尔留着没改：0.6 池上抬 12%（1.65→1.85）看着像台阶，但实测
      // 「AI 开一枪、英雄按池的 frac 倍加回来」这条线（frac 就是 betSizeRel，
      // 见 tool/ai_probe.dart 的「面对加注」那一节，0.54~0.66 每 2% 一格）：
      // 顶对弱踢 A8 的跟注率是 97/94/88/83/79/73/63/47——0.60→0.61→0.62
      // 这三步掉 4、6 个点，跟两边的坡度（3~10）连成一条曲线，没有任何一步
      // 跳出去；第二对在 0.60 两侧都已经 100% 弃。12% 的门槛扰动被赔率本身
      // 的坡度（约 +0.25 胜率/池）盖掉了，落到决策上不到一个采样格。以后要
      // 动这个数，先看那一节有没有冒出跳变。
      if (facingRaise) need *= spot.betSizeRel <= 0.6 ? 1.65 : 1.85;
      // 一对牌是「抓诈唬」的牌：没位置抓的人，后面还有一整条街要挨打，
      // 而且河牌拿不到薄价值，门槛本来就该比有位置高一档。
      if (!spot.inPosition) need *= 1.2;
      // 小注面前按赔率抓（折扣随尺度连续消失，见 [smallStabFade] 说明）。
      if (game.street == Street.river) {
        need *= 1.0 - 0.3 * smallStabFade;
      }
      need *= streetCost * callFactor; // 街道成本 + 抓诈唬牌（越疯越要跟）
      // 筹码已经套进去（spr 低到「跟注 ≈ 把剩下的推出去」）：门槛随 spr
      // 连续下移——真人在这儿跟得比平时宽，因为能赢的底池相对要投的钱大。
      // 以前这里是一道硬闸门 `spr <= 1.0 就无脑跟`，探针里露得很清楚：
      // 同一个第二对面对连开三枪，200% 池（spr 1.02）弃 97%，250% 池
      // （spr 0.875，掉进闸门）反而跟 29%——「注越大跟得越多」，而那 52
      // 手牌按赔率要 42% 胜率、实际只有 15%。对手把尺度从 2 倍池加到 2.5
      // 倍池，就能把我们的一对牌从「按赔率算」直接买成「无脑跟」。
      // 改成连续下移之后：下注前的 spr 在 1.5 池以上不动，往下一路收到
      // 0.55（spr→0），「套进去了要跟」这条真人的直觉留着，但不再盖过价格。
      // 判定用**下注前**的 spr，不跟这一注的大小挂钩：「注越大跟得越少」
      // 这条规矩要求门槛里凡随这一注变化的项都是「越贵越收」。用下注后的
      // spr 会让折扣跟着这一注一起涨，和价格项互相抵消——实测那样写会在
      // 浅筹码上把 1.5 池→2.0 池的跟注率抬回去 3 个点。改用下注前的 spr
      // 之后，尺度这一维只剩 potOdds 和 sizePremium 在管，方向一定是收的。
      final potBeforeBet = max(1, spot.pot - spot.toCall);
      final committed =
          ((1.5 - me.stack / potBeforeBet) / 1.5).clamp(0.0, 1.0);
      need *= 1.0 - 0.45 * committed;
      // 河牌封顶：手里是个真对子，就不能 100% 弃牌。探针实测以前第二对
      // 面对河牌 2/3 池弃 92%、面对 1 池弃 93%（底对更是 100%），等于告诉
      // 对手「你随便两张牌下 2/3 池我都走」——会诈唬的人白拿底池，我们的
      // 跟注范围也只剩顶对以上，一眼就能读出来。真人这里靠的是 MDF：
      // 注再大也要留一部分「次好的对子」按赔率抓（只有超池例外，超池线
      // 是两极的，不硬接）。封顶后底对/空气照样弃（它们离这个门槛还远），
      // 只有第二对这类刚好够边界的牌会被抓回来。
      //
      // 封顶的量还得跟着尺度往上走，不能是个定值：定值会把「注越大抓得
      // 越少」这条规律整个压平——探针实测第二对面对 2/3 池跟 52%、面对
      // 一个满池还是跟 53%，尺度这个变量在河牌跟注上被抹得一干二净，
      // 对手打多大我们都一样跟，他拿任意两张牌打个满池就能白拿底池。
      // 改成「小注封得低、大注封得高」之后，2/3 池保持原来的五成上下，
      // 满池掉到两成多，跟注率重新随尺度递减。
      // 翻牌/转牌同样要有个顶：上面那些余量是「胜率兑现率」的粗模型，而
      // 兑现率本身有物理上限——一对牌再差也在 0.7 上下，折成门槛就是赔率的
      // 1.4 倍左右，没位置再高一档。没有这个顶，各项相乘会把门槛顶到赔率的
      // 1.8~2.8 倍：探针实测翻牌面对一个满池，弱成牌门槛中位 0.61，同一批牌
      // 对着范围算出的胜率中位是 0.41（赔率只要 0.33），只有 6% 过门槛——
      // 等于拿到正确价格还把自己的牌扔掉，对手拿任意两张牌满池一抡就白拿。
      // 顶是「赔率的倍数」而不是定值，所以注越大门槛越高的方向不变。
      // 封顶必须跟门槛一起按风格缩：跟注站「赔率上该弃也跟」靠的是把门槛
      // 整体打折（1 - callSlack），封顶写成死数就等于在大注面前把三种风格
      // 压成同一个数——探针实测底对面对翻牌一个满池，紧凶/松被动/松凶的
      // 弃牌率都是 35%，牌桌上最黏的那类人跟谁都不差一格，风格标签就白贴了。
      final styleSlack = 1 - _p.callSlack;
      // 兑现率上限的**街道项**：转牌要再差一档。翻牌跟注之后还有两张牌可
      // 看、对手也还可能先收手；转牌跟完只剩一条街，而对手多半还会再开一
      // 枪，河牌又拿不到薄价值——同一个 2/3 池的注，翻牌该跟的一对牌到了
      // 转牌常常就该放了。真人这两条街的防守范围差别很明显。
      //
      // 这一档给的是「赔率倍数上的绝对增量」，不是再乘一个统一的系数：
      // 没位置本来就背着 1.6 那道惩罚（后面还要挨打），再乘满一档的话，
      // 第二对面对转牌 2/3 池就变成「一律弃」（探针实测弃 93%，等于对手
      // 随便两张牌开第二枪就白拿底池）；所以有位置 1.3→1.62、没位置
      // 1.6→1.78，两边都只往上一档。改之前这一档是统一乘 1.1，探针里
      // 第二对 87 面对 2/3 池翻牌跟 96%、转牌还是跟 94%，一整条街的差别
      // 都看不出来。
      // 这一档还跟着下注尺度爬坡：1/2 池以下是「该跟的价格」（收窄几乎为
      // 零，跟翻牌那一档一样），2/3 池往上才收满。注越大，跟注之后剩下的
      // 筹码越少、也越可能在河牌再挨一枪，这条街的收窄才真的值钱。
      final turnRamp =
          ((spot.betSizeRel - 0.4) / 0.26).clamp(0.0, 1.0);
      final streetRealization = (spot.inPosition ? 1.3 : 1.6) +
          (game.street == Street.turn
              ? turnRamp * (spot.inPosition ? 0.32 : 0.18)
              : 0.0);
      final realizationCap = potOdds * streetRealization * styleSlack;
      if (!facingRaise) {
        // 上限随尺度**逐步**放松，而不是在 1.15 池那道门槛上直接放开
        // （见 [_capRelease]）：以前写成 `betSizeRel < 1.15 才封顶`
        // 之后，第二对（有位置）对着 1.14 池弃 9%、对着 1.16 池弃 99%，
        // 门槛两侧是两个世界。门越浅，对手拿任意两张牌下 1.16 池就越赚。
        final cap = game.street == Street.river
            ? (0.34 + 0.12 * spot.betSizeRel) * styleSlack
            : realizationCap;
        if (need > cap) need = cap + (need - cap) * _capRelease(spot);
      }
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
      if (canRaise &&
          spot.raisesThisStreet <= 1 &&
          read.blockerScore >= 0.5 &&
          _roll(0.04)) {
        _registerFire(game.street, _PlanKind.pureBluff);
        return _raise(game, me, 0.8);
      }
      if (_roll(riverDefendFloor *
          _riverFloorHedge(equity(), need, smallStabFade))) {
        return const AiDecision(ActionType.call);
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
    // 河牌的小注要用「高张」去抓：A 高、K 高这类牌没成牌但有摊牌价值，
    // 对着 1/4、1/3 池的小注跟一张是常规操作（小注大半是没把握的薄价值
    // 或阻挡注，赢不过任何一对，但能赢过所有没成的听牌）。探针实测以前
    // 这里一律弃牌（面对 1/4 池弃 83%），对手拿任意两张牌小注一下就能
    // 白拿底池——真人不会这么交牌。
    //
    // 门槛在赔率上还留一个折扣（1 → 0.85），两头都与「注越大跟得越少」
    // 一致。折扣不为 0 是因为范围模型仍偏保守：它算的是「对手这条线里
    // 剩下多少空气」，而它自己那套空气权重（[_rangeFilter] 里的 airBase）
    // 是按牌型分档给的，小注那一档给不足。折扣随尺度线性过渡，不再是一道
    // 门（见下面 [_stabNeed] 那几行的说明）。
    //
    // 只认单挑 + 至少一张高张：多人池的小注多半真有货；没高张的纯空气
    // （比如 76s 在 AKQ 上）连「赢过没成的听牌」都做不到，抓不动。
    if (game.street == Street.river &&
        !facingRaise &&
        spot.opponents == 1 &&
        read.overcards >= 1) {
      // 折扣随尺度**连续**变化，不再有硬门槛：以前是「0.4 池以内 0.7 折、
      // 0.4 池以上干脆不打折」，探针实测那道门两侧是两个世界（0.4 池跟
      // 37%、0.42 池 0%），对手把注抬 2% 就能让我们的抓诈唬范围归零。
      //
      // 配合 [_rangeFilter] 那边「河牌空气权重按尺度给」的改动，改后
      // A 高（AdKd on Qd7d2c5h9s）面对：1/4 池 98%、1/3 池 79%、0.4 池
      // 66%、0.42 池 61%、1/2 池 7% 跟 + 10% 加、2/3 池以上直接弃——
      // 单调、连续，没有一处能当开关用。
      var stabNeed = potOdds *
          (0.85 + 0.15 * ((spot.betSizeRel - 0.4) / 0.6).clamp(0.0, 1.0)) *
          // 阻断牌：挡掉对手价值范围里的坚果，他这条街的诈唬占比就更高，
          // 这手「没成牌的高张」正是真人拿来抓小注的牌。
          (1 - 0.15 * read.blockerScore);
      // 没位置的高张抓诈唬要收一档（跟其他牌力档一致）：对手往没位置的人
      // 身上开火，范围里真东西的比例天然更高，我们那些「只赢诈唬」的高张
      // 兑现得也更差。
      if (!spot.inPosition) stabNeed *= 1.15;
      // 小注（≤0.45 池）先抓：这个价格「按赔率看一眼」比「拿着空气去
      // 加注」划算得多，不该被诈唬加注抢在前面。
      if (spot.betSizeRel <= 0.45 && _callMix(equity(), stabNeed)) {
        return const AiDecision(ActionType.call);
      }
      // 注大了就反过来：先把「听牌死了转成诈唬」这一手用掉，剩下的部分
      // 再按（打折的）赔率抓。以前这条诈唬排在抓之后，等于小注档把诈唬
      // 的牌全吃掉了；大注档又没有抓的牌，于是「弃牌」是唯一出路，
      // 听牌死在河牌就再也不会转成诈唬。
      if (canRaise &&
          spot.raisesThisStreet <= 1 &&
          _roll(_bluffRaiseChance(game, me, spot, read))) {
        _registerFire(game.street, _PlanKind.pureBluff);
        return _raise(game, me, 0.8);
      }
      if (_callMix(equity(), stabNeed)) {
        return const AiDecision(ActionType.call);
      }
      return const AiDecision(ActionType.fold);
    }
    // 极少数情况诈唬加注。空气只在下注面前诈唬（<=1，也就是一次加注都不
    // 还没发生）；已经有人加过注还拿空气往上顶，就是纯送——真人拿空气做
    // 3-bet 只挑阻断牌很硬的场合，频率远低于这里能放出来的量。
    if (canRaise &&
        spot.raisesThisStreet <= 1 &&
        _roll(_bluffRaiseChance(game, me, spot, read))) {
      _registerFire(game.street, _PlanKind.pureBluff);
      return _raise(game, me, 0.8);
    }
    // 跟注站的招牌之一：价格不贵的时候，手里什么都没中他也跟一张。
    //
    // 这一档和上面所有档都不一样——上面那些都是「按赔率抓诈唬」，胜率得
    // 够得上赔率；纯空气的胜率永远达不到任何一个门槛，所以它在任何风格下
    // 都是干净地弃牌。可真人里最典型的一类对手就是「你打不跑他」：1/3 池
    // 这种小注，他连后门花都不需要有，拿两张高张就敢跟，甚至只是「懒得
    // 弃」。训练器里缺了这一档，玩家就永远练不到「对着跟注站别诈唬、拿
    // 价值牌往死里打」这件事——而那是这个游戏最常见的赢钱方式。
    //
    // 门槛卡得很死，免得它变成「无脑跟」：
    //   * 只对着**下注**（不是加注，见 [_Profile.callSlack] 的说明）；
    //   * 只在价格不贵时（≤1/3 池）——大注面前跟注站也会收手；
    //   * 只在有位置时：没位置跟一张之后还要在不利位置挨后面两条街，连
    //     跟注站都不爱干（这一条同时避开「浮牌是位置的特权」那条设计）；
    //   * 单挑 + 后面还有牌可发（河牌用高张抓小注是上面那条 smallStab，
    //     不需要再放宽一档）；
    //   * 频率直接取 [callSlack]，别的风格是 0，等于这档只属于跟注站。
    if (!facingRaise &&
        spot.inPosition &&
        spot.opponents == 1 &&
        spot.betSizeRel <= 0.35 &&
        spot.spr > 2.0 &&
        game.street != Street.river &&
        _p.callSlack > 0 &&
        _roll(_p.callSlack)) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 边缘牌别一刀切：胜率和门槛挨得很近时按比例混合（真人也会
  /// 「这手跟、下手弃」），离得远就是干净的是/否。
  ///
  /// 河牌圈的胜率是蒙特卡洛估出来的，同一个牌线往往每次都差不多，
  /// 纯阈值判断会让 AI 在边缘局面上一律跟或一律弃——太机械了。
  ///
  /// [band] 是「够得上门槛」那一侧的过渡带宽，[foldBand] 是弃牌那一侧的。
  /// 默认两侧相同（0.04）。分开是因为**门槛和胜率都随尺度在动**：同一手牌
  /// 换个下注尺度、edge 就在动，一条太窄的带子会被整条穿过去——探针实测
  /// 两头顺对着 1.18 池跟 31%、1.2 池直接 0%，对手把注抬 1% 就能把这个
  /// 牌力的跟注整个关掉。听牌那边把弃牌侧放宽到 0.08，让「从跟到弃」这件
  /// 事摊在一个够宽的尺度区间里做完。
  ///
  /// [cap] 是跟注概率的上限（默认 1.0，等于不限）：赢面明显过关的牌也只
  /// 能按这个概率跟。用来表达「对手这条线太强，我们这一档抓诈唬的牌整体
  /// 只能守到这么多」——只在两极线的超池段用（见 [_facingBet] 的
  /// overbetCap）。它和抬 [need] 的区别很关键：抬门槛会把近门槛的牌一起
  /// 压死，上限只削掉「赢面明显够」的那部分，两类牌不互相牵连。
  ///
  /// 斜坡必须在带宽的边界上正好走到 0 / 1：[h]0.5 + edge / (2 * band)[h]
  /// 就是这条斜坡。以前写成 [h]0.5 + edge / 0.08 * 0.5[h]（分母少乘 2），
  /// 结果边界上还剩 0.25 的跟注率，被上面那两句 if 直接切成 0——同一手牌
  /// 在两个相邻尺度上会出现「还有三成在跟」紧接着「一个都不跟」的台阶，
  /// 这正是听牌那条线 1.18 池 / 1.2 池之间那道缺口的来源。
  ///
  /// [band] 为 0（听牌那条线要的「门槛以上一律跟」）时上侧的斜坡只剩一个
  /// 点，门槛两侧的取值都得是 1.0，所以下侧这条必须从 1.0 铺到 0。第一版
  /// 图省事让它照通用式子从 0.5 铺起，等于在门槛上留了整整 0.5 的台阶：
  /// 探针实测卡顺（JT on Q82）面对 40.5% 池跟 93%、41% 池只剩 44%，
  /// 半个百分点的池差换掉一半的跟注率。
  bool _callMix(double equity, double need,
      {double band = 0.04, double? foldBand, double cap = 1.0}) {
    final lower = foldBand ?? band;
    final edge = equity - need;
    if (edge >= band) return cap >= 1.0 ? true : _roll(cap);
    if (edge <= -lower) return false;
    final p = band <= 0
        ? 1.0 + edge / lower
        : (edge >= 0 ? 0.5 + edge / (2 * band) : 0.5 + edge / (2 * lower));
    return _roll(p < cap ? p : cap);
  }

  /// 听牌面对下注：跟注要跟得上「隐含赔率」，跟不动就弃。
  AiDecision _drawCallOrFold(GameEngine game, PlayerState me, _Spot spot,
      HandReading read, double potOdds, double Function() equity) {
    if (spot.toCall <= 0) return const AiDecision(ActionType.check);
    // 河牌听牌已死：不再跟注买牌，改为小频率诈唬（有阻断牌时更合理）。
    if (game.street == Street.river) {
      if (spot.canRaise &&
          spot.raisesThisStreet <= 1 &&
          _roll(_bluffRaiseChance(game, me, spot, read))) {
        _registerFire(game.street, _PlanKind.pureBluff);
        return _raise(game, me, 0.75);
      }
      return const AiDecision(ActionType.fold);
    }
    final streets = game.street == Street.flop ? 2 : 1;
    // 隐含赔率只有在「后面还有钱能赢」时才算数。以前这里是一条硬门槛
    // `me.stack > pot * 1.5`：同一个听牌、同一个下注，筹码从 1.5 倍池涨到
    // 1.6 倍池，那 6~8 个点的补贴就从有到无。探针实测（摊牌扫描已经固化
    // 成 engine_test 的用例「听牌隐含赔率：筹码从 1.5 倍池涨到 1.8 倍池」）
    // 坚果花听在转牌面对 2/3 池：1.5 倍池弃 11%、1.6 倍池直接弃 0%——5% 的筹码差把一整
    // 档弃牌抹掉，对手只要把筹码摆到那个数上就能读出来。
    // 改成 1.2~1.8 倍池之间的线性斜坡，两头锚点跟以前一致：1.8 倍池以上
    // 逐点不变（回归里那些深筹码的探针格子全落在这段，所以数字一个不动），
    // 1.2 倍池以下也确实没钱可赢、补贴为零。
    final deepRamp =
        ((me.stack / max(1, spot.pot) - 1.2) / 0.6).clamp(0.0, 1.0);
    // 隐含赔率：坚果花听/组合听牌成牌后还能再赢一笔。
    //
    // 它不是个常数：注越大，成牌之后能再收回来的钱越少——对手敢把 1.5 倍
    // 池砸进来，要么本来就没打算再付我们，要么剩下的筹码相对底池已经不值
    // 几个钱了。下面 [trustWeight] 那条注释里说的「成牌也收不回钱（隐含赔率
    // 被超池吃掉）」一直在靠「不相信范围模型」间接兑现，这里把它直接落在
    // 补贴本身上：1 倍池以内不动，往上沿 [_capRelease] 那条平滑曲线（它已经
    // 是为了「别再制造台阶」调过的）连续缩到六成。
    final implied = ((read.nutFlushDraw || read.isComboDraw) ? 0.08 : 0.06) *
        (1 - 0.4 * _capRelease(spot));
    // 「数 outs」只数得出花/顺的出路，高张、后门这些全看不见：AdKd 在
    // Qd7d2c5h 是 9 outs 的坚果花听，可它还有两张高张能赢，真实胜率三成
    // 上下，对着转牌 2/3 池的下注（要 28.6%）该跟——只数 outs 会算成
    // 19.6%+8% = 27.6%，差一个多点，于是这种牌一律弃牌（探针实测：
    // 面对 2/3 池的转牌下注，跟注 0%，要么加要么弃，一眼就不像真人）。
    // 所以这里跟蒙特卡洛胜率（对着对手范围算的，什么都算进去了）取大值：
    // 谁更乐观听谁的，边缘牌才不会因为估值方式差一个档就整档弃掉。
    // 两条边界不能越：
    //   · 卡顺这种 4~5 outs 的弱听牌不享受这个待遇。它们能赢的出路本来就
    //     少，「对着范围算胜率」会把对手诈唬的那一份也算成我们的，
    //     真实可兑现的胜率没那么多——继续按数 outs 来，该弃就弃。
    //   · 超池也是例外：敢超池的人范围明显偏价值，范围模型给的胜率偏乐观，
    //     而且成牌之后也收不回钱（隐含赔率被超池吃掉）。这时退回保守估值，
    //     不硬凑，超池面前老实弃牌。
    //   · 面对「加注」同样不算：能加注出来的范围强得多，而且我们手上那点
    //     成牌（第二对之类，这类牌也算听牌线）在加注线里根本兑现不了，
    //     把它按摊牌价值算进去就变成「拿第二对去接加注」。
    final strongDraw =
        read.drawOuts >= 8 || read.isComboDraw || read.nutFlushDraw;
    final overbet = _overbetProgress(spot);
    // 「信任范围模型给的那个胜率」的权重：注越大，对手范围里的价值牌越多，
    // 蒙特卡洛（对着范围算、把两张高张的出路也算进去）就越乐观，越该退回
    // 「只数 outs」的保守估值。
    //
    // 这里的关键不是「起点在哪」，而是**权重必须沿着整段尺度缓慢变化**。
    // 早先写成一条 0.7→1.2 池的线性斜坡（把权重从 1 拉到 0），等于在那
    // 0.5 池里造了一条 -0.5/池的胜率滑坡——比门槛自己的坡度（约 +0.12/池）
    // 陡四倍，于是整条跟注曲线都挤进那一小段：探针实测坚果花听（AKs on
    // Qh7h4c，翻牌面对下注，800 手一格）1.14 池跟 91%、1.18 池 77%、
    // 1.20 池 52%，两头顺（98 on 762）更早，1.00 池 91%、1.14 池 42%；
    // 转牌那张牌面（AKd on Qd7d2c5h）干脆在 1.00→1.14 池之间掉 69 个点。
    // 对手只要把尺度挪几个百分点，就能把一个牌力的跟注整条关掉——真人这
    // 条曲线是连续的，而且「他下多大」本来就是一个连续变量。
    //
    // 换成按尺度自适应的衰减（1/(1+x²)）：0.75 池以内跟以前逐点一致
    // （正常尺度该跟的那一档，权重仍是 1），往后连续下滑，1.2 池还剩一半、
    // 1.7 池两成、2 池一成、超池趋近 0。两头照旧：小注全信范围模型，
    // 真超池面前退回「只数 outs」。
    //
    // 转牌还要再整体打个折：只剩一张牌，范围模型多算的那份（两张高张能
    // 赢、对手在诈唬）在这里兑现不了——跟完这一注，河牌成不了牌就只能扔。
    // 打对折的理由跟成牌那边「转牌收得比河牌晚」（[strongFoldStreet]）是
    // 同一条，只是听牌更狠：成牌的落后还能摊牌，听牌不能。
    final streetTrust = game.street == Street.turn ? 0.5 : 1.0;
    final fade = (spot.betSizeRel - 0.75) / 0.45;
    final trustWeight = (!strongDraw || spot.villainRaisedThisStreet)
        ? 0.0
        : streetTrust / (1.0 + fade * fade);
    final drawOnly = read.drawEquity(streets);
    final base = trustWeight <= 0
        ? drawOnly
        : drawOnly + (max(drawOnly, equity()) - drawOnly) * trustWeight;
    final drawEq = base + implied * deepRamp;
    // 听牌的门槛只比裸赔率高一点点。以前在这上面再乘 1.25 × 1.1 的
    // 「安全余量」，等于要求 9 outs 的花听对着 1 倍池要有 46% 胜率才跟，
    // 结果 8~9 outs 的顺听/花听对着正常尺度一律弃掉——真人拿到这些牌
    // 几乎都会跟一张看两张牌（赔率够，成牌之后还有隐含赔率）。
    // 真正要防的是被更强的成牌清空，所以余量只留在「对手线很强」和
    // 「超池」这两项上。
    var need = potOdds * (spot.villainStrength > 0.75 ? 1.08 : 1.0);
    // 超池是两极的：真东西和空气都在里面。模型给的胜率是「对着整条范围」
    // 算的，被价值牌清空的风险没算进去；而且注额越大，成牌之后能再收回来的
    // 钱越少（隐含赔率被超池吃掉），门槛要跟着抬。
    // 门槛写 1.15 而不是 1.2：注额是整数，1.2 倍池的下注算出来常常是
    // 1.1997，写 1.2 这条判断等于永远不生效（以前就是这样，超池的余量
    // 一直是白写的）。
    need *= 1 + (spot.polarizedBet ? 0.1 : 0.2) * overbet;
    need *= _callVsReadFactor(game, me); // 疯子付得出隐含赔率，岩石付不出
    // 没位置的听牌不好兑现：跟注之后转牌还得先挨一枪，成牌了也很难
    // 在后面两条街收满价值（先说话的人收不到薄价值）。
    if (!spot.inPosition) need *= 1.08;
    if (!spot.villainRaisedThisStreet) {
      need *= 1 - 0.6 * _p.callSlack; // 跟注站连听牌都买得更便宜
    }
    // 边缘局面混着打：胜率和门槛挨得近时按比例决定跟不跟。以前这里是硬
    // 阈值，同一个牌线每次都一样——听牌面对下注要么跟、要么弃，一眼看得出
    // 是程序（真人这种局面本来就是混着来的）。只在强听牌上混：卡顺这种
    // 出路太少的牌不值得给自己找理由，赔率不够就干净弃掉。
    // 强听牌的弃牌侧过渡带放宽到 0.08（见 [_callMix]）：8~9 outs 的顺听/
    // 花听是「成牌才有用」的牌，范围模型给它的胜率里有一部分是「对手也在
    // 诈唬」那份，兑现不了；但门槛也因此卡得很紧，窄带子会让「跟」和「弃」
    // 在两个相邻的尺度上隔着一条缝。放宽之后两头顺面对 1.14/1.16/1.18/
    // 1.2/1.25/1.3 池的跟注率是 54/46/42/34/16/3%，单调连续。
    //
    // 弱听牌也得有个过渡带，只是**只往弃牌那侧铺**。「不值给自己找理由」
    // 讲的是别在门槛以上给自己加频率，不是「把交叉点留成一个点」：卡顺
    // 的出路数不随尺度变（4 outs 就是固定的 4/47），门槛却随尺度线性爬，
    // 两条线迟早交叉——`drawEq >= need` 把交叉变成一个点。探针实测
    // （JT on Q82 翻牌面对下注，400 手一格）：40.5% 池跟 93%，41% 池直接
    // 弃 93%，半个百分点的池差就换了一次决定，对手把尺度挪半格就能把这手
    // 牌的跟注整条关掉。真人这里是一段模糊区。
    //
    // 为什么 `band: 0`（门槛以上不给频率、照旧一律跟）：往上铺坡等于在
    // 「赔率明明够」的价格上也开始丢牌，那不是模糊区、是打错。试过
    // 0.04/0.035 的对称带，35% 池的跟注率从 93% 掉到 66%——弃掉的那些
    // 全是占了便宜的价格，真人在这条线上不会丢。所以只把门槛以下那条
    // 竖直的边改成斜坡，门槛以上一个点不动。
    //
    // 这条斜坡的起点必须是 1.0：`band: 0` 时门槛上方那条斜坡只剩一个点、
    // 取值正是 1.0，可 [_callMix] 的通用式子让下坡从 0.5 起算，门槛两侧
    // 于是留着整整 0.5 的台阶——探针实测 40.5% 池跟 93%、41% 池只剩
    // 44%，半个百分点的池差换掉一半跟注率，跟修之前是同一个病。
    //
    // 带宽从 0.035 收到 0.025：宽度是按 equity 差定的，铺到池的尺度上会
    // 被 [_capRelease] 那条隐含赔率曲线拉长——0.035 对应 0.405~0.57 池，
    // 卡顺在 46% 池还跟 53%、50% 池还跟 25%，一个四条出路的弱听牌在半个
    // 池的价格上跟掉四分之一，比真人松。收到 0.025 之后混合区是
    // 0.405~0.475 池（实测 41% 池跟 91%、42% 78%、44% 57%、46% 44%、
    // 50% 7%），门槛上照样接得上、没有台阶，验证器那句「只有卡顺时面对
    // 下注大多弃牌」也从 70% 回到 94%。
    // 强听牌那档带宽（0.04 上 / 0.08 下）不动：8~9 outs 的牌本来就在
    // 门槛上混着打，那是刻意的。
    if (strongDraw
        ? _callMix(drawEq, need, foldBand: 0.08)
        : _callMix(drawEq, need, band: 0, foldBand: 0.025)) {
      return const AiDecision(ActionType.call);
    }
    // 便宜的小注：弱听牌也可以跟一张看转牌。
    if (spot.betSizeRel <= 0.3 &&
        read.drawOuts >= 4 &&
        drawEq >= need * 0.75) {
      return const AiDecision(ActionType.call);
    }
    return const AiDecision(ActionType.fold);
  }

  /// 怪兽牌面对进攻时「只跟不加」（慢打）的频率。
  ///
  /// 以前这一档几乎是常量：面对一次下注跟 11% / 加 89%，面对加注再加 100%，
  /// 而且干面湿面、翻牌河牌全都一样。等于对手只要看我们「加没加」就知道
  /// 我们有没有大家伙——拿着顶对、听牌的都老远就弃，我们反而收不到价值；
  /// 加注战也一路往上打，最后只剩能打败我们的牌愿意继续放筹码。
  ///
  /// 真人慢打是有条件的，而且理由很具体：
  ///   · 牌面越干越该慢打：加注保护不到任何东西（没听牌可赶），还把对手
  ///     范围里的诈唬和中等牌全打走——干面上「他会不会跟」跟「他有什么」
  ///     几乎无关，留他一手才能让他接着开火；
  ///   · 湿面上听牌愿意付钱，这一笔要收，慢打明显变少（河牌没有听牌了，
  ///     这一条自动失效）；
  ///   · 面对加注比面对下注更少慢打：他既然加注出来，范围本来就更强，
  ///     再加他接得住的概率高，而「留住诈唬」这一半收益却小得多；
  ///   · 河牌没有「以后」了，跟注换不到更多价值，慢打也压一档。
  /// 风格给的 [_Profile.slowPlay] 仍是基准：跟注站本来「中了也不加」。
  double _monsterTrap(GameEngine game, _Spot spot, HandReading read,
      {required bool facingRaise}) {
    // 「湿面少慢打」讲的其实是「收听牌的钱」：这件事只有翻牌/转牌才有。
    // 河牌发完最后一张牌，已经没有听牌要赶，剩下唯一的理由是留住他的诈唬，
    // 所以河牌一律按「干面」那一档算（再乘下面那个河牌折扣）。
    final chargeDraws =
        game.street != Street.river && read.texture.wetness > 0.6;
    var trap = (_p.slowPlay + 0.12) *
        (chargeDraws ? 0.6 : 1.4) *
        (facingRaise ? 0.75 : 1.0);
    if (!spot.inPosition) trap *= 0.8; // 没位置：跟完后面两条街先说话
    if (game.street == Street.river) trap *= 0.7;
    // 下注尺度：真人对小注加注、对大注跟注。对手下得越大，他的范围越两极
    // （转牌/河牌的超池就是「坚果或空气」），我们的加注只会把诈唬打走、把
    // 能打败我们的牌请进来——「加注只被更好的牌跟」这条对怪兽牌同样成立，
    // 以前只接在强牌那一档上（见 [noRaiseVsBigBet]）。这里完全不看尺度：
    // 实测河牌拿两对/三条对着 0.5 倍池加 76%，对着 1.5~2 倍池反而加到 95%
    // （多出来的部分是低 SPR 的自动推），尺度越大加得越凶，正好反了。
    //
    // 翻牌圈不吃这一档：那时候加注是「收听牌的钱」，对手下得大说明底池涨得
    // 快、更要保护，真人对小注大注都愿意加（这条另有「湿面多收」那一项管）。
    // 慢打的上限按街分开：翻牌圈是「收听牌的钱」，加注本来就是这一档的主线，
    // 慢打再满也只有七成；转牌/河牌面对大注，薄怪物退到以跟注为主是对的
    // （对手那条线两极分化，加注只会把诈唬打走），所以放到 0.85。
    var maxTrap = 0.7;
    if (game.street != Street.flop) {
      // 同一个「怪兽牌」档里的成色还得再分一层：两对和顺子/三条被 [HandTier]
      // 压在一起，可真人拿它们面对同一个大注完全是两种打法——顺子、三条
      // 加注收价值，两对更接近抓诈唬、以跟为主。以前这一档只看 tier，探针
      // 实测河牌拿 99（三条）和拿 97（两对）对着 1.5 倍池的读数逐字相同
      // （跟 62% / 加 38%），对手从「他加不加」里读不出我们拿着哪一档，
      // 我们自己也拿薄两对跟三条一样猛。见 [HandReading.monsterGrade]：
      // 以三条（0.6）为基准往外线性拉，坚果级压低慢打、多收价值，
      // 两对抬高慢打、多留诈唬。
      final gradeTrap = 1.0 - (read.monsterGrade - 0.6) * 0.55;
      trap *= (1.0 + 1.6 * (spot.betSizeRel - 0.5)).clamp(1.0, 3.0) * gradeTrap;
      maxTrap = 0.85;
    }
    return trap.clamp(0.0, maxTrap);
  }

  /// 强牌（顶对顶踢、超对这些）面对下注时「抬回去」的频率。
  ///
  /// 以前这一整套写在调用处，而且被 `bigBet`（≥0.7 池）一刀切掉：0.69 池
  /// 顶对顶踢加 31%、0.71 池永远加 0，翻牌/转牌/河牌三条街都一样。对手只要
  /// 试出「打大注不会被加」，拿任意两张牌打大注就白抢底池；反过来 0.69 池
  /// 又总会被加——下注尺度成了「AI 加不加注」的开关。真人对大注也还是留着
  /// 一点加注的（不然加注范围里全是怪物，一眼就读出来），所以拆成这里算频率、
  /// 大注那一侧用 [_bigBetRaiseScale] 连续衰减，不再一刀切。
  ///
  /// 频率由这些项一起决定：
  ///   * 街道：真人不会拿顶对在河牌乱加（翻牌 0.55 / 转牌 0.35 / 河牌 0.18）；
  ///   * 人数：多人池里顶对被两对/三条压住的机会大得多，收着加；
  ///   * 尺度：对手小注试探（≤1/3 池）更像阻挡注或者便宜的诈唬，多抬；
  ///     接近 2/3 池以上更像真东西，抬回去撞上大牌的概率高，多跟注控池。
  ///     以前这一档完全不看尺度，1/4 池和 1/2 池的加注率一模一样（探针实测
  ///     都是 56%），对手拿强牌打大注、拿弱牌打小注，都能从我们「加还是跟」
  ///     的反应里读出手牌强度。折扣本身也必须是连续的：写成三档常量
  ///     （1.2 / 0.9 / 0.6）之后，两个分界点上各有一次跳变——探针实测翻牌
  ///     顶对顶踢对着 0.35 池加 65%、对着 0.37 池只剩 48%，对着 0.59 池还有
  ///     48%、对着 0.61 池只剩 31%。对手只要把注额压到分界点两侧，就能从
  ///     「他加不加」里读出我们拿着什么。现在两个分界点之间线性过渡；
  ///   * 过牌-加注：先过牌再被下注是没位置一方回收价值的主力（拿着顶对憋一手
  ///     等的就是这一注），倍率吃满；别的线吃尺度折扣。位置方向不能反——没位置
  ///     的人加注之后还要在不利位置打后面两条街；
  ///   * 对手已经加注出来：频率减半（那一下本身就说明他的范围强得多）。
  double _strongRaiseChance(GameEngine game, PlayerState me, _Spot spot,
      HandReading read, {required bool checkRaise}) {
    final base = switch (game.street) {
      Street.flop => 0.55,
      Street.turn => 0.35,
      _ => 0.18,
    };
    return base *
        _manyWay(spot) *
        _aggression *
        _p.aggressionScale *
        (spot.betSizeRel <= 0.35
            ? 1.2
            : (spot.betSizeRel >= 0.6
                ? 0.6
                : 1.2 - 0.6 * (spot.betSizeRel - 0.35) / 0.25)) *
        (read.texture.wetness > 0.6 ? 0.8 : 1.0) *
        (checkRaise ? 1.2 : 1.0) *
        (spot.villainRaisedThisStreet ? 0.5 : 1.0);
  }

  /// 超对在翻牌比顶对顶踢多出来的加注频率（加量，不是乘系数）。
  ///
  /// 超对打赢对手范围里的顶对——对手拿顶对就是被我们盖住的那一手；顶对顶踢
  /// 加回去却只被更好的牌跟。真人拿这两手面对同一个下注/加注不是一个打法。
  /// 可 [HandReading.overPair] 这个字段虽然早就算好了，很长一段时间里除了
  /// verify_engine 那句断言之外全代码没人读，于是探针里（同一块 Q♥7♦2♣）
  /// A♥Q♦ 和 K♥K♠ 面对下注、被加注两格都**逐字相同**。
  ///
  /// 为什么是加量，而且挂在 [_strongRaiseChance] 外面：
  ///   · 乘系数：AI 自己就是翻前加注者那种牌局里这条式子本来就有三成上下，
  ///     乘起来直接把超对顶到 100%（探针实测 32% → 100%）。
  ///   · 放式子里面：「对手加到一个底池」那格要走大注分支，
  ///     _bigBetRaiseScale 和 strengthScale 两个折扣一起把它压成 0.4 个点。
  ///
  /// 幅度：翻牌被加注 0.10 / 面对一注 0.08，转牌各收一档（0.08 / 0.06）——
  /// 转牌的加注本来就比翻牌少（base 0.55 → 0.35），差异也跟着收。面对一注时
  /// 顶对顶踢本来就有四成在加（见门禁用例「单加池里顶对顶踢照样要加 >35%」），
  /// 不能往下压，所以想分开只能把超对往上抬一点。两个都按人数折（[_Spot] 的
  /// 口径跟 [_strongRaiseChance] 的 manyWay 一致），不然四人池里那条式子本来
  /// 就只剩一两成，加量相对起来会显得很大。
  ///
  /// 只挂翻牌和转牌：河牌再加回去等于只留下能打败我们的牌——门禁用例「河牌
  /// 下注被加注：顶对不再推回去，只跟」盯着，乘 5 系数那一版就是被它抓红的。
  double _overPairFlopRaiseBonus(GameEngine game, _Spot spot, HandReading read) {
    if (!read.overPair) return 0.0;
    final raised = spot.villainRaisedThisStreet;
    final base = switch (game.street) {
      Street.flop => raised ? 0.10 : 0.08,
      Street.turn => raised ? 0.08 : 0.06,
      _ => 0.0,
    };
    if (base == 0.0) return 0.0;
    return base * _manyWay(spot);
  }

  /// 多人底池对「同一档内部的差异」的摊薄系数。
  ///
  /// 超对 vs 顶对、成牌 + 听牌 vs 纯成牌这些差别，在单挑里各是一手牌的全部，
  /// 到四人池里只是「反正都得跟」的那点边际——真人也是这么打的。口径跟
  /// [_strongRaiseChance] 里那档一致，别各写一份漂掉。
  double _manyWay(_Spot spot) {
    final n = spot.opponents;
    if (n <= 1) return 1.0;
    if (n == 2) return 0.55;
    return 0.3 * _manyTail(n, 3);
  }

  /// 「人多于某一档之后接着摊薄」的尾巴：锚点那两级逐点不变，往后每多一家
  /// 再乘 0.8。
  ///
  /// 多人池的折扣一直是「单挑一档、两家一档、三家以上一档」，第三家往后
  /// **全是同一个数**——四个人的池子、五个人的池子、六个人的池子在我们眼里
  /// 完全一样。探针实测（tool/ai_multi_probe.dart 的 B 节「所有人都过牌到
  /// AI」）：第二对 87 在 3 / 4 / 5 人池里都是下注 24%，花听 AKs 在 4 / 5
  /// 人池都是 37%，空气 87 在 4 / 5 人池都是 4%——逐字相同。真人不会在第三家
  /// 上停下来：后面每多一家，「一注打走所有人」的概率往下走、有人反超的概率
  /// 往上走，两个方向都指向同一个动作：收着打。
  ///
  /// 挂上之后的读数（同一块牌面、同一个种子、300 手一格）：第二对 87 在
  /// 3 / 4 / 5 人池从 24 / 24 / 24 变成 24 / 18 / 13，花听 AKs 从 55 / 37 / 37
  /// 变成 55 / 37 / 28，空气 87 从 7 / 4 / 4 变成 7 / 4 / 3——3 人池那一格
  /// （锚点）逐点没动，掉的是第三家往后。
  ///
  /// 代价记一笔：ai_reraise_probe（9 人桌 1200 手、种子 7）跟着动了——单街
  /// 第 2+ 次加注 54 → 60，其中「一对（strong）」从 4 手涨到 12 手。不过
  /// 第 3+ 次加注（4-bet 以上）还是怪兽牌打底（9 手里 7 手怪兽，改前 9 手
  /// 全是怪兽），而 [_valueRaiseChance] 那边要的本来就是「加注范围别清一色
  /// 是怪兽牌」；收的主要是「没人下注时」的开火与薄价值，加注侧只是跟着
  /// 宽了一点。真正要盯的是那 8 手多出来的 3-bet：牌力下沿确实松了，得靠
  /// 用例继续看着，别一路松成「拿一对就能反加」。
  ///
  /// 挂在 [_manyWay] 上那一处（强牌加注 / 加注尺度的倍率）在 ai_multi_probe
  /// 和 ai_reraise_probe 上都量不出差（逐字相同）：要四家以上、又正好拿着
  /// 强牌面对下注才走到，300 手的分辨率看不见。留着是为了口径一致，不是
  /// 因为量到了。
  ///
  /// [from] 是这一档的锚点人数（`>= 3` 的档传 3、`>= 2` 的档传 2）。锚点本身
  /// 一点不动——那两级是好几条用例和探针格钉着的，改的是它对**上**的延伸。
  double _manyTail(int opponents, int from) =>
      opponents > from ? pow(0.8, opponents - from).toDouble() : 1.0;

  /// 「成牌 + 强听」（顶对顶踢配坚果花听这类）的标记。
  ///
  /// 闸门是 8 张出路：花听 9 张、两头顺 8 张都算，卡顺 4 张不算——多一两张
  /// 出路改变不了这手牌怎么打，真正让真人变激进的是一手成牌之外还多一条街
  /// 的出路（被跟了有得补，被加注了也乐意把筹码放进去）。
  bool _isStrongDraw(HandReading read) =>
      read.tier == HandTier.strong && read.drawOuts >= 8;

  /// 强牌档里「成牌 + 强听」比纯成牌多要的价值下注尺度（乘系数）。
  ///
  /// [HandTier.strong] 只装「顶对以上、怪兽未满」，可它把「顶对顶踢」和
  /// 「顶对顶踢 + 坚果花听」混成一手牌：后者的胜率对着几乎任何范围都过半，
  /// 真人拿它下得更大也更敢把筹码放进去。而 [HandReading.hasDraw] 在强牌
  /// 分支里一直没人读——探针实测同一块 Q♦7♦2♣ 上 A♦Q♦（顶对顶踢 + 坚果
  /// 花听）和 A♠Q♦（纯顶对，牌面逐字相同）在「被过牌到」那格的尺度分布
  /// **逐字相同**，连下注频率都一模一样。
  ///
  /// 幅度刻意比 [_overPairFlopRaiseBonus] 小一档：超对是「打赢对手范围里
  /// 的顶对」的成牌升级，多要两成池都合理；成牌 + 听牌只是多一手出路，
  /// 尺度上多一两成就够。抬多了反而把「下注越大牌越强」这条明线递出去——
  /// 我们现在下大注的范围里会多出一批听牌，正是要它别那么干净。
  /// 只挂翻牌和转牌：河牌听牌已经发完，[_isStrongDraw] 自己也会判成 false。
  double _strongDrawSizeScale(
      GameEngine game, _Spot spot, HandReading read) {
    if (!_isStrongDraw(read)) return 1.0;
    final base = switch (game.street) {
      Street.flop => 0.12,
      Street.turn => 0.08,
      _ => 0.0,
    };
    return 1 + base * _manyWay(spot);
  }

  /// 强牌档里「成牌 + 强听」多出来的加注频率（加量，不是乘系数）。
  ///
  /// 同一块 Q♦7♦2♣、面对同一个 0.5 池下注：A♠Q♦（纯顶对顶踢）加回去只
  /// 被更好的牌跟，A♦Q♦（顶对顶踢 + 坚果花听）加回去被跟也还有一条街的
  /// 出路，真人这两手的加注频率差得很明显。跟 [_overPairFlopRaiseBonus]
  /// 一样挂在 [_strongRaiseChance] 外面，理由同它：乘系数会把本来就三成
  /// 上下的式子顶到一百，放式子里面又会被大注那两个折扣压没。
  ///
  /// 幅度比超对小：超对是打赢顶对的成牌升级，成牌 + 听牌只是半诈唬那一侧
  /// 的底气，翻牌被加注 0.07 / 面对一注 0.06，转牌各收一档。同样按人数折。
  /// 只挂翻牌和转牌，河牌不抬——那时候听牌已经发完，抬了等于拿顶对乱 3-bet。
  double _strongDrawRaiseBonus(
      GameEngine game, _Spot spot, HandReading read) {
    if (!_isStrongDraw(read)) return 0.0;
    final raised = spot.villainRaisedThisStreet;
    final base = switch (game.street) {
      Street.flop => raised ? 0.07 : 0.06,
      Street.turn => raised ? 0.06 : 0.05,
      _ => 0.0,
    };
    if (base == 0.0) return 0.0;
    return base * _manyWay(spot);
  }

  /// 大注（≥0.7 池）对强牌加注频率的压制。0.7 池不吃折扣，1.2 池压到两成，
  /// 中间线性过渡——留两成而不是归零，理由见 [_strongRaiseChance]。
  double _bigBetRaiseScale(_Spot spot) =>
      1 - 0.8 * ((spot.betSizeRel - 0.7) / 0.5).clamp(0.0, 1.0);

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
    // 多人底池别拿一对乱加，人越多越别加（见 [_manyTail]）。
    if (spot.opponents >= 2) {
      base *= 0.35 * _manyTail(spot.opponents, 2);
    }
    if (spot.isThreeBetPot) base *= 0.7; // 3bet 底池大家范围都强
    base *= 1 - 0.6 * spot.villainStrength; // 对手线越强越少加
    // 对手小注更像阻挡注，值得抬回去；大注通常是真牌，别硬顶。
    // 但「加注」和「下注」是两码事：最小加注也是加注，不能按阻挡注处理
    // （这一维以前只看了尺度，没看对手是 bet 还是 raise）。
    if (spot.villainRaisedThisStreet) {
      base *= spot.betSizeRel >= 0.8 ? 0.35 : 0.6;
    } else {
      base *= spot.betSizeRel >= 0.8 ? 0.45 : (spot.betSizeRel <= 0.35 ? 1.3 : 1.0);
    }
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
    // 大注浮不动——但这条曲线以前是一道硬门槛（`betSizeRel > 0.6 直接
    // 返回 0`）：探针实测同一手「后门花 + 两张高张」，0.55 池浮 21%、
    // 0.60 池 15%、0.62 池一手都不浮了。而且这一档一关，浮牌登记的那条
    // 半诈唬线整条消失——转牌对手过牌后「接着开火」的那部分挂在它上面
    // （见 [_checkedTo] 第 6 档里的 [_registerFire]），对手把注抬过 0.6 池
    // 就同时关掉了两条街的诈唬。改成 0.6~1.2 池的线性斜坡：0.6 池以内逐点
    // 不变，1.2 池及以上仍然是零（那头本来就不该浮）。
    //
    // 但「0.6 池以内逐点不变」留了一段常量区间：探针实测 0.40 / 0.50 /
    // 0.55 / 0.60 池四格读数逐字相同（弃 74%、跟 21%），也就是「注越小越
    // 值得跟一张」这个真人最基本的判断在 0.6 池以内根本不存在——对手把注
    // 从 0.6 池收小到 0.4 池，弃牌率一点没变，他大可以照 0.6 池的价格收
    // 价值。补一条便宜那侧的斜坡：0.25 池及以下 ×1.5（再往上见封顶），
    // 0.6 池收敛回 1.0——0.6 池那个锚点和上面那条大注斜坡一个点都不动。
    f *= 1 + 0.5 * ((0.6 - spot.betSizeRel) / 0.35).clamp(0.0, 1.0);
    final priceFade = ((spot.betSizeRel - 0.6) / 0.6).clamp(0.0, 1.0);
    f *= 1 - priceFade;
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
    if (spot.opponents >= 2) base *= 0.4 * _manyTail(spot.opponents, 2);
    // 「大注不硬凑」原来是 `betSizeRel >= 0.8` 的布尔（0.79 池乘 1.0、
    // 0.80 池乘 0.4），探针实测坚果花听（AdKd on Qd7d2c）面对下注：
    // 0.79 池加注 20%、0.80 池 12%、0.81 池 7%——加注率在门槛上一步掉
    // 13 个点，对手把尺度卡在 0.79 池就必被加、卡到 0.81 池就稳收底池。
    // 改成从 0.6 池起连续收到 0.4（1.0 池到满档），两端锚点跟以前一致
    // （0.6 池以下不增不减、1.0 池及以上仍是 0.4）。
    //
    // 面对**加注**那条线必须换一组锚点，因为 [betSizeRel] 在两处的量纲不一样：
    // 加注要先把对手那一注配上，同样「加到 2.2 倍」，摊到相对底池上只有
    // 0.18~0.31 池；加到 3.5 倍也只有 0.37~0.65 池（探针实测的分布，见下）。
    // 而上面这组锚点是照**下注**定的（0.6 池起、1.0 池封顶）——放到加注线上
    // 斜坡整个是死的：探针（tool/ai_vs_raise_probe.dart，转牌牌面已钉死）实测
    // 坚果花听面对 2.2 倍和 3.5 倍都是再加 13%、卡顺两档都是 4%，可同一块牌面
    // 上的强牌和怪兽都随尺度衰减（顶对顶踢 19% → 11%、超对 29% → 17%）。
    // 也就是说「他加到 3.5 倍」这个信息在这一档完全没进决策，而加到 3.5 倍的
    // 人范围实得多、弃牌率也低得多，真人这时候很少再拿听牌往上顶。
    // 所以加注侧按实测分布重定锚点：0.25 池起、0.6 池封顶，压到 0.45
    // （0.25 及以下不动，0.6 及以上乘 0.45）。面对下注那一侧一个点不动。
    final fadeFloor = spot.villainRaisedThisStreet ? 0.45 : 0.4;
    final fadeFrom = spot.villainRaisedThisStreet ? 0.25 : 0.6;
    final fence = spot.villainRaisedThisStreet ? 0.6 : 1.0;
    final bigBetFade =
        ((spot.betSizeRel - fadeFrom) / (fence - fadeFrom)).clamp(0.0, 1.0);
    base *= 1 - (1 - fadeFloor) * bigBetFade;

    // 第二枪选牌：发出来的牌帮不到对手才值得用听牌加注施压。
    base *= barrel;
    // 先过牌再对下注加注（过牌-加注）本来就是没位置时打听牌的主力。
    if (spot.checkedThisStreet) base *= 1.5;
    // 对手已经加注出来了：再加就成了 3-bet 一个范围很实的人——弃牌率低，
    // 被跟就被压着打，而且他这手牌不会再被我们的小加注逼走。真人拿听牌
    // 在这儿的再加注频率明显低于「面对单纯下注」，多数是先跟一手看牌
    // （隐含赔率还在）。以前这一维完全没算，探针实测：卡顺在转牌被加注
    // 有 36% 直接 3-bet、跟注 0%，成了一条「要么加要么弃」的线，
    // 一眼就能被读出来（AI 的加注范围里全是怪兽和听牌，没有强成牌）。
    if (spot.villainRaisedThisStreet) base *= 0.45;
    // 3bet 底池同理，而且这一项在这一档一直是漏的：[_bluffChance]（纯诈唬）
    // 早就有「3bet 池弃牌率低一档、×0.6」，可加注这一侧只在翻前范围里看过
    // 池子类型，翻后的半诈唬加注完全不看。探针实测同一手坚果花听（AdKd on
    // Qd7d2c）面对半池，单加池和 3bet 底池逐档一模一样（跟 77% + 加 23%）
    // ——底池里多了一次 3bet，对「要不要拿听牌加注」没有任何影响。可 3bet
    // 方的范围窄了一半、强度高得多，用加注逼走的那一批牌本来就少，真人在这
    // 儿明显更愿意先跟一手（隐含赔率还在，被 3-bet 也更难受）。
    if (spot.isThreeBetPot) base *= 0.6;
    // 同一个道理还有另一种写法：他不是「这一条街加了一下」，而是**连着几条街
    // 都在开火**。那也一样是范围实、弃牌率低，加注只会把自己送进去。
    //
    // 这一维以前完全没有（文件里其它每个加注频率都算对手的线，只有这里不算），
    // 于是出现了一个方向反了的读数：探针实测同一手坚果花听（AdKd on Qd7d2c），
    // 翻牌面对一枪 1/2 池加 23%（7/5/5/4/2%），转牌面对「1/2 池 + 2/3 池」
    // 这条两枪线反而加到 34%（11/8/7/5/2/1%）——对手的线强了一整档，我们的
    // 半诈唬加注频率涨了五成。真人拿听牌在转牌面对连开两枪明显更愿意先跟一手
    // 看河牌（隐含赔率还在、被 3-bet 更难受），加注留到翻牌那一档。
    base *= 1 - 0.45 * spot.priorAgg;
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
    if (spot.villainRaisedThisStreet) {
      // 加注线不套「小注 = 牌力偏弱」那一套：最小加注也是加注，代表他愿意
      // 把筹码放进去，冲着它去诈唬加注是纯烧钱（被跟之后手里什么都没有）。
      // 老逻辑把最小加注当成阻挡注，还额外乘 2 倍，探针实测：AKQ 这种
      // 完全没后路的空气面对最小加注，11% 直接 3-bet、跟注 0%——
      // 真人在这儿的频率只有它的三分之一。
      // 0.8 池上那道 2.25 倍的开关（0.45 → 0.2）同样量过：AI 开一枪、
      // 英雄按 0.5/0.58/0.62/0.7/0.8 倍池加回来，AKQ 上的纯空气在整段
      // 都是 100% 弃、诈唬再加注 0%（见 tool/ai_probe.dart 的「面对加注」
      // 一节）。基数本来就只剩两三个点，2.25 倍摊到决策上看不见，留着。
      base *= spot.betSizeRel >= 0.8 ? 0.2 : 0.45;
    } else if (spot.betSizeRel <= 0.35) {
      base *= 2.0; // 对手小注 = 牌力偏弱
    }
    // 同一道台阶在这个函数里也有一份：`>= 0.75` 乘 0.35。探针实测破花听
    // （AhJh on Kh7h2c9s3d）面对河牌下注，0.74 池加注 8%、0.75 池只剩 3%。
    // 同样改成连续：从 0.5 池起收到 0.35（1.0 池满档）。
    final bigBetFade = ((spot.betSizeRel - 0.5) / 0.5).clamp(0.0, 1.0);
    base *= 1 - 0.65 * bigBetFade;
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

  /// 尺度混合（筹码额度版）：真人不会永远用一个尺寸——翻前开池、3bet 都一样，
  /// 而是在「小一点 / 正常 / 大一点」之间换档。这既是真人的习惯，也让对手没法
  /// 靠下注尺度反推我们的牌力（固定尺度是最容易被抓的机器味）。
  ///
  /// 概率加权后平均是 ×1.015，所以整体尺度几乎不变，只是不再一条直线。
  /// 这里收的是**筹码额度**（开池 2.4bb 那类绝对数）；翻后的「相对底池比例」
  /// 走 [_mixFrac]，台阶宽度完全不同，两个函数别合并。
  double _mixSize(double frac) {
    final r = _random.nextDouble();
    if (r < 0.20) return frac * 0.85;
    if (r < 0.45) return frac * 1.18;
    return frac;
  }

  /// 尺度混合（底池比例版）：翻后的下注 / 加注都走这里。
  ///
  /// 换档宽度是这条函数的关键，不是随便调的数字。第一版跟 [_mixSize] 共用
  /// 一套窄档（×0.85 / ×1.0 / ×1.18），加权平均 ×1.015——看着「不再是一条
  /// 直线」，实测根本没有换档这回事：探针（`tool/ai_probe.dart` 里按 5% 一档
  /// 分的尺度桶）中 AI 在干燥面上拿顶对 / 三条 / 听牌下注，全部落在
  /// 0.35~0.45 池这一个桶里。三档一叠加，整条分布只有一个峰，对手打两圈就能
  /// 把我们「永远三分之一池」记下来。真人哪怕只打一天，也不会所有牌都用同一
  /// 个尺寸。
  ///
  /// 现在换成真正的台阶（相对基准 ×0.6 / ×0.85 / ×1.0 / ×1.25 / ×1.5），
  /// 权重 0.18 / 0.22 / 0.30 / 0.18 / 0.12，加权平均正好是 ×1.0：整体尺度跟
  /// 以前一样，变的只有分布的宽度。
  ///
  /// 大注那一档（≥0.8 池，含超池诈唬和超池价值）只往回收、不跟着往上翻：
  /// 0.8 池再 ×1.5 就是 1.2 倍池开外，手里那条「1.2 倍池」的超池线会被顺手
  /// 放大成 2 倍池，那是另一个游戏了。这一档用 ×0.85 / ×1.08 / ×1.0
  /// （均值 ×0.99），把「超池永远刚好 1.2 倍」这条同样好读的线也打散一点。
  double _mixFrac(double frac) {
    final r = _random.nextDouble();
    if (frac >= 0.8) {
      if (r < 0.25) return frac * 0.85;
      if (r < 0.60) return frac * 1.08;
      return frac;
    }
    if (r < 0.18) return frac * 0.60;
    if (r < 0.40) return frac * 0.85;
    if (r < 0.70) return frac;
    if (r < 0.88) return frac * 1.25;
    return frac * 1.50;
  }

  /// 下注到本街总额：底池的 [frac]（再按 [_mixFrac] 换一次档）。
  AiDecision _bet(GameEngine game, PlayerState me, double frac) {
    final pot = game.potTotal();
    final add = max(game.config.bigBlind, (pot * _mixFrac(frac)).round());
    return AiDecision(ActionType.bet, amountTo: me.streetBet + add);
  }

  /// 加注到本街总额：在当前最高注上再加一个底池比例（至少补足最小加注）。
  /// 尺度同样过 [_mixFrac]。
  AiDecision _raise(GameEngine game, PlayerState me, double frac) {
    final pot = game.potTotal();
    final minRaise = game.minRaiseTo - game.currentBet;
    final add = max(minRaise, (pot * _mixFrac(frac)).round());
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
    required this.coldCallers,
    required this.priorAgg,
    required this.villainCalls,
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

  /// 还留在牌局里的「翻前用跟注进池」的人数（冷跟者 / 溜入者）。
  ///
  /// 跟 [limpers] 的区别：[limpers] 数的是「跟注这个动作发生过几次」，
  /// 已经弃牌的人也算；这一项只数**还没弃牌**的那些。防守 3bet 时要看的
  /// 是「池里现在还有几家」，一个已经弃掉的人不该让我们的隐含赔率变好。
  final int coldCallers;

  /// 对手在前面几条街已经在开火的累计强度（0~2）：
  /// 一条街一条街地砸过来，手里的东西和「只开一枪」完全不是一回事。
  final double priorAgg;

  /// 前面几条街「我下注、他跟注」了几次（0~2）。
  ///
  /// [priorAgg] 记的是**他**开火，这一项记的是**我**开火之后他的回应。
  /// 第三枪最关键的输入就是这个：翻牌开一枪被跟、转牌再开一枪被跟，对手
  /// 的范围已经从「随便看看」筛成了真东西，同样的空气在河牌再开一枪就是
  /// 白送一个底池。真人这时候只剩「阻断牌够硬」和「最强的那些破听牌」还
  /// 会开火，以前 AI 完全没有这个变量——不管被跟了几条街，河牌的开火频率
  /// 都是同一个数（探针：破坚果花听 65%、纯空气 37%，而这两条线的对手
  /// 范围其实差着一整个数量级）。
  final int villainCalls;

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
    final calledIds = <String>{};
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
        if (a.actorId != me.id) calledIds.add(a.actorId);
      }
    }
    // 还留在牌局里的跟注者（已经弃掉的不算）。
    final coldCallers = calledIds.where((id) =>
        game.active.any((p) => p.id == id)).length;
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

    // 下注尺度「相对底池多大」：分母要扣掉「对手出手之后、我动作之前」中间
    // 那几家的跟注钱。不扣的话，多人池里同一个 1.5 倍池的注会被读成小注——
    // 固定 SPR 探针实测河牌面对 1.5 倍池，顶对顶踢单挑弃 45%、三人池只剩
    // 4%、四人池 1%，还反过来加注 10%：中间两家的跟注把池撑大，betSizeRel
    // 从 1.5 掉到 0.375，连「大注」的门槛（0.7）都没够上，靠尺度说话的那
    // 几档（河牌挑着弃、不拿一对反加）整条失效。单挑时这一项恒为 0，读数
    // 跟以前一模一样。
    var betSizeDenom = pot - toCall;
    for (var i = actions.length - 1; i >= 0; i--) {
      final a = actions[i];
      if (a.street != game.street) break;
      if (a.actorId == me.id) continue;
      if (a.type != ActionType.bet && a.type != ActionType.raise) continue;
      betSizeDenom -= pot - a.potAfter; // 他出手之后、我动作之前别人跟的钱
      break;
    }
    final betSizeRel =
        toCall > 0 ? toCall / max(bb, betSizeDenom) : 0.0;
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

    // 「我下注、他跟注」发生过的条数（只看翻牌和转牌，翻前的跟注是常规
    // 动作、说明不了什么）。过牌给他、他下注我跟，都不算——那条线里他才是
    // 主动的一方，已经由 [priorAgg] 记着了。
    var villainCalls = 0;
    for (final st in const [Street.flop, Street.turn]) {
      if (st == game.street) continue;
      final onStreet = actions.where((a) => a.street == st);
      final iFired = onStreet.any((a) =>
          a.actorId == me.id &&
          (a.type == ActionType.bet || a.type == ActionType.raise));
      if (iFired &&
          onStreet.any(
              (a) => a.actorId != me.id && a.type == ActionType.call)) {
        villainCalls++;
      }
    }

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
      coldCallers: coldCallers,
      priorAgg: priorAgg,
      villainCalls: villainCalls,
      polarizedBet: polarizedBet,
      villainStrength: villainStrength,
      villainTightness: (0.55 + 0.45 * villainStrength).clamp(0.5, 1.0),
      canRaise: me.stack > toCall,
    );
  }
}
