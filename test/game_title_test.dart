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

/// 对局页顶部导航栏：第几手 + 本手输赢 + 本局输赢。
///
/// 桌名和盲注级别在大厅卡片、存档和总结页里都有，导航栏这一行只留「打到
/// 第几手、这一手赚了还是亏了」——抬头就能看见。
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

  testWidgets('导航栏：不显示桌名与盲注，本手输赢跟着筹码走', (tester) async {
    // 手机宽度也要放得下：标题过长用省略号收尾，不能溢出报错。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table = await pumpTable(tester);

    expect(find.text('第 1 手'), findsOneWidget);
    expect(find.textContaining('实战 单挑'), findsNothing,
        reason: '导航栏里不再显示桌名');
    expect(find.textContaining('50/100'), findsNothing,
        reason: '导航栏里也不显示盲注级别');

    // 单挑里英雄坐按钮 = 小盲：一开局就投了 50，先显示 -50。
    expect(table.heroHandNet, -50);
    expect(find.text('本手 -50'), findsOneWidget);
    // 本局累计也一起显示（还没打完任何一手，本局 = 本手）。
    expect(find.text('本局 -50'), findsOneWidget);

    // 两个数字要和手数挤在同一行（不再单独占一条），顺序是手数在前。
    final titleRect = tester.getRect(find.text('第 1 手'));
    final handRect = tester.getRect(find.text('本手 -50'));
    final sessRect = tester.getRect(find.text('本局 -50'));
    expect((handRect.center.dy - titleRect.center.dy).abs(), lessThan(2),
        reason: '本手要和手数同一行');
    expect((sessRect.center.dy - titleRect.center.dy).abs(), lessThan(2),
        reason: '本局要和手数同一行');
    expect(handRect.left, greaterThanOrEqualTo(titleRect.right),
        reason: '数字排在手数右边');
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

  testWidgets('续局后标题仍然不带桌名、不带盲注', (tester) async {
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
    // 标题就又变成「实战 9人桌 · 50/100 · 第 1 手」。现在标题只有手数。
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

    expect(find.text('第 1 手'), findsOneWidget);
    expect(find.textContaining('实战 9人桌'), findsNothing,
        reason: '续局也不把桌名带到导航栏');
    expect(find.textContaining('50/100'), findsNothing);
  });

  testWidgets('窄屏 320：手数和两个数字挤在同一行也不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table = await pumpTable(tester);
    // 赢一大把的极端数字：本手 +12800（缩写成 1.3万）、本局 -34500。
    expect(find.text('本手 -50'), findsOneWidget);
    expect(find.text('本局 -50'), findsOneWidget);

    final titleRect = tester.getRect(find.text('第 1 手'));
    final handRect = tester.getRect(find.text('本手 -50'));
    expect(handRect.left, greaterThanOrEqualTo(titleRect.right),
        reason: '窄屏上也要把两个数字摆在手数右边');
    expect(tester.takeException(), isNull, reason: '窄屏这一行不能溢出');
    expect(table.heroHandNet, -50);
  });

  testWidgets('补充筹码条：底栏随内容长高，不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table =
        TableController(random: Random(7), aiThinkTime: Duration.zero);
    await tester.pumpWidget(ProviderScope(
      overrides: [tableProvider.overrideWith((ref) => table)],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const GameScreen(autoStart: false),
      ),
    ));

    // 续一张英雄已经输光（筹码不足一个大盲）的桌：一恢复就停在补码那一步。
    table.savedSession = TableSession(
      id: 'table-rebuy',
      label: '实战 单挑 · 50/100',
      name: '实战 单挑',
      config: config,
      styles: [AiStyle.tightAggressive.name],
      seats: const [
        SessionSeat(id: 'hero', name: '我', stack: 40),
        SessionSeat(id: 'ai0', name: '紧凶·AI1', stack: 10000),
      ],
      buttonIndex: 0,
      handsPlayed: 5,
      heroNet: -9960,
      rebuys: 2,
      savedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    expect(table.resumeSession(), isTrue);
    await tester.pump();

    expect(table.heroBusted, isTrue);
    // 补码条比普通底栏多一行「本局已补码 x/3」——以前底栏高度钉死 124，
    // 这一屏会被顶穿报 RenderFlex overflowed on the bottom（实测 9~17 像素）。
    expect(find.textContaining('补充筹码'), findsOneWidget);
    expect(find.textContaining('本局已补码 2/3'), findsOneWidget);
    // 「本手亏损」不再重复——标题栏右上角已经有本手输赢了（这里是「本局」）。
    expect(find.textContaining('本手亏损'), findsNothing,
        reason: '本手输赢标题栏已经有了，底栏别再说一遍');
    expect(find.text('本局 -9960'), findsOneWidget);
    // 还没发牌时补一句为什么停下来。
    expect(find.text('筹码不够一个大盲，先决定补不补'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '补码底栏不能溢出');
    // 底栏确实长高了：按钮底边仍然留在屏幕里，没被顶到屏幕外。
    expect(tester.getRect(find.textContaining('补充筹码')).bottom,
        lessThanOrEqualTo(844));
  });

  testWidgets('补充筹码条：刚打完一手也不重复本手亏损', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final table =
        TableController(random: Random(1), aiThinkTime: Duration.zero);
    await tester.pumpWidget(ProviderScope(
      overrides: [tableProvider.overrideWith((ref) => table)],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const GameScreen(autoStart: false),
      ),
    ));
    // 短筹码单挑：每手都推全下，几手就把自己打光，停在补码那一步。
    table.startRealTable(
        name: '实战 单挑',
        config: const GameConfig(
            startingStack: 400, smallBlind: 50, bigBlind: 100),
        playerCount: 2);
    await tester.pump();

    for (var hand = 0; hand < 12 && !table.heroBusted; hand++) {
      var guard = 0;
      while (!table.handStopped && guard++ < 200) {
        if (table.heroToAct) {
          LegalAction? raise;
          for (final a in table.heroLegalActions) {
            if (a.type == ActionType.raise || a.type == ActionType.bet) {
              raise = a;
            }
          }
          table.heroAct(raise?.type ?? ActionType.fold,
              amountTo: raise?.maxAmount);
        }
        await tester.pump(const Duration(milliseconds: 1));
      }
      await tester.pump();
      if (table.handStopped && !table.heroBusted) {
        table.startHand();
        await tester.pump();
      }
    }

    expect(table.heroBusted, isTrue, reason: '短筹码全下几手就该停下来补码');
    // 刚打完一手：标题栏有「本手 -X」，底栏只留「筹码耗尽 + 已补码次数」。
    expect(find.textContaining('本手亏损'), findsNothing,
        reason: '本手输赢标题栏已经有了，底栏别再说一遍');
    expect(find.text('筹码耗尽'), findsOneWidget);
    expect(find.textContaining('补充筹码'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '补码底栏不能溢出');
  });

  testWidgets('座位头像：类型用两个字，名牌还是 AI1', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpTable(tester);

    // 单挑桌的 AI 是紧凶：头像上是完整类型，而不是以前那个看不出所以然的
    // 「紧」（松被动 / 松凶都会剩一个「松」）。名牌照旧是 AI1。
    expect(find.text('紧凶'), findsOneWidget, reason: '头像是两个字的风格');
    expect(find.text('紧'), findsNothing, reason: '一个字看不出类型，不用了');
    expect(find.text('AI1'), findsOneWidget, reason: '名牌照旧');
  });
}
