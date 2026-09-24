// 临时探针：按牌力档 × 位置 × 风格量「面对下注时加注率」
// 用固定底牌 / 公共牌 + 英雄脚本，跑很多个随机种子，
// 看电脑玩家在各种局面的动作分布是否合理。
// ignore_for_file: avoid_print
import 'dart:math';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();

class _Result {
  final Map<String, int> counts = {};
  int total = 0;

  /// [pot] = 决策时的底池，[ref] = 加注前的最高注（下注时为 0）。
  /// 下注/加注不按绝对筹码分类，而是按「相对底池的档位」（5% 一档）——
  /// 尺度混合之后同一个局面会有好几档尺寸，绝对数字看着就是一团乱麻。
  void add(AiDecision d, {required int pot, required int ref}) {
    total++;
    var key = d.type.label;
    if ((d.type == ActionType.bet || d.type == ActionType.raise) && pot > 0) {
      final frac = ((d.amountTo ?? 0) - ref) / pot;
      final bucket = (frac * 20).round() / 20;
      key = '${d.type.label} ~${(100 * bucket).toStringAsFixed(0)}%池';
    }
    counts[key] = (counts[key] ?? 0) + 1;
  }

  @override
  String toString() {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .map((e) =>
            '${e.key} ${(100 * e.value / total).toStringAsFixed(0)}%')
        .join('  |  ');
  }
}

/// 单挑牌桌：player0 = AI（按钮/小盲），player1 = 英雄（大盲）。
/// [heroFirst] 指定英雄在每条街的第一次行动，其余时候一律跟注。
/// 记录 AI 在 [target] 街的第一次决策。
///
/// [oop] = true 时把按钮换给英雄，AI 坐大盲（没位置），翻牌得先过牌——
/// 用来对比同一个局面下有/没位置的差别。
/// [facingOnly] = true 时只记录「面对下注/加注」的那次决策，不然没位置
/// 这一侧记录到的都是「先说话时怎么打」，比不出面对下注的应对。
_Result _sample({
  required String hole,
  required String heroHole,
  required String board,
  required Street target,
  Map<Street, ({ActionType type, double frac})> heroFirst = const {},
  int seeds = 300,
  AiStyle style = AiStyle.tightAggressive,
  int stack = 10000,
  int bb = 100,
  bool oop = false,
  bool facingOnly = false,
}) {
  final res = _Result();
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: GameConfig(startingStack: stack, smallBlind: bb ~/ 2, bigBlind: bb),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    final ai = AiPlayer(style, random: rnd);
    final boardCards = cs(board);
    if (oop) g.buttonIndex = 0; // startHand 里 +1 → 英雄坐按钮
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs(heroHole)},
      boardOverride: boardCards,
    );

    // 英雄脚本：每条街第一次行动按配置，之后跟注。
    final acted = <Street, int>{};
    var guard = 0;
    var recorded = false;
    while (!g.handOver && guard++ < 300) {
      final p = g.pendingAction();
      final legal = p.actions;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        final facing = g.currentBet > p.player.streetBet;
        if (!recorded && g.street == target && (!facingOnly || facing)) {
          recorded = true;
          res.add(
            d,
            pot: g.potTotal(),
            ref: d.type == ActionType.bet ? p.player.streetBet : g.currentBet,
          );
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final n = acted[g.street] ?? 0;
      acted[g.street] = n + 1;
      final cfg = n == 0 ? heroFirst[g.street] : null;
      var type = cfg?.type ?? ActionType.check;
      var amount = 0;
      if (type == ActionType.check && !legal.any((a) => a.type == type)) {
        type = ActionType.call;
      }
      if (type == ActionType.bet || type == ActionType.raise) {
        final frac = cfg?.frac ?? 0.5;
        final pot = g.potTotal();
        final target = type == ActionType.bet
            ? p.player.streetBet + (pot * frac).round()
            : g.currentBet + (pot * frac).round();
        amount = target;
      }
      final la = legal.firstWhere((a) => a.type == type,
          orElse: () => legal.firstWhere((a) => a.type == ActionType.check,
              orElse: () =>
                  legal.firstWhere((a) => a.type == ActionType.call,
                      orElse: () => legal.first)));
      final sized = la.type == ActionType.bet || la.type == ActionType.raise
          ? amount.clamp(la.minAmount, la.maxAmount)
          : null;
      g.apply(p.player.id, la.type, amount: sized);
    }
  }
  return res;
}


void main() {
  void spot(String name,
      {required String hole,
      required String board,
      double frac = 0.5,
      Street street = Street.flop}) {
    final read = HandReading.of(cs(hole), cs(board).take(street == Street.flop ? 3 : 4).toList());
    final tags = 'tier=${read.tier.name} outs=${read.drawOuts} '
        'over=${read.overcards} bd=${read.backdoorFlush}';
    print('${name.padRight(22)} [$tags]');
    for (final style in AiStyle.values) {
      final ip = _sample(
          hole: hole, heroHole: '4c 3s', board: board, target: street,
          style: style, facingOnly: true, oop: false, seeds: 300,
          heroFirst: {street: (type: ActionType.bet, frac: frac)});
      final oop = _sample(
          hole: hole, heroHole: '4c 3s', board: board, target: street,
          style: style, facingOnly: true, oop: true, seeds: 300,
          heroFirst: {street: (type: ActionType.bet, frac: frac)});
      String raise(_Result r) {
        if (r.total == 0) return '-';
        final n = r.counts.entries
            .where((e) => e.key.startsWith('加注') || e.key.startsWith('下注'))
            .fold(0, (a, e) => a + e.value);
        return '${(100 * n / r.total).round()}%';
      }
      print('  ${style.label.padRight(6)} 有位置 加${raise(ip).padLeft(3)} '
          '(n=${ip.total})   没位置 加${raise(oop).padLeft(3)} (n=${oop.total})');
    }
  }

  final flop = 'Kh 8d 3c';
  print('==== 翻牌圈 面对 1/2 池 ====');
  spot('底对 4h3h', hole: '4h 3h', board: flop);
  spot('第二对 8h7s', hole: '8h 7s', board: flop);
  spot('顶对弱踢 Kc5d', hole: 'Kc 5d', board: flop);
  spot('中间对 9h9s', hole: '9h 9s', board: flop);
  spot('顶对顶踢 AhKd', hole: 'Ah Kd', board: flop);

  final turn = 'Kh 8d 3c 5s';
  print('');
  print('==== 转牌圈 面对 2/3 池 ====');
  spot('底对 4h3h', hole: '4h 3h', board: turn, frac: 0.66, street: Street.turn);
  spot('第二对 8h7s', hole: '8h 7s', board: turn, frac: 0.66, street: Street.turn);
  spot('顶对弱踢 Kc5d', hole: 'Kc 5d', board: turn, frac: 0.66, street: Street.turn);
  spot('中间对 9h9s', hole: '9h 9s', board: turn, frac: 0.66, street: Street.turn);
  spot('顶对顶踢 AhKd', hole: 'Ah Kd', board: turn, frac: 0.66, street: Street.turn);

  final river = 'Kh 8d 3c 5s Jd';
  print('');
  print('==== 河牌圈 面对 2/3 池 ====');
  spot('底对 4h3h', hole: '4h 3h', board: river, frac: 0.66, street: Street.river);
  spot('第二对 8h7s', hole: '8h 7s', board: river, frac: 0.66, street: Street.river);
  spot('顶对弱踢 Kc5d', hole: 'Kc 5d', board: river, frac: 0.66, street: Street.river);
}
