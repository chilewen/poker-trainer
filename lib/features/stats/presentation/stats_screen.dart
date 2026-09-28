import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/domain/hero_stats.dart';
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
    final stats =
        HeroStats.from(history.reversed, heroId: TableController.heroId);
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
              label: '3bet',
              value: stats.threeBet == null ? '-' : _percent(stats.threeBet!),
            ),
            _StatTile(
              label: '攻击系数 AF',
              value: stats.aggressionFactor?.toStringAsFixed(1) ?? '-',
            ),
            _StatTile(
              label: '摊牌胜率',
              value: stats.showdownWinRate == null
                  ? '-'
                  : _percent(stats.showdownWinRate!),
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
