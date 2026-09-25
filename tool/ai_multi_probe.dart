// 多人底池探针：dart run tool/ai_multi_probe.dart
//
// ai_probe 只量单挑；这个探针把「池子里几个人」也变成变量。量两条线：
//
//   A. 面对下注：英雄第一个下注、中间的人依次跟注，看 AI 最后行动时面对
//      同一个下注会怎么打。顶对顶踢在多人池里该怎么收着加，就是靠这一格
//      量出来的。
//   B. 无人下注：所有人都过牌到 AI（它在按钮、最后说话），看它下不下注、
//      下多大。以前强牌档的四条过牌档全挂着 !multiway，翻牌被过牌到在
//      2/3/4/5 人池里都是 100% 下注，尺度还随人数往上抬——这一格就是用来
//      盯「过牌到我 = 一定下注」这种机器味的。
//   C. 河牌大注：英雄按倍数下注、中间的人全跟，看 AI 收不收着弃。下注尺度
//      要是按「我们决策时的池」算，中间那几家的跟注钱会把同一个 1.5 倍池
//      的重注摊薄成小注（三人池只剩 0.375 倍池），河牌挑着弃那一档整条失效
//      ——改之前顶对顶踢在三人池只弃 4%、还反过来加注。
// ignore_for_file: avoid_print
import 'dart:math';

import 'probe_scale.dart';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();

/// 牌桌：ai（按钮，最后行动）+ hero（先行动）+ [callers] 个跟注的人。
/// 翻牌圈 hero 按 [frac] 池下注、跟注的人全跟，记录 AI 面对下注时的动作。
({double raise, double call, double fold, int n}) probe({
  required String hole,
  required String board,
  required int callers,
  double frac = 0.5,
  AiStyle style = AiStyle.tightAggressive,
  Street street = Street.flop,
  int seeds = 300,
}) {
  var raise = 0, call = 0, fold = 0, n = 0;
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(random: rnd)..addPlayer('ai', 'AI');
    final ai = AiPlayer(style, random: rnd);
    g.addPlayer('hero', '我');
    for (var i = 0; i < callers; i++) {
      g.addPlayer('c$i', 'C$i');
    }
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('3h 2c')},
      boardOverride: cs(board).take(street == Street.flop ? 3 : 4).toList(),
    );
    var guard = 0;
    var recorded = false;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = g.currentBet > p.player.streetBet;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (!recorded && g.street == street && facing) {
          recorded = true;
          n++;
          if (d.type == ActionType.raise) {
            raise++;
          } else if (d.type == ActionType.call) {
            call++;
          } else {
            fold++;
          }
          break;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      // 别人一律「能下注就下注（hero）、其余跟注」，把局面喂到 AI 面前。
      if (p.player.id == 'hero' &&
          !facing &&
          legal.any((a) => a.type == ActionType.bet)) {
        final la = legal.firstWhere((a) => a.type == ActionType.bet);
        g.apply(
            'hero',
            ActionType.bet,
            amount: (g.potTotal() * frac)
                .round()
                .clamp(la.minAmount, la.maxAmount));
        continue;
      }
      final want = legal.any((a) => a.type == ActionType.call)
          ? ActionType.call
          : ActionType.check;
      g.apply(p.player.id, want);
    }
  }
  return (
    raise: n == 0 ? 0 : raise / n,
    call: n == 0 ? 0 : call / n,
    fold: n == 0 ? 0 : fold / n,
    n: n,
  );
}

/// 同一条桌，但所有人（包括英雄）都过牌到 AI：量它下注/过牌与平均尺度。
({double bet, double check, double avgFrac, int n}) probeCheckedTo({
  required String hole,
  required String board,
  required int callers,
  AiStyle style = AiStyle.tightAggressive,
  Street street = Street.flop,
  int seeds = 300,
}) {
  var bet = 0, check = 0, n = 0;
  var fracSum = 0.0;
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(random: rnd)..addPlayer('ai', 'AI');
    final ai = AiPlayer(style, random: rnd);
    g.addPlayer('hero', '我');
    for (var i = 0; i < callers; i++) {
      g.addPlayer('c$i', 'C$i');
    }
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('3c 2c')},
      boardOverride: cs(board).take(street == Street.flop ? 3 : 4).toList(),
    );
    var guard = 0;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = g.currentBet > p.player.streetBet;
      if (p.player.id == 'ai') {
        // 翻前只让 AI 补齐，不让它自己决定。
        //
        // 这一节要量的是「翻后没人下注时 AI 怎么打」，可 AI 在按钮面对
        // 溜入者时会把不少牌直接扔掉（实测 5 人池拿 87o 弃 100%、4 人池
        // 弃 79%），于是 4 人池那一格只剩 64 手、5 人池直接 0 手——打出来
        // 的「下注 0%」根本没有样本，是探针自己在骗人。翻前补不补齐不是
        // 这一节的问题（那是翻前范围那一节的事），所以这里统一按跟注走，
        // 保证每个格子都是同一个翻后场景：所有人过牌到按钮。
        if (g.street == Street.preflop) {
          g.apply('ai',
              legal.any((a) => a.type == ActionType.call)
                  ? ActionType.call
                  : ActionType.check);
          continue;
        }
        final d = ai.decide(g, p.player);
        if (g.street == street && !facing) {
          n++;
          if (d.type == ActionType.bet) {
            bet++;
            fracSum += (d.amountTo ?? 0) / max(1, g.potTotal());
          } else {
            check++;
          }
          break;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final want = facing
          ? ActionType.call
          : (legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : legal.first.type);
      g.apply(p.player.id, legal.any((a) => a.type == want) ? want : legal.first.type);
    }
  }
  if (n == 0) return (bet: 0, check: 0, avgFrac: 0, n: 0);
  return (
    bet: bet / n,
    check: check / n,
    avgFrac: bet == 0 ? 0 : fracSum / bet,
    n: n,
  );
}

/// 河牌大注：hero 按 [frac] 倍池先下注、中间的人全跟，记录 AI 的应对。
///
/// 专门盯「下注尺度要看**对手出手那一刻的池**」这条：分母里不扣掉中间那几家
/// 跟注的钱，同一个 1.5 倍池的重注会被摊薄成小注，靠尺度说话的那几档（河牌
/// 挑着弃、不拿一对反加）整条失效。
({double raise, double call, double fold, int n}) probeRiverFacing({
  required String hole,
  required String board,
  required int callers,
  required double frac,
  AiStyle style = AiStyle.tightAggressive,
  int seeds = 300,
}) {
  var raise = 0, call = 0, fold = 0, n = 0;
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(random: rnd)..addPlayer('ai', 'AI');
    final ai = AiPlayer(style, random: rnd);
    g.addPlayer('hero', '我');
    for (var i = 0; i < callers; i++) {
      g.addPlayer('c$i', 'C$i');
    }
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('3h 2c')},
      boardOverride: cs(board),
    );
    var guard = 0;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = g.currentBet > p.player.streetBet;
      if (p.player.id == 'ai') {
        // 前面的街一律过牌：把河牌做成「前面没人开火、这条街突然砸出来」
        // 那条线（也是这些档最容易被误读的地方）。
        if (g.street != Street.river) {
          g.apply('ai', legal.any((a) => a.type == ActionType.check)
              ? ActionType.check
              : ActionType.call);
          continue;
        }
        final d = ai.decide(g, p.player);
        if (!facing) break; // 英雄没下注的手不算样本
        n++;
        if (d.type == ActionType.raise) {
          raise++;
        } else if (d.type == ActionType.call) {
          call++;
        } else {
          fold++;
        }
        break;
      }
      if (p.player.id == 'hero' &&
          g.street == Street.river &&
          !facing &&
          legal.any((a) => a.type == ActionType.bet)) {
        final la = legal.firstWhere((a) => a.type == ActionType.bet);
        g.apply(
            'hero',
            ActionType.bet,
            amount: (p.player.streetBet + (g.potTotal() * frac).round())
                .clamp(la.minAmount, la.maxAmount));
        continue;
      }
      final want = facing ? ActionType.call : ActionType.check;
      g.apply(p.player.id, legal.any((a) => a.type == want) ? want : legal.first.type);
    }
  }
  return (
    raise: n == 0 ? 0 : raise / n,
    call: n == 0 ? 0 : call / n,
    fold: n == 0 ? 0 : fold / n,
    n: n,
  );
}

String pct(double v) => '${(100 * v).round()}%';

void main() {
  void row(String name, {required String hole, required String board}) {
    final read = HandReading.of(cs(hole), cs(board));
    print('${name.padRight(22)} [tier=${read.tier.name}]');
    for (final callers in [0, 1, 2]) {
      final r = probe(hole: hole, board: board, callers: callers);
      print('  ${callers + 2} 人池: 加 ${pct(r.raise).padLeft(3)}  '
          '跟 ${pct(r.call).padLeft(3)}  弃 ${pct(r.fold).padLeft(3)}  n=${r.n}');
    }
  }

  // 8 是牌面最大牌：A8 = 顶对顶踢（strong）。
  row('顶对顶踢 A8 on 854', hole: 'Ah 8d', board: '8h 5s 4s');
  row('中间对 99 on K84', hole: '9h 9d', board: 'Kh 8s 4s');
  row('第二对 87 on K84', hole: '8h 7d', board: 'Kh 8s 4s');
  row('花听 AKs on Q74', hole: 'Ah Kh', board: 'Qh 7h 4c');

  print('');
  print('== B. 所有人都过牌到 AI（AI 在按钮）==');
  // 翻前一律让 AI 补齐（见 [probeCheckedTo] 里的说明），量的是「所有人都
  // 过牌到按钮，AI 下不下注」；每格都打样本数 n，n 太小的时候别照数字下结论。
  //
  // 牌面写成完整五张：转牌/河牌那两行要按 take(3)/take(4) 截，只写三张的话
  // 后面两条街会从牌堆里随机发，量出来的就不是同一张牌面了。
  final checkHands = <({String name, String hole, String board})>[
    (name: '顶对顶踢 A8 on 854（湿）', hole: 'Ah 8d', board: '8h 5s 4s 2c 9d'),
    (name: '超对 99 on 852（彩虹干面）', hole: '9h 9d', board: '8d 5c 2h Js 4d'),
    (name: '第二对 87 on K84', hole: '8h 7d', board: 'Kh 8s 4s 2c 9d'),
    (name: '花听 AKs on Q74', hole: 'Ah Kh', board: 'Qh 7h 4c 2s 9d'),
    (name: '空气 87 on AKQ', hole: '8h 7d', board: 'As Kd Qc 2h 5s'),
  ];
  for (final street in [Street.flop, Street.turn, Street.river]) {
    print('-- $street 圈 --');
    for (final h in checkHands) {
      final parts = <String>[];
      for (final callers in [0, 1, 2, 3]) {
        final r = probeCheckedTo(
            hole: h.hole, board: h.board, callers: callers, street: street);
        parts.add('${callers + 2}人 下注 ${pct(r.bet)}'
            '(~${r.avgFrac.toStringAsFixed(2)}池) n=${r.n}');
      }
      print('${h.name.padRight(24)} ${parts.join('  |  ')}');
    }
  }

  print('');
  print('== C. 河牌重注：人越多越不该拿一对接 ==');
  // 牌面写成完整五张：截到河牌才是同一张牌面。
  final riverHands = <({String name, String hole, String board})>[
    (name: '顶对顶踢 AQ on Q7259', hole: 'Ah Qd', board: 'Qh 7d 2c 5h 9s'),
    (name: '第二对 87 on K8359', hole: '8h 7s', board: 'Kh 8d 3c 5h 9s'),
  ];
  for (final frac in [1.0, 1.5]) {
    for (final h in riverHands) {
      final parts = <String>[];
      for (final callers in [0, 1, 2]) {
        final r = probeRiverFacing(
            hole: h.hole, board: h.board, callers: callers, frac: frac);
        if (r.n == 0) {
          parts.add('${callers + 2}人 n=0');
          continue;
        }
        parts.add('${callers + 2}人 弃 ${pct(r.fold).padLeft(3)}'
            '  跟 ${pct(r.call).padLeft(3)}  加 ${pct(r.raise).padLeft(3)}');
      }
      print('下注 ${frac.toStringAsFixed(1)} 池  ${h.name.padRight(20)} '
          '${parts.join('  |  ')}');
    }
  }
}
