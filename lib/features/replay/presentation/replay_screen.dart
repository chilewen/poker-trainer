import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/card.dart' as poker;
import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../../main.dart';
import '../../game/presentation/game_screen.dart';
import '../../game/presentation/table_controller.dart';

/// 复盘页：手牌列表 + 逐步回放 + 错局重玩入口。
class ReplayScreen extends ConsumerWidget {
  const ReplayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(tableProvider).history;
    if (history.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '暂无手牌记录\n先去「对局」打几手，这里会保存每一手的完整过程。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black45, height: 1.6),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: history.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final hand = history[i];
        return Dismissible(
          key: ValueKey(hand.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red.shade400,
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) =>
              ref.read(tableProvider).deleteHand(hand.id),
          child: _HandCard(hand: hand),
        );
      },
    );
  }
}

/// 列表里的单条手牌摘要。
class _HandCard extends StatelessWidget {
  const _HandCard({required this.hand});

  final HandHistory hand;

  @override
  Widget build(BuildContext context) {
    final heroNet = hand.netResult[TableController.heroId] ?? 0;
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => HandDetailScreen(hand: hand)),
        ),
        title: Row(
          children: [
            Text(_fmtTime(hand.timestamp), style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            Text(
              _fmtStreet(hand),
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.black45),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final c in hand.board) PlayingCard(card: c),
              if (hand.board.isEmpty)
                Text('未发公共牌', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${heroNet >= 0 ? '+' : ''}$heroNet',
              style: theme.textTheme.titleMedium?.copyWith(
                color:
                    heroNet >= 0 ? Colors.green.shade700 : Colors.red.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text('底池 ${hand.finalPot}', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// 手牌详情：按动作逐步回放。
class HandDetailScreen extends ConsumerStatefulWidget {
  const HandDetailScreen({super.key, required this.hand});

  final HandHistory hand;

  @override
  ConsumerState<HandDetailScreen> createState() => _HandDetailScreenState();
}

class _HandDetailScreenState extends ConsumerState<HandDetailScreen> {
  /// 已回放到第几步（0 = 尚未行动，len = 全部）。
  int _step = 0;
  bool _playing = false;
  Timer? _timer;

  HandHistory get hand => widget.hand;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Street get _currentStreet {
    if (_step == 0) return Street.preflop;
    return hand.actions[_step - 1].street;
  }

  int get _boardCount => _streetBoardCount(_currentStreet);

  int _streetBoardCount(Street s) {
    final n = switch (s) {
      Street.preflop => 0,
      Street.flop => 3,
      Street.turn => 4,
      Street.river || Street.showdown => 5,
    };
    return n.clamp(0, hand.board.length);
  }

  int get _pot {
    if (_step == 0) return hand.smallBlind + hand.bigBlind;
    return hand.actions[_step - 1].potAfter;
  }

  bool get _finished => _step == hand.actions.length;

  void _goTo(int step) {
    setState(() => _step = step.clamp(0, hand.actions.length));
  }

  void _togglePlay() {
    setState(() {
      _playing = !_playing;
      if (_playing) {
        if (_finished) _step = 0;
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(milliseconds: 800), (_) {
          if (_step >= hand.actions.length) {
            _togglePlay();
            return;
          }
          _goTo(_step + 1);
        });
      } else {
        _timer?.cancel();
      }
    });
  }

  void _replayThisHand() {
    _timer?.cancel();
    ref.read(tableProvider).replayHand(hand);
    // 回到大厅并打开牌桌进行重玩。
    ref.read(tabIndexProvider.notifier).state = 0;
    Navigator.of(context)
      ..popUntil((r) => r.isFirst)
      ..push(
        MaterialPageRoute<void>(
          builder: (_) => const GameScreen(autoStart: false),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revealed = _boardCount;
    return Scaffold(
      appBar: AppBar(
        title: Text('复盘 · ${_fmtTime(hand.timestamp)}'),
        actions: [
          TextButton.icon(
            onPressed: _replayThisHand,
            icon: const Icon(Icons.replay),
            label: const Text('重玩本局'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _boardRow(revealed),
          const SizedBox(height: 16),
          _playersRow(),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '阶段：${_currentStreet.label}',
                style: theme.textTheme.titleSmall,
              ),
              Text(
                '底池：$_pot',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: Colors.green.shade700),
              ),
              Text(
                '进度：$_step / ${hand.actions.length}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                onPressed: _step == 0 ? null : () => _goTo(_step - 1),
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                onPressed: _finished ? null : () => _goTo(_step + 1),
                icon: const Icon(Icons.skip_next),
              ),
              Expanded(
                child: Slider(
                  value: _step.toDouble(),
                  max: hand.actions.length.toDouble(),
                  divisions: hand.actions.length,
                  label: '$_step',
                  onChanged: (v) => _goTo(v.round()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_finished) _resultCard(theme),
          const SizedBox(height: 8),
          _actionsList(theme),
        ],
      ),
    );
  }

  Widget _boardRow(int revealed) {
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < 5; i++)
          PlayingCard(
              card:
                  i < hand.board.length && i < revealed ? hand.board[i] : null),
      ],
    );
  }

  Widget _playersRow() {
    final heroCards = hand.holeCards[TableController.heroId] ?? const [];
    final others = hand.playerNames.entries
        .where((e) => e.key != TableController.heroId)
        .toList();
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _playerChip(
          '我',
          heroCards,
          net: hand.netResult[TableController.heroId],
          highlight: true,
        ),
        for (final e in others)
          _playerChip(
            e.value,
            hand.holeCards[e.key] ?? const [],
            net: hand.netResult[e.key],
          ),
      ],
    );
  }

  Widget _playerChip(String name, List<poker.Card> cards,
      {int? net, bool highlight = false}) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final c in cards) PlayingCard(card: c),
        ]),
        if (net != null)
          Text(
            '${net >= 0 ? '+' : ''}$net',
            style: theme.textTheme.labelSmall?.copyWith(
              color: net >= 0 ? Colors.green.shade700 : Colors.red.shade700,
            ),
          ),
      ],
    );
  }

  Widget _resultCard(ThemeData theme) {
    final lines = hand.playerNames.entries
        .map((e) => '${e.value}：${hand.netResult[e.key] ?? 0}')
        .join('　');
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '结算\n$lines',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
      ),
    );
  }

  Widget _actionsList(ThemeData theme) {
    final visible = hand.actions
        .where((a) => a.street.index <= _currentStreet.index)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text('动作记录', style: theme.textTheme.labelLarge),
            ),
            for (var i = 0; i < visible.length; i++)
              _actionRow(theme, i, visible[i], highlighted: i == _step - 1),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('翻牌前行动', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(ThemeData theme, int i, ActionRecord a,
      {required bool highlighted}) {
    final actor = hand.playerNames[a.actorId] ?? a.actorId;
    final amount = (a.type == ActionType.bet || a.type == ActionType.raise)
        ? ' ${a.amount}'
        : '';
    return Container(
      color: highlighted ? Colors.green.shade100 : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(a.street.label, style: theme.textTheme.labelSmall),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$actor ${a.type.label}$amount',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: highlighted ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text('池 ${a.potAfter}', style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

String _fmtTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
}

String _fmtStreet(HandHistory hand) {
  final last = hand.actions.isEmpty ? null : hand.actions.last.street;
  return last?.label ?? '未行动';
}
