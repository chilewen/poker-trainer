// 河牌防守频率 vs MDF：dart tool/ai_river_defense_probe.dart [每个格子的手数]
//
// 局面是最常见的那种「被连开三枪」：英雄是翻前加注方，手里什么牌都不看
// （任意两张），翻牌/转牌/河牌各开一枪；只统计 AI 在翻牌、转牌都跟注，
// 到河牌面对第三枪的那次决策。这样 AI 的范围就是它自己的跟注范围，
// 量出来的弃牌率直接对应「对手随便开三枪，我能挡住多少」。
//
// 判据是 MDF（最低防守频率）：对手下 b 进 p 的池，我们弃牌率只要高过
// b/(p+b)，他拿任意两张牌开火就是赚的。所以把整体弃牌率和这条保本线并排
// 放出来——高出来的那部分，就是能被「任意两张」直接兑现的漏洞。
// ignore_for_file: avoid_print
import 'dart:math';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();

bool _facing(GameEngine g, PlayerState p) => g.currentBet > p.streetBet;

class _Stats {
  int fold = 0, call = 0, raised = 0, total = 0, potSum = 0;
  double needSum = 0, fracSum = 0;
  final Map<String, int> tierAll = {};
  final Map<String, int> tierFold = {};
}

_Stats _run(String board, double riverFrac, int seeds) {
  final st = _Stats();
  for (var seed = 0; seed < seeds; seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config:
          const GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    )
      ..addPlayer('ai', 'AI')
      ..addPlayer('hero', 'Hero');
    final ai = AiPlayer(AiStyle.tightAggressive, random: rnd);
    g.buttonIndex = 0; // startHand 里 +1 → 英雄坐按钮，AI 守大盲
    g.startHand(boardOverride: cs(board));

    var recorded = false, aborted = false;
    var guard = 0;
    while (!g.handOver && guard++ < 400) {
      final p = g.pendingAction();
      final street = g.street;
      if (p.player.id == 'ai') {
        final facing = _facing(g, p.player);
        if (!facing) {
          // AI 先说话（翻牌/转牌/河牌都有）：这条线要求它过牌，让英雄开火。
          // 它自己主动下注（donk）就不是我们要量的局面了。
          final d = ai.decide(g, p.player);
          if (d.type != ActionType.check) {
            aborted = true;
            break;
          }
          g.apply('ai', ActionType.check);
          continue;
        }
        if (street == Street.river) {
          // 要量的就是这一次：英雄连开三枪的第三枪。
          final toCall = g.currentBet - p.player.streetBet;
          final pot = g.potTotal();
          final read = HandReading.of(p.player.holeCards, g.board);
          final key = read.tier.name;
          st.tierAll[key] = (st.tierAll[key] ?? 0) + 1;
          final d = ai.decide(g, p.player);
          st.total++;
          st.potSum += pot;
          st.needSum += toCall / (pot + toCall);
          st.fracSum += toCall / (pot - toCall);
          switch (d.type) {
            case ActionType.fold:
              st.fold++;
              st.tierFold[key] = (st.tierFold[key] ?? 0) + 1;
            case ActionType.call:
              st.call++;
            default:
              st.raised++;
          }
          recorded = true;
          break;
        }
        // 翻牌/转牌面对英雄的下注：跟注才继续看下一条街。
        final d = ai.decide(g, p.player);
        if (d.type != ActionType.call) {
          aborted = true;
          break;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      // 英雄：翻前加注到 3bb；之后无人下注就开火，有人下注就跟。
      final legal = p.actions;
      if (street == Street.preflop) {
        final raise = legal.where((a) => a.type == ActionType.raise).firstOrNull;
        if (raise != null && g.currentBet < 300) {
          g.apply('hero', ActionType.raise, amount: min(300, raise.maxAmount));
        } else if (legal.any((a) => a.type == ActionType.call)) {
          g.apply('hero', ActionType.call);
        } else {
          aborted = true;
          break;
        }
        continue;
      }
      if (_facing(g, p.player)) {
        g.apply('hero', ActionType.call);
        continue;
      }
      final bet = legal.where((a) => a.type == ActionType.bet).firstOrNull;
      if (bet == null) {
        aborted = true;
        break;
      }
      final frac = street == Street.river ? riverFrac : 0.66;
      final amount = (g.potTotal() * frac).round();
      g.apply('hero', ActionType.bet,
          amount: amount.clamp(bet.minAmount, bet.maxAmount));
    }
    if (aborted || !recorded) continue;
  }
  return st;
}

void main(List<String> args) {
  final seeds = args.isNotEmpty ? int.parse(args[0]) : 600;
  final scenarios = <String, String>{
    '干燥 Kd8c3h5s9d': 'Kd 8c 3h 5s 9d',
    '湿润 QhJh4c9h2d': 'Qh Jh 4c 9h 2d',
    '配对面 Ah8h8c2d7s': 'Ah 8h 8c 2d 7s',
  };
  const fracs = [0.5, 0.66, 1.0, 1.5];
  for (final sc in scenarios.entries) {
    print('== ${sc.key} ==');
    for (final frac in fracs) {
      final st = _run(sc.value, frac, seeds);
      if (st.total == 0) {
        print('  ${frac.toStringAsFixed(2)} 池  （无样本）');
        continue;
      }
      final foldPct = 100 * st.fold / st.total;
      final needPct = 100 * st.needSum / st.total;
      final tiers = st.tierAll.keys.toList()..sort();
      print('  ${frac.toStringAsFixed(2).padLeft(4)} 池 '
          '（实际 ${(st.fracSum / st.total * 100).toStringAsFixed(0)}%）  '
          '弃 ${foldPct.toStringAsFixed(0).padLeft(3)}%  '
          '跟 ${(100 * st.call / st.total).toStringAsFixed(0).padLeft(3)}%  '
          '加 ${(100 * st.raised / st.total).toStringAsFixed(0).padLeft(3)}%  '
          '| 保本线 ${needPct.toStringAsFixed(0).padLeft(3)}%  '
          '${foldPct > needPct + 5 ? '★可被任意两张白抢 +${(foldPct - needPct).toStringAsFixed(0)}pt' : 'OK'}'
          '  | n=${st.total} 平均池 ${st.potSum ~/ st.total}');
      print('        ${tiers.map((t) => '$t ${st.tierAll[t]}'
          '（弃 ${st.tierFold[t] ?? 0}）').join(' / ')}');
    }
    print('');
  }
}
