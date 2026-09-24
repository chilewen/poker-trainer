import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/hand_history.dart';
import '../../../engine/types.dart';
import '../../game/presentation/game_screen.dart';
import '../../game/presentation/table_controller.dart';

/// 统计页：基于手牌历史汇总英雄的打法数据与盈亏曲线。
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(tableProvider).history;
    if (history.isEmpty) {
      return const Center(child: Text('还没有手牌记录，先去打几手吧'));
    }
    final stats = _HeroStats.from(history.reversed);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatTile(label: '总手数', value: '${stats.hands}'),
            _StatTile(
              label: '净盈亏',
              value: _signed(stats.net),
              color: stats.net >= 0 ? Colors.green.shade700 : Colors.red,
            ),
            _StatTile(label: '胜率', value: _percent(stats.winRate)),
            _StatTile(label: 'VPIP', value: _percent(stats.vpip)),
            _StatTile(label: 'PFR', value: _percent(stats.pfr)),
            _StatTile(
              label: '攻击系数 AF',
              value: stats.aggressionFactor.isInfinite
                  ? '无限'
                  : stats.aggressionFactor.toStringAsFixed(1),
            ),
            _StatTile(
              label: '摊牌胜率',
              value: stats.showdowns == 0
                  ? '-'
                  : _percent(stats.showdownWins / stats.showdowns),
            ),
            _StatTile(
              label: '每手均盈亏',
              value: _signed(stats.net ~/ stats.hands),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('盈亏曲线', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(height: 200, child: _ProfitChart(points: stats.cumulativeNet)),
      ],
    );
  }

  static String _percent(double v) => '${(v * 100).toStringAsFixed(0)}%';

  static String _signed(int v) => v >= 0 ? '+$v' : '$v';
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 按时间顺序（最早到最新）遍历手牌，汇总英雄统计数据。
class _HeroStats {
  _HeroStats();

  static const _hero = TableController.heroId;

  int hands = 0;
  int net = 0;
  int wins = 0;
  int vpipHands = 0;
  int pfrHands = 0;
  int aggressiveActs = 0; // 所有街道 bet + raise 次数
  int calls = 0;
  int showdowns = 0;
  int showdownWins = 0;
  final List<double> cumulativeNet = [];

  double get winRate => hands == 0 ? 0 : wins / hands;
  double get vpip => hands == 0 ? 0 : vpipHands / hands;
  double get pfr => hands == 0 ? 0 : pfrHands / hands;
  double get aggressionFactor =>
      calls == 0 ? double.infinity : aggressiveActs / calls;

  factory _HeroStats.from(Iterable<HandHistory> chronological) {
    final s = _HeroStats();
    for (final hand in chronological) {
      if (!hand.holeCards.containsKey(_hero)) continue;
      s.hands++;
      final result = hand.netResult[_hero] ?? 0;
      s.net += result;
      if (result > 0) s.wins++;
      s.cumulativeNet.add(s.net.toDouble());

      var putVoluntary = false;
      var raisedPreflop = false;
      for (final a in hand.actions.where((a) => a.actorId == _hero)) {
        switch (a.type) {
          case ActionType.bet:
          case ActionType.raise:
            s.aggressiveActs++;
            if (a.street == Street.preflop) {
              putVoluntary = true;
              raisedPreflop = true;
            }
          case ActionType.call:
            s.calls++;
            if (a.street == Street.preflop) putVoluntary = true;
          case ActionType.check:
          case ActionType.fold:
            break;
        }
      }
      if (putVoluntary) s.vpipHands++;
      if (raisedPreflop) s.pfrHands++;

      if (hand.actions.any((a) => a.street == Street.showdown)) {
        s.showdowns++;
        if (result > 0) s.showdownWins++;
      }
    }
    return s;
  }
}

/// 盈亏曲线：折线 + 零轴。
class _ProfitChart extends StatelessWidget {
  const _ProfitChart({required this.points});

  final List<double> points;

  @override
  Widget build(BuildContext context) {
    final positive = points.isEmpty || points.last >= 0;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: CustomPaint(
        painter: _ProfitPainter(
          points: points,
          lineColor: positive ? Colors.green.shade700 : Colors.red,
          gridColor: Theme.of(context).dividerColor,
        ),
      ),
    );
  }
}

class _ProfitPainter extends CustomPainter {
  const _ProfitPainter({
    required this.points,
    required this.lineColor,
    required this.gridColor,
  });

  final List<double> points;
  final Color lineColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 8.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;

    var minV = points.fold<double>(0, min);
    var maxV = points.fold<double>(0, max);
    if (minV == maxV) {
      minV -= 1;
      maxV += 1;
    }

    double yOf(double v) => pad + h * (1 - (v - minV) / (maxV - minV));

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(pad, yOf(0)), Offset(pad + w, yOf(0)), grid);

    if (points.length < 2) return;
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = pad + w * i / (points.length - 1);
      final y = yOf(points[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_ProfitPainter old) =>
      old.points.length != points.length ||
      (old.points.isNotEmpty && old.points.last != points.last);
}
