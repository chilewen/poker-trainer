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
import '../domain/session_summary.dart';
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
      AiStyle.pro,
      AiStyle.gto,
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

  /// 当前桌名称（大厅场景选择后更新）。含盲注级别，用于大厅/存档显示。
  String tableLabel = '常规 6 人桌';

  /// 对局页顶部标题用的桌名：不带盲注级别。盲注在大厅卡片和存档里已经
  /// 有了，导航栏那一行留给「打到第几手」和本手输赢。
  String tableName = '常规 6 人桌';

  // ---------- 本局规则：补码上限 + 什么时候收手 ----------

  /// 一局最多补几次筹码。补满之后再输光，这局就结束了。
  ///
  /// 「无限补码」等于没有风险：输多少都补回来，打得再烂也感觉不到疼。
  /// 给个上限，一局才有「打完」这件事，也才有了对局总结可看。
  static const maxRebuys = 6;

  int _rebuys = 0;

  /// 本局已经补过几次筹码。
  int get rebuys => _rebuys;

  /// 还能补几次。
  int get rebuysLeft => max(0, maxRebuys - _rebuys);

  /// 现在还能不能补：这局没结束、次数也没用完。
  bool get canRebuy => !_sessionOver && _rebuys < maxRebuys;

  bool _sessionOver = false;

  /// 这局是不是已经结束了（补码用尽还输光，或者玩家自己按了「结束对局」）。
  bool get sessionOver => _sessionOver;

  String _endReason = '';

  /// 结束的原因，直接显示在总结页上（如「筹码输光，补码次数已用完」）。
  String get endReason => _endReason;

  /// 回到牌桌时筹码就不够、还不发下一手（等着玩家决定补还是收）。
  bool _awaitingChips = false;

  /// 这张桌现在停在两手之间（不轮任何人行动）。
  ///
  /// 正常打完一手时是 [GameEngine.handOver]；[resumeSession] 拉回来的局如果
  /// 筹码已经不够，会停在「等玩家决定补还是收」这一步，这时牌还没发下来，
  /// `handOver` 是 false——界面必须按结算态渲染，不然会去问一个没开的牌局
  /// 「轮到谁了」。
  bool get handStopped => engine.handOver || _awaitingChips;

  // 本局自己的流水账。不能拿 [history] 凑：那份是全量历史，换桌不清空，
  // 直接把上一桌的牌算进本局总结。
  DateTime _sessionStart = DateTime.now();
  int _handsWon = 0;
  int _handsLost = 0;
  int _handsTied = 0;
  int _bestHandNet = 0;
  int _worstHandNet = 0;
  final List<HandHistory> _sessionHands = [];

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
    tableName = label;
    handsPlayed = 0;
    _heroNetTotal = 0;
    _resetSessionRules();
    _sessionId = 'table-${DateTime.now().microsecondsSinceEpoch}';
    engine = GameEngine(config: _config, random: _random);
    // 开局座位随机排：以前对手永远按固定顺序落座（紧凶必坐你左手），每局看着
    // 一模一样。洗一下顺序再落座，风格、名牌、行动顺序都跟着换位置。
    // 先复制再洗：调用方可能传 const 列表，而且不同桌之间不该互相影响。
    _setupPlayers([...styles]..shuffle(_random));
    engine.startHand();
    notifyListeners();
    _pump();
    unawaited(persistSession());
  }

  /// 本局计数清零（开新局时用）。
  void _resetSessionRules() {
    _rebuys = 0;
    _sessionOver = false;
    _endReason = '';
    _awaitingChips = false;
    _sessionStart = DateTime.now();
    _handsWon = 0;
    _handsLost = 0;
    _handsTied = 0;
    _bestHandNet = 0;
    _worstHandNet = 0;
    _sessionHands.clear();
  }

  /// 实战开桌：按盲注级别与人数重建一桌（筹码重置），并立即发牌。
  ///
  /// AI 风格按紧凶 / 松弱 / 松凶 / 职业玩家 / 均衡循环分配：五种打法都上桌，
  /// 从「能读懂的鱼」到「会读人的常客」再到「不看人的均衡型」各坐几个，
  /// 9 人桌上也不会像以前那样只有三种人、同一种对手坐满半桌。
  ///
  /// [name] 只给桌名（如「实战 6人桌」）；带盲注级别的完整 [tableLabel]
  /// 由控制器拼出来，对局页的标题则用不带盲注的 [tableName]。
  void startRealTable({
    required String name,
    required GameConfig config,
    required int playerCount,
  }) {
    assert(playerCount >= 2);
    _config = config;
    const rotation = [
      AiStyle.tightAggressive,
      AiStyle.loosePassive,
      AiStyle.looseAggressive,
      AiStyle.pro,
      AiStyle.gto,
    ];
    startScenario('$name · ${config.smallBlind}/${config.bigBlind}', [
      for (var i = 0; i < playerCount - 1; i++) rotation[i % rotation.length],
    ]);
    tableName = name;
  }

  int _generation = 0; // 防呆：AI 延迟回调落在旧手牌上

  /// 已完成手牌历史（最新在前），供复盘/错局重玩使用。
  final List<HandHistory> history = [];

  // ---------- 对局存档：关掉再回来接着打 ----------

  /// 上一次落盘的存档（冷启动后大厅据此显示「继续上局」）。
  TableSession? savedSession;

  /// 内存里这张桌对应的存档 id；null = 还没开过桌。
  String? _sessionId;

  /// 落盘串行化：动作很密时后一次写必须压过前一次，不能交错。
  Future<void> _writes = Future<void>.value();

  /// 当前这张桌已经打完多少手（存档恢复时一起带回来）。
  int handsPlayed = 0;

  /// 英雄在本局的累计输赢（只累已打完的手牌，跟着存档走）。
  ///
  /// 补码是「往桌上补钱」，不该算成赢钱，所以这里累的是每手的净赢输，
  /// 而不是「当前筹码 - 起始筹码」。
  int _heroNetTotal = 0;

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

  /// 把当前桌面状态落盘。
  ///
  /// 开新桌、每个动作、每手结束都会落一次：哪怕中途退出（甚至被系统杀掉），
  /// 回来也能接着打——这一手没打完就接着打完，打完了就发下一手。
  Future<void> persistSession() async {
    // 收了的局不该再有存档（[endSession] 已经把盘上的那份删了）；
    // [dispose] 之后就完全停笔，免得临时目录都删了又被写回来。
    if (_disposed || _sessionOver) return;
    final session = TableSession(
      id: _sessionId ??= 'table-${DateTime.now().microsecondsSinceEpoch}',
      label: tableLabel,
      name: tableName,
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
      heroNet: _heroNetTotal,
      rebuys: _rebuys,
      handsWon: _handsWon,
      handsLost: _handsLost,
      handsTied: _handsTied,
      bestHandNet: _bestHandNet,
      worstHandNet: _worstHandNet,
      startedAt: _sessionStart,
      savedAt: DateTime.now(),
      handSnapshot: _inProgressSnapshot(),
    );
    savedSession = session;
    notifyListeners();
    final store = sessionStore;
    if (store == null) return;
    // 串行写：动作密集时保证最后落盘的就是最新状态；单次写失败不拖垮后续存档。
    _writes = _writes.then((_) => store.save(session)).catchError((Object _) {});
    await _writes;
  }

  /// 正在进行的那手牌的快照；停在两手之间（或还没发牌）时返回 null。
  Map<String, Object?>? _inProgressSnapshot() =>
      handStopped || engine.lastHand == null
          ? null
          : engine.toSnapshotJson();

  /// 每个动作之后落一次盘，让牌局随时可续。
  void _saveProgress() {
    if (_disposed || _sessionOver || handStopped) return;
    unawaited(persistSession());
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
    // 标题用不带盲注的桌名：老存档没有 'name' 时 TableSession 会从 label 里剪。
    tableName = s.name;
    _config = s.config;
    handsPlayed = s.handsPlayed;
    _heroNetTotal = s.heroNet;
    _rebuys = s.rebuys;
    _sessionOver = false;
    _endReason = '';
    _awaitingChips = false;
    _sessionStart = s.sessionStart;
    _handsWon = s.handsWon;
    _handsLost = s.handsLost;
    _handsTied = s.handsTied;
    _bestHandNet = s.bestHandNet;
    _worstHandNet = s.worstHandNet;
    _sessionHands.clear();
    final rebuilt = restoreTable(s, heroId: heroId, random: _random);
    engine = rebuilt.engine;
    _ais
      ..clear()
      ..addAll(rebuilt.ais);
    _sessionId = s.id;
    if (s.handInProgress && !engine.handOver && engine.lastHand != null) {
      // 上一手打到一半：原样接着打完，不重发牌。
      notifyListeners();
      _pump();
    } else {
      _beginHand();
    }
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

  /// 英雄本局的累计输赢：已经打完的手牌之和 + 正在进行这一手的实时输赢。
  ///
  /// 本手结算完就不再加实时值（那一手的钱已经算进 [_heroNetTotal] 了）。
  int get heroSessionNet =>
      _heroNetTotal + (engine.handOver ? 0 : heroHandNet ?? 0);

  /// 英雄本手的净赢输（正 = 赢、负 = 输）。没有牌局时返回 null。
  ///
  /// 用「当前筹码 - 本手起始筹码」算：下注/跟注的筹码已经从筹码里扣掉，
  /// 赢下的底池也已经加回来，所以本手进行中显示的就是这一刻的输赢，
  /// 打完就等于 [HandHistory.netResult]。
  int? get heroHandNet {
    final start = lastHand?.startingStacks[heroId];
    if (start == null) return null;
    return hero.stack - start;
  }

  /// 英雄筹码不够一个大盲、要停下来决定「补还是收」。
  ///
  /// 两种情形：一手打完才发现（[GameEngine.handOver]），或者回到牌桌时
  /// 就已经不够了（[_awaitingChips]，这时牌还没发）。牌打到一半不算——
  /// 那时候筹码低是正常的（可能已经全下），不该弹补码提示。
  bool get heroBusted =>
      !_sessionOver &&
      handStopped &&
      hero.stack < engine.config.bigBlind;

  PlayerState? get _pendingPlayer =>
      handStopped ? null : engine.pendingAction().player;

  /// 是否轮到英雄操作（且不是结算阶段）。
  bool get heroToAct => _pendingPlayer?.id == heroId;

  /// AI 正在思考（界面上禁用输入、显示提示）。
  bool get aiThinking => !handStopped && !heroToAct;

  List<LegalAction> get heroLegalActions =>
      heroToAct ? engine.legalActions(hero) : const [];

  HandHistory? get lastHand => engine.lastHand;

  /// 开一手（或下一手）。
  void startHand() {
    if (_sessionOver) return; // 这局已经收了，别再发牌
    _generation++;
    replayingHand = null;
    _beginHand();
  }

  /// 在当前这张桌上发下一手（存档恢复后也走这里）。
  void _beginHand() {
    if (_sessionOver) return;
    // 破产的 AI 自动续码（不限次数）。
    for (final p in engine.players) {
      if (p.id != heroId && p.stack < engine.config.bigBlind) {
        engine.topUp(p.id);
      }
    }
    // 英雄**不**自动续码：补码是这局的一次「机会」，用完了就该收手
    // （见 [_afterHand]）。所以筹码不够时先停下，让玩家在结算条上决定。
    if (hero.stack < engine.config.bigBlind) {
      _awaitingChips = true;
      if (!canRebuy) {
        endSession(reason: '筹码输光，补码次数已用完');
        return;
      }
      notifyListeners();
      unawaited(persistSession()); // 停在哪一步也落盘，关掉再回来还是这一步
      return;
    }
    _awaitingChips = false;
    engine.startHand();
    notifyListeners();
    unawaited(persistSession()); // 一手刚发下来就落盘，随时关掉都接得上
    _pump();
  }

  /// 英雄补充筹码：补满至起始买入，并立即开始下一手。
  ///
  /// 一局最多补 [maxRebuys] 次——这里的守门不是防呆，是规则本身。
  void heroRebuy() {
    if (!canRebuy) return;
    _rebuys++;
    engine.topUp(heroId);
    notifyListeners();
    startHand();
  }

  /// 结束本局：不再发牌、清掉存档，界面转去对局总结。
  ///
  /// 两种触发：补码次数用完还把筹码输光（见 [_afterHand]），
  /// 或者玩家自己按了「结束对局」。
  void endSession({required String reason}) {
    if (_sessionOver) return;
    _sessionOver = true;
    _endReason = reason;
    _awaitingChips = false;
    // 挂着的 AI 回调作废：这局已经收手，别再改筹码、别再落盘。
    _generation++;
    // 结束的局没有「继续上局」可言：存档删掉，大厅不再显示那张卡片。
    savedSession = null;
    _sessionId = null;
    final store = sessionStore;
    if (store != null) {
      // 排在写队列**后面**：先让挂着的落盘写完再删，不然刚删完又被写回来。
      _writes = _writes.then((_) => store.clear()).catchError((Object _) {});
    }
    notifyListeners();
  }

  /// 再来一局：同样的桌名、盲注、人数，筹码与本局计数全部重来。
  void restartSession() {
    startRealTable(
      name: tableName,
      config: _config,
      playerCount: engine.players.length,
    );
  }

  /// 本局总结（对局结束后给总结页用）。
  ///
  /// 冷启动恢复的局只带得回存档里那几个数——早先那几手的明细本来就没在
  /// 内存里，所以明细只列恢复之后打的。计数器（手数、盈亏、补码）都是
  /// 跟着存档走的，那几个数是准的。
  SessionSummary buildSummary() => SessionSummary(
        tableName: tableName,
        label: tableLabel,
        handsPlayed: handsPlayed,
        handsWon: _handsWon,
        handsLost: _handsLost,
        handsTied: _handsTied,
        heroNet: heroSessionNet,
        bestHandNet: _bestHandNet,
        worstHandNet: _worstHandNet,
        rebuys: _rebuys,
        maxRebuys: maxRebuys,
        duration: DateTime.now().difference(_sessionStart),
        endReason: _endReason.isEmpty ? '主动结束' : _endReason,
        hands: List.unmodifiable(_sessionHands),
      );

  /// 错局重玩：以与 [hand] 相同的手牌与公共牌再开一局，
  /// 英雄可在相同局面下尝试不同打法。英雄筹码沿用当前桌面筹码。
  void replayHand(HandHistory hand) {
    // 上一局已经收手（补码用尽 / 主动结束）时，「重玩本手」当成开一局新的：
    // 不复位的话牌是摆好了，界面却还钉在总结页上（那边看的是本局已结束）。
    if (_sessionOver) {
      handsPlayed = 0;
      _heroNetTotal = 0;
      _resetSessionRules();
      _sessionId = 'table-${DateTime.now().microsecondsSinceEpoch}';
    }
    _generation++;
    _recordFinishedHand();
    replayingHand = hand;
    engine.startHand(
      holeOverride: hand.holeCards,
      boardOverride: hand.board,
    );
    notifyListeners();
    unawaited(persistSession());
    _pump();
  }

  /// 英雄执行动作。bet/raise 传 [amountTo]（「下到」的本街总额）。
  void heroAct(ActionType type, {int? amountTo}) {
    if (!heroToAct) return;
    engine.apply(heroId, type, amount: amountTo);
    notifyListeners();
    _saveProgress();
    _pump();
  }

  /// 推进 AI 行动直到轮到英雄或本手结束。
  void _pump() {
    if (engine.handOver) {
      _recordFinishedHand();
      _afterHand();
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
      _afterHand();
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
      _saveProgress();
      _pump();
    }));
  }

  void _recordFinishedHand() {
    if (_disposed) return;
    final h = engine.lastHand;
    if (h == null) return;
    if (history.any((x) => x.id == h.id)) return;
    handsPlayed++;
    final net = h.netResult[heroId] ?? 0;
    _heroNetTotal += net;
    // 本局自己的账：换桌不清空的 [history] 不能拿来当「本局」用。
    _sessionHands.insert(0, h);
    if (net > 0) {
      _handsWon++;
      _bestHandNet = max(_bestHandNet, net);
    } else if (net < 0) {
      _handsLost++;
      _worstHandNet = min(_worstHandNet, net);
    } else {
      _handsTied++;
    }
    history.insert(0, h);
    unawaited(store?.save(h));
    unawaited(persistSession());
  }

  /// 一手打完之后的收尾：补码次数用完还把筹码输光，这局就到头了。
  ///
  /// 还有补码次数时不自动收——补不补是玩家的选择，结算条上给他按钮。
  void _afterHand() {
    if (_sessionOver || !heroBusted || canRebuy) return;
    endSession(reason: '筹码输光，补码次数已用完');
  }

  bool _disposed = false;

  /// 停掉这台控制器：挂着的 AI 定时器作废，之后也不再落盘。
  ///
  /// 生产里只有 Riverpod 销毁容器（App 退出）才会走到这里；用例收尾时也要
  /// 显式叫一下——不叫停的话，那些挂着的 AI 回调会在临时目录删掉之后继续
  /// 落盘，[TableSessionStore.save] 里的 `file.parent.create(recursive: true)`
  /// 又把目录原样建回来（跑一轮回归就多几个空壳）。
  @override
  void dispose() {
    if (_disposed) return; // 重复 dispose 不报错：Riverpod 可能先替我们收过
    _disposed = true;
    _generation++;
    super.dispose();
  }

  /// 等挂着的落盘写完（和 [dispose] 配对：先叫停、再刷干、最后才删目录）。
  Future<void> flushWrites() => _writes;
}
