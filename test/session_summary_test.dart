import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/engine/card.dart' as poker;
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/hand_history.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/hero_stats.dart';
import 'package:poker_trainer/features/game/domain/session_summary.dart';
import 'package:poker_trainer/features/game/presentation/game_screen.dart';
import 'package:poker_trainer/features/game/presentation/session_summary_screen.dart';
import 'package:poker_trainer/features/game/presentation/table_controller.dart';

const _config = GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100);

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

  ActionRecord rec(
    String id,
    ActionType type,
    int potAfter, {
    Street street = Street.preflop,
    int amount = 0,
  }) =>
      ActionRecord(
        street: street,
        actorId: id,
        type: type,
        amount: amount,
        potAfter: potAfter,
      );

  /// 一手打错的牌：单挑坐庄，翻牌拿 76s 在中不到的牌面上跟了一个重注
  /// ——「跟注没有赔率」。总结页该给它挂 ⚠ 并按类型归并。
  HandHistory mistakeHand() {
    final h = HandHistory(
      id: 'm1',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      playerNames: const {'hero': '我', 'ai0': '紧凶·AI1'},
      startingStacks: const {'hero': 10000, 'ai0': 10000},
      holeCards: {
        'hero': '7h 6h'.split(' ').map(poker.Card.parse).toList(),
        'ai0': '2c 3d'.split(' ').map(poker.Card.parse).toList(),
      },
      buttonIndex: 0,
      smallBlind: 50,
      bigBlind: 100,
    );
    h.board.addAll('Kh Qd 9c'.split(' ').map(poker.Card.parse));
    h.actions.addAll([
      rec('hero', ActionType.bet, 50),
      rec('ai0', ActionType.bet, 100),
      rec('hero', ActionType.call, 200),
      rec('ai0', ActionType.check, 200),
      rec('ai0', ActionType.bet, 400, street: Street.flop, amount: 200),
      rec('hero', ActionType.call, 600, street: Street.flop),
    ]);
    h.netResult['hero'] = -250;
    h.netResult['ai0'] = 250;
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
        heroStats: HeroStats.from(const [], heroId: 'hero'),
        hands: hands ?? [hand('h3', -4200), hand('h2', 9000), hand('h1', 300)],
      );

  Future<void> pump(
    WidgetTester tester,
    SessionSummary summary, {
    VoidCallback? onPlayAgain,
    VoidCallback? onLeave,
  }) async {
    // 总结页是整屏列表：测试窗口给高一点，免得下面的按钮还没建出来。
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        // 点击换成水波纹，免得依赖 Material 3 的 ink_sparkle 着色器。
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: SessionSummaryScreen(
          summary: summary,
          onPlayAgain: onPlayAgain ?? () {},
          onLeave: onLeave ?? () {},
        ),
      ),
    );
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

  testWidgets('总结页：本局打法 + 逐手复盘里能看到单手范围/胜率/底池', (tester) async {
    await pump(tester, sample());

    // 打法统计：和统计页同一口径（VPIP/PFR/3bet/AF/摊牌）。
    expect(find.text('本局打法'), findsOneWidget);
    expect(find.text('入池 VPIP'), findsOneWidget);
    expect(find.text('3bet'), findsOneWidget);
    expect(find.text('打法失误'), findsOneWidget);
    expect(find.text('没有'), findsOneWidget, reason: '造的历史没有失误');

    // 点进逐手复盘，展开第一手：单手基础数据 + 范围 + 翻前胜率 + 底池。
    await tester.tap(find.text('逐手复盘'));
    await tester.pumpAndSettle();
    expect(find.text('手牌回顾'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('起手 AKo'), findsOneWidget);
    expect(find.textContaining('翻前胜率'), findsOneWidget);
    expect(find.textContaining('翻前池'), findsOneWidget);
    expect(find.textContaining('最终池'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('总结页：打错的牌挂 ⚠，失误按类型归并', (tester) async {
    await pump(tester, sample(hands: [mistakeHand(), hand('h1', 300)]));

    expect(find.text('1 处'), findsOneWidget, reason: '汇总报失误数');
    expect(
      find.textContaining('跟注没有赔率 1'),
      findsOneWidget,
      reason: '分类归并：哪一类错了几次',
    );
    expect(find.text('⚠1'), findsOneWidget, reason: '打错的那手带标记');
    expect(find.text('庄位'), findsWidgets, reason: '每手标出英雄的位置');
    expect(tester.takeException(), isNull);
  });

  testWidgets('总结页：窄屏上打法那一块也不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: SessionSummaryScreen(
          summary: sample(),
          onPlayAgain: () {},
          onLeave: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('总结页：两个出口各按各的回调走', (tester) async {
    var again = 0;
    var left = 0;
    await pump(
      tester,
      sample(),
      onPlayAgain: () => again++,
      onLeave: () => left++,
    );

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
    await pump(
      tester,
      sample(
        handsPlayed: 0,
        handsWon: 0,
        handsLost: 0,
        heroNet: 0,
        bestHandNet: 0,
        worstHandNet: 0,
        endReason: '主动结束',
        hands: const [],
      ),
    );
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
    final table = TableController(
      random: Random(3),
      aiThinkTime: Duration.zero,
    );
    addTearDown(table.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tableProvider.overrideWith((ref) => table)],
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const GameScreen(autoStart: false),
        ),
      ),
    );
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
    expect(
      find.byType(SessionSummaryScreen),
      findsNothing,
      reason: '还在打的时候不该有总结页',
    );

    // 弃牌走完这一手（-50），然后主动收手。
    table.heroAct(ActionType.fold);
    await tester.pump();
    expect(table.handsPlayed, 1);
    table.endSession(reason: '主动结束');
    await tester.pump();

    expect(
      find.byType(SessionSummaryScreen),
      findsOneWidget,
      reason: '收局之后牌桌整页换成总结',
    );
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

  testWidgets('最后一手输光：先留在牌桌上看这手牌，按「查看本局总结」才翻页', (tester) async {
    final table = await pumpTable(tester);

    // 把 3 次补码机会用光：每次都是「输光 + 停下来等补码」。
    for (var i = 0; i < TableController.maxRebuys; i++) {
      table.engine.handOver = true;
      table.hero.stack = 0;
      table.startHand();
      table.heroRebuy();
    }
    await advance(tester);
    expect(table.canRebuy, isFalse, reason: '补码机会已经用完');

    // 推进到轮到英雄行动的那一手（单挑里偶尔 AI 先弃牌，就重新发一手）。
    var guard = 0;
    while (!table.heroToAct && guard++ < 200) {
      if (table.handStopped) {
        table.startHand();
        await tester.pump();
      } else {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }
    expect(table.heroToAct, isTrue, reason: '总有一手会轮到英雄行动');

    // 最后这一手也输光：这局到头了，但牌桌得留着。
    table.hero.stack = 0;
    table.heroAct(ActionType.fold);
    await advance(tester);

    expect(table.sessionOver, isTrue);
    expect(table.lastHand, isNotNull, reason: '最后一手的牌还在');
    expect(table.showSummary, isFalse, reason: '刚输光那一手不能一帧都不给看');
    expect(find.byType(SessionSummaryScreen), findsNothing);
    expect(find.text('筹码输光，补码次数已用完'), findsOneWidget);
    expect(find.text('本手复盘'), findsOneWidget);
    expect(find.text('查看本局总结'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '收局底栏不能溢出');

    // 本手复盘：这一手的行动路线还翻得出来。
    await tester.tap(find.text('本手复盘'));
    await tester.pumpAndSettle();
    expect(find.text('手牌回顾'), findsOneWidget);
    Navigator.of(tester.element(find.text('手牌回顾'))).pop();
    await tester.pumpAndSettle();

    // 玩家自己按了才翻去总结页。
    await tester.tap(find.text('查看本局总结'));
    await advance(tester);
    expect(find.byType(SessionSummaryScreen), findsOneWidget);
    expect(find.text('对局总结'), findsOneWidget);
  });

  testWidgets('行动路线：新开一局只列本局的牌，不把上一局的倒出来', (tester) async {
    final table = await pumpTable(tester);
    table.heroAct(ActionType.fold);
    await advance(tester);
    expect(table.history.length, 1);
    final firstHandId = table.lastHand!.id;

    // 重开一局：全量历史留着（「复盘」「数据」两个 tab 用的就是它），
    // 但牌桌右上角那个「行动路线」只该看本局。
    table.startRealTable(name: '实战 单挑', config: _config, playerCount: 2);
    expect(table.sessionHands, isEmpty, reason: '本局的账一局一清');
    expect(table.history.length, 1, reason: '全量历史不清空');
    expect(table.reviewHands.length, 1, reason: '行动路线只该有刚发的这一手');
    await advance(tester);

    await tester.tap(find.byTooltip('行动路线'));
    await tester.pumpAndSettle();
    expect(find.text('手牌回顾'), findsOneWidget);
    expect(find.byKey(ValueKey('hand-$firstHandId')), findsNothing,
        reason: '上一局的牌不该出现在这一局的复盘里');
    expect(find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith('hand-');
    }), findsOneWidget, reason: '本局只有刚发的这一手');
  });
}
