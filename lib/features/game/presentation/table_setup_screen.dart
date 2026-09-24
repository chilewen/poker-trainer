import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/game.dart';
import 'game_screen.dart';

/// 盲注级别：小盲/大盲与 100bb 买入。
class _BlindLevel {
  const _BlindLevel(this.smallBlind, this.bigBlind);

  final int smallBlind;
  final int bigBlind;

  int get buyIn => bigBlind * 100;

  String get label => '$smallBlind/$bigBlind';
}

const _blindLevels = [
  _BlindLevel(1, 2),
  _BlindLevel(2, 4),
  _BlindLevel(5, 10),
  _BlindLevel(10, 20),
  _BlindLevel(50, 100),
  _BlindLevel(100, 200),
  _BlindLevel(500, 1000),
];

const _playerCounts = [2, 6, 9];

/// 实战设置页：选择人数与盲注级别，点击「开始实战」进入牌桌。
class TableSetupScreen extends ConsumerStatefulWidget {
  const TableSetupScreen({super.key});

  @override
  ConsumerState<TableSetupScreen> createState() => _TableSetupScreenState();
}

class _TableSetupScreenState extends ConsumerState<TableSetupScreen> {
  int _playerCount = 6;
  _BlindLevel _level = _blindLevels[4]; // 默认 50/100

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('人机实战')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  Text('人数', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: [
                      for (final n in _playerCounts)
                        ButtonSegment(
                          value: n,
                          label: Text(n == 2 ? '单挑' : '$n人'),
                        ),
                    ],
                    selected: {_playerCount},
                    onSelectionChanged: (s) =>
                        setState(() => _playerCount = s.first),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text('级别（常规 100bb）',
                            style: theme.textTheme.titleSmall),
                      ),
                      Text('后手',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final level in _blindLevels) _levelTile(level),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始实战'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _levelTile(_BlindLevel level) {
    final theme = Theme.of(context);
    final selected = level == _level;
    return InkWell(
      onTap: () => setState(() => _level = level),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                level.label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: selected ? theme.colorScheme.primary : null,
                ),
              ),
            ),
            Text('${level.buyIn}', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 12),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }

  void _start() {
    final count = _playerCount;
    final level = _level;
    ref.read(tableProvider).startRealTable(
          label: '实战 ${count == 2 ? "单挑" : "$count人桌"} · ${level.label}',
          config: GameConfig(
            startingStack: level.buyIn,
            smallBlind: level.smallBlind,
            bigBlind: level.bigBlind,
          ),
          playerCount: count,
        );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const GameScreen(autoStart: false),
      ),
    );
  }
}
