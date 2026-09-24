// 定向试探 AI 的单点决策：dart tool/ai_probe.dart
// 用固定底牌 / 公共牌 + 英雄脚本，跑很多个随机种子，
// 看电脑玩家在各种局面的动作分布是否合理。
// ignore_for_file: avoid_print
import 'dart:math';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';

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
        if (!recorded && g.street == target) {
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
  void show(String name, _Result r) =>
      print('${name.padRight(34)} $r');

  print('== 翻牌圈（无人下注）== ');
  show('听花 AKs on Qd7d2c',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop));
  show('两头顺 98 on 762r',
      _sample(hole: '9h 8h', heroHole: '3c 2h', board: '7s 6h 2d', target: Street.flop));
  show('卡顺 76 on A92',
      _sample(hole: '7h 6h', heroHole: '3c 2h', board: 'As 9d 2c', target: Street.flop));
  // 用 87s 而不是 72o：翻前范围表里的牌才会真的走到翻牌圈，
  // 否则 AI 翻前就弃了、这一格永远是空的（87s 在 AKQ 上仍是纯空气）。
  show('空气 87s on AKQ',
      _sample(hole: '8h 7h', heroHole: '9c 8d', board: 'As Kd Qc', target: Street.flop));
  show('三条 99 on 9s6h2d',
      _sample(hole: '9h 9d', heroHole: '3c 2h', board: '9s 6h 2d', target: Street.flop));
  show('顶对顶踢 AQ on Qh7d2c',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c', target: Street.flop));

  print('');
  print('== 翻牌圈（英雄下注 1/2 池）== ');
  show('听花 面对方 bet',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  show('卡顺 面对方 bet',
      _sample(hole: '7h 6h', heroHole: '3c 2h', board: 'As 9d 2c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 0.5)}));
  show('空气 面对方 pot bet',
      _sample(hole: '8h 7h', heroHole: '9c 8d', board: 'As Kd Qc', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 1.0)}));
  show('底对 面对方 pot bet',
      _sample(hole: 'Ah 2h', heroHole: '3c 4h', board: 'Qh 7d 2c', target: Street.flop,
          heroFirst: {Street.flop: (type: ActionType.bet, frac: 1.0)}));

  print('');
  print('== 转牌圈（听牌未成，对手一直过牌）== ');
  show('听花转牌（无人下注）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h', target: Street.turn));
  show('听花转牌（面对 1/2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 0.5)}));
  show('听花转牌（面对 1.2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h', target: Street.turn,
          heroFirst: {Street.turn: (type: ActionType.bet, frac: 1.2)}));

  print('');
  print('== 河牌圈（听牌已经错过）== ');
  show('miss 花（无人下注）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river));
  show('miss 花（面对 1/4 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.25)}));
  show('miss 花（面对 1 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('成花（面对 1/2 池 bet）',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 3d', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  show('河牌顶对（面对 1/2 池 bet）',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
  show('河牌两对（面对 1/2 池 bet）',
      _sample(hole: '9h 7d', heroHole: '3c 2h', board: 'Qh 9d 7c 5h 2s', target: Street.river,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));

  print('');
  print('== 松凶风格对照 == ');
  show('听花（无人下注）LAG',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop,
          style: AiStyle.looseAggressive));
  show('空气（无人下注）LAG',
      _sample(hole: '9h 8h', heroHole: '3c 2h', board: 'As Kd Qc', target: Street.flop,
          style: AiStyle.looseAggressive));
  show('miss 花（无人下注）LAG',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.looseAggressive));
  show('miss 花（面对 1 池 bet）LAG',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.looseAggressive,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 1.0)}));
  show('河牌顶对（面对 1/2 池 bet）LAG',
      _sample(hole: 'Ah Qd', heroHole: '3c 2h', board: 'Qh 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.looseAggressive,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));

  print('');
  print('== 松被动风格对照 == ');
  show('听花（无人下注）LP',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c', target: Street.flop,
          style: AiStyle.loosePassive));
  show('miss 花（无人下注）LP',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 9s', target: Street.river,
          style: AiStyle.loosePassive));
  show('成花（面对 1/2 池 bet）LP',
      _sample(hole: 'Ad Kd', heroHole: '3c 2h', board: 'Qd 7d 2c 5h 3d', target: Street.river,
          style: AiStyle.loosePassive,
          heroFirst: {Street.river: (type: ActionType.bet, frac: 0.5)}));
}
