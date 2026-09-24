import 'package:flutter/material.dart';

import '../../../engine/card.dart' as poker;
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';

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

/// 中文位置名：庄位/小盲/大盲/枪口/中位/关煞（单挑：庄位、大盲）。
String? cnPosition(List<String> order, int buttonIndex, String id) {
  final n = order.length;
  if (n < 2 || buttonIndex < 0) return null;
  final i = order.indexOf(id);
  if (i < 0) return null;
  if (n == 2) return i == buttonIndex ? '庄位' : '大盲';
  final d = (i - buttonIndex + n) % n;
  switch (d) {
    case 0:
      return '庄位';
    case 1:
      return '小盲';
    case 2:
      return '大盲';
    case 3:
      return '枪口';
    default:
      if (d == n - 1) return '关煞';
      if (d == n - 2 && n > 6) return '嗨加';
      return '中位';
  }
}

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
                  itemBuilder: (context, index) =>
                      _HandTile(hand: hands[index], heroId: heroId),
                ),
        ),
      ],
    );
  }
}

/// 单手牌的可展开卡片：收起显示盈亏与牌面，展开显示各人行动路线。
class _HandTile extends StatefulWidget {
  const _HandTile({required this.hand, required this.heroId});

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

/// 单手牌明细：按街分组，同一玩家的连续动作合并为一行。
class _HandDetail extends StatelessWidget {
  const _HandDetail({required this.hand, required this.heroId});

  final HandHistory hand;
  final String heroId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _buildSections(),
    );
  }

  List<Widget> _buildSections() {
    final order = hand.playerNames.keys.toList();
    // 逐条记录模拟每位玩家的「后手」（剩余筹码）与本街下注额。
    final behind = Map<String, int>.of(hand.startingStacks);
    final streetBet = {for (final id in order) id: 0};
    var streetMax = 0;
    Street? cur;
    var preflopBets = 0; // 用于识别前两条盲注

    final widgets = <Widget>[];
    final folded = <String>{};

    Widget rowOf({
      required String posText,
      required bool isHero,
      int? behindStack,
      required String actionText,
      required Color color,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                posText,
                style: TextStyle(
                  color: isHero ? _cyan : const Color(0xFF9AA3AB),
                  fontSize: 12.5,
                ),
              ),
            ),
            SizedBox(
              width: 54,
              child: behindStack == null
                  ? const SizedBox.shrink()
                  : Text(
                      '($behindStack)',
                      style: const TextStyle(
                          color: Color(0xFF7A838B), fontSize: 11.5),
                    ),
            ),
            Expanded(
              child: Text(actionText,
                  style: TextStyle(color: color, fontSize: 12.5)),
            ),
          ],
        ),
      );
    }

    final acts = hand.actions;
    var i = 0;
    while (i < acts.length) {
      cur = acts[i].street;
      streetMax = 0;
      for (final id in streetBet.keys) {
        streetBet[id] = 0;
      }

      // 收集本街动作：同一玩家的连续动作合并为一行（用 → 连接），
      // 所有弃牌合并为一行，不再每步各占一行。
      final seqPlayers = <String>[];
      final seqLabels = <String, List<String>>{};
      final seqTypes = <String, ActionType>{};
      final seqBehind = <String, int>{};
      final foldNames = <String>[];
      var heroFolded = false;

      while (i < acts.length && acts[i].street == cur) {
        final a = acts[i];
        if (a.type == ActionType.fold) {
          folded.add(a.actorId);
          heroFolded = heroFolded || a.actorId == heroId;
          foldNames.add(
              cnPosition(order, hand.buttonIndex, a.actorId) ?? a.actorId);
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

        if (!seqLabels.containsKey(a.actorId)) {
          seqLabels[a.actorId] = [];
          seqPlayers.add(a.actorId);
        }
        seqLabels[a.actorId]!.add(label);
        seqTypes[a.actorId] = a.type;
        seqBehind[a.actorId] = behind[a.actorId]!;
        i++;
      }

      widgets.add(_streetHeader(cur));
      widgets.addAll([
        for (final pid in seqPlayers)
          rowOf(
            posText: cnPosition(order, hand.buttonIndex, pid) ?? pid,
            isHero: pid == heroId,
            behindStack: seqBehind[pid],
            actionText: seqLabels[pid]!.join(' → '),
            color: actionColor(seqTypes[pid]!),
          ),
        if (foldNames.isNotEmpty)
          rowOf(
            posText: foldNames.join('、'),
            isHero: heroFolded,
            actionText: '弃牌',
            color: actionColor(ActionType.fold),
          ),
      ]);
    }

    // 摊牌汇总：未弃牌者亮牌 + 盈亏。
    if (hand.netResult.values.any((v) => v != 0)) {
      widgets.add(_streetHeader(Street.showdown));
      widgets.addAll([
        for (final id in order.where((id) => !folded.contains(id)))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
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
      ]);
    }

    return widgets;
  }

  int? _streetEndPot(Street s) {
    final acts = hand.actions;
    for (var k = acts.length - 1; k >= 0; k--) {
      if (acts[k].street == s) return acts[k].potAfter;
    }
    return null;
  }

  Widget _streetHeader(Street street) {
    final cards = switch (street) {
      Street.preflop => hand.holeCards[heroId] ?? const [],
      Street.flop =>
        hand.board.length >= 3 ? hand.board.sublist(0, 3) : hand.board,
      Street.turn =>
        hand.board.length >= 4 ? hand.board.sublist(0, 4) : hand.board,
      Street.river ||
      Street.showdown =>
        hand.board,
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
