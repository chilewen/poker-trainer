import '../../../engine/hand_history.dart';

/// 一局结束后的总结（纯 Dart，不碰 Flutter，好在用例里直接断言）。
///
/// 数字全部来自控制器一直在维护的本局计数，不是从全量历史里筛的
/// ——历史是跨局的（换桌不清空），拿它当「本局」用会多出上一桌的牌。
/// 这个类只管「怎么读」，不管「怎么算」。
class SessionSummary {
  const SessionSummary({
    required this.tableName,
    required this.label,
    required this.handsPlayed,
    required this.handsWon,
    required this.handsLost,
    required this.handsTied,
    required this.heroNet,
    required this.bestHandNet,
    required this.worstHandNet,
    required this.rebuys,
    required this.maxRebuys,
    required this.duration,
    required this.endReason,
    this.hands = const [],
  });

  /// 对局页标题用的桌名（不带盲注）。
  final String tableName;

  /// 带盲注级别的完整标签（如「实战 6人桌 · 50/100」）。
  final String label;

  /// 本局打完的手数。
  final int handsPlayed;

  final int handsWon;
  final int handsLost;
  final int handsTied;

  /// 本局净输赢（含盲注、不含补码——补码是往桌上补钱，不是赢来的）。
  final int heroNet;

  /// 单手最大盈利 / 最大亏损；没有对应手牌时为 0。
  final int bestHandNet;
  final int worstHandNet;

  final int rebuys;
  final int maxRebuys;

  /// 本局时长（第一次坐下来到现在）。
  final Duration duration;

  /// 为什么结束：'主动结束' / '筹码输光' 之类，直接显示给玩家。
  final String endReason;

  /// 本局打过的牌（最新在前），给「逐手明细」用。
  final List<HandHistory> hands;

  /// 胜率：赢的手数 ÷ 打过的总手数。没打过牌时按 0。
  double get winRate => handsPlayed == 0 ? 0 : handsWon / handsPlayed;

  /// 每手平均盈亏，向下取整（负数是输）。没打过牌时 0。
  int get netPerHand => handsPlayed == 0 ? 0 : heroNet ~/ handsPlayed;

  /// 补码次数是不是已经用完（用完再输光这局就结束了）。
  bool get rebuysExhausted => rebuys >= maxRebuys;

  /// 一句话结论，给总结页顶部那行大字用。
  String get verdict {
    if (handsPlayed == 0) return '没打完就收了';
    if (heroNet > 0) return '这局是赢着走的';
    if (heroNet < 0) return '这局是输着走的';
    return '不输不赢，白忙一场';
  }

  /// 时长文案：`1 小时 12 分` / `12 分 30 秒` / `38 秒`。
  ///
  /// 只写到「秒」：一局通常几十分钟，再细没有意义，反而让数字变长。
  String get durationText {
    final s = duration.inSeconds;
    if (s < 60) return '$s 秒';
    final m = s ~/ 60;
    if (m < 60) return '$m 分 ${s % 60} 秒';
    return '${m ~/ 60} 小时 ${m % 60} 分';
  }
}
