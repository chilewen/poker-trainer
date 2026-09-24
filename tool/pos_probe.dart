// 位置对照探针：dart run tool/pos_probe.dart
// 同一个局面（同样的牌、同样的下注尺度），比较 AI 在「有位置（按钮）」
// 与「没位置（大盲）」面对下注时的动作分布。
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
  int hands = 0; // 真的在目标街面对下注的手数（分母）

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

  String get call =>
      total == 0 ? '-' : '${(100 * (counts['跟注'] ?? 0) / total).toStringAsFixed(0)}%';
  String get fold =>
      total == 0 ? '-' : '${(100 * (counts['弃牌'] ?? 0) / total).toStringAsFixed(0)}%';
  String get aggro {
    if (total == 0) return '-';
    final n = counts.entries
        .where((e) => e.key.startsWith('加注') || e.key.startsWith('下注'))
        .fold(0, (a, e) => a + e.value);
    return '${(100 * n / total).toStringAsFixed(0)}%';
  }

  String detail() {
    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list
        .map((e) => '${e.key} ${(100 * e.value / total).toStringAsFixed(0)}%')
        .join('  |  ');
  }
}

_Result _sample({
  required String hole,
  required String heroHole,
  required String board,
  required Street target,
  Map<Street, ({ActionType type, double frac})> heroFirst = const {},
  int seeds = 400,
  AiStyle style = AiStyle.tightAggressive,
  bool heroButton = false, // true = AI 在大盲（没位置）
}) {
  final res = _Result();
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: const GameConfig(
          startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    final ai = AiPlayer(style, random: rnd);
    if (heroButton) g.buttonIndex = 0; // startHand 里会 +1 → 英雄是按钮
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs(heroHole)},
      boardOverride: cs(board),
    );
    final acted = <Street, int>{};
    var guard = 0;
    var recorded = false;
    while (!g.handOver && guard++ < 400) {
      final p = g.pendingAction();
      final legal = p.actions;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        final facing = g.currentBet > p.player.streetBet;
        if (!recorded && g.street == target && facing) {
          recorded = true;
          res.hands++;
          res.add(d, pot: g.potTotal(), ref: g.currentBet);
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
        amount = type == ActionType.bet
            ? p.player.streetBet + (pot * frac).round()
            : g.currentBet + (pot * frac).round();
      }
      final la = legal.firstWhere((a) => a.type == type,
          orElse: () => legal.firstWhere((a) => a.type == ActionType.check,
              orElse: () => legal.firstWhere(
                  (a) => a.type == ActionType.call,
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
  void row(String name,
      {required String hole,
      required String board,
      double frac = 0.5,
      Street street = Street.flop,
      AiStyle style = AiStyle.tightAggressive}) {
    final ip = _sample(
        hole: hole,
        heroHole: '4c 3s',
        board: board,
        target: street,
        style: style,
        heroFirst: {street: (type: ActionType.bet, frac: frac)});
    final oop = _sample(
        hole: hole,
        heroHole: '4c 3s',
        board: board,
        target: street,
        style: style,
        heroButton: true,
        heroFirst: {street: (type: ActionType.bet, frac: frac)});
    print('${name.padRight(26)} '
        '有位置 n=${ip.total.toString().padLeft(3)} 跟${ip.call}/弃${ip.fold}/加${ip.aggro}   '
        '没位置 n=${oop.total.toString().padLeft(3)} 跟${oop.call}/弃${oop.fold}/加${oop.aggro}');
  }

  print('== 翻牌：面对 1/2 池  (有位置 vs 没位置) ==');
  row('空气+后门花 AdTd on 9d7c2c', hole: 'Ad 10d', board: '9d 7c 2c');
  row('空气+后门花 Kh9h on As7h2c', hole: 'Kh 9h', board: 'As 7h 2c');
  row('卡顺 76 on A92', hole: '7h 6h', board: 'As 9d 2c');
  row('花听 AKs on Qd7d2c', hole: 'Ad Kd', board: 'Qd 7d 2c');
  row('底对 Ah2h on Qh7d2c', hole: 'Ah 2h', board: 'Qh 7d 2c');
  row('第二对 9h8h on Qh9d2c', hole: '9h 8h', board: 'Qh 9d 2c');
  row('顶对弱踢 Qh3h on Qd7c2s', hole: 'Qh 3h', board: 'Qd 7c 2s');
  print('');
  print('== 转牌圈：面对 2/3 池 ==');
  row('miss 花 AdKd on Qd7d2c5h', hole: 'Ad Kd', board: 'Qd 7d 2c 5h',
      frac: 0.66, street: Street.turn);
  row('第二对 9h8h on Qh9d2c5h', hole: '9h 8h', board: 'Qh 9d 2c 5h',
      frac: 0.66, street: Street.turn);
  print('');
  print('== 松被动 / 松凶 ==');
  for (final st in [AiStyle.loosePassive, AiStyle.looseAggressive]) {
    print('-- ${st.label} --');
    row('空气+后门花 AdTd', hole: 'Ad 10d', board: '9d 7c 2c', style: st);
    row('底对 Ah2h', hole: 'Ah 2h', board: 'Qh 7d 2c', style: st);
  }
  print('');
  print('-- 明细：空气+后门花 AdTd on 9d7c2c（1/3 池）--');
  final ip = _sample(
      hole: 'Ad 10d',
      heroHole: '4c 3s',
      board: '9d 7c 2c',
      target: Street.flop,
      heroFirst: const {Street.flop: (type: ActionType.bet, frac: 0.33)});
  final oop = _sample(
      hole: 'Ad 10d',
      heroHole: '4c 3s',
      board: '9d 7c 2c',
      target: Street.flop,
      heroButton: true,
      heroFirst: const {Street.flop: (type: ActionType.bet, frac: 0.33)});
  print('  有位置 ${ip.detail()}');
  print('  没位置 ${oop.detail()}');
}
