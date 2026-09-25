// 单街「再加注」牌力分布：dart tool/ai_reraise_probe.dart [手数] [种子]
//
// 关注点：真人翻后单街的「第 2 次及以后的加注」（也就是 3-bet 以上、真正的
// 加注战）几乎只拿两对以上的真牌打；空气/听牌/一对去 3-bet、4-bet 是明显的
// 破绽——对手只要一路抬，我们就会用垃圾把筹码送出去。
// ignore_for_file: avoid_print
import 'dart:math';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';

List<Card> _boardAt(List<Card> board, Street s) {
  switch (s) {
    case Street.preflop:
      return const [];
    case Street.flop:
      return board.take(3).toList();
    case Street.turn:
      return board.take(4).toList();
    case Street.river:
      return board;
    case Street.showdown:
      return board;
  }
}

void main(List<String> args) {
  final total = args.isNotEmpty ? int.parse(args[0]) : 1200;
  final seed = args.length > 1 ? int.parse(args[1]) : 7;
  final rnd = Random(seed);
  final g = GameEngine(random: rnd);
  final ais = <String, AiPlayer>{};
  for (var i = 0; i < 9; i++) {
    const rotation = [
      AiStyle.tightAggressive,
      AiStyle.loosePassive,
      AiStyle.looseAggressive,
    ];
    final style = rotation[i % rotation.length];
    final id = 'ai$i';
    g.addPlayer(id, '${style.label}$i');
    ais[id] = AiPlayer(style, random: rnd);
  }

  // 3-bet 以上（单街第 2+ 次加注）按牌力分档
  final byTier = <String, int>{}; // 第 2 次加注（3-bet）
  final byThird = <String, int>{}; // 第 3 次及以后（4-bet+）
  final byFirstRaise = <String, int>{}; // 对照组：单街第 1 次加注
  var reraiseTotal = 0;
  var raiseTotal = 0;
  final samples = <String>[];

  for (var h = 0; h < total; h++) {
    for (final p in g.players) {
      if (p.stack < g.config.bigBlind) g.topUp(p.id);
    }
    g.startHand();
    var guard = 0;
    while (!g.handOver && guard++ < 600) {
      final p = g.pendingAction();
      final d = ais[p.player.id]!.decide(g, p.player);
      g.apply(p.player.id, d.type, amount: d.amountTo);
    }
    final hand = g.lastHand!;
    final raisesOnStreet = <Street, int>{};
    for (final a in hand.actions) {
      if (a.street == Street.preflop) continue;
      if (a.type != ActionType.raise) continue;
      final before = raisesOnStreet[a.street] ?? 0;
      raisesOnStreet[a.street] = before + 1;
      final hole = hand.holeCards[a.actorId]!;
      final read =
          HandReading.of(hole, _boardAt(hand.board, a.street));
      raiseTotal++;
      final key = read.hasDraw && read.tier == HandTier.junk
          ? '${read.tier.name}+听牌'
          : read.tier.name;
      if (before == 0) {
        byFirstRaise[key] = (byFirstRaise[key] ?? 0) + 1;
      } else {
        reraiseTotal++;
        if (before == 1) {
          byTier[key] = (byTier[key] ?? 0) + 1;
        } else {
          byThird[key] = (byThird[key] ?? 0) + 1;
        }
        if (samples.length < 8) {
          samples.add('${a.street.name.padRight(5)} ${a.actorId} '
              '单街第 ${before + 1} 次加注 ${a.amount}  '
              '[${hole.map((c) => c.pretty).join('')}] ${read.toString()}'
              ' | board ${_boardAt(hand.board, a.street).map((c) => c.pretty).join(' ')}');
        }
      }
    }
  }

  // 紧凑汇总行：方便多跑几个种子直接相加做对拍。
  String total1(Map<String, int> m) {
    final ks = m.keys.toList()..sort();
    return '${m.values.fold(0, (a, b) => a + b)}'
        '（${ks.map((k) => '$k ${m[k]}').join(' / ')}）';
  }
  void summary() {
    print('汇总 第1次加注: ${total1(byFirstRaise)}');
    print('汇总 第2次加注: ${total1(byTier)}');
    print('汇总 第3+次加注: ${total1(byThird)}');
  }

  String fmt(Map<String, int> m, int denom) {
    final ks = m.keys.toList()..sort((a, b) => m[b]!.compareTo(m[a]!));
    if (denom == 0) return '  （无样本）';
    return ks
        .map((k) => '    ${k.padRight(12)} ${m[k]}'
            '  ${(100 * m[k]! / denom).toStringAsFixed(0)}%')
        .join('\n');
  }

  print('=== $total 手（9 人桌 50/100，种子 $seed） ===');
  print('翻后加注总数: $raiseTotal');
  print('其中「单街第 2+ 次加注」(3-bet 以上): $reraiseTotal');
  print('');
  print('单街第 1 次加注的牌力分布（对照）:');
  print(fmt(byFirstRaise, raiseTotal - reraiseTotal));
  print('');
  print('单街第 2 次加注（3-bet）的牌力分布:');
  print(fmt(byTier, byTier.values.fold(0, (a, b) => a + b)));
  print('');
  print('单街第 3 次及以后（4-bet+）的牌力分布（该只有 monster）:');
  print(fmt(byThird, byThird.values.fold(0, (a, b) => a + b)));
  print('');
  summary();
  print('');
  print('再加注样例:');
  for (final s in samples) {
    print('  $s');
  }
}
