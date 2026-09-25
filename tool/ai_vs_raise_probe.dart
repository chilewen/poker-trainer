// 面对加注探针：dart run tool/ai_vs_raise_probe.dart
//
// 前面几个探针量的都是「面对下注」，但牌桌上最容易被玩家看穿的是另一条线：
// AI 先下注，被对手**加注**回来之后怎么办。真人不会拿一对牌被小小地抬一手
// 就交牌——那样对手用任意两张牌加注就能白拿底池（玩家原话：「我只是小小的
// 加注了一下，99 就弃牌了」）。
//
// 单挑：AI 按钮开池 250、英雄跟注；翻牌英雄过牌，AI 一开火英雄就加注
// （加到 AI 下注的 2.2 倍 / 3.5 倍两档），统计 AI 面对这个加注的应对。
// AI 自己过牌的那些手不算样本——量的是「我下注被他加注」这个局面。
// ignore_for_file: avoid_print
import 'dart:math';

import 'probe_scale.dart';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();

typedef Row = ({double fold, double call, double raise, int n});

/// 英雄加注的幅度：把 AI 的下注加到他下注额的 [mult] 倍左右
/// （2.2 倍≈最小加注，3.5 倍≈正常加注）。
Row vsRaise(
  String hole,
  String board,
  double mult, {
  Street street = Street.flop,
  AiStyle style = AiStyle.tightAggressive,
  int seeds = 400,
}) {
  var fold = 0, call = 0, raise = 0, n = 0;
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', '我');
    final ai = AiPlayer(style, random: rnd);
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('4c 5d')},
      boardOverride: cs(board),
    );
    g.apply('ai', ActionType.raise, amount: 250);
    g.apply('hero', ActionType.call);

    var guard = 0;
    var asked = false;
    var heroActed = false;
    var heroRaised = false;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = g.currentBet > p.player.streetBet;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (g.street == street && facing && heroRaised && !asked) {
          asked = true;
          n++;
          switch (d.type) {
            case ActionType.fold:
              fold++;
            case ActionType.call:
              call++;
            default:
              raise++;
          }
          break;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      // 英雄：目标街先过牌，AI 一开火就加注；其它一律过牌/跟注。
      final canRaise = legal.any((a) => a.type == ActionType.raise);
      if (g.street == street && facing && !heroRaised && canRaise) {
        heroRaised = true;
        heroActed = true;
        final la = legal.firstWhere((a) => a.type == ActionType.raise);
        final want = (g.currentBet * mult).round();
        g.apply('hero', ActionType.raise,
            amount: want.clamp(la.minAmount, la.maxAmount));
        continue;
      }
      if (g.street == street && !facing && !heroActed) {
        heroActed = true;
        g.apply('hero', ActionType.check);
        continue;
      }
      final want = facing ? ActionType.call : ActionType.check;
      g.apply(p.player.id,
          legal.any((a) => a.type == want) ? want : ActionType.check);
    }
  }
  double r(int v) => n == 0 ? 0 : v / n;
  return (fold: r(fold), call: r(call), raise: r(raise), n: n);
}

void main() {
  const streetName = {
    Street.flop: '翻牌',
    Street.turn: '转牌',
    Street.river: '河牌',
  };
  final hands = <({String name, String hole, String board})>[
    (name: '三条 99 on 9s6h2d', hole: '9h 9d', board: '9s 6h 2d'),
    (name: '超对 99 on 7s4c2d', hole: '9h 9d', board: '7s 4c 2d'),
    (name: '顶对顶踢 AK on As7c2d', hole: 'Ah Kd', board: 'As 7c 2d'),
    (name: '顶对弱踢 A8 on As7c2d', hole: 'Ah 8d', board: 'As 7c 2d'),
    (name: '第二对 87 on Kh8d3c', hole: '8h 7s', board: 'Kh 8d 3c'),
    (name: '底对 43 on Ks7d3c', hole: '4h 3h', board: 'Ks 7d 3c'),
    (name: '花听 AKs on Qd7d2c', hole: 'Ad Kd', board: 'Qd 7d 2c'),
    (name: '卡顺 76 on 9d5c2s', hole: '7h 6h', board: '9d 5c 2s'),
    (name: '空气 87 on AsKdQc', hole: '8h 7h', board: 'As Kd Qc'),
  ];
  // 河牌是「我下注被他加注」最该收手的地方：加注是最后一条街最实的信号，
  // 一对牌被抬起来还一路跟到底，等于对手随便两张牌加一下就能白拿底池。
  // 同一个牌力的名字沿用上面的，只是把牌面补满五张。
  final riverHands = <({String name, String hole, String board})>[
    (name: '三条 99 on 9s6h2d3s', hole: '9h 9d', board: '9s 6h 2d 8c 3s'),
    (name: '超对 99 on 7s4h2d5h3c', hole: '9h 9d', board: '7s 4h 2d 5h 3c'),
    (name: '顶对顶踢 AK on As7c2d5h9s', hole: 'Ah Kd', board: 'As 7c 2d 5h 9s'),
    (name: '顶对弱踢 A8 on As7c2d5h9s', hole: 'Ah 8d', board: 'As 7c 2d 5h 9s'),
    (name: '第二对 87 on Kh8d3c5h9s', hole: '8h 7s', board: 'Kh 8d 3c 5h 9s'),
    (name: '底对 43 on Ks7d3c5h9s', hole: '4h 3h', board: 'Ks 7d 3c 5h 9s'),
    (name: 'miss 花 AKs on Qd7d2c5h9s', hole: 'Ad Kd', board: 'Qd 7d 2c 5h 9s'),
    (name: '空气 87 on AsKdQc5h9s', hole: '8h 7h', board: 'As Kd Qc 5h 9s'),
  ];

  for (final street in [Street.flop, Street.turn, Street.river]) {
    print('== ${streetName[street]}圈：AI 下注 → 英雄加注 ==');
    for (final mult in [2.2, 3.5]) {
      print('-- 加注到 $mult 倍 --');
      for (final h in street == Street.river ? riverHands : hands) {
        final r = vsRaise(h.hole, h.board, mult, street: street);
        print('${h.name.padRight(24)} n=${r.n.toString().padLeft(3)}  '
            '弃 ${(100 * r.fold).round()}%  跟 ${(100 * r.call).round()}%  '
            '再加 ${(100 * r.raise).round()}%');
      }
    }
    print('');
  }

  print('== 风格对照（翻牌，加注到 2.2 倍）==');
  for (final style in AiStyle.values) {
    final strong = vsRaise('Ah Kd', 'As 7c 2d', 2.2, style: style);
    final medium = vsRaise('8h 7s', 'Kh 8d 3c', 2.2, style: style);
    print('${style.name.padRight(18)} '
        '顶对顶踢 弃 ${(100 * strong.fold).round()}% / 跟 ${(100 * strong.call).round()}%  '
        '第二对 弃 ${(100 * medium.fold).round()}% / 跟 ${(100 * medium.call).round()}%');
  }
}
