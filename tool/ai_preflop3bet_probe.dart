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
  int callers = 0, // 英雄 3bet 之后，小盲/大盲里有几家先冷跟进来
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
    var coldUsed = 0;
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
      // 小盲/大盲按 [callers] 冷跟 3bet：这样开池的人就是「关着门、池里
      // 还有别人陪着」——用来量「多路底池该不该跟得比单挑宽」。
      final isBlind = p.player.id == ids[0] || p.player.id == ids[1];
      if (isBlind &&
          coldUsed < callers &&
          facingBet &&
          g.street == Street.preflop &&
          legal.any((a) => a.type == ActionType.call)) {
        coldUsed++;
        g.apply(p.player.id, ActionType.call);
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

  // 第二节：同一个 3bet 尺度下，池里几家先冷跟进来对开池方的跟注率有什么影响。
  // 真人被 3bet 之后，只要池里有人陪着进池（关门、价格便宜、隐含赔率好），
  // 投机牌跟得明显比单挑宽；以前这一档完全不看人数，两种情况逐格相同。
  print('== 池里几家冷跟，对「面对 3bet 跟不跟」的影响（${seatLabel[rel]}开池，英雄按钮位 3bet 到 9bb）==');
  for (final hole in ['2h 2d', '5h 5d', '7h 7d', '9h 8h', 'Ah Qd', 'Kh Qh']) {
    final parts = <String>[];
    for (final cc in [0, 1, 2]) {
      final r = probe(hole: hole, rel: rel, threeBet: 900, callers: cc);
      final f = r.facing['弃牌'] ?? 0;
      final c = r.facing['跟注'] ?? 0;
      final ra = r.facing['加注'] ?? 0;
      parts.add('冷跟$cc: 弃${_pct(f, r.n)} 跟${_pct(c, r.n)} 加${_pct(ra, r.n)}');
    }
    print('  ${hole.padRight(8)} ${parts.join('   ')}');
  }

  // 第三节：「便宜 3bet」那道门槛附近的坡度。
  //
  // 便宜档（任何对子都买三条、同花 A / 同花连张全上、KQo 也跟）和正常档
  // （99+/ATs+/AQo）之间的跟注率差得很远，所以原来把边界写成
  // `<=5.5bb 或者 <=2.2 倍开池` 的硬条件。可开池尺度本身是混合的，同一个
  // 3bet 到 620 撞上不同开池就是 1.6~2.6 倍——边界两边于是成了两个世界：
  // 同一手 KQo 对着 620 跟 82%、对着 640 跟 37%，只差 20 个筹码。
  // 这一节就是盯这条坡度：边界附近每一步都该在动，没有哪一步掉几十个点。
  print('== 「便宜 3bet」边界附近的跟注率（${seatLabel[rel]}开池）==');
  for (final sb in [470, 560, 620, 660, 700, 800]) {
    final parts = <String>[];
    for (final hole in ['Kh Qs', 'Jh 10h', '9h 8h']) {
      final r = probe(hole: hole, rel: rel, threeBet: sb, seeds: 400);
      parts.add('${hole.replaceAll(' ', '')} 跟${_pct(r.facing['跟注'] ?? 0, r.n)}');
    }
    print('  3bet ${(sb / 100).toStringAsFixed(1)}bb   ${parts.join('   ')}');
  }
}
