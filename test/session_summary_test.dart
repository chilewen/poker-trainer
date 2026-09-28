import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/card.dart' as poker;
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/hand_history.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/session_summary.dart';
import 'package:poker_trainer/features/game/presentation/game_screen.dart';
import 'package:poker_trainer/features/game/presentation/session_summary_screen.dart';
import 'package:poker_trainer/features/game/presentation/table_controller.dart';

const _config =
    GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

/// 对局总结页：一局收手之后，这一局打了多久、赚亏多少、补码用了几次、
/// 为什么结束，一屏看得清；最近几手还能直接点进逐手复盘。
void main() {
  HandHistory hand(String id, int heroNet) {
    final h = HandHistory(
      id: id,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      playerNames: const {'hero': '我', 'ai0': '紧凶·AI1'},
      startingStacks: const {'hero': 10000, 'ai0': 10000},
      holeCards: {
        'hero': 'Ah Kd'.split(' ').map(poker.Card.parse).toList(),
        'ai0': '2c 3d'.split(' ').map(poker.Card.parse).toList(),
      },
      buttonIndex: 0,
      smallBlind: 50,
      bigBlind: 100,
    );
    h.netResult['hero'] = heroNet;
    h.netResult['ai0'] = -heroNet;
    return h;
  }

  SessionSummary sample({
    int handsPlayed = 11,
    int handsWon = 5,
    int handsLost = 6,
    int handsTied = 0,
    int heroNet = 3400,
    int bestHandNet = 9000,
    int worstHandNet = -4200,
    int rebuys = 2,
    String endReason = '主动结束',
    List<HandHistory>? hands,
  }) =>
      SessionSummary(
        tableName: '实战 6人桌',
        label: '实战 6人桌 · 50/100',
        handsPlayed: handsPlayed,
        handsWon: handsWon,
        handsLost: handsLost,
        handsTied: handsTied,
        heroNet: heroNet,
        bestHandNet: bestHandNet,
        worstHandNet: worstHandNet,
        rebuys: rebuys,
        maxRebuys: 3,
        duration: const Duration(minutes: 42, seconds: 5),
        endReason: endReason,
        hands:
            hands ?? [hand('h3', -4200), hand('h2', 9000), hand('h1', 300)],
      );

  Future<void> pump(WidgetTester tester, SessionSummary summary,
      {VoidCallback? onPlayAgain, VoidCallback? onLeave}) async {
    // 总结页是整屏列表：测试窗口给高一点，免得下面的按钮还没建出来。
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      // 点击换成水波纹，免得依赖 Material 3 的 ink_sparkle 着色器。
      theme: ThemeData(splashFactory: InkRipple.splashFactory),
      home: SessionSummaryScreen(
        summary: summary,
        onPlayAgain: onPlayAgain ?? () {},
        onLeave: onLeave ?? () {},
      ),
    ));
    await tester.pump();
  }

  testWidgets('总结页：本局账目、补码、结束原因一屏看得见', (tester) async {
    await pump(tester, sample());

    expect(find.text('对局总结'), findsOneWidget);
    expect(find.text('实战 6人桌 · 50/100'), findsOneWidget);
    // 顶部大字：本局净输赢。
    expect(find.text('+3400'), findsOneWidget);
    expect(find.text('这局是赢着走的'), findsOneWidget);
    // 四格事实。
    expect(find.text('11 手'), findsOneWidget);
    expect(find.text('42 分 5 秒'), findsOneWidget);
    expect(find.text('2/3 次'), findsOneWidget);
    expect(find.text('主动结束'), findsOneWidget);
    // 拆细。
    expect(find.text('5 手'), findsOneWidget);
    expect(find.text('6 手'), findsOneWidget);
    // 这两个数在明细里也会出现（最佳/最惨那两手），所以只要求「有」。
    expect(find.text('+9000'), findsWidgets);
    expect(find.text('-4200'), findsWidgets);
    // 明细：最近几手 + 复盘入口。
    expect(find.text('最近几手'), findsOneWidget);
    expect(find.text('逐手复盘'), findsOneWidget);
    expect(find.text('A♥ K♦'), findsWidgets, reason: '明细里带着英雄底牌');
    // 最赚/最惨那两手要标出来，方便一眼找到该复盘哪一手。
    expect(find.text('最佳'), findsOneWidget);
    expect(find.text('最惨'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('总结页：两个出口各按各的回调走', (tester) async {
    var again = 0;
    var left = 0;
    await pump(tester, sample(),
        onPlayAgain: () => again++, onLeave: () => left++);

    await tester.tap(find.text('再来一局'));
    expect(again, 1);
    await tester.tap(find.text('返回大厅'));
    expect(left, 1);
  });

  testWidgets('总结页：补码用尽、没打完这两种收尾也说得清楚', (tester) async {
    // 补码用尽：补码那一格要报满，结束原因是输光。
    await pump(tester, sample(rebuys: 3, endReason: '筹码输光，补码次数已用完'));
    expect(find.text('3/3 次'), findsOneWidget);
    expect(find.text('筹码输光，补码次数已用完'), findsOneWidget);

    // 一手没打完就收手：别硬说赢了还是输了，也别列空明细。
    await pump(tester, sample(
      handsPlayed: 0,
      handsWon: 0,
      handsLost: 0,
      heroNet: 0,
      bestHandNet: 0,
      worstHandNet: 0,
      endReason: '主动结束',
      hands: const [],
    ));
    expect(find.text('没打完就收了'), findsOneWidget);
    expect(find.text('最近几手'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ---------- 对局页与总结页的联动 ----------

  /// 起一张真的牌桌（不落盘：这一节只关心页面怎么切）。
  Future<TableController> pumpTable(WidgetTester tester) async {
    // 总结页是整屏列表，窗口给高一点，免得下面的按钮还没建出来。
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final table =
        TableController(random: Random(3), aiThinkTime: Duration.zero);
    addTearDown(table.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [tableProvider.overrideWith((ref) => table)],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: const GameScreen(autoStart: false),
      ),
    ));
    table.startRealTable(name: '实战 单挑', config: _config, playerCount: 2);
    await tester.pump();
    return table;
  }

  /// 走几帧把过场动画走完。
  ///
  /// 不用 pumpAndSettle：AI 的思考计时器是零延迟的，一路接一路地排，
  /// 它会一直等不到「没有待办」，直接把用例挂在那儿。
  Future<void> advance(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('对局结束：牌桌整页换成总结，点「再来一局」回到新的一局', (tester) async {
    final table = await pumpTable(tester);
    expect(find.byType(SessionSummaryScreen), findsNothing,
        reason: '还在打的时候不该有总结页');

    // 弃牌走完这一手（-50），然后主动收手。
    table.heroAct(ActionType.fold);
    await tester.pump();
    expect(table.handsPlayed, 1);
    table.endSession(reason: '主动结束');
    await tester.pump();

    expect(find.byType(SessionSummaryScreen), findsOneWidget,
        reason: '收局之后牌桌整页换成总结');
    expect(find.text('对局总结'), findsOneWidget);
    expect(find.text('主动结束'), findsOneWidget);
    // 同一个数在大字、每手均盈亏、单手最惨、明细里都会出现，只要求「有」。
    expect(find.text('-50'), findsWidgets, reason: '本局净输赢对得上');

    // 再来一局：回到牌桌，本局计数归零。
    await tester.tap(find.text('再来一局'));
    await advance(tester);
    expect(find.byType(SessionSummaryScreen), findsNothing);
    expect(table.sessionOver, isFalse);
    expect(table.handsPlayed, 0);
    expect(table.rebuys, 0);
  });

  testWidgets('牌桌「结束对局」要先确认：取消就接着打，确认才收局', (tester) async {
    final table = await pumpTable(tester);

    await tester.tap(find.byTooltip('结束对局'));
    await advance(tester);
    expect(find.text('结束本局？'), findsOneWidget, reason: '不能点一下就收局');

    await tester.tap(find.text('继续打'));
    await advance(tester);
    expect(table.sessionOver, isFalse);
    expect(find.byType(SessionSummaryScreen), findsNothing);
    expect(find.text('结束本局？'), findsNothing);

    await tester.tap(find.byTooltip('结束对局'));
    await advance(tester);
    await tester.tap(find.text('结束'));
    await advance(tester);
    expect(table.sessionOver, isTrue);
    expect(find.byType(SessionSummaryScreen), findsOneWidget);
    expect(find.text('主动结束'), findsOneWidget);
  });
}
