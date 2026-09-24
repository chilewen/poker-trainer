import 'package:flutter/material.dart';

import '../../../engine/card.dart' as poker;
import '../../../trainer/odds.dart';

/// 概率工具页：蒙特卡洛胜率、outs、底池赔率。
class OddsScreen extends StatefulWidget {
  const OddsScreen({super.key});

  @override
  State<OddsScreen> createState() => _OddsScreenState();
}

class _OddsScreenState extends State<OddsScreen> {
  final _heroHole = <poker.Card?>[null, null];
  final _board = <poker.Card?>[null, null, null, null, null];
  int _streetIndex = 0; // 0翻牌前 1翻牌 2转牌 3河牌
  int _opponents = 1;
  EquityResult? _result;
  bool _calculating = false;

  final _potController = TextEditingController(text: '300');
  final _toCallController = TextEditingController(text: '100');

  static const _streetLabels = ['翻牌前', '翻牌', '转牌', '河牌'];
  static const _streetBoardCounts = [0, 3, 4, 5];

  int get _boardCount => _streetBoardCounts[_streetIndex];

  Set<poker.Card> get _usedCards => {
        for (final c in _heroHole)
          if (c != null) c,
        for (final c in _board)
          if (c != null) c,
      };

  List<poker.Card> get _boardCards =>
      _board.take(_boardCount).whereType<poker.Card>().toList();

  bool get _inputComplete =>
      _heroHole.every((c) => c != null) &&
      _board.take(_boardCount).every((c) => c != null);

  Future<void> _calculate() async {
    if (!_inputComplete || _calculating) return;
    setState(() {
      _calculating = true;
      _result = null;
    });
    // 让出一帧刷新 UI，再跑模拟。
    final result = await Future(() => Odds.equity(
          heroHole: _heroHole.cast<poker.Card>(),
          board: _boardCards,
          opponents: _opponents,
          trials: 3000,
        ));
    if (!mounted) return;
    setState(() {
      _calculating = false;
      _result = result;
    });
  }

  @override
  void dispose() {
    _potController.dispose();
    _toCallController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle(theme, '我的底牌'),
        Row(
          children: [
            for (var i = 0; i < 2; i++)
              _CardSlot(
                card: _heroHole[i],
                onTap: () => _pickCard((c) => setState(() => _heroHole[i] = c),
                    current: _heroHole[i]),
              ),
            const Spacer(),
            TextButton(
              onPressed: _clearAll,
              child: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionTitle(theme, '公共牌'),
        SegmentedButton<int>(
          segments: [
            for (var i = 0; i < 4; i++)
              ButtonSegment(value: i, label: Text(_streetLabels[i])),
          ],
          selected: {_streetIndex},
          onSelectionChanged: (s) => setState(() => _streetIndex = s.first),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < 5; i++)
              Expanded(
                child: i < _boardCount
                    ? _CardSlot(
                        card: _board[i],
                        onTap: () => _pickCard(
                            (c) => setState(() => _board[i] = c),
                            current: _board[i]),
                      )
                    : const _CardSlot(card: null, onTap: null),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _sectionTitle(theme, '对手数量'),
            const Spacer(),
            DropdownButton<int>(
              value: _opponents,
              items: [
                for (var i = 1; i <= 8; i++)
                  DropdownMenuItem(value: i, child: Text('$i 人')),
              ],
              onChanged: (v) => setState(() => _opponents = v ?? 1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _inputComplete && !_calculating ? _calculate : null,
          icon: _calculating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.calculate),
          label: Text(_calculating ? '模拟中…' : '计算胜率'),
        ),
        const SizedBox(height: 16),
        if (_result != null) _resultCard(theme, _result!),
        if (_boardCount >= 3 &&
            _boardCount <= 4 &&
            _board.take(_boardCount).every((c) => c != null) &&
            _heroHole.every((c) => c != null))
          _outsCard(theme),
        const SizedBox(height: 16),
        _sectionTitle(theme, '底池赔率'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _potController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '当前底池',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _toCallController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '需跟注',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _potOddsCard(theme),
        const SizedBox(height: 32),
      ],
    );
  }

  void _clearAll() {
    setState(() {
      for (var i = 0; i < 2; i++) {
        _heroHole[i] = null;
      }
      for (var i = 0; i < 5; i++) {
        _board[i] = null;
      }
      _result = null;
    });
  }

  Widget _resultCard(ThemeData theme, EquityResult r) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('胜率模拟（${r.trials} 次）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                _metric(theme, '胜', r.win, Colors.green.shade700),
                _metric(theme, '平', r.tie, Colors.orange.shade700),
                _metric(theme, '负', r.lose, Colors.red.shade700),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Row(
                children: [
                  _bar(r.win, Colors.green.shade600),
                  _bar(r.tie, Colors.orange.shade400),
                  _bar(r.lose.clamp(0.0, 1.0), Colors.red.shade400),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(double fraction, Color color) => Expanded(
        flex: (fraction * 1000).round().clamp(0, 1000),
        child: Container(height: 8, color: color),
      );

  Widget _metric(ThemeData theme, String label, double v, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Text(
        '$label ${(v * 100).toStringAsFixed(1)}%',
        style: theme.textTheme.titleMedium
            ?.copyWith(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _outsCard(ThemeData theme) {
    final outs = Odds.outs(
      heroHole: _heroHole.cast<poker.Card>(),
      board: _boardCards,
    );
    final oneStreet = Odds.ruleOfTwoFour(outs);
    final twoStreets = _boardCount == 3 ? Odds.ruleOfTwoFour(outs, twoStreets: true) : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('听牌（outs）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('$outs 张成牌外牌', style: theme.textTheme.bodyMedium),
            Text(
              '二四法则：下一条街约 ${(oneStreet * 100).toStringAsFixed(0)}%'
              '${twoStreets != null ? '；到河牌约 ${(twoStreets * 100).toStringAsFixed(0)}%' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _potOddsCard(ThemeData theme) {
    final pot = int.tryParse(_potController.text) ?? 0;
    final toCall = int.tryParse(_toCallController.text) ?? 0;
    if (toCall <= 0) {
      return Text('输入需跟注金额后显示所需胜率', style: theme.textTheme.bodySmall);
    }
    final need = Odds.potOdds(pot: pot, toCall: toCall);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '底池赔率：$pot : $toCall\n'
          '跟注不亏需要的胜率 ≥ ${(need * 100).toStringAsFixed(1)}%',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: theme.textTheme.titleSmall),
      );

  void _pickCard(void Function(poker.Card?) onPicked, {poker.Card? current}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CardPickerSheet(
        used: _usedCards..remove(current),
        onPicked: (c) {
          Navigator.of(context).pop();
          onPicked(c);
        },
      ),
    );
  }
}

/// 单个牌位：可点选牌。
class _CardSlot extends StatelessWidget {
  const _CardSlot({required this.card, required this.onTap});

  final poker.Card? card;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = card;
    final red = c != null &&
        (c.suit == poker.Suit.hearts || c.suit == poker.Suit.diamonds);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: onTap == null
              ? Colors.black12
              : c == null
                  ? Colors.green.shade50
                  : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: onTap == null ? Colors.black12 : Colors.black26,
            style: c == null && onTap != null
                ? BorderStyle.solid
                : BorderStyle.solid,
          ),
        ),
        alignment: Alignment.center,
        child: c == null
            ? Icon(
                onTap == null ? Icons.block : Icons.add,
                size: 16,
                color: Colors.black26,
              )
            : Text(
                c.pretty,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: red ? Colors.red.shade700 : Colors.black87,
                ),
              ),
      ),
    );
  }
}

/// 52 张牌选择面板。
class _CardPickerSheet extends StatelessWidget {
  const _CardPickerSheet({required this.used, required this.onPicked});

  final Set<poker.Card> used;
  final void Function(poker.Card?) onPicked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('选择一张牌', style: theme.textTheme.titleMedium),
              TextButton(
                onPressed: () => onPicked(null),
                child: const Text('清除'),
              ),
            ],
          ),
          for (final suit in poker.Suit.values) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final rank in poker.Rank.values.reversed)
                  _pickTile(poker.Card(rank, suit)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pickTile(poker.Card c) {
    final disabled = used.contains(c);
    final red =
        c.suit == poker.Suit.hearts || c.suit == poker.Suit.diamonds;
    return GestureDetector(
      onTap: disabled ? null : () => onPicked(c),
      child: Container(
        width: 44,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: disabled ? Colors.black12 : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black26),
        ),
        child: Text(
          c.pretty,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: disabled
                ? Colors.black26
                : red
                    ? Colors.red.shade700
                    : Colors.black87,
          ),
        ),
      ),
    );
  }
}
