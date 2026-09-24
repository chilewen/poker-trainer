// 多人底池探针：dart run tool/ai_multi_probe.dart
//
// ai_probe 只量单挑；这个探针把「池子里几个人」也变成变量：英雄第一个
// 下注、中间的人依次跟注，看 AI 最后行动时面对同一个下注会怎么打。
// 顶对顶踢在多人池里该怎么收着加，就是靠这一格量出来的。
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
}
