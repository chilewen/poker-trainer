import 'dart:math';

import '../../../engine/card.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import 'table_position.dart';

/// 一次动作的「决策上下文」：动手之前的底池、面对的下注、后手还剩多少。
///
/// 全部从 [HandHistory] 推出来，不额外落盘——存档里已有的那些字段就够：
/// 每个 [ActionRecord] 都带 `potAfter`，相邻两条一减就是这步投进去多少。
class DecisionPoint {
  const DecisionPoint({
    required this.index,
    required this.street,
    required this.actorId,
    required this.actorName,
    required this.position,
    required this.type,
    required this.isHero,
    required this.isBlind,
    required this.blindLabel,
    required this.toAmount,
    required this.potBefore,
    required this.toCall,
    required this.amountIn,
    required this.potAfter,
    required this.stackBefore,
    required this.currentBet,
  });

  /// 在 `hand.actions` 里的序号（后面接回放/重玩要用同一个下标）。
  final int index;
  final Street street;
  final String actorId;
  final String actorName;

  /// 中文位置名（庄位/小盲/…）；人数或按钮位缺失时为 null。
  final String? position;
  final ActionType type;
  final bool isHero;

  /// 翻前那两条盲注（记录里存的也是 bet），不是玩家主动下注。
  final bool isBlind;

  /// 盲注是哪一个：'小盲' / '大盲'；不是盲注时为 null。
  final String? blindLabel;

  /// 这步做完之后本街累计投入多少——即下注/加注说的「到多少」。
  ///
  /// 和 [amountIn] 不同：加注「到 30」时英雄本街可能已经先投了 5（盲注），
  /// 那 [amountIn] 只是后补的 25。复盘要显示的是 30。
  final int toAmount;

  /// 动作前的底池（已含对手这一注）。
  final int potBefore;

  /// 面对的下注额：0 = 可以免费过牌。盲注不算「面对下注」，记 0。
  final int toCall;

  /// 这一步实际投进去的筹码。
  final int amountIn;

  final int potAfter;

  /// 动作前的后手（剩余筹码）。
  final int stackBefore;

  /// 动作前本街的最大下注额。
  final int currentBet;

  /// 底池赔率：跟 [toCall] 去赢 [potBefore]，保本需要的最低胜率（0~1）。
  ///
  /// 口径和 `Odds.potOdds` 一致（pot 是跟注前的底池，已经包含对手这一注）。
  double get potOdds => toCall <= 0 ? 0 : toCall / (potBefore + toCall);

  /// 是不是「面对下注要决定跟不跟」：有跟注额、且不是盲注。
  bool get facingBet => toCall > 0 && !isBlind;

  /// 「跟注 / 弃牌」二选一时的期望换算：以 [potOdds] 为保本线。
  bool get isCloseCall => facingBet && potOdds >= 0.20 && potOdds <= 0.40;
}

/// 一条街的行动线（按发生顺序）。
class StreetLine {
  const StreetLine({required this.street, required this.entries});

  final Street street;

  /// 如 `['庄位 加注 300', '我 跟注 300']`。
  final List<String> entries;

  String get text => entries.join(' → ');
}

/// 单手牌的复盘数据：基础信息 + 行动线 + 每次决策的底池赔率。
///
/// 纯 Dart（不碰 Flutter），所以可以直接在用例里断言，也能给总结页、复盘页、
/// 探针共用。
class HandAnalysis {
  const HandAnalysis._({
    required this.hand,
    required this.heroId,
    required this.order,
    required this.heroSeat,
    required this.heroPosition,
    required this.heroHole,
    required this.heroNet,
    required this.finalPot,
    required this.potPreflop,
    required this.potAtFlop,
    required this.effectiveStackAtFlop,
    required this.decisions,
    required this.lines,
  });

  final HandHistory hand;
  final String heroId;

  /// 开局的玩家顺序（`playerNames` 的键顺序），位置就是按它算的。
  final List<String> order;

  /// 英雄在 [order] 里的下标（-1 = 这手里没英雄）。
  final int heroSeat;

  /// 英雄的位置名（庄位/小盲/…）。
  final String? heroPosition;

  final List<Card> heroHole;

  /// 英雄本手净输赢。
  final int heroNet;

  /// 最后一动之后的底池总额。
  final int finalPot;

  /// 翻前打完时的底池（含盲注）。没发过牌时为 0。
  final int potPreflop;

  /// 进翻牌时的底池；这手没走到翻牌就是 null。
  final int? potAtFlop;

  /// 进翻牌时还在牌里的玩家中，最小的后手（有效筹码）。
  final int? effectiveStackAtFlop;

  /// 这手的所有决策点（含盲注和对手的）。
  final List<DecisionPoint> decisions;

  /// 按街分组的行动线。
  final List<StreetLine> lines;

  /// 英雄自己的决策点。
  List<DecisionPoint> get heroDecisions =>
      [for (final d in decisions) if (d.isHero) d];

  /// 英雄面对下注的决策点（要决定跟/加/弃的那些）。
  List<DecisionPoint> get heroFacingBet =>
      [for (final d in heroDecisions) if (d.facingBet) d];

  int get nPlayers => order.length;

  /// 每条街的行动线拼成一行，用来一眼扫完整手。
  String get actionLine => lines.map((l) => '${l.street.label} ${l.text}').join(' ｜ ');

  /// 翻前底池已经多少（盲注 + 翻前投入）——用来判断「这手是个大池还是小池」。
  bool get isMultiway => order.length > 2;

  /// 进翻牌时的 SPR（有效筹码 ÷ 底池）。没走到翻牌就是 null。
  ///
  /// 0.5 以下 = 已经套牢；1~3 = 一注到两注就全下；6 以上 = 深筹码，可以多点
  /// 操作空间。复盘时看这个比看绝对筹码直观。
  double? get spr {
    final pot = potAtFlop;
    final stack = effectiveStackAtFlop;
    if (pot == null || stack == null || pot <= 0) return null;
    return stack / pot;
  }

  static HandAnalysis of(HandHistory hand, {required String heroId}) {
    final order = hand.playerNames.keys.toList();
    final decisions = <DecisionPoint>[];
    // 本街投入：推「面对多少」和「后手还剩多少」都靠它。
    final streetIn = {for (final id in order) id: 0};
    final behind = Map<String, int>.of(hand.startingStacks);
    final folded = <String>{};

    var street = hand.actions.isEmpty ? Street.preflop : hand.actions.first.street;
    var currentBet = 0;
    var blindPosts = 0; // 翻前前两条 bet 就是大小盲
    int? potPreflop;
    int? potAtFlop;
    int? effectiveStackAtFlop;
    var flopCaptured = false;

    for (var i = 0; i < hand.actions.length; i++) {
      final a = hand.actions[i];
      final potBefore = i == 0 ? 0 : hand.actions[i - 1].potAfter;

      if (a.street != street) {
        if (street == Street.preflop) potPreflop = potBefore;
        if (a.street == Street.flop && !flopCaptured) {
          flopCaptured = true;
          potAtFlop = potBefore;
          final live = [
            for (final id in order)
              if (!folded.contains(id)) behind[id] ?? 0,
          ];
          effectiveStackAtFlop = live.isEmpty ? 0 : live.reduce(min);
        }
        street = a.street;
        for (final id in order) {
          streetIn[id] = 0;
        }
        currentBet = 0;
      }

      final amountIn = max(0, a.potAfter - potBefore);
      final isBlind = a.street == Street.preflop &&
          a.type == ActionType.bet &&
          blindPosts < 2;
      final blindLabel = !isBlind ? null : (blindPosts == 0 ? '小盲' : '大盲');
      if (isBlind) blindPosts++;
      // 盲注明面上也「面对」大盲，但那不是要做的决策，按 0 记。
      final toCall = isBlind
          ? 0
          : max(0, currentBet - (streetIn[a.actorId] ?? 0));
      final toAmount = max(0, (streetIn[a.actorId] ?? 0) + amountIn);

      decisions.add(DecisionPoint(
        index: i,
        street: a.street,
        actorId: a.actorId,
        actorName: hand.playerNames[a.actorId] ?? a.actorId,
        position: cnPosition(order, hand.buttonIndex, a.actorId),
        type: a.type,
        isHero: a.actorId == heroId,
        isBlind: isBlind,
        blindLabel: blindLabel,
        toAmount: toAmount,
        potBefore: potBefore,
        toCall: toCall,
        amountIn: amountIn,
        potAfter: a.potAfter,
        stackBefore: behind[a.actorId] ?? 0,
        currentBet: currentBet,
      ));

      if (a.type == ActionType.fold) folded.add(a.actorId);
      streetIn[a.actorId] = (streetIn[a.actorId] ?? 0) + amountIn;
      behind[a.actorId] = (behind[a.actorId] ?? 0) - amountIn;
      if (a.type == ActionType.bet || a.type == ActionType.raise) {
        currentBet = max(currentBet, streetIn[a.actorId] ?? 0);
      }
    }
    // 整手都在翻前（或只有盲注）：翻前底池就是最终底池。
    potPreflop ??= hand.finalPot;

    return HandAnalysis._(
      hand: hand,
      heroId: heroId,
      order: order,
      heroSeat: order.indexOf(heroId),
      heroPosition: cnPosition(order, hand.buttonIndex, heroId),
      heroHole: hand.holeCards[heroId] ?? const [],
      heroNet: hand.netResult[heroId] ?? 0,
      finalPot: hand.finalPot,
      potPreflop: potPreflop,
      potAtFlop: potAtFlop,
      effectiveStackAtFlop: effectiveStackAtFlop,
      decisions: decisions,
      lines: _linesOf(hand, decisions, heroId),
    );
  }

  static List<StreetLine> _linesOf(
    HandHistory hand,
    List<DecisionPoint> decisions,
    String heroId,
  ) {
    final byStreet = <Street, List<String>>{};
    for (final d in decisions) {
      final who = d.blindLabel ??
          (d.isHero ? '我' : (d.position ?? shortPlayerName(d.actorName)));
      byStreet.putIfAbsent(d.street, () => []).add('$who ${_verbOf(d)}');
    }
    return [
      for (final street in Street.values)
        if (byStreet[street]?.isNotEmpty ?? false)
          StreetLine(street: street, entries: byStreet[street]!),
    ];
  }

  static String _verbOf(DecisionPoint d) {
    if (d.isBlind) return '${d.toAmount}';
    return switch (d.type) {
      ActionType.fold => '弃牌',
      ActionType.check => '过牌',
      ActionType.call => '跟注 ${d.amountIn}',
      ActionType.bet => '下注 ${d.toAmount}',
      ActionType.raise => '加注到 ${d.toAmount}',
    };
  }
}
