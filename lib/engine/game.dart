import 'dart:math';

import 'card.dart';
import 'hand_evaluator.dart';
import 'hand_history.dart';
import 'types.dart';

/// 牌桌配置：起始筹码与盲注级别。
class GameConfig {
  const GameConfig({
    this.startingStack = 10000,
    this.smallBlind = 50,
    this.bigBlind = 100,
  }) : assert(bigBlind >= smallBlind);

  final int startingStack;
  final int smallBlind;
  final int bigBlind;
}

/// 单个玩家在一手牌里的实时状态（筹码跨手牌保留）。
class PlayerState {
  PlayerState({required this.id, required this.name, this.stack = 0});

  final String id;
  final String name;
  int stack;

  final List<Card> holeCards = [];
  int streetBet = 0; // 本街已下注
  int totalBet = 0; // 本手牌累计下注
  bool folded = false;
  bool allIn = false;

  void resetForHand() {
    holeCards.clear();
    streetBet = 0;
    totalBet = 0;
    folded = false;
    allIn = false;
  }

  @override
  String toString() =>
      '$name(stack=$stack,streetBet=$streetBet,totalBet=$totalBet'
      '${folded ? ',folded' : ''}${allIn ? ',allIn' : ''})';
}

/// 单个可执行动作。bet/raise 用 [minAmount]/[maxAmount] 给出「下到」的额度区间。
class LegalAction {
  const LegalAction(this.type,
      {this.amount = 0, this.minAmount = 0, this.maxAmount = 0});

  final ActionType type;
  final int amount;
  final int minAmount;
  final int maxAmount;
}

/// 一手牌的完整执行器：发牌、下注轮、边池、摊牌。
///
/// 用法：
/// ```dart
/// final game = GameEngine(config: config)..addPlayer(...)..startHand();
/// while (!game.handOver) {
///   final pending = game.pendingAction();
///   game.apply(pending.player.id, ActionType.call);
/// }
/// ```
///
/// 规则说明：短筹码全下加注不足最小加注额时按全下处理，
/// 简化起见允许其他玩家再次加注（严格的“不再开放下注”规则未实现）。
class GameEngine {
  GameEngine({this.config = const GameConfig(), Random? random})
      : _random = random ?? Random();

  final GameConfig config;
  final Random _random;

  final List<PlayerState> players = [];
  final List<Card> board = [];
  List<Card> _deck = [];
  List<Card> _boardOverride = [];

  /// 当前手牌按钮位在 [players] 中的索引；未开局时为 -1。
  ///
  /// [startHand] 每次会把它往前挪一格；恢复存档时可以直接赋值，
  /// 把按钮位拨回上一手的位置（下一手再照常前移）。
  int buttonIndex = -1;
  Street _street = Street.preflop;
  int _actorIndex = 0;
  int _remainingToAct = 0; // 本街还需行动的人数
  int _minRaise = 0; // 最小加注量（相对当前最高注）

  bool handOver = false;
  HandHistory? lastHand;

  // ---------- 只读状态 ----------

  Street get street => _street;

  List<PlayerState> get active =>
      players.where((p) => !p.folded).toList(growable: false);

  List<PlayerState> get actable =>
      players.where((p) => !p.folded && !p.allIn).toList(growable: false);

  int get currentBet =>
      players.fold(0, (m, p) => p.streetBet > m ? p.streetBet : m);

  int get minRaiseTo => currentBet + _minRaise;

  int potTotal() => players.fold(0, (s, p) => s + p.totalBet);

  void addPlayer(String id, String name, {int? stack}) {
    players.add(PlayerState(
      id: id,
      name: name,
      stack: stack ?? config.startingStack,
    ));
  }

  /// 两手之间补充筹码：补满至设置的起始筹码，返回补充数量。
  /// （本手进行中请勿调用，会破坏记账一致性。）
  int topUp(String playerId) {
    final p = players.firstWhere(
      (p) => p.id == playerId,
      orElse: () => throw ArgumentError('未知玩家: $playerId'),
    );
    final add = config.startingStack - p.stack;
    if (add <= 0) return 0;
    p.stack += add;
    return add;
  }

  // ---------- 手牌生命周期 ----------

  /// 推进按钮位并发一手新牌。
  ///
  /// [holeOverride] 可指定部分/全部玩家的底牌（用于错局重玩），
  /// 未指定的玩家随机发牌；[boardOverride] 预定本手公共牌，
  /// 发公共牌时优先从其中取牌，不足部分从牌堆随机补足。
  void startHand({
    Map<String, List<Card>>? holeOverride,
    List<Card>? boardOverride,
  }) {
    if (players.length < 2) {
      throw StateError('至少需要 2 名玩家');
    }
    for (final p in players) {
      p.resetForHand();
    }
    buttonIndex = (buttonIndex + 1) % players.length;
    board.clear();
    _street = Street.preflop;
    handOver = false;
    _minRaise = config.bigBlind;

    _boardOverride = List.of(boardOverride ?? const []);
    _deck = [
      for (final suit in Suit.values)
        for (final rank in Rank.values) Card(rank, suit),
    ]..shuffle(_random);
    if (holeOverride != null) {
      for (final entry in holeOverride.entries) {
        final p = players.firstWhere(
          (pl) => pl.id == entry.key,
          orElse: () => throw ArgumentError('未知玩家: ${entry.key}'),
        );
        for (final c in entry.value) {
          if (!_deck.remove(c)) {
            throw ArgumentError('底牌重复或不存在: $c');
          }
        }
        p.holeCards.addAll(entry.value);
      }
    }
    // 从公共牌覆盖中剔除牌堆里的对应牌，避免重复发出。
    for (final c in _boardOverride) {
      _deck.remove(c);
    }
    for (final p in players) {
      while (p.holeCards.length < 2) {
        p.holeCards.add(_deck.removeLast());
      }
    }

    lastHand = HandHistory(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now(),
      playerNames: {for (final p in players) p.id: p.name},
      startingStacks: {for (final p in players) p.id: p.stack},
      holeCards: {for (final p in players) p.id: List.of(p.holeCards)},
      buttonIndex: buttonIndex,
      smallBlind: config.smallBlind,
      bigBlind: config.bigBlind,
    );

    // 下盲注（不足则全下）。
    _postBlind(_smallBlindIndex(), config.smallBlind);
    _postBlind(_bigBlindIndex(), config.bigBlind);

    // 预翻牌圈第一个行动：
    // - 单挑：庄位（小盲）先动；多人桌：大盲下一家（枪口位）。
    _actorIndex = players.length == 2
        ? _smallBlindIndex()
        : (_bigBlindIndex() + 1) % players.length;
    _skipToActable();
    _remainingToAct = actable.length;
    _maybeEarlyFinish();
  }

  int _smallBlindIndex() =>
      players.length == 2 ? buttonIndex : (buttonIndex + 1) % players.length;

  int _bigBlindIndex() => (_smallBlindIndex() + 1) % players.length;

  void _postBlind(int index, int amount) {
    final p = players[index];
    _putChips(p, amount);
    lastHand?.actions.add(ActionRecord(
      street: _street,
      actorId: p.id,
      type: ActionType.bet,
      amount: amount,
      potAfter: potTotal(),
    ));
  }

  /// 从 [_actorIndex] 起向后找到第一个可行动的玩家。
  void _skipToActable() {
    for (var i = 0; i < players.length; i++) {
      final p = players[_actorIndex];
      if (!p.folded && !p.allIn) return;
      _actorIndex = (_actorIndex + 1) % players.length;
    }
  }

  // ---------- 决策接口 ----------

  /// 当前等待行动的玩家与其合法动作。
  ({PlayerState player, List<LegalAction> actions}) pendingAction() {
    if (handOver) {
      throw StateError('本手已结束');
    }
    final actor = players[_actorIndex];
    if (actor.folded || actor.allIn) {
      throw StateError('内部状态错误：行动者不可行动');
    }
    return (player: actor, actions: legalActions(actor));
  }

  /// 某玩家当前可执行的动作与合法范围。
  List<LegalAction> legalActions(PlayerState p) {
    if (p.folded || p.allIn) return const [];
    final toCall = currentBet - p.streetBet;
    final actions = <LegalAction>[LegalAction(ActionType.fold)];
    if (toCall == 0) {
      actions.add(const LegalAction(ActionType.check));
    } else {
      actions.add(
          LegalAction(ActionType.call, amount: toCall.clamp(0, p.stack)));
    }
    if (p.stack > toCall) {
      // 留有加注空间（含全下加注）。
      final maxTo = p.streetBet + p.stack;
      final minTo = minRaiseTo.clamp(currentBet, maxTo);
      if (maxTo > currentBet) {
        actions.add(LegalAction(
          currentBet == 0 ? ActionType.bet : ActionType.raise,
          minAmount: minTo,
          maxAmount: maxTo,
        ));
      }
    }
    return actions;
  }

  /// 执行一次动作；bet/raise 的 [amount] 是「下到」的本街总额度。
  void apply(String playerId, ActionType type, {int? amount}) {
    if (handOver) {
      throw StateError('本手已结束，不能继续行动');
    }
    final actor = players[_actorIndex];
    if (actor.id != playerId) {
      throw StateError('轮到 ${actor.id}，不是 $playerId');
    }

    var reopened = false; // 本次动作是否让大家需要再次表态
    switch (type) {
      case ActionType.fold:
        actor.folded = true;
      case ActionType.check:
        if (actor.streetBet < currentBet) {
          throw StateError('当前必须跟注，不能过牌');
        }
      case ActionType.call:
        final need = currentBet - actor.streetBet;
        _putChips(actor, need);
      case ActionType.bet:
      case ActionType.raise:
        final to = amount ?? minRaiseTo;
        reopened = _placeBet(actor, to);
    }
    lastHand?.actions.add(ActionRecord(
      street: _street,
      actorId: playerId,
      type: type,
      amount: amount ?? 0,
      potAfter: potTotal(),
    ));

    _remainingToAct = reopened
        ? actable.where((p) => p != actor).length
        : _remainingToAct - 1;

    if (active.length == 1) {
      _finishUncontested();
      return;
    }
    if (_remainingToAct <= 0) {
      _advanceStreet();
    } else {
      _actorIndex = (_actorIndex + 1) % players.length;
      _skipToActable();
    }
  }

  // ---------- 内部流程 ----------

  void _putChips(PlayerState p, int delta) {
    final actual = delta.clamp(0, p.stack);
    p.stack -= actual;
    p.streetBet += actual;
    p.totalBet += actual;
    if (p.stack == 0) p.allIn = true;
  }

  /// 下注/加注。返回是否重新开放下注（需要其他玩家再次表态）。
  bool _placeBet(PlayerState p, int toAmount) {
    final maxTo = p.streetBet + p.stack;
    if (toAmount <= currentBet || toAmount > maxTo) {
      throw StateError('非法下注额 $toAmount（当前 $currentBet，上限 $maxTo）');
    }
    // 不足最小加注额且玩家还有余 → 强制最小加注；全下则允许。
    var to = toAmount;
    final isAllIn = to == maxTo;
    if (!isAllIn && to < minRaiseTo) {
      to = minRaiseTo;
    }
    if (to > currentBet) {
      _minRaise = to - currentBet;
    }
    _putChips(p, to - p.streetBet);
    return true;
  }

  void _advanceStreet() {
    if (_street == Street.river) {
      _street = Street.showdown;
      _finishShowdown();
      return;
    }
    final next = switch (_street) {
      Street.preflop => Street.flop,
      Street.flop => Street.turn,
      Street.turn => Street.river,
      _ => Street.showdown,
    };
    _street = next;
    final n = next == Street.flop ? 3 : 1;
    _dealBoard(n);

    // 重置本街下注。
    for (final p in players) {
      p.streetBet = 0;
    }
    _minRaise = config.bigBlind;
    _remainingToAct = actable.length;
    _actorIndex = (buttonIndex + 1) % players.length;
    _skipToActable();
    _maybeEarlyFinish();
  }

  /// 摊牌前若可行动者不足 2 人（其余全下/弃牌），直接发完公共牌摊牌。
  void _maybeEarlyFinish() {
    if (handOver) return;
    if (active.length == 1) {
      _finishUncontested();
      return;
    }
    if (actable.length <= 1) {
      _runout();
    }
  }

  void _runout() {
    _street = Street.showdown;
    while (board.length < 5) {
      _dealBoard(board.isEmpty ? 3 : 1);
    }
    _finishShowdown();
  }

  /// 发 [n] 张公共牌：优先消耗预定的覆盖牌，其余从牌堆随机发。
  void _dealBoard(int n) {
    final cards = <Card>[];
    for (var i = 0; i < n; i++) {
      cards.add(_boardOverride.isNotEmpty
          ? _boardOverride.removeAt(0)
          : _deck.removeLast());
    }
    board.addAll(cards);
    lastHand?.board.addAll(cards);
  }

  void _finishUncontested() {
    final winner = active.first;
    final pot = potTotal();
    winner.stack += pot;
    _finalize({winner.id: pot});
  }

  void _finishShowdown() {
    // 按全下层级切边池；每层由贡献达到该层且未弃牌的玩家竞争。
    final levels = active.map((p) => p.totalBet).toSet().toList()..sort();
    var prev = 0;
    final winnings = <String, int>{};
    for (final level in levels) {
      var layer = 0;
      for (final p in players) {
        layer += (min(p.totalBet, level) - prev).clamp(0, level - prev);
      }
      prev = level;
      if (layer == 0) continue;
      final eligible =
          active.where((p) => p.totalBet >= level).toList();
      if (eligible.isEmpty) continue;
      var best = HandEvaluator.bestOf(
          [...eligible.first.holeCards, ...board]);
      for (final p in eligible.skip(1)) {
        final s = HandEvaluator.bestOf([...p.holeCards, ...board]);
        if (s > best) best = s;
      }
      final winners = eligible
          .where((p) =>
              HandEvaluator.bestOf([...p.holeCards, ...board]) == best)
          .toList();
      final share = layer ~/ winners.length;
      var remainder = layer % winners.length;
      for (final w in winners) {
        final extra = remainder > 0 ? 1 : 0;
        if (remainder > 0) remainder--;
        winnings[w.id] = (winnings[w.id] ?? 0) + share + extra;
        w.stack += share + extra;
      }
    }
    _finalize(winnings);
  }

  void _finalize(Map<String, int> winnings) {
    handOver = true;
    for (final p in players) {
      lastHand?.netResult[p.id] = (winnings[p.id] ?? 0) - p.totalBet;
    }
  }
}
