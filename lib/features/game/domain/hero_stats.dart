import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';

/// 英雄的打法统计：VPIP / PFR / 3bet / 攻击系数 / 摊牌。
///
/// 纯 Dart（不碰 Flutter）。统计页拿全量历史、对局总结拿本局那几十手，
/// 走的是同一个类——两处各写一份口径，迟早会对不上。
///
/// 口径：
/// - VPIP：翻前主动投钱的手数占比（跟注/加注；盲注不算）。
/// - PFR：翻前自己加注过的手数占比。
/// - 3bet：面对别人的加注、自己再加注的次数 ÷ 面对过加注的次数
///   （只看翻开后的第一次决策，后面几条街的再加注不算 3bet）。
/// - 攻击系数 AF：(下注 + 加注) ÷ 跟注，所有街道一起算。
/// - 摊牌胜率：走到摊牌的手里赢的比例——高 VPIP 配低摊牌胜率就是典型鱼。
class HeroStats {
  HeroStats({required this.heroId});

  final String heroId;

  int hands = 0;
  int net = 0;
  int wins = 0;

  int vpipHands = 0;
  int pfrHands = 0;
  int threeBetHands = 0;
  int threeBetChances = 0;

  int aggressiveActs = 0; // 所有街道的 bet + raise
  int calls = 0;
  int showdowns = 0;
  int showdownWins = 0;

  /// 每手打完之后的本局累计盈亏，用来画曲线。
  final List<double> cumulativeNet = [];

  double get winRate => hands == 0 ? 0 : wins / hands;

  double get vpip => hands == 0 ? 0 : vpipHands / hands;

  double get pfr => hands == 0 ? 0 : pfrHands / hands;

  /// 没面对过加注时返回 null（0/0 不是 0%，是「没这个机会」）。
  double? get threeBet =>
      threeBetChances == 0 ? null : threeBetHands / threeBetChances;

  /// 没跟注过时返回 null（infinity 显示出来没意义）。
  double? get aggressionFactor =>
      calls == 0 ? null : aggressiveActs / calls;

  /// 没摊牌过时返回 null。
  double? get showdownWinRate =>
      showdowns == 0 ? null : showdownWins / showdowns;

  int get netPerHand => hands == 0 ? 0 : net ~/ hands;

  static HeroStats from(
    Iterable<HandHistory> chronological, {
    required String heroId,
  }) {
    final s = HeroStats(heroId: heroId);
    for (final hand in chronological) {
      if (!hand.holeCards.containsKey(heroId)) continue;
      s.hands++;
      final result = hand.netResult[heroId] ?? 0;
      s.net += result;
      if (result > 0) s.wins++;
      s.cumulativeNet.add(s.net.toDouble());

      var putVoluntary = false;
      var raisedPreflop = false;
      // 翻前前两条 bet 是大小盲：盲注在记录里也是 bet，但它不是英雄「主动」
      // 投的钱，算进 VPIP / 攻击系数会把每手都算成入池。
      var blindPosts = 0;
      for (final a in hand.actions) {
        final isBlind = a.street == Street.preflop &&
            a.type == ActionType.bet &&
            blindPosts < 2;
        if (isBlind) blindPosts++;
        if (a.actorId != heroId) continue;
        switch (a.type) {
          case ActionType.bet:
          case ActionType.raise:
            if (isBlind) break;
            s.aggressiveActs++;
            if (a.street == Street.preflop) {
              putVoluntary = true;
              raisedPreflop = true;
            }
          case ActionType.call:
            s.calls++;
            if (a.street == Street.preflop) putVoluntary = true;
          case ActionType.check:
          case ActionType.fold:
            break;
        }
      }
      if (putVoluntary) s.vpipHands++;
      if (raisedPreflop) s.pfrHands++;

      _countThreeBetChance(s, hand);

      // 引擎不落「摊牌」这个动作，所以不能按 street==showdown 判。摊牌的
      // 硬特征只有一个：五张公共牌发完、英雄还没弃——一键全下把别人打跑
      // 的那种（发不满五张）不算摊牌。
      final heroFolded = hand.actions
          .any((a) => a.actorId == s.heroId && a.type == ActionType.fold);
      if (!heroFolded && hand.board.length == 5) {
        s.showdowns++;
        if (result > 0) s.showdownWins++;
      }
    }
    return s;
  }

  /// 翻前第一次决策时，前面有没有人加过注；有就是一次 3bet 机会。
  ///
  /// 盲注在记录里是 `bet`（不是 raise），所以这里天然不会被当成加注。
  static void _countThreeBetChance(HeroStats s, HandHistory hand) {
    var raisedBefore = false;
    var acted = false;
    for (final a in hand.actions) {
      if (a.street != Street.preflop) break;
      if (a.actorId == s.heroId) {
        final isRealAction = a.type == ActionType.call ||
            a.type == ActionType.raise ||
            a.type == ActionType.fold ||
            a.type == ActionType.check;
        if (!isRealAction || acted) continue;
        acted = true;
        if (raisedBefore) {
          s.threeBetChances++;
          if (a.type == ActionType.raise) s.threeBetHands++;
        }
      } else if (a.type == ActionType.raise) {
        raisedBefore = true;
      }
    }
  }
}
