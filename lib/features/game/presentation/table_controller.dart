import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../engine/game.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../history/data/hand_history_store.dart';
import '../domain/ai_player.dart';

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
    engine = GameEngine(config: _config, random: _random);
    _setupPlayers(styles);
    engine.startHand();
    notifyListeners();
    _pump();
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
    history.insert(0, h);
    unawaited(store?.save(h));
  }
}
