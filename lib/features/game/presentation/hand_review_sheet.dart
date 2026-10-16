import 'package:flutter/material.dart';

import '../../../engine/card.dart' as poker;
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../domain/hand_analysis.dart';
import '../domain/hand_grade.dart';
import '../domain/table_position.dart';

const _sheetBg = Color(0xFF0F1418);
const _cardBg = Color(0xFF141B21);
const _cyan = Color(0xFF3AD0CC);
const _green = Color(0xFF7CC98B);
const _red = Color(0xFFE56B6B);
const _grey = Color(0xFF8A9299);

/// 行动颜色：弃牌/过牌灰、跟注绿、下注蓝、加注红。
Color actionColor(ActionType t) => switch (t) {
      ActionType.fold => _grey,
      ActionType.check => _grey,
      ActionType.call => _green,
      ActionType.bet => const Color(0xFF5FA8F5),
      ActionType.raise => _red,
    };

/// 打开「手牌回顾」底部面板：近局列表，点开展开该手的行动路线。
/// [hands] 最新在前（可含进行中的当前手）。
Future<void> showHandReviewSheet(
  BuildContext context,
  List<HandHistory> hands,
  String heroId,
) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: _sheetBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) =>
          _HandReviewSheet(hands: hands, heroId: heroId, controller: controller),
    ),
  );
}

class _HandReviewSheet extends StatelessWidget {
  const _HandReviewSheet({
    required this.hands,
    required this.heroId,
    required this.controller,
  });

  final List<HandHistory> hands;
  final String heroId;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 0),
          child: Row(
            children: [
              const SizedBox(width: 48),
              Expanded(
                child: Text(
                  '手牌回顾',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Colors.white),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white54),
              ),
            ],
          ),
        ),
        Expanded(
          child: hands.isEmpty
              ? const Center(
                  child: Text('还没有手牌记录',
                      style: TextStyle(color: _grey, fontSize: 13)),
                )
              : ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: hands.length,
                  itemBuilder: (context, index) => _HandTile(
                    key: ValueKey('hand-${hands[index].id}'),
                    hand: hands[index],
                    heroId: heroId,
                  ),
                ),
        ),
      ],
    );
  }
}

/// 单手牌的可展开卡片：收起显示盈亏与牌面，展开显示各人行动路线。
class _HandTile extends StatefulWidget {
  const _HandTile({super.key, required this.hand, required this.heroId});

  final HandHistory hand;
  final String heroId;

  @override
  State<_HandTile> createState() => _HandTileState();
}

class _HandTileState extends State<_HandTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hand = widget.hand;
    final net = hand.netResult[widget.heroId];
    final hole = hand.holeCards[widget.heroId] ?? const <poker.Card>[];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 46,
                    child: net == null
                        ? const Icon(Icons.toll, color: _cyan, size: 14)
                        : Text(
                            '${net > 0 ? '+' : ''}$net',
                            style: TextStyle(
                              color: net > 0
                                  ? _green
                                  : net < 0
                                      ? _red
                                      : _grey,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  for (final c in hole) _MiniCard(card: c),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          for (final c in hand.board) _MiniCard(card: c),
                        ],
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.white38,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: Color(0xFF232B32)),
            _HandDetail(hand: hand, heroId: widget.heroId),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// 小号牌面贴（列表与明细共用）。
class _MiniCard extends StatelessWidget {
  const _MiniCard({required this.card});

  final poker.Card card;

  @override
  Widget build(BuildContext context) {
    final red = card.suit == poker.Suit.hearts ||
        card.suit == poker.Suit.diamonds;
    return Container(
      width: 28,
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black26),
      ),
      alignment: Alignment.center,
      child: Text(
        card.pretty,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: red ? Colors.red.shade700 : Colors.black87,
        ),
      ),
    );
  }
}

/// 单手牌明细：按街分列（横向滚动），每列列出该街行动的人。
///
/// 样式照「牌谱视图」：一个街道一列，列头是街名 + 该街起始底池；列里每位玩家
/// 一行（风格头像 + 名字 + 位置 + 行动），弃牌的人收进一个可点开的小药丸。
class _HandDetail extends StatefulWidget {
  const _HandDetail({required this.hand, required this.heroId});

  final HandHistory hand;
  final String heroId;

  @override
  State<_HandDetail> createState() => _HandDetailState();
}

class _HandDetailState extends State<_HandDetail> {
  /// 哪些街道的「弃牌」小药丸被展开了。
  final Set<Street> _openFolds = {};

  static const _boardStreets = [
    Street.preflop,
    Street.flop,
    Street.turn,
    Street.river,
  ];

  @override
  Widget build(BuildContext context) {
    final hand = widget.hand;
    final heroId = widget.heroId;
    final order = hand.playerNames.keys.toList();
    // 单手复盘数据（位置/SPR/底池/赔率）——纯 Dart 算，这里只负责摆出来。
    final analysis = HandAnalysis.of(hand, heroId: heroId);
    // 判断层：范围归属、翻前胜率、失误标记。
    final grade = HandGrade.of(analysis);
    final mistakeAt = {for (final m in grade.mistakes) m.decisionIndex: m};
    // 逐条记录模拟每位玩家的「后手」（剩余筹码）与本街下注额。
    final behind = Map<String, int>.of(hand.startingStacks);
    final streetBet = {for (final id in order) id: 0};
    var streetMax = 0;
    var preflopBets = 0; // 用于识别前两条盲注

    final sections = <Street, _StreetSection>{};
    final folded = <String>{};

    final acts = hand.actions;
    var i = 0;
    while (i < acts.length) {
      final street = acts[i].street;
      streetMax = 0;
      for (final id in streetBet.keys) {
        streetBet[id] = 0;
      }
      // 同一玩家的连续动作合并为一行（用 → 连接）；弃牌的人单收进小药丸。
      final seqPlayers = <String>[];
      final seqLabels = <String, List<String>>{};
      final seqTypes = <String, ActionType>{};
      final seqNotes = <String, List<String>>{};
      final foldedHere = <String>[];

      while (i < acts.length && acts[i].street == street) {
        final a = acts[i];
        if (a.type == ActionType.fold) {
          folded.add(a.actorId);
          foldedHere.add(a.actorId);
          i++;
          continue;
        }
        // 推进入池额，更新本街下注与后手。
        int delta = 0;
        switch (a.type) {
          case ActionType.check:
          case ActionType.fold:
            break;
          case ActionType.call:
            delta = streetMax - (streetBet[a.actorId] ?? 0);
          case ActionType.bet:
          case ActionType.raise:
            delta = a.amount - (streetBet[a.actorId] ?? 0);
        }
        delta = delta.clamp(0, behind[a.actorId] ?? 0);
        behind[a.actorId] = (behind[a.actorId] ?? 0) - delta;
        streetBet[a.actorId] = (streetBet[a.actorId] ?? 0) + delta;
        if (streetBet[a.actorId]! > streetMax) {
          streetMax = streetBet[a.actorId]!;
        }

        String label;
        if (a.street == Street.preflop &&
            a.type == ActionType.bet &&
            preflopBets < 2) {
          label = '${preflopBets == 0 ? '小盲' : '大盲'} ${a.amount}';
          preflopBets++;
        } else if (a.type == ActionType.call) {
          label = '跟注 $delta';
        } else if (a.type == ActionType.fold || a.type == ActionType.check) {
          label = a.type.label;
        } else {
          label = '${a.type.label} ${a.amount}';
        }

        final miss = mistakeAt[i];
        if (miss != null) {
          label += '  ⚠${miss.kind.label}';
        }

        if (!seqLabels.containsKey(a.actorId)) {
          seqLabels[a.actorId] = [];
          seqPlayers.add(a.actorId);
        }
        seqLabels[a.actorId]!.add(label);
        seqTypes[a.actorId] = a.type;

        // 英雄面对下注的决策注解（保本胜率 + 跟注 EV）：单独起一行放在名字
        // 底下，别塞进右边那点地方——光看赔率不够，胜率足够高时跟注才正 EV。
        final point = analysis.decisions[i];
        if (point.isHero && point.facingBet) {
          var tail = '保本 ${(point.potOdds * 100).round()}%';
          final ev = grade.callEv(point);
          if (ev != null) {
            tail += ' · 跟注 EV ${ev >= 0 ? '+' : ''}${ev.round()}';
          }
          seqNotes.putIfAbsent(a.actorId, () => []).add(tail);
        }
        i++;
      }

      final si = _boardStreets.indexOf(street);
      sections[street] = _StreetSection(
        street: street,
        // 列头显示的是**进入这条街时的底池**（上一条街打完的池），翻前是 0。
        pot: si <= 0 ? 0 : (_streetEndPot(_boardStreets[si - 1]) ?? 0),
        actors: [
          for (final pid in seqPlayers)
            _actor(pid, seqLabels[pid]!.join(' → '), seqTypes[pid]!, order,
                note: seqNotes[pid]?.join(' · ')),
        ],
        folded: [
          for (final pid in foldedHere)
            _actor(pid, '弃牌', ActionType.fold, order),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _overview(analysis, grade),
        if (grade.mistakes.isNotEmpty) _mistakeList(grade),
        const SizedBox(height: 6),
        _streetColumns(sections),
        if (hand.netResult.values.any((v) => v != 0)) _showdown(order, folded),
        const SizedBox(height: 8),
      ],
    );
  }

  _StreetActor _actor(
      String pid, String text, ActionType type, List<String> order,
      {String? note}) {
    final hand = widget.hand;
    return _StreetActor(
      playerId: pid,
      name: hand.playerNames[pid] ?? pid,
      position: cnPosition(order, hand.buttonIndex, pid) ?? '',
      actionText: text,
      color: actionColor(type),
      isHero: pid == widget.heroId,
      note: note,
    );
  }

  /// 列头街名：翻牌前在窄列里写成「翻前」（跟牌谱视图一致），其余照旧。
  String _streetTitle(Street s) => s == Street.preflop ? '翻前' : s.label;

  /// 各街分列：横向滚动，列里是该街行动的人。
  Widget _streetColumns(Map<Street, _StreetSection> sections) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in _boardStreets)
              _streetColumn(sections[s] ??
                  _StreetSection(
                      street: s, pot: 0, actors: const [], folded: const [])),
          ],
        ),
      ),
    );
  }

  Widget _streetColumn(_StreetSection section) {
    final open = _openFolds.contains(section.street);
    return Container(
      width: 216,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF232B32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 列头：街名 + 该街起始底池。
          Row(
            children: [
              Text(
                _streetTitle(section.street),
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                width: 7,
                height: 7,
                decoration:
                    const BoxDecoration(color: _cyan, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text('${section.pot}',
                  style: const TextStyle(color: _cyan, fontSize: 12)),
            ],
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: const Color(0xFF232B32),
          ),
          if (section.actors.isEmpty && section.folded.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('—',
                  style: TextStyle(color: Color(0xFF5A636B), fontSize: 12)),
            ),
          for (final actor in section.actors) ...[
            _actorRow(actor),
            if (actor.note != null)
              Padding(
                padding: const EdgeInsets.only(left: 38, bottom: 4),
                child: Text(
                  actor.note!,
                  style: const TextStyle(
                      color: Color(0xFF7A838B),
                      fontSize: 10.5,
                      height: 1.35),
                ),
              ),
          ],
          if (section.folded.isNotEmpty)
            _foldedPill(section.folded, open: open, street: section.street),
        ],
      ),
    );
  }

  Widget _actorRow(_StreetActor actor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _SeatAvatar(name: actor.name, seed: actor.playerId, size: 30),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortPlayerName(actor.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: actor.isHero ? _cyan : Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                if (actor.position.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232B32),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(actor.position,
                        style: const TextStyle(
                            color: Color(0xFF9AA3AB), fontSize: 10)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 78,
            child: Text(
              actor.actionText,
              textAlign: TextAlign.right,
              style: TextStyle(color: actor.color, fontSize: 12.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  /// 弃牌的人收进一个小药丸：叠放头像 + 位置 + 展开箭头。
  Widget _foldedPill(List<_StreetActor> folded,
      {required bool open, required Street street}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          if (open) {
            _openFolds.remove(street);
          } else {
            _openFolds.add(street);
          }
        }),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1B232B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 14.0 * (folded.length.clamp(1, 3) - 1) + 26,
                    height: 26,
                    child: Stack(
                      children: [
                        for (var k = 0; k < folded.length && k < 3; k++)
                          Positioned(
                            left: k * 14.0,
                            child: _SeatAvatar(
                              name: folded[k].name,
                              seed: folded[k].playerId,
                              size: 26,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      folded
                          .map((f) =>
                              f.position.isNotEmpty ? f.position : f.name)
                          .join('、'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFF9AA3AB), fontSize: 11.5),
                    ),
                  ),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: Colors.white38,
                  ),
                ],
              ),
            ),
            if (open)
              for (final f in folded)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 2),
                  child: Row(
                    children: [
                      _SeatAvatar(name: f.name, seed: f.playerId, size: 22),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          shortPlayerName(f.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF9AA3AB),
                              fontSize: 11.5,
                              decoration: TextDecoration.lineThrough),
                        ),
                      ),
                      Text(f.position,
                          style: const TextStyle(
                              color: Color(0xFF5A636B), fontSize: 10.5)),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 摊牌汇总：未弃牌者亮牌 + 盈亏。
  Widget _showdown(List<String> order, Set<String> folded) {
    final hand = widget.hand;
    final heroId = widget.heroId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _streetHeader(Street.showdown),
        for (final id in order.where((id) => !folded.contains(id)))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                _SeatAvatar(
                    name: hand.playerNames[id] ?? id, seed: id, size: 26),
                const SizedBox(width: 8),
                SizedBox(
                  width: 56,
                  child: Text(
                    cnPosition(order, hand.buttonIndex, id) ?? id,
                    style: TextStyle(
                      color: id == heroId ? _cyan : const Color(0xFF9AA3AB),
                      fontSize: 12.5,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${hand.playerNames[id] ?? id}　'
                    '${(hand.holeCards[id] ?? const [])
                        .map((c) => c.pretty)
                        .join(' ')}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12.5),
                  ),
                ),
                Text(
                  '${(hand.netResult[id] ?? 0) >= 0 ? '+' : ''}'
                  '${hand.netResult[id] ?? 0}',
                  style: TextStyle(
                    color: (hand.netResult[id] ?? 0) > 0
                        ? _green
                        : (hand.netResult[id] ?? 0) < 0
                            ? _red
                            : _grey,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 单手概览：位置、起手牌与范围、翻前胜率、SPR、各街底池，再加行动线速记。
  ///
  /// 位置和底池在下面的分街明细里也有，但那要一行行读；这里给的是「一眼看完
  /// 这手是个什么局面」——SPR 1 和 SPR 15 是完全两种打法。
  Widget _overview(HandAnalysis a, HandGrade g) {
    final equity = g.preflopEquity(opponents: a.order.length - 1);
    final facts = <(String, String)>[
      if (a.heroPosition != null) ('位置', a.heroPosition!),
      if (g.preflopLabel != null) ('起手', g.preflopLabel!),
      if (g.preflopLabel != null)
        ('范围', g.inOpenRange ? '开池内' : '开池外'),
      if (equity != null)
        ('翻前胜率', '${(equity * 100).round()}% · 对${a.order.length - 1}人'),
      if (a.spr != null) ('SPR', a.spr!.toStringAsFixed(1)),
      ('翻前池', '${a.potPreflop}'),
      if (a.potAtFlop != null) ('翻牌池', '${a.potAtFlop}'),
      ('最终池', '${a.finalPot}'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final (label, value) in facts)
                Text('$label $value',
                    style: const TextStyle(
                        color: Color(0xFF9AA3AB), fontSize: 11.5)),
            ],
          ),
          if (a.actionLine.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              a.actionLine,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// 失误清单：这手哪里打错了、下次怎么打，一条失误两行。
  ///
  /// 光说「错在哪」玩家看完还是会犯；紧跟着给一句改法，复盘才算有用。
  Widget _mistakeList(HandGrade g) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in g.mistakes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚠ ${m.kind.label}：${m.detail}',
                    style: const TextStyle(
                        color: Color(0xFFE5A96B), fontSize: 11.5, height: 1.4),
                  ),
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      '↳ 下次这样打：${m.fix}',
                      style: const TextStyle(
                          color: Color(0xFF8FD8D5),
                          fontSize: 11.5,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  int? _streetEndPot(Street s) {
    final acts = widget.hand.actions;
    for (var k = acts.length - 1; k >= 0; k--) {
      if (acts[k].street == s) return acts[k].potAfter;
    }
    return null;
  }

  Widget _streetHeader(Street street) {
    final hand = widget.hand;
    final heroId = widget.heroId;
    final cards = switch (street) {
      Street.preflop => hand.holeCards[heroId] ?? const [],
      Street.flop =>
        hand.board.length >= 3 ? hand.board.sublist(0, 3) : hand.board,
      Street.turn =>
        hand.board.length >= 4 ? hand.board.sublist(0, 4) : hand.board,
      Street.river || Street.showdown => hand.board,
    };
    final pot = street == Street.showdown
        ? (hand.actions.isEmpty ? 0 : hand.actions.last.potAfter)
        : _streetEndPot(street);
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 10, 4, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1418),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(
            street.label,
            style: const TextStyle(color: Color(0xFF9AA3AB), fontSize: 12.5),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cards.map((c) => c.pretty).join(' '),
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
          if (pot != null) ...[
            const Icon(Icons.toll, color: _cyan, size: 13),
            const SizedBox(width: 3),
            Text('$pot', style: const TextStyle(color: _cyan, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// 圆形头像：里面镶风格简称（跟牌桌座位一致），底色按 id 稳定取。
class _SeatAvatar extends StatelessWidget {
  const _SeatAvatar({required this.name, required this.seed, this.size = 30});

  final String name;
  final String seed;
  final double size;

  static const _colors = [
    Color(0xFF4E6E8E),
    Color(0xFF7A5C8E),
    Color(0xFF4E8E6A),
    Color(0xFF8E6A4E),
    Color(0xFF8E4E5C),
  ];

  static int _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x3FFFFFFF;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _colors[_hash(seed) % _colors.length],
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        avatarLabel(name),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.34,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// 一位玩家在一街里的行动（用于分列展示）。
class _StreetActor {
  const _StreetActor({
    required this.playerId,
    required this.name,
    required this.position,
    required this.actionText,
    required this.color,
    required this.isHero,
    this.note,
  });

  final String playerId;
  final String name;
  final String position;
  final String actionText;
  final Color color;
  final bool isHero;
  final String? note;
}

/// 一街的分列数据。
class _StreetSection {
  const _StreetSection({
    required this.street,
    required this.pot,
    required this.actors,
    required this.folded,
  });

  final Street street;
  final int pot;
  final List<_StreetActor> actors;
  final List<_StreetActor> folded;
}
