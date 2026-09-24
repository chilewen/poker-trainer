import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'features/game/data/table_session_store.dart';
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
  // 对局存档与数据库放在同一个 App 支持目录下。
  final dir = await getApplicationSupportDirectory();
  final sessionStore =
      TableSessionStore(File('${dir.path}/table_session.json'));
  runApp(
    ProviderScope(
      overrides: [
        historyStoreProvider.overrideWithValue(store),
        sessionStoreProvider.overrideWithValue(sessionStore),
      ],
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
