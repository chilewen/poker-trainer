// 听牌转诈唬探针：dart run tool/ai_draw_probe.dart
//
// 单挑，翻前由脚本让 AI（按钮）加注、英雄跟注，翻后英雄一路过牌、面对下注
// 就跟——把三条街的主动权全交给 AI，看它拿着各种听牌是怎么打完整手的：
//   · 翻牌/转牌有没有开枪（半诈唬）
//   · 河牌错过了听牌之后，还开不开第三枪（听牌转诈唬最容易被漏掉的一步）
// 对照同一张牌面上的「纯空气」，看 AI 有没有真的把听牌当牌打。
// ignore_for_file: avoid_print
import 'dart:math';

import 'probe_scale.dart';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';

List<Card> cs(String s) => s.split(' ').map(Card.parse).toList();

typedef Row = ({int bet, int check, int n});

class Stat {
  final Map<Street, Row> byStreet = {};
  int _bet(Street s) => byStreet[s]?.bet ?? 0;
  int _n(Street s) => byStreet[s]?.n ?? 0;

  void add(Street s, ActionType t) {
    final cur = byStreet[s] ?? (bet: 0, check: 0, n: 0);
    byStreet[s] = (
      bet: cur.bet + (t == ActionType.bet ? 1 : 0),
      check: cur.check + (t == ActionType.check ? 1 : 0),
      n: cur.n + 1,
    );
  }

  String pct(Street s) =>
      _n(s) == 0 ? '-' : '${(100 * _bet(s) / _n(s)).round()}%';
}

/// AI 在按钮位拿 [hole] 打完整手，英雄一路过牌/跟注。
Stat probe({
  required String hole,
  required String board,
  int seeds = 150,
  AiStyle style = AiStyle.tightAggressive,
}) {
  final stat = Stat();
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(
      config: const GameConfig(startingStack: 10000, smallBlind: 50, bigBlind: 100),
      random: rnd,
    );
    g.addPlayer('ai', 'AI');     // 按钮/小盲
    g.addPlayer('hero', 'Hero'); // 大盲
    g.startHand(
      holeOverride: {'ai': cs(hole), 'hero': cs('4c 3d')},
      boardOverride: cs(board),
    );
    // 翻前脚本：AI 开 300，英雄跟注——保证翻后是「AI 主动、英雄被动」的线。
    g.apply('ai', ActionType.raise, amount: 300);
    g.apply('hero', ActionType.call);
    final ai = AiPlayer(style, random: rnd);
    var guard = 0;
    while (!g.handOver && guard++ < 200) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = g.currentBet > p.player.streetBet;
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (g.street == Street.flop ||
            g.street == Street.turn ||
            g.street == Street.river) {
          stat.add(g.street, d.type);
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      final want = facing ? ActionType.call : ActionType.check;
      g.apply(p.player.id,
          legal.any((a) => a.type == want) ? want : ActionType.check);
    }
  }
  return stat;
}

void main() {
  const board = 'Kh 7h 2c 9s 3d'; // 河牌 3d 是空白牌
  void row(String name, String hole, {String b = board, AiStyle? style}) {
    final read = HandReading.of(cs(hole), cs(b));
    final s = probe(hole: hole, board: b, style: style ?? AiStyle.tightAggressive);
    print('${name.padRight(26)} ${hole.padRight(8)} '
        '[tier=${read.tier.name} outs=${read.drawOuts} blocker=${read.blockerScore.toStringAsFixed(2)}]');
    final label = {Street.flop: '翻牌', Street.turn: '转牌', Street.river: '河牌'};
    final parts = [
      for (final st in [Street.flop, Street.turn, Street.river])
        '${label[st]}开枪 ${s.pct(st).padLeft(3)}(n=${s.byStreet[st]?.n ?? 0})',
    ];
    print('  ${parts.join('  ')}');
  }

  print('== 同一张牌面（K♥7♥2♣9s3d）：错过听牌之后还开不开枪 ==');
  row('坚果花听（破）', 'Ah Jh');
  row('花听+卡顺（破）', 'Jh 10h');
  row('两头顺（破）', '9c 8c', b: '7d 6d 2s Ks 3h');
  row('卡顺（破）', '9c 8c', b: '7d 5d 2s Ks 3h');
  print('');
  print('== 对照：河牌这张是空气、没有听牌的牌 ==');
  row('纯空气（无阻断）', 'Qc 6d');
  row('空气+A阻断', 'Ac 6d');
  row('顶对（价值对照）', 'Kc Qd');
  print('');
  print('== 风格差异（同一手破花听）==');
  for (final st in AiStyle.values) {
    row('  ${st.name}', 'Ah Jh', style: st);
  }
}
