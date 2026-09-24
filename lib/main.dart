import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/game/presentation/lobby_screen.dart';
import 'features/game/presentation/game_screen.dart';
import 'features/history/data/hand_history_store.dart';
import 'features/odds/presentation/odds_screen.dart';
import 'features/replay/presentation/replay_screen.dart';
import 'features/stats/presentation/stats_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = HandHistoryStore();
  await store.init();
  runApp(
    ProviderScope(
      overrides: [historyStoreProvider.overrideWithValue(store)],
      child: const PokerTrainerApp(),
    ),
  );
}

/// 底部导航当前页索引；复盘页「重玩本局」会切回对局页。
final tabIndexProvider = StateProvider<int>((ref) => 0);

class PokerTrainerApp extends StatelessWidget {
  const PokerTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Poker Trainer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

/// 主框架：大厅（新建对局）/ 复盘 / 概率工具 / 统计。
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _tabs = [
    (icon: Icons.play_circle_outline, label: '对局'),
    (icon: Icons.history, label: '复盘'),
    (icon: Icons.percent, label: '概率'),
    (icon: Icons.insights, label: '统计'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_tabs[index].label)),
      body: SafeArea(child: _pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(tabIndexProvider.notifier).state = i,
        destinations: [
          for (final t in _tabs)
            NavigationDestination(icon: Icon(t.icon), label: t.label),
        ],
      ),
    );
  }
}

const _pages = [
  LobbyScreen(),
  ReplayScreen(),
  OddsScreen(),
  StatsScreen(),
];
