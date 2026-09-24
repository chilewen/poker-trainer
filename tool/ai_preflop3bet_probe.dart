// 翻前「面对 3bet」探针：dart run tool/ai_preflop3bet_probe.dart
//
// 复现实战里的这一幕：9 人桌，某个中位 AI 先开池，按钮位的英雄 3bet，
// 看这个开池的人（拿着 99/JJ/AQs/88…）到底跟、弃还是 4bet。
// 用来量「3bet 防守范围」是不是太紧——太紧的话对手拿任意两张牌 3bet 都赚。
// ignore_for_file: avoid_print
import 'dart:math';

import 'probe_scale.dart';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();


/// 9 人桌：hero 在按钮位，AI 坐在 [rel] 这个相对位置上先行动开池，
/// 英雄 3bet 到 [threeBet]；记录开池方第二次面对 3bet 时的决策。
///
/// [rel] 按座位相对庄位算：1 = 小盲、2 = 大盲、3~4 = 前位、5~6 = 中位、7~8 = 劫位。
({Map<String, int> facing, List<int> openSizes, int n}) probe({
  required String hole,
  required int rel,
  int threeBet = 470,
  AiStyle style = AiStyle.tightAggressive,
  int stack = 10000,
  int seeds = 300,
}) {
  final facing = <String, int>{};
  final openSizes = <int>[];
  var n = 0;
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: GameConfig(startingStack: stack, smallBlind: 50, bigBlind: 100),
      random: rnd,
    );
    // players[0] 就是按钮位（startHand 会把 buttonIndex 从 -1 推到 0）。
    g.addPlayer('hero', '我');
    final ids = <String>[];
    for (var i = 1; i <= 8; i++) {
      final id = 'a$i';
      ids.add(id);
      g.addPlayer(id, 'AI$i');
    }
    final target = ids[rel - 1];
    final ai = <String, AiPlayer>{};
    for (final id in ids) {
      ai[id] = AiPlayer(style, random: rnd);
    }
    final holes = <String, List<Card>>{'hero': cs('3h 2c'), target: cs(hole)};
    // 其余人的底牌从剩余牌堆里随便发，保证不和主角 / 英雄撞牌。
    final used = <Card>{...cs('3h 2c'), ...cs(hole)};
    final pool = [
      for (final suit in Suit.values)
        for (final rank in Rank.values)
          if (!used.contains(Card(rank, suit))) Card(rank, suit),
    ];
    var f = 0;
    for (final id in ids) {
      if (id == target) continue;
      holes[id] = [pool[f * 2], pool[f * 2 + 1]];
      f++;
    }
    g.startHand(holeOverride: holes);

    var guard = 0;
    var opened = false;
    var done = false;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facingBet = g.currentBet > p.player.streetBet;
      if (p.player.id == 'hero') {
        // 英雄：面对开池就 3bet 到 [threeBet]，没人加注就弃牌（不是我们的主角）。
        if (g.handOver) break;
        final want = facingBet ? ActionType.raise : ActionType.fold;
        final la = legal.firstWhere((a) => a.type == want,
            orElse: () => legal.firstWhere((a) => a.type == ActionType.fold));
        if (la.type == ActionType.raise) {
          g.apply('hero', ActionType.raise,
              amount: threeBet.clamp(la.minAmount, la.maxAmount));
        } else {
          g.apply('hero', ActionType.fold);
        }
        continue;
      }
      if (p.player.id == target) {
        final d = ai[target]!.decide(g, p.player);
        if (!opened) {
          // 第一次行动 = 开池（这里所有人都不溜入，所以必然是加注或弃牌）。
          opened = true;
          if (d.type == ActionType.raise) openSizes.add(d.amountTo ?? 0);
        } else if (facingBet) {
          n++;
          final key = d.type.label;
          facing[key] = (facing[key] ?? 0) + 1;
          done = true;
        }
        g.apply(target, d.type, amount: d.amountTo);
        if (done) break;
        continue;
      }
      // 其余 AI 一律弃牌，把局面干净地喂到英雄/目标面前。
      g.apply(p.player.id,
          legal.any((a) => a.type == ActionType.fold)
              ? ActionType.fold
              : ActionType.check);
    }
  }
  return (facing: facing, openSizes: openSizes, n: n);
}

String _pct(int v, int n) => n == 0 ? '-' : '${(100 * v / n).round()}%';

void main() {
  final seatLabel = {1: '小盲', 2: '大盲', 3: '前位', 4: '前位', 5: '中位', 6: '中位', 7: '劫位', 8: '劫位'};
  const rel = 6; // 中位开池，英雄按钮位 3bet（截图里 A16 那个位置）
  for (final sb in [470, 700, 900, 1400]) {
    print('== 开池者在${seatLabel[rel]}（开池约 3bb），英雄按钮位 3bet 到 $sb ==');
    for (final hole in ['2h 2d', '5h 5d', '7h 7d', '9h 9d', '10h 10d', 'Jh Jd', 'Qh Qd', 'Ah Kd', 'Ah Qd', 'Kh Qs', 'Ah Jh', 'Kh Qh', 'Jh 10h', '9h 8h', 'Ah 5h', '7h 6h']) {
      final r = probe(hole: hole, rel: rel, threeBet: sb);
      final avg = r.openSizes.isEmpty
          ? 0
          : r.openSizes.reduce((a, b) => a + b) ~/ r.openSizes.length;
      final parts = r.facing.entries.map((e) => '${e.key} ${_pct(e.value, r.n)}').join('  ');
      print('  ${hole.padRight(8)} 开池 ${avg.toString().padLeft(4)}  3bet ${(sb / 100).toStringAsFixed(1)}bb  n=${r.n.toString().padLeft(3)}  $parts');
    }
    print('');
  }
}
