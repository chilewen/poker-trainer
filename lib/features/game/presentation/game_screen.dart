import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/card.dart' as poker;
import '../../../engine/game.dart';
import '../../../engine/hand_evaluator.dart';
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../../trainer/odds.dart';
import '../../history/data/hand_history_store.dart';
import '../data/table_session_store.dart';
import 'hand_review_sheet.dart';
import 'table_controller.dart';

// ---------- 主题常量（深色牌桌风） ----------

const _bg = Color(0xFF0A0E11);
const _plate = Color(0xFF13191F);
const _chipBg = Color(0xFF242C33);
const _cyan = Color(0xFF3AD0CC);
const _nameColor = Color(0xFFEF7A5D);
const _feltLight = Color(0xFF13605C);
const _feltDark = Color(0xFF062E33);
const _btnBlue = Color(0xFF2D8FE6);
const _btnGreen = Color(0xFF57C36C);
const _btnRed = Color(0xFFE5484E);

/// 底部区域固定高度：容纳最高的操作栏（预设档 + 滑杆 + 按钮），
/// 避免「行动栏 / 等待 / 结算」切换时牌桌高度跳动。
const _bottomBarHeight = 124.0;

String? cnPositionOf(GameEngine engine, PlayerState p) => cnPosition(
      [for (final p in engine.players) p.id],
      engine.buttonIndex,
      p.id,
    );

/// 玩家名短显示：去掉风格前缀（紧凶·AI1 → AI1）。
String shortName(String name) =>
    name.contains('·') ? name.split('·').last : name;

/// 行动概览条用的徽标文案与颜色。
(String, Color)? stripBadge(ActionRecord a) {
  if (a.type == ActionType.bet || a.type == ActionType.raise) {
    return ('${a.type.label} ${a.amount}', actionColor(a.type));
  }
  return (a.type.label, actionColor(a.type));
}

/// 手牌存储：在 main() 中初始化并 override。
final historyStoreProvider = Provider<HandHistoryStore>(
  (ref) =>
      throw UnimplementedError('historyStoreProvider 必须在 main() 中 override'),
);

/// 对局存档存储：在 main() 中初始化并 override。
final sessionStoreProvider = Provider<TableSessionStore>(
  (ref) => throw UnimplementedError(
      'sessionStoreProvider 必须在 main() 中 override'),
);

/// 牌桌控制器常驻：筹码与历史跨 Tab 保留。
final tableProvider = ChangeNotifierProvider<TableController>((ref) {
  final c = TableController(
    store: ref.watch(historyStoreProvider),
    sessionStore: ref.watch(sessionStoreProvider),
  );
  c.loadHistory();
  c.loadSession();
  return c;
});

/// 对局页：深色牌桌主界面，由大厅 push 进入。
/// [autoStart] 为 false 时进入已开局的桌（大厅场景已发牌）。
class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key, this.autoStart = true});

  final bool autoStart;

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    final table = ref.watch(tableProvider);
    if (!_started && widget.autoStart) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => table.startHand());
    }
    final g = table.engine;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white70,
        elevation: 0,
        title: _TableTitle(table: table),
        // 标题下面一条：本手 / 本局输赢。标题那一行放不下两个数字
        // （窄屏还要给返回键和两个按钮留位置），单开一条更清楚。
        // 高度要留够：药丸本身（字号 12 + 上下内边距 + 描边）约 23px，
        // 加下边距已经超过 24——声明小了这条会往上压住标题那一行。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: _NetStrip(table: table),
        ),
        actions: [
          IconButton(
            tooltip: '行动路线',
            icon: const Icon(Icons.receipt_long_outlined, size: 20),
            onPressed: g.lastHand == null && table.history.isEmpty
                ? null
                : () {
                    // 当前手（进行或刚结束）放最前，其后是已完成的历史。
                    final current = g.lastHand;
                    final hands = <HandHistory>[
                      if (current != null &&
                          (table.history.isEmpty ||
                              table.history.first.id != current.id))
                        current,
                      ...table.history,
                    ];
                    showHandReviewSheet(
                        context, hands, TableController.heroId);
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ActionStrip(table: table),
            Expanded(child: _TableArea(table: table)),
            SizedBox(
              height: _bottomBarHeight,
              width: double.infinity,
              child: Center(
                child: g.handOver
                    ? _HandOverBar(table: table)
                    : table.heroToAct
                        ? _ActionBar(table: table)
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5, color: _cyan)),
                              SizedBox(width: 10),
                              Text('等待行动…',
                                  style: TextStyle(
                                      color: Color(0xFF8FD8D5), fontSize: 13)),
                            ],
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部行动概览条：每位玩家一格（位置 + 最近动作 + 筹码），
/// 当前行动者以青色描边高亮。
class _ActionStrip extends StatelessWidget {
  const _ActionStrip({required this.table});

  final TableController table;

  @override
  Widget build(BuildContext context) {
    final g = table.engine;
    final hand = g.lastHand;
    final lastAct = <String, ActionRecord>{};
    if (hand != null) {
      for (final a in hand.actions.reversed) {
        lastAct.putIfAbsent(a.actorId, () => a);
      }
    }
    final pendingId = g.handOver ? null : g.pendingAction().player.id;

    // 识别翻牌前的前两条盲注记录，徽标显示为「小盲/大盲」而非「下注」。
    final acts = hand?.actions ?? const <ActionRecord>[];
    final sbRec = acts.length >= 2 &&
            acts[0].street == Street.preflop &&
            acts[0].type == ActionType.bet
        ? acts[0]
        : null;
    final bbRec = acts.length >= 2 &&
            acts[1].street == Street.preflop &&
            acts[1].type == ActionType.bet
        ? acts[1]
        : null;

    // 按位置顺序排列：庄位 → 小盲 → 大盲 → 枪口 → 中位 → 关煞。
    final players = g.players;
    final ordered = g.buttonIndex >= 0
        ? [
            for (var k = 0; k < players.length; k++)
              players[(g.buttonIndex + k) % players.length],
          ]
        : players;

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final p in ordered)
            _stripChip(
              p,
              lastAct[p.id],
              cnPositionOf(g, p),
              p.id == pendingId,
              blindLabel: identical(lastAct[p.id], sbRec)
                  ? '小盲'
                  : identical(lastAct[p.id], bbRec)
                      ? '大盲'
                      : null,
            ),
        ],
      ),
    );
  }

  Widget _stripChip(PlayerState p, ActionRecord? act, String? pos, bool pending,
      {String? blindLabel}) {
    final badge = act == null
        ? null
        : blindLabel != null
            ? ('$blindLabel ${act.amount}', const Color(0xFF9AA3AB))
            : stripBadge(act);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _plate,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: pending ? _cyan : Colors.transparent,
          width: 1.4,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            pos ?? shortName(p.name),
            style:
                const TextStyle(color: Color(0xFF9AA3AB), fontSize: 11.5),
          ),
          if (badge != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: _chipBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(badge.$1,
                  style: TextStyle(color: badge.$2, fontSize: 10.5)),
            ),
          ],
          const SizedBox(width: 6),
          Text(
            '${p.stack + p.streetBet}',
            style: const TextStyle(
                color: _cyan, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 椭圆牌桌 + 座位布局：对手环绕桌面，英雄悬浮于底边。
class _TableArea extends StatelessWidget {
  const _TableArea({required this.table});

  final TableController table;

  /// 对手座位：按「英雄之后的座位顺序」排布——offset 1（你左侧，行动
  /// 顺序的下一家，如你是庄位则为小盲）到 offset n-1（你右侧，如关煞）。
  static List<Alignment> slotsFor(int n) => switch (n) {
        1 => const [Alignment(0, -1)],
        2 => const [Alignment(-0.9, 0.55), Alignment(0.9, 0.55)],
        3 => const [
            Alignment(-0.9, 0.55),
            Alignment(0, -1.02),
            Alignment(0.9, 0.55),
          ],
        4 => const [
            Alignment(-0.9, 0.55),
            Alignment(-0.97, -0.35),
            Alignment(0.97, -0.35),
            Alignment(0.9, 0.55),
          ],
        5 => const [
            Alignment(-0.9, 0.55),
            Alignment(-0.97, -0.35),
            Alignment(0, -1.02),
            Alignment(0.97, -0.35),
            Alignment(0.9, 0.55),
          ],
        6 => const [
            Alignment(-0.92, 0.6),
            Alignment(-0.97, -0.1),
            Alignment(-0.4, -1.02),
            Alignment(0.4, -1.02),
            Alignment(0.97, -0.1),
            Alignment(0.92, 0.6),
          ],
        7 => const [
            Alignment(-0.92, 0.6),
            Alignment(-0.97, 0.0),
            Alignment(-0.85, -0.55),
            Alignment(0, -1.05),
            Alignment(0.85, -0.55),
            Alignment(0.97, 0.0),
            Alignment(0.92, 0.6),
          ],
        _ => const [
            Alignment(-0.92, 0.6),
            Alignment(-0.97, 0.02),
            Alignment(-0.85, -0.52),
            Alignment(-0.38, -1.02),
            Alignment(0.38, -1.02),
            Alignment(0.85, -0.52),
            Alignment(0.97, 0.02),
            Alignment(0.92, 0.6),
          ],
      };

  @override
  Widget build(BuildContext context) {
    final g = table.engine;
    // 无论英雄在玩家列表何处，都按其后座位顺序排列对手。
    final heroIdx =
        g.players.indexWhere((p) => p.id == TableController.heroId);
    final opponents = [
      for (var k = 1; k < g.players.length; k++)
        g.players[(heroIdx + k) % g.players.length],
    ];
    final slots = slotsFor(opponents.length);
    final pendingId = g.handOver ? null : g.pendingAction().player.id;
    final results = g.lastHand?.netResult ?? const {};

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 桌面毡面
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: const Color(0xFF1B2229), width: 9),
                gradient: const RadialGradient(
                  center: Alignment(0, -0.15),
                  radius: 1.05,
                  colors: [_feltLight, _feltDark],
                ),
              ),
            ),
          ),
          // 中央：底池 + 公共牌
          Align(alignment: const Alignment(0, -0.12), child: _Board(g: g)),
          // 对手座位
          for (var i = 0; i < opponents.length; i++)
            Align(
              alignment: slots[i],
              child: OpponentSeat(
                player: opponents[i],
                engine: g,
                pending: opponents[i].id == pendingId,
                won: (results[opponents[i].id] ?? 0) > 0,
              ),
            ),
          // 英雄区：悬浮于桌面底边
          Align(
            alignment: const Alignment(0, 1.04),
            child: HeroCluster(table: table),
          ),
        ],
      ),
    );
  }
}

/// 桌面中央：底池与公共牌。
class _Board extends StatelessWidget {
  const _Board({required this.g});

  final GameEngine g;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'pot: ${g.potTotal()}',
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 5; i++)
              i < g.board.length
                  ? PlayingCard(
                      card: g.board[i],
                      width: 40,
                      height: 56,
                      fontSize: 15,
                      marginH: 2,
                    )
                  : Container(
                      width: 40,
                      height: 56,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white12),
                      ),
                    ),
          ],
        ),
      ],
    );
  }
}

/// 对手座位（紧凑版）：头像 + 叠放名牌（姓名/筹码），
/// 行动高亮，庄位以 D 角标表示，摊牌亮牌悬浮不占布局高度。
class OpponentSeat extends StatelessWidget {
  const OpponentSeat({
    super.key,
    required this.player,
    required this.engine,
    required this.pending,
    required this.won,
  });

  final PlayerState player;
  final GameEngine engine;
  final bool pending;
  final bool won;

  static const _avatarColors = [
    Color(0xFF4E6E8E),
    Color(0xFF7A5C8E),
    Color(0xFF4E8E6A),
    Color(0xFF8E6A4E),
    Color(0xFF8E4E5C),
  ];

  @override
  Widget build(BuildContext context) {
    final p = player;
    final g = engine;
    final seatIndex = g.players.indexOf(p);
    final isButton = g.buttonIndex == seatIndex;
    // 结算亮牌：手牌结束后亮出全部 AI 底牌供学习（含弃牌者，
    // 已弃牌玩家整体以 35% 透明度加以区分）。
    final showCards = g.handOver;
    final avatarColor = _avatarColors[positiveHash(p.id) % _avatarColors.length];

    return Opacity(
      opacity: p.folded ? 0.35 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 本街已下注额（筹码提示）：固定占位，避免下注后座位高度跳动。
          SizedBox(
            height: 15,
            child: p.streetBet > 0
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '◉ ${p.streetBet}',
                    style: const TextStyle(color: _cyan, fontSize: 11),
                  ),
                )
                : null,
          ),
          // 头像与名牌叠放：名牌上缘压住头像下缘，节省纵向空间。
          SizedBox(
            height: 66,
            child: Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: avatarColor,
                      child: Text(
                        p.name.characters.first,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (isButton)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: const BoxDecoration(
                            color: Color(0xFF3AD0CC),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Text('D',
                              style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                  ],
                ),
                Positioned(
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _plate,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: pending
                            ? _cyan
                            : won
                                ? const Color(0xFF57C36C)
                                : Colors.transparent,
                        width: 1.4,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          shortName(p.name),
                          style: const TextStyle(
                              color: _nameColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${p.stack}',
                          style: const TextStyle(
                              color: _cyan,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
                // 摊牌亮牌悬浮于头像上方，不改变座位布局高度。
                if (showCards)
                  Positioned(
                    top: -24,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final c in p.holeCards)
                          PlayingCard(
                              card: c,
                              width: 26,
                              height: 36,
                              fontSize: 11,
                              marginH: 1),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static int positiveHash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x3FFFFFFF;
    }
    return h;
  }
}

/// 英雄区：扇形手牌 + 位置/筹码牌 + 牌型与胜率提示。
class HeroCluster extends StatelessWidget {
  const HeroCluster({super.key, required this.table});

  final TableController table;

  @override
  Widget build(BuildContext context) {
    final hero = table.hero;
    final g = table.engine;
    final pos = cnPositionOf(g, hero);
    final madeHand = g.board.length >= 3 && !hero.folded
        ? HandEvaluator.bestOf([...hero.holeCards, ...g.board]).category.label
        : null;
    final equityHint = _equityHint();

    return Opacity(
      opacity: hero.folded ? 0.5 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 胜率提示：固定占位，避免轮到行动时英雄区高度跳动。
          SizedBox(
            height: 17,
            child: equityHint != null
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      equityHint,
                      style: const TextStyle(
                          color: Color(0xFF8FD8D5), fontSize: 11),
                    ),
                  )
                : null,
          ),
          SizedBox(
            height: 74,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < hero.holeCards.length; i++)
                  Transform.translate(
                    offset: Offset(i == 0 ? -18 : 18, 0),
                    child: Transform.rotate(
                      angle: i == 0 ? -0.12 : 0.12,
                      child: PlayingCard(
                        card: hero.holeCards[i],
                        width: 52,
                        height: 72,
                        fontSize: 18,
                        marginH: 0,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (madeHand != null)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: _chipBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(madeHand,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11)),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: _plate,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color:
                        table.heroToAct ? _cyan : Colors.transparent,
                    width: 1.4,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(pos ?? '我',
                        style: const TextStyle(color: _cyan, fontSize: 13)),
                    Text(
                      '${hero.stack}',
                      style: const TextStyle(
                          color: _cyan,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              if (hero.streetBet > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '◉ ${hero.streetBet}',
                    style: const TextStyle(color: _cyan, fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String? _equityHint() {
    final g = table.engine;
    if (!table.heroToAct || g.board.length < 3 || g.active.length < 2) {
      return null;
    }
    final equity = Odds.equity(
      heroHole: table.hero.holeCards,
      board: g.board,
      opponents: g.active.length - 1,
      trials: 300,
    ).win;
    final buf =
        StringBuffer('胜率约 ${(equity * 100).toStringAsFixed(0)}%');
    if (g.board.length < 5) {
      try {
        final outs =
            Odds.outs(heroHole: table.hero.holeCards, board: g.board);
        if (outs > 0) buf.write(' · outs $outs');
      } catch (_) {
        // board 仅 1~2 张时 outs 不适用，忽略。
      }
    }
    return buf.toString();
  }
}

/// 英雄操作栏：预设档 + 滑杆选注，底部三个大按钮。
class _ActionBar extends StatefulWidget {
  const _ActionBar({required this.table});

  final TableController table;

  @override
  State<_ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends State<_ActionBar> {
  String _sig = '';
  int? _amount;

  TableController get table => widget.table;

  @override
  Widget build(BuildContext context) {
    final g = table.engine;
    final actions = table.heroLegalActions;
    LegalAction? find(ActionType t) {
      for (final a in actions) {
        if (a.type == t) return a;
      }
      return null;
    }

    final call = find(ActionType.call);
    final check = find(ActionType.check);
    final raiser = find(ActionType.bet) ?? find(ActionType.raise);

    // 局面变化时重置滑杆到最小可下注额。
    final sig = raiser == null
        ? ''
        : '${g.currentBet}/${raiser.minAmount}/${raiser.maxAmount}/${g.potTotal()}';
    if (sig != _sig) {
      _sig = sig;
      _amount = null;
    }
    final amount = (_amount ?? raiser?.minAmount ?? 0)
        .clamp(raiser?.minAmount ?? 0, raiser?.maxAmount ?? 0);

    final raiseType = raiser?.type;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (raiser != null)
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  for (final preset in _presetAmounts(g, raiser))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setState(() => _amount = preset.$2),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: amount == preset.$2
                                ? _chipBg
                                : const Color(0xFF161D22),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: amount == preset.$2
                                  ? _cyan
                                  : const Color(0xFF2A333B),
                            ),
                          ),
                          child: Text(preset.$1,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11.5)),
                        ),
                      ),
                    ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: _cyan,
                        thumbColor: _cyan,
                        inactiveTrackColor: const Color(0xFF2A333B),
                        overlayShape: SliderComponentShape.noOverlay,
                        trackHeight: 5,
                      ),
                      child: Slider(
                        value: amount.toDouble(),
                        min: raiser.minAmount.toDouble(),
                        max: raiser.maxAmount.toDouble(),
                        onChanged: (v) => setState(() => _amount = v.round()),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 52,
            child: Row(
              children: [
                _bigButton(
                  color: _btnBlue,
                  label: '弃牌',
                  onPressed: find(ActionType.fold) == null
                      ? null
                      : () => table.heroAct(ActionType.fold),
                ),
                const SizedBox(width: 8),
                _bigButton(
                  color: _btnGreen,
                  label: check != null
                      ? '过牌'
                      : '跟注 ${call?.amount ?? 0}',
                  onPressed: check != null
                      ? () => table.heroAct(ActionType.check)
                      : call != null
                          ? () => table.heroAct(ActionType.call)
                          : null,
                ),
                if (raiser != null) ...[
                  const SizedBox(width: 8),
                  _bigButton(
                    color: _btnRed,
                    label:
                        '${raiseType == ActionType.bet ? '下注' : '加注'} $amount',
                    onPressed: () =>
                        table.heroAct(raiseType!, amountTo: amount),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigButton({
    required Color color,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withValues(alpha: 0.25),
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          textStyle:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        onPressed: onPressed,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, maxLines: 1),
        ),
      ),
    );
  }

  /// 预设档位：(文案, 下到额度)。
  List<(String, int)> _presetAmounts(GameEngine g, LegalAction a) {
    final base = g.potTotal() + g.currentBet;
    final presets = <(String, int)>[
      ('最小', a.minAmount),
      ('½池', (base * 0.5).round().clamp(a.minAmount, a.maxAmount)),
      ('一池', base.clamp(a.minAmount, a.maxAmount)),
      ('全下', a.maxAmount),
    ];
    final seen = <int>{};
    return presets.where((p) => seen.add(p.$2)).toList();
  }
}

/// 顶部标题：桌名 · 第几手。
///
/// 盲注级别不在导航栏里显示（大厅卡片和存档里已经有），数字都在下面
/// 那条 [_NetStrip] 上。
class _TableTitle extends StatelessWidget {
  const _TableTitle({required this.table});

  final TableController table;

  @override
  Widget build(BuildContext context) {
    // 手数跟着右边的输赢数字走：数字是「刚打完/正在打的那一手」的，
    // 手数也是那一手的（本手结算完停在同一个数上，下一手发牌才 +1）。
    final handNo = table.engine.handOver
        ? (table.handsPlayed < 1 ? 1 : table.handsPlayed)
        : table.handsPlayed + 1;
    return Text(
      // 还没发牌时只写桌名，发下来就一直带手数（第 1 手也显示，
      // 以前要等第一手打完才冒出手数，标题会突然变长）。
      table.lastHand == null
          ? table.tableName
          : '${table.tableName} · 第 $handNo 手',
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 15),
    );
  }
}

/// 标题下面那条：本手输赢 + 本局输赢。
///
/// 「本手」是这一手牌的输赢（进行中就是实时值，打完就是最终结果，
/// 和结算条里的「本手赢利/亏损」是同一个数）；「本局」是坐在这张桌上
/// 从头到现在的累计。
class _NetStrip extends StatelessWidget {
  const _NetStrip({required this.table});

  final TableController table;

  @override
  Widget build(BuildContext context) {
    final hand = table.heroHandNet;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 5),
      child: Row(
        children: [
          if (hand != null) ...[
            _NetChip(label: '本手', value: hand),
            const SizedBox(width: 6),
          ],
          _NetChip(label: '本局', value: table.heroSessionNet),
        ],
      ),
    );
  }
}

/// 输赢小药丸：赢绿、亏红、不亏不赚灰。
class _NetChip extends StatelessWidget {
  const _NetChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final color = value > 0
        ? const Color(0xFF7CC98B)
        : value < 0
            ? const Color(0xFFE56B6B)
            : const Color(0xFF8A9299);
    final sign = value > 0 ? '+' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$label $sign${compactChips(value)}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 筹码数缩写：上万之后改写成「万」，免得导航栏被长数字撑爆。
String compactChips(int v) {
  final n = v.abs();
  if (n < 10000) return '$v';
  return '${v < 0 ? '-' : ''}${(n / 10000).toStringAsFixed(1)}万';
}

/// 结算条：盈亏 + 下一手。
class _HandOverBar extends StatelessWidget {
  const _HandOverBar({required this.table});

  final TableController table;

  @override
  Widget build(BuildContext context) {
    final hand = table.lastHand;
    final heroNet = hand?.netResult[TableController.heroId] ?? 0;
    final lines = hand == null
        ? ''
        : hand.netResult.entries
            .where((e) => e.value > 0)
            .map((e) => '${shortName(hand.playerNames[e.key] ?? e.key)} '
                '+${e.value}')
            .join('，');
    if (table.heroBusted) {
      final buyIn = table.engine.config.startingStack;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '筹码耗尽',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFFE56B6B),
              ),
            ),
            const SizedBox(height: 2),
            Text('本手亏损 $heroNet',
                style: const TextStyle(
                    color: Color(0xFF8A9299), fontSize: 11.5)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _btnRed,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: table.heroRebuy,
                icon: const Icon(Icons.replay),
                label: Text('补充筹码 $buyIn 并开始下一手',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            heroNet > 0
                ? '本手赢利 +$heroNet'
                : heroNet < 0
                    ? '本手亏损 $heroNet'
                    : '本手不亏不赚',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: heroNet > 0
                  ? const Color(0xFF7CC98B)
                  : heroNet < 0
                      ? const Color(0xFFE56B6B)
                      : Colors.white70,
            ),
          ),
          if (lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(lines,
                  style: const TextStyle(
                      color: Color(0xFF8A9299), fontSize: 11.5)),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _btnGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: table.startHand,
              icon: const Icon(Icons.skip_next),
              label: const Text('下一手',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单张扑克牌（card 为 null 时显示占位框）。
class PlayingCard extends StatelessWidget {
  const PlayingCard({
    super.key,
    required this.card,
    this.width = 44,
    this.height = 60,
    this.fontSize = 16,
    this.marginH = 3,
  });

  final poker.Card? card;
  final double width;
  final double height;
  final double fontSize;
  final double marginH;

  @override
  Widget build(BuildContext context) {
    final c = card;
    final red = c != null &&
        (c.suit == poker.Suit.hearts || c.suit == poker.Suit.diamonds);
    return Container(
      width: width,
      height: height,
      margin: EdgeInsets.symmetric(horizontal: marginH),
      decoration: BoxDecoration(
        color: c == null ? Colors.white24 : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black26),
      ),
      alignment: Alignment.center,
      child: c == null
          ? null
          : Text(
              c.pretty,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                color: red ? Colors.red.shade700 : Colors.black87,
              ),
            ),
    );
  }
}
