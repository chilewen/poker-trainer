import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../engine/game.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../history/data/hand_history_store.dart';
import '../data/table_session.dart';
import '../data/table_session_store.dart';
import '../domain/ai_player.dart';
import '../domain/table_restore.dart';

/// 牌桌控制器：驱动 GameEngine，英雄由 UI 操作，AI 自动行动。
///
/// 状态流转：startHand → （AI 自动轮流 / 等待英雄输入）→ handOver →
/// 展示结算 → startHand 进入下一手。
class TableController extends ChangeNotifier {
  TableController({
    GameConfig config = const GameConfig(),
    List<AiStyle> opponentStyles = const [
      AiStyle.tightAggressive,
      AiStyle.loosePassive,
      AiStyle.looseAggressive,
      AiStyle.tightAggressive,
      AiStyle.loosePassive,
    ],
    this.aiThinkTime = const Duration(milliseconds: 300),
    this.store,
    this.sessionStore,
    Random? random,
  })  : engine = GameEngine(config: config, random: random),
        _config = config,
        _random = random ?? Random() {
    _setupPlayers(opponentStyles);
  }

  static const heroId = 'hero';

  GameEngine engine;
  final Duration aiThinkTime;
  final HandHistoryStore? store;

  /// 对局存档（可空：测试/无存储环境下照样能玩，只是不落盘）。
  final TableSessionStore? sessionStore;

  GameConfig _config;
  final Random _random;
  final Map<String, AiPlayer> _ais = {};

  /// 当前桌名称（大厅场景选择后更新）。
  String tableLabel = '常规 6 人桌';

  void _setupPlayers(List<AiStyle> opponentStyles) {
    _ais.clear();
    engine.addPlayer(heroId, '我');
    for (var i = 0; i < opponentStyles.length; i++) {
      final style = opponentStyles[i];
      final id = 'ai$i';
      engine.addPlayer(id, '${style.label}·AI${i + 1}');
      _ais[id] = AiPlayer(style, random: _random);
    }
  }

  /// 场景重开：按 [styles] 重建一桌全新对手（筹码重置），
  /// 并立即发第一手。历史记录保留。
  void startScenario(String label, List<AiStyle> styles) {
    _generation++;
    replayingHand = null;
    tableLabel = label;
    handsPlayed = 0;
    _sessionId = 'table-${DateTime.now().microsecondsSinceEpoch}';
    engine = GameEngine(config: _config, random: _random);
    _setupPlayers(styles);
    engine.startHand();
    notifyListeners();
    _pump();
    unawaited(persistSession());
  }

  /// 实战开桌：按盲注级别与人数重建一桌（筹码重置），并立即发牌。
  /// AI 风格按紧凶 / 松被动 / 松凶循环分配，桌上三种打法都有。
  void startRealTable({
    required String label,
    required GameConfig config,
    required int playerCount,
  }) {
    assert(playerCount >= 2);
    _config = config;
    const rotation = [
      AiStyle.tightAggressive,
      AiStyle.loosePassive,
      AiStyle.looseAggressive,
    ];
    startScenario(label, [
      for (var i = 0; i < playerCount - 1; i++) rotation[i % rotation.length],
    ]);
  }

  int _generation = 0; // 防呆：AI 延迟回调落在旧手牌上

  /// 已完成手牌历史（最新在前），供复盘/错局重玩使用。
  final List<HandHistory> history = [];

  // ---------- 对局存档：关掉再回来接着打 ----------

  /// 上一次落盘的存档（冷启动后大厅据此显示「继续上局」）。
  TableSession? savedSession;

  /// 内存里这张桌对应的存档 id；null = 还没开过桌。
  String? _sessionId;

  /// 当前这张桌已经打完多少手（存档恢复时一起带回来）。
  int handsPlayed = 0;

  /// 磁盘上有上一局的存档。
  bool get hasSavedSession => savedSession != null;

  /// 存档还没加载进内存（冷启动后第一次「继续上局」需要重建这张桌）。
  bool get sessionNeedsRestore =>
      savedSession != null && _sessionId != savedSession!.id;

  /// 冷启动时读回上次的存档（与 [loadHistory] 一起在启动时调用一次）。
  ///
  /// 连英雄座位都没有的存档直接丢掉——那种桌子恢复出来也没法打。
  Future<void> loadSession() async {
    final s = await sessionStore?.load();
    if (s == null || s.stackOf(heroId) == null) return;
    savedSession = s;
    notifyListeners();
  }

  /// 把当前桌面状态落盘（开新桌、每手结束各存一次）。
  Future<void> persistSession() async {
    final store = sessionStore;
    if (store == null) return;
    final session = TableSession(
      id: _sessionId ??= 'table-${DateTime.now().microsecondsSinceEpoch}',
      label: tableLabel,
      config: _config,
      styles: [
        for (final p in engine.players)
          if (p.id != heroId)
            _ais[p.id]?.style.name ?? AiStyle.tightAggressive.name,
      ],
      seats: [
        for (final p in engine.players)
          SessionSeat(id: p.id, name: p.name, stack: p.stack),
      ],
      buttonIndex: engine.buttonIndex,
      handsPlayed: handsPlayed,
      savedAt: DateTime.now(),
    );
    savedSession = session;
    notifyListeners();
    await store.save(session);
  }

  /// 继续上局：把存档里的那张桌原样搬回来，然后发下一手。
  ///
  /// 内存里的桌就是存档里的桌时（App 没关，只是逛回大厅再进来），
  /// 直接沿用现状——不重发牌、不重置筹码。
  ///
  /// 返回这张桌能不能打：false 表示存档不可用，调用方别把用户带进空桌。
  bool resumeSession() {
    final s = savedSession;
    if (s == null) return false;
    if (_sessionId == s.id) {
      notifyListeners();
      return true;
    }
    if (!s.isPlayable || s.stackOf(heroId) == null) return false;
    _generation++;
    replayingHand = null;
    tableLabel = s.label;
    _config = s.config;
    handsPlayed = s.handsPlayed;
    final rebuilt = restoreTable(s, heroId: heroId, random: _random);
    engine = rebuilt.engine;
    _ais
      ..clear()
      ..addAll(rebuilt.ais);
    _sessionId = s.id;
    _beginHand();
    return true;
  }

  /// 正在进行错局重玩时，对应的原手牌记录。
  HandHistory? replayingHand;

  /// 从数据库载入历史（App 启动时调用一次）。
  Future<void> loadHistory() async {
    final s = store;
    if (s == null) return;
    history
      ..clear()
      ..addAll(await s.loadAll());
    notifyListeners();
  }

  /// 从内存与数据库中删除一只手牌。
  Future<void> deleteHand(String id) async {
    history.removeWhere((h) => h.id == id);
    await store?.delete(id);
    notifyListeners();
  }

  PlayerState get hero => engine.players.firstWhere((p) => p.id == heroId);

  /// 英雄是否已破产：本手结束后筹码不足一个大盲，需要补充。
  bool get heroBusted =>
      engine.handOver && hero.stack < engine.config.bigBlind;

  PlayerState? get _pendingPlayer =>
      engine.handOver ? null : engine.pendingAction().player;

  /// 是否轮到英雄操作（且不是结算阶段）。
  bool get heroToAct => !engine.handOver && _pendingPlayer?.id == heroId;

  /// AI 正在思考（界面上禁用输入、显示提示）。
  bool get aiThinking => !engine.handOver && !heroToAct;

  List<LegalAction> get heroLegalActions =>
      heroToAct ? engine.legalActions(hero) : const [];

  HandHistory? get lastHand => engine.lastHand;

  /// 开一手（或下一手）。
  void startHand() {
    _generation++;
    replayingHand = null;
    _beginHand();
  }

  /// 在当前这张桌上发下一手（存档恢复后也走这里）。
  void _beginHand() {
    // 破产的 AI 自动续码，英雄由「补充筹码」按钮显式处理；
    // 这里兜底防止 0 筹码也直接开局。
    for (final p in engine.players) {
      if (p.stack < engine.config.bigBlind) engine.topUp(p.id);
    }
    engine.startHand();
    notifyListeners();
    _pump();
  }

  /// 英雄补充筹码：补满至起始买入，并立即开始下一手。
  void heroRebuy() {
    engine.topUp(heroId);
    notifyListeners();
    startHand();
  }

  /// 错局重玩：以与 [hand] 相同的手牌与公共牌再开一局，
  /// 英雄可在相同局面下尝试不同打法。英雄筹码沿用当前桌面筹码。
  void replayHand(HandHistory hand) {
    _generation++;
    _recordFinishedHand();
    replayingHand = hand;
    engine.startHand(
      holeOverride: hand.holeCards,
      boardOverride: hand.board,
    );
    notifyListeners();
    _pump();
  }

  /// 英雄执行动作。bet/raise 传 [amountTo]（「下到」的本街总额）。
  void heroAct(ActionType type, {int? amountTo}) {
    if (!heroToAct) return;
    engine.apply(heroId, type, amount: amountTo);
    notifyListeners();
    _pump();
  }

  /// 推进 AI 行动直到轮到英雄或本手结束。
  void _pump() {
    if (engine.handOver) {
      _recordFinishedHand();
      notifyListeners();
      return;
    }
    if (heroToAct) {
      notifyListeners();
      return;
    }
    // 英雄已弃牌或全下（本手不再有决策）：直接快进结算剩余动作，
    // 不再逐个延迟等待。
    if (hero.folded || hero.allIn) {
      var guard = 0;
      while (!engine.handOver && guard++ < 100) {
        final pending = engine.pendingAction();
        final ai = _ais[pending.player.id];
        if (ai == null) break;
        final d = ai.decide(engine, pending.player);
        engine.apply(pending.player.id, d.type, amount: d.amountTo);
      }
      _recordFinishedHand();
      notifyListeners();
      return;
    }
    final gen = _generation;
    final actorId = engine.pendingAction().player.id;
    unawaited(Future.delayed(aiThinkTime, () {
      if (gen != _generation || engine.handOver) return;
      final pending = engine.pendingAction();
      final ai = _ais[pending.player.id];
      if (ai == null || pending.player.id != actorId) return;
      final d = ai.decide(engine, pending.player);
      engine.apply(pending.player.id, d.type, amount: d.amountTo);
      notifyListeners();
      _pump();
    }));
  }

  void _recordFinishedHand() {
    final h = engine.lastHand;
    if (h == null) return;
    if (history.any((x) => x.id == h.id)) return;
    handsPlayed++;
    history.insert(0, h);
    unawaited(store?.save(h));
    unawaited(persistSession());
  }
}
