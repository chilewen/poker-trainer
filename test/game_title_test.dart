import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
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

    // 单挑里英雄坐按钮 = 小盲：一开局就投了 50，标题先显示 -50。
    expect(table.heroHandNet, -50);
    expect(find.text('本手 -50'), findsOneWidget);

    // 弃牌走完这一手：数字换成最终结果，和结算条里的「本手输赢」一致。
    table.heroAct(ActionType.fold);
    await tester.pump();
    expect(table.engine.handOver, isTrue);
    expect(find.text('本手 -50'), findsOneWidget);
    // 结算期间手数停在刚打完的那一手（下一手发牌才 +1），
    // 和结算条里的「本手亏损」对得上。
    expect(find.textContaining('第 1 手'), findsOneWidget,
        reason: '结算时手数还停在刚打完的这一手');
    expect(find.text('本手 -50'), findsOneWidget);
  });
}
