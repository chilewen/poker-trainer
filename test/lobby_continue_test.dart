import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/data/table_session_store.dart';
import 'package:poker_trainer/features/game/presentation/game_screen.dart';
import 'package:poker_trainer/features/game/presentation/lobby_screen.dart';
import 'package:poker_trainer/features/game/presentation/table_controller.dart';

/// 大厅的「继续上局」入口：冷启动后看得见、点得进去。
///
/// 存档分两种：牌局打到一半退出（回来接着打这一手）和停在两手之间
/// （回来发下一手）；大厅文案要把这两种区别讲清楚。
void main() {
  const config =
      GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

  /// 开一桌、随便打两下，返回落好盘的那张桌。
  Future<TableController> playThenQuit(Directory dir) async {
    final live = TableController(
      sessionStore: TableSessionStore(File('${dir.path}/session.json')),
      random: Random(5),
      aiThinkTime: Duration.zero,
    );
    live.startRealTable(
        label: '实战 单挑 · 50/100', config: config, playerCount: 2);
    var steps = 0;
    while (!live.engine.handOver && steps++ < 2) {
      if (live.heroToAct) live.heroAct(ActionType.call);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return live;
  }

  /// 冷启动：内存里没有桌，只能读磁盘。
  Future<TableController> coldStart(Directory dir) async {
    final cold = TableController(
      sessionStore: TableSessionStore(File('${dir.path}/session.json')),
      random: Random(5),
      aiThinkTime: Duration.zero,
    );
    await cold.loadSession();
    return cold;
  }

  Future<void> pumpLobby(WidgetTester tester, TableController table) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [tableProvider.overrideWith((ref) => table)],
      child: MaterialApp(
        // 只测大厅：点击换成水波纹，免得依赖 Material 3 的 ink_sparkle 着色器。
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const Scaffold(body: LobbyScreen()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('大厅：打到一半退出，冷启动是「继续上局 · 这手进行中」', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pt_lobby_mid');
    addTearDown(() => dir.deleteSync(recursive: true));
    late TableController cold;
    await tester.runAsync(() async {
      final live = await playThenQuit(dir);
      expect(live.engine.handOver, isFalse, reason: '这一手要停在半截');
      cold = await coldStart(dir);
    });
    expect(cold.savedSession!.handInProgress, isTrue);

    await pumpLobby(tester, cold);
    expect(find.text('继续上局'), findsOneWidget);
    expect(find.textContaining('第 1 手进行中'), findsOneWidget);
  });

  testWidgets('大厅：停在两手之间，冷启动是「继续上局 · 下一手 + 我的筹码」', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pt_lobby_between');
    addTearDown(() => dir.deleteSync(recursive: true));
    late TableController cold;
    await tester.runAsync(() async {
      final live = await playThenQuit(dir);
      live.engine.handOver = true; // 这一手已结算 = 存档停在两手之间
      await live.persistSession();
      cold = await coldStart(dir);
    });
    expect(cold.savedSession!.handInProgress, isFalse);

    await pumpLobby(tester, cold);
    expect(find.text('继续上局'), findsOneWidget);
    expect(find.textContaining('第 1 手'), findsOneWidget);
    expect(find.textContaining('我的筹码'), findsOneWidget);
  });

  testWidgets('冷启动点「继续上局」能直接坐回牌桌', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pt_lobby_enter');
    addTearDown(() => dir.deleteSync(recursive: true));
    late TableController cold;
    await tester.runAsync(() async {
      await playThenQuit(dir);
      cold = await coldStart(dir);
    });

    await pumpLobby(tester, cold);
    await tester.tap(find.text('继续上局'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(GameScreen), findsOneWidget, reason: '点一下就该坐回牌桌');
    expect(cold.engine.handOver, isFalse, reason: '坐回去就能接着打');
    expect(cold.sessionNeedsRestore, isFalse, reason: '内存里的桌已经是存档那张');
  });
}
