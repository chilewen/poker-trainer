import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart';
import '../domain/ai_player.dart';
import 'game_screen.dart';
import 'table_setup_screen.dart';

/// 大厅页：新建对局入口（实战 / 场景 / 复盘 / 工具）。
class LobbyScreen extends ConsumerWidget {
  const LobbyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
              child: _LobbyCard(
                title: '实战 · 玩',
                subtitle: 'AI陪练 · 动态对手',
                icon: Icons.sports_mma,
                colors: [const Color(0xFF0B6B3A), const Color(0xFF12B76A)],
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TableSetupScreen(),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _LobbyCard(
                title: '场景 · 练',
                subtitle: '单挑 · 松浪 · 紧凶 · 松凶',
                icon: Icons.gps_fixed,
                colors: [const Color(0xFF0B5394), const Color(0xFF14B8D4)],
                onTap: () => _pickScenario(context, ref),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _LobbyCard(
          title: '策略 · 学',
          subtitle: '手牌复盘 · 逐动作回放 · 错局重玩',
          icon: Icons.school_outlined,
          colors: [const Color(0xFF4A3A8C), const Color(0xFF7C63C8)],
          actionLabel: '极速复盘',
          onTap: () => ref.read(tabIndexProvider.notifier).state = 1,
        ),
        const SizedBox(height: 12),
        Text('辅助工具', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ToolTile(
                title: '概率速算',
                subtitle: '胜率 · outs · 底池赔率',
                icon: Icons.percent,
                color: const Color(0xFF0E7C86),
                onTap: () => ref.read(tabIndexProvider.notifier).state = 2,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ToolTile(
                title: '数据统计',
                subtitle: '盈亏曲线 · VPIP · AF',
                icon: Icons.insights,
                color: const Color(0xFF8A5A00),
                onTap: () => ref.read(tabIndexProvider.notifier).state = 3,
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _openTable(BuildContext context, {required bool autoStart}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameScreen(autoStart: autoStart),
      ),
    );
  }

  void _pickScenario(BuildContext context, WidgetRef ref) {
    const scenarios = [
      ('单挑 · 紧凶', [AiStyle.tightAggressive]),
      ('单挑 · 松跟', [AiStyle.loosePassive]),
      ('单挑 · 松凶', [AiStyle.looseAggressive]),
      ('松浪混战 · 6人桌', [
        AiStyle.loosePassive,
        AiStyle.loosePassive,
        AiStyle.loosePassive,
        AiStyle.loosePassive,
        AiStyle.loosePassive,
      ]),
      ('紧凶对抗 · 6人桌', [
        AiStyle.tightAggressive,
        AiStyle.tightAggressive,
        AiStyle.tightAggressive,
        AiStyle.tightAggressive,
        AiStyle.tightAggressive,
      ]),
      ('松凶乱斗 · 6人桌', [
        AiStyle.looseAggressive,
        AiStyle.looseAggressive,
        AiStyle.looseAggressive,
        AiStyle.looseAggressive,
        AiStyle.looseAggressive,
      ]),
      ('混合对手 · 9人桌', [
        AiStyle.tightAggressive,
        AiStyle.loosePassive,
        AiStyle.looseAggressive,
        AiStyle.tightAggressive,
        AiStyle.loosePassive,
        AiStyle.looseAggressive,
        AiStyle.tightAggressive,
        AiStyle.loosePassive,
      ]),
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, styles) in scenarios)
              ListTile(
                leading: const Icon(Icons.gps_fixed),
                title: Text(label),
                onTap: () {
                  ref.read(tableProvider).startScenario(label, styles);
                  Navigator.of(sheetContext).pop();
                  _openTable(context, autoStart: false);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 渐变入口卡片。
class _LobbyCard extends StatelessWidget {
  const _LobbyCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.actionLabel,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          height: 150,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12)),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (actionLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('$actionLabel ›',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    )
                  else
                    const CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.white24,
                      child: Icon(Icons.chevron_right,
                          color: Colors.white, size: 18),
                    ),
                  Icon(icon, color: Colors.white54, size: 40),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部工具小卡片。
class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 8),
              Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: onTap,
                  style: FilledButton.styleFrom(
                    minimumSize: Size.zero,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('打开 ›'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
