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

/// 一次加注对后面的人意味着什么。
enum _RaiseReopen {
  /// 不是加注（弃牌 / 过牌 / 跟注）。
  none,

  /// 完整加注：所有人都要再表态一次，加注权重新开放。
  full,

  /// 不足最小加注的全下：只有还没跟平的人要表态，而且他们不能再加注。
  short,
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
/// 规则说明：加注的底线是「当前最高注 + 上一次的加注幅度」——3bet 以开池
/// 为基准、4bet 以 3bet 为基准，一路如此，不是固定倍数。
///
/// 短筹码全下加注不足最小加注额时按全下处理（半开的下注）：还没跟平的人
/// 仍然要表态，但已经表过态的人不能再加注——跟真规则一致。
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
  // 本街还要表态的玩家。用集合而不是「还剩几个人」的计数：不足最小加注的
  // 全下（短码）不重开下注，但**还没跟平的人**仍然要继续表态——计数表达不了
  // 「谁还得再说一次」，按集合来才不会要么漏问、要么把已经跟平的人再问一遍。
  final Set<String> _pending = <String>{};
  // 本街已经表过态的玩家。碰上「不足最小加注」的全下时，他们只能跟或弃：
  // 真规则里半开的下注不重开加注权，只有还没说话的人能加。
  final Set<String> _closedToRaise = <String>{};
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
    _resetStreetAction();
    _skipToActable();
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

  /// 从 [_actorIndex] 起向后找到第一个「本街还没表态」的玩家。
  void _skipToActable() {
    for (var i = 0; i < players.length; i++) {
      if (_pending.contains(players[_actorIndex].id)) return;
      _actorIndex = (_actorIndex + 1) % players.length;
    }
  }

  /// 开手 / 换街时重置本街的表态状态。
  void _resetStreetAction() {
    _pending
      ..clear()
      ..addAll(actable.map((p) => p.id));
    _closedToRaise.clear();
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
    // 半开的下注（短码全下不足最小加注）不给已经表态过的人再加注的机会。
    if (p.stack > toCall && !_closedToRaise.contains(p.id)) {
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

    var reopen = _RaiseReopen.none;
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
        reopen = _placeBet(actor, to);
    }
    lastHand?.actions.add(ActionRecord(
      street: _street,
      actorId: playerId,
      type: type,
      amount: amount ?? 0,
      potAfter: potTotal(),
    ));

    _pending.remove(actor.id);
    _closedToRaise.add(actor.id);
    switch (reopen) {
      case _RaiseReopen.full:
        // 完整加注：所有人重新表态一次，加注权也重新开放。
        _pending.addAll(actable.where((p) => p != actor).map((p) => p.id));
        _closedToRaise
          ..clear()
          ..add(actor.id);
      case _RaiseReopen.short:
        // 不足最小加注的全下：只有还没跟平的人要继续表态，而且他们不能再加。
        _pending.addAll(actable
            .where((p) => p != actor && p.streetBet < currentBet)
            .map((p) => p.id));
      case _RaiseReopen.none:
        break;
    }

    if (active.length == 1) {
      _finishUncontested();
      return;
    }
    if (_pending.isEmpty) {
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

  /// 下注/加注：返回这次算「完整加注」还是「不足最小加注的全下」，
  /// 两者对后面的人意味的东西不一样（见 [apply]）。
  ///
  /// 最小加注额的口径：**在当前最高注之上，至少再加「上一次的加注幅度」**。
  /// 3bet 的底线是「开池额 + 开池幅度」，4bet 的底线是「3bet 额 + 3bet
  /// 幅度」，一路都以之前那一次加注为基准，而不是固定倍数。
  _RaiseReopen _placeBet(PlayerState p, int toAmount) {
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
    final raised = to - currentBet;
    // 不足最小加注的全下不改「最小加注幅度」：真规则里它只是半开，下一次
    // 合法加注仍然照着上一次**完整**加注的幅度算。
    if (raised < _minRaise) {
      _putChips(p, to - p.streetBet);
      return _RaiseReopen.short;
    }
    _minRaise = raised;
    _putChips(p, to - p.streetBet);
    return _RaiseReopen.full;
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
    _resetStreetAction();
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

  // ---------- 快照：一手牌打到一半也能原样接着打 ----------

  /// 把当前这手牌的完整状态序列化（含余下牌堆的顺序）。
  ///
  /// App 中途退出时靠它接着打完同一手牌：底牌、公共牌、各家下注、
  /// 当前行动者都不变；牌堆顺序一起存下来，后面几条街发出来的牌
  /// 与原局完全一致（不会重洗牌）。
  Map<String, Object?> toSnapshotJson() => {
        'buttonIndex': buttonIndex,
        'street': _street.name,
        'actorIndex': _actorIndex,
        'remainingToAct': _pending.length,
        'pending': _pending.toList(),
        'closedToRaise': _closedToRaise.toList(),
        'minRaise': _minRaise,
        'handOver': handOver,
        'board': [for (final c in board) c.notation],
        'deck': [for (final c in _deck) c.notation],
        'boardOverride': [for (final c in _boardOverride) c.notation],
        'players': [
          for (final p in players)
            {
              'id': p.id,
              'name': p.name,
              'stack': p.stack,
              'streetBet': p.streetBet,
              'totalBet': p.totalBet,
              'folded': p.folded,
              'allIn': p.allIn,
              'hole': [for (final c in p.holeCards) c.notation],
            },
        ],
        if (lastHand != null) 'hand': lastHand!.toJson(),
      };

  /// 按 [toSnapshotJson] 的快照重建引擎，可直接接着 [pendingAction]/[apply] 打。
  ///
  /// 快照自带座位与筹码，因此不需要再 [addPlayer]；[config] 与 [random]
  /// 由调用方给出（快照里不存这两样）。
  factory GameEngine.fromSnapshotJson(
    Map<String, Object?> json, {
    GameConfig config = const GameConfig(),
    Random? random,
  }) {
    final engine = GameEngine(config: config, random: random);
    for (final raw in (json['players']! as List)) {
      final m = (raw! as Map).cast<String, Object?>();
      final p = PlayerState(
        id: m['id']! as String,
        name: m['name']! as String,
        stack: (m['stack']! as num).toInt(),
      )
        ..streetBet = (m['streetBet']! as num).toInt()
        ..totalBet = (m['totalBet']! as num).toInt()
        ..folded = m['folded']! as bool
        ..allIn = m['allIn']! as bool;
      for (final c in (m['hole']! as List)) {
        p.holeCards.add(Card.parse(c! as String));
      }
      engine.players.add(p);
    }
    engine.buttonIndex = (json['buttonIndex']! as num).toInt();
    engine._street = Street.values.byName(json['street']! as String);
    engine._actorIndex = (json['actorIndex']! as num).toInt();
    engine._pending.clear();
    final pending = json['pending'];
    if (pending is List) {
      engine._pending.addAll(pending.map((e) => '$e'));
    } else {
      // 老存档只存了「还剩几个人」：按「从行动位往后数 N 个还能行动的人」
      // 还原——这正是旧计数器当年的语义。
      final remaining = (json['remainingToAct']! as num).toInt();
      var idx = engine._actorIndex;
      for (var i = 0;
          i < engine.players.length * 2 && engine._pending.length < remaining;
          i++) {
        final p = engine.players[idx];
        if (!p.folded && !p.allIn) engine._pending.add(p.id);
        idx = (idx + 1) % engine.players.length;
      }
    }
    engine._closedToRaise.clear();
    final closed = json['closedToRaise'];
    if (closed is List) engine._closedToRaise.addAll(closed.map((e) => '$e'));
    engine._minRaise = (json['minRaise']! as num).toInt();
    engine.handOver = json['handOver']! as bool;
    for (final c in (json['board']! as List)) {
      engine.board.add(Card.parse(c! as String));
    }
    for (final c in (json['deck']! as List)) {
      engine._deck.add(Card.parse(c! as String));
    }
    for (final c in (json['boardOverride']! as List)) {
      engine._boardOverride.add(Card.parse(c! as String));
    }
    final hand = json['hand'];
    if (hand != null) {
      engine.lastHand =
          HandHistory.fromJson((hand as Map).cast<String, Object?>());
    }
    return engine;
  }
}
