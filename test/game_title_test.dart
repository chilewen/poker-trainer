import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/data/table_session.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/presentation/game_screen.dart';
import 'package:poker_trainer/features/game/presentation/table_controller.dart';

/// 对局页顶部导航栏：桌名（不带盲注级别）+ 第几手 + 本手输赢。
///
/// 盲注级别在大厅卡片和存档里已经有，导航栏这一行留给「打到第几手、
/// 本手赢了多少」——抬头就能看见这一手是赚是亏。
void main() {
  const config =
      GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

  Future<TableController> pumpTable(WidgetTester tester) async {
    final table = TableController(random: Random(3), aiThinkTime: Duration.zero);
    await tester.pumpWidget(ProviderScope(
      overrides: [tableProvider.overrideWith((ref) => table)],
      child: MaterialApp(
        // 点击换成水波纹，免得依赖 Material 3 的 ink_sparkle 着色器。
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const GameScreen(autoStart: false),
      ),
    ));
    table.startRealTable(name: '实战 单挑', config: config, playerCount: 2);
    await tester.pump();
    return table;
  }

  testWidgets('导航栏：桌名不带盲注，本手输赢跟着筹码走', (tester) async {
    // 手机宽度也要放得下：标题过长用省略号收尾，不能溢出报错。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table = await pumpTable(tester);

    expect(find.textContaining('实战 单挑 · 第 1 手'), findsOneWidget);
    expect(find.textContaining('50/100'), findsNothing,
        reason: '导航栏里不再显示盲注级别');

    // 单挑里英雄坐按钮 = 小盲：一开局就投了 50，先显示 -50。
    expect(table.heroHandNet, -50);
    expect(find.text('本手 -50'), findsOneWidget);
    // 本局累计也一起显示（还没打完任何一手，本局 = 本手）。
    expect(find.text('本局 -50'), findsOneWidget);

    // 两个数字要和桌名挤在同一行（不再单独占一条），顺序是桌名在前。
    final titleRect = tester.getRect(find.textContaining('实战 单挑 · 第 1 手'));
    final handRect = tester.getRect(find.text('本手 -50'));
    final sessRect = tester.getRect(find.text('本局 -50'));
    expect((handRect.center.dy - titleRect.center.dy).abs(), lessThan(2),
        reason: '本手要和标题同一行');
    expect((sessRect.center.dy - titleRect.center.dy).abs(), lessThan(2),
        reason: '本局要和标题同一行');
    expect(handRect.left, greaterThanOrEqualTo(titleRect.right),
        reason: '数字排在桌名右边');
    expect(sessRect.left, greaterThan(handRect.right),
        reason: '本局排在本手右边');
    expect(tester.takeException(), isNull, reason: '这一行不能溢出');

    // 弃牌走完这一手：数字换成最终结果，和结算条里的「本手输赢」一致。
    table.heroAct(ActionType.fold);
    await tester.pump();
    expect(table.engine.handOver, isTrue);
    expect(find.text('本手 -50'), findsOneWidget);
    expect(find.text('本局 -50'), findsOneWidget);
    // 结算期间手数停在刚打完的那一手（下一手发牌才 +1），
    // 和结算条里的「本手亏损」对得上。
    expect(find.textContaining('第 1 手'), findsOneWidget,
        reason: '结算时手数还停在刚打完的这一手');
    expect(find.text('本手 -50'), findsOneWidget);
  });

  testWidgets('续局后标题仍然不带盲注', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table =
        TableController(random: Random(5), aiThinkTime: Duration.zero);
    await tester.pumpWidget(ProviderScope(
      overrides: [tableProvider.overrideWith((ref) => table)],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const GameScreen(autoStart: false),
      ),
    ));

    // 冷启动「继续上局」：以前这里直接拿存档里的完整 label 当桌名，
    // 标题就又变成「实战 9人桌 · 50/100 · 第 1 手」。
    table.savedSession = TableSession(
      id: 'table-1',
      label: '实战 9人桌 · 50/100',
      name: '实战 9人桌',
      config: config,
      styles: [AiStyle.tightAggressive.name, AiStyle.loosePassive.name],
      seats: const [
        SessionSeat(id: 'hero', name: '我', stack: 10000),
        SessionSeat(id: 'ai0', name: '紧凶·AI1', stack: 10000),
        SessionSeat(id: 'ai1', name: '松被动·AI2', stack: 10000),
      ],
      buttonIndex: 0,
      handsPlayed: 0,
      savedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    expect(table.resumeSession(), isTrue);
    // 恢复后 AI 可能先行动：把这一手走完，别给测试留等待计时器。
    var guard = 0;
    while (!table.engine.handOver && guard++ < 60) {
      if (table.heroToAct) table.heroAct(ActionType.fold);
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(find.textContaining('实战 9人桌 · 第 1 手'), findsOneWidget);
    expect(find.textContaining('50/100'), findsNothing);
  });

  testWidgets('窄屏 320：两个数字和桌名挤在同一行也不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table = await pumpTable(tester);
    // 赢一大把的极端数字：本手 +12800（缩写成 1.3万）、本局 -34500。
    expect(find.text('本手 -50'), findsOneWidget);
    expect(find.text('本局 -50'), findsOneWidget);

    final titleRect =
        tester.getRect(find.textContaining('实战 单挑 · 第 1 手'));
    final handRect = tester.getRect(find.text('本手 -50'));
    expect(handRect.left, greaterThanOrEqualTo(titleRect.right),
        reason: '窄屏上也要把两个数字摆在桌名右边');
    expect(tester.takeException(), isNull, reason: '窄屏这一行不能溢出');
    expect(table.heroHandNet, -50);
  });
}
