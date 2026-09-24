// AI 行为统计：dart tool/ai_sim.dart
// 用来观察电脑玩家打得像不像真人：翻前松紧、持续下注率、
// 听牌有没有主动半诈唬、河牌未成牌还敢不敢开火。
// ignore_for_file: avoid_print
import 'dart:math';

import 'package:poker_trainer/engine/card.dart';
import 'package:poker_trainer/engine/game.dart';
import 'package:poker_trainer/engine/types.dart';
import 'package:poker_trainer/features/game/domain/ai_player.dart';
import 'package:poker_trainer/features/game/domain/hand_strength.dart';

/// 按风格统计：分「决策数」与「事件数」，避免百分比分母混乱。
class _Stats {
  final Map<AiStyle, int> preDecisions = {};
  final Map<AiStyle, int> preFold = {};
  final Map<AiStyle, int> preLimp = {};
  final Map<AiStyle, int> preRaise = {};
  final Map<AiStyle, int> postDecisions = {};
  final Map<AiStyle, int> postBet = {};
  final Map<AiStyle, int> postRaise = {};
  final Map<AiStyle, int> postCall = {};
  final Map<AiStyle, int> postFold = {};
  final Map<AiStyle, int> flopDraws = {}; // 翻牌圈拿着 8+ outs 听牌
  final Map<AiStyle, int> flopDrawAggro = {}; // 其中主动下注/加注
  final Map<AiStyle, int> riverBustDraws = {}; // 河牌拿着未成牌听牌
  final Map<AiStyle, int> riverBustFire = {}; // 其中开火
  final Map<AiStyle, int> riverBustCheck = {}; // 其中没人下注时选择过牌
  final Map<AiStyle, int> riverBustGiveUp = {}; // 其中弃牌
  final Map<AiStyle, int> cbetChances = {};
  final Map<AiStyle, int> cbets = {};

  void bump(Map<AiStyle, int> m, AiStyle s) => m[s] = (m[s] ?? 0) + 1;

  static String _ratio(Map<AiStyle, int> a, Map<AiStyle, int> b, AiStyle s) {
    final d = b[s] ?? 0;
    if (d == 0) return '-';
    return '${(100 * (a[s] ?? 0) / d).toStringAsFixed(0)}%';
  }

  String pctLine(String label, Map<AiStyle, int> m, Map<AiStyle, int> denom) =>
      '  ${label.padRight(18)}'
      '${_ratio(m, denom, AiStyle.tightAggressive).padLeft(7)}'
      '${_ratio(m, denom, AiStyle.loosePassive).padLeft(9)}';

  String countLine(String label, Map<AiStyle, int> m) =>
      '  ${label.padRight(18)}'
      '${'${m[AiStyle.tightAggressive] ?? 0}'.padLeft(7)}'
      '${'${m[AiStyle.loosePassive] ?? 0}'.padLeft(9)}';
}

List<Card> _boardAt(List<Card> board, Street s) => switch (s) {
      Street.preflop => const [],
      Street.flop => board.take(3).toList(),
      Street.turn => board.take(4).toList(),
      _ => board.take(5).toList(),
    };

void main() {
  final rnd = Random(42);
  final g = GameEngine(random: rnd);
  final ais = <String, AiPlayer>{};
  final styles = <String, AiStyle>{};
  for (var i = 0; i < 9; i++) {
    final style = i.isEven ? AiStyle.tightAggressive : AiStyle.loosePassive;
    final id = 'ai$i';
    g.addPlayer(id, '${style.label}$i');
    ais[id] = AiPlayer(style, random: rnd);
    styles[id] = style;
  }

  const total = 800;
  final st = _Stats();
  var showdowns = 0;
  var potSum = 0;
  var biggestPot = 0;
  var raiseWars = 0;
  var sawFlopSum = 0;
  var allInHands = 0;
  final endStreet = <Street, int>{};
  final samples = <String>[];
  final warSamples = <String>[];
  final riverSamples = <String>[];

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
    // 真摊牌 = 结束时还有 2 人以上没弃牌（河牌圈全弃牌不算）。
    final liveAtEnd = g.players.where((p) => !p.folded).length;
    if (liveAtEnd >= 2) showdowns++;
    potSum += hand.finalPot;
    biggestPot = max(biggestPot, hand.finalPot);
    if (g.players.any((p) => p.allIn)) allInHands++;

    // 看翻牌人数：翻前结束还没弃牌的人数。
    final foldedPre = <String>{};
    for (final a in hand.actions) {
      if (a.street != Street.preflop) break;
      if (a.type == ActionType.fold) foldedPre.add(a.actorId);
    }
    final flopPlayers = g.players.length - foldedPre.length;

    // ---- 回看这手牌：统计每个动作背后的牌力 ----
    var preflopAggressor = '';
    final raiseCount = <Street, int>{};
    for (final a in hand.actions) {
      final style = styles[a.actorId];
      if (style == null) continue;
      final aggro = a.type == ActionType.bet || a.type == ActionType.raise;
      if (a.street == Street.preflop) {
        st.bump(st.preDecisions, style);
        switch (a.type) {
          case ActionType.fold:
            st.bump(st.preFold, style);
          case ActionType.raise:
            st.bump(st.preRaise, style);
            preflopAggressor = a.actorId;
          case ActionType.call:
            st.bump(st.preLimp, style);
          case ActionType.check:
          case ActionType.bet:
            break;
        }
        continue;
      }
      if (aggro) {
        raiseCount[a.street] = (raiseCount[a.street] ?? 0) + 1;
      }
      st.bump(st.postDecisions, style);
      if (a.type == ActionType.bet) {
        st.bump(st.postBet, style);
      } else if (a.type == ActionType.raise) {
        st.bump(st.postRaise, style);
      } else if (a.type == ActionType.call) {
        st.bump(st.postCall, style);
      } else if (a.type == ActionType.fold) {
        st.bump(st.postFold, style);
      }

      final hole = hand.holeCards[a.actorId]!;
      final read = HandReading.of(hole, _boardAt(hand.board, a.street));
      if (a.street == Street.flop && read.drawOuts >= 8) {
        st.bump(st.flopDraws, style);
        if (aggro) {
          st.bump(st.flopDrawAggro, style);
          if (samples.length < 5) {
            samples.add('${a.actorId} ${a.type.label} ${read.toString()}'
                ' | board ${_boardAt(hand.board, a.street).map((c) => c.pretty).join(' ')}'
                ' | hole ${hole.map((c) => c.pretty).join('')}');
          }
        }
      }
      if (a.street == Street.river) {
        final turnRead =
            HandReading.of(hole, _boardAt(hand.board, Street.turn));
        if (turnRead.hasDraw && read.tier == HandTier.junk) {
          st.bump(st.riverBustDraws, style);
          if (aggro) {
            st.bump(st.riverBustFire, style);
          } else if (a.type == ActionType.fold) {
            st.bump(st.riverBustGiveUp, style);
          } else if (a.type == ActionType.check) {
            st.bump(st.riverBustCheck, style);
          }
        }
      }
      if (a.street == Street.flop && a.actorId == preflopAggressor) {
        st.bump(st.cbetChances, style);
        if (aggro) st.bump(st.cbets, style);
      }
    }
    sawFlopSum += flopPlayers;
    for (final e in raiseCount.entries) {
      if (e.value >= 3) raiseWars++;
    }
    if (warSamples.length < 3 && raiseCount.values.any((v) => v >= 3)) {
      final buf = StringBuffer('board '
          '${hand.board.map((c) => c.pretty).join(' ')}');
      for (final a in hand.actions) {
        if (a.street == Street.preflop) continue;
        final hole = hand.holeCards[a.actorId]!;
        final boardHere = _boardAt(hand.board, a.street);
        final read = boardHere.length >= 3
            ? HandReading.of(hole, boardHere).toString()
            : '';
        buf.write('\n    ${a.street.name.padRight(8)} ${a.actorId}'
            ' ${a.type.label}${a.amount > 0 ? ' ${a.amount}' : ''}'
            '  [${hole.map((c) => c.pretty).join('')}] $read');
      }
      warSamples.add(buf.toString());
    }
    if (riverSamples.length < 3) {
      for (final a in hand.actions) {
        if (a.street != Street.river) continue;
        final style = styles[a.actorId];
        if (style == null) continue;
        final hole = hand.holeCards[a.actorId]!;
        final turnRead = HandReading.of(hole, _boardAt(hand.board, Street.turn));
        final riverRead = HandReading.of(hole, _boardAt(hand.board, Street.river));
        if (turnRead.hasDraw && riverRead.tier == HandTier.junk) {
          riverSamples.add('${a.actorId} 河牌 ${a.type.label}  '
              '转牌 ${turnRead.toString()}  河牌 ${riverRead.toString()}'
              '  | board ${hand.board.map((c) => c.pretty).join(' ')}'
              ' | hole ${hole.map((c) => c.pretty).join('')}');
          break;
        }
      }
    }
    endStreet[g.street] = (endStreet[g.street] ?? 0) + 1;
  }

  print('=== 电脑玩家 $total 手（9 人桌，50/100） ===');
  print('平均看翻牌人数: ${(sawFlopSum / total).toStringAsFixed(2)}');
  print('打到摊牌: $showdowns (${(100 * showdowns / total).toStringAsFixed(0)}%)');
  print('有人全下的牌局: $allInHands');
  print('平均底池: ${potSum ~/ total}  最大底池: $biggestPot');
  print('翻后单街 >=3 次加注: $raiseWars');
  print('结束街: ${endStreet.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}');
  print('');
  print('=== 按风格 ===            紧凶    松被动');
  print(st.pctLine('翻前 弃牌率', st.preFold, st.preDecisions));
  print(st.pctLine('翻前 跟注/溜入率', st.preLimp, st.preDecisions));
  print(st.pctLine('翻前 加注率', st.preRaise, st.preDecisions));
  print(st.pctLine('翻后 弃牌率', st.postFold, st.postDecisions));
  print(st.pctLine('翻后 跟注率', st.postCall, st.postDecisions));
  print(st.countLine('翻后 下注次数', st.postBet));
  print(st.countLine('翻后 加注次数', st.postRaise));
  print(st.pctLine('翻牌 c-bet 率', st.cbets, st.cbetChances));
  print(st.pctLine('翻牌 听牌开火率', st.flopDrawAggro, st.flopDraws));
  print(st.countLine('翻前 决策数', st.preDecisions));
  print(st.countLine('翻后 决策数', st.postDecisions));
  print(st.countLine('c-bet 机会/命中', st.cbetChances));
  print(st.countLine('c-bet 命中数', st.cbets));
  print(st.countLine('河牌 miss(全)', st.riverBustDraws));
  print(st.countLine('河牌 miss 没bet', st.riverBustCheck));
  print(st.countLine('河牌 miss bet', st.riverBustFire));
  print(st.countLine('河牌 miss 弃牌', st.riverBustGiveUp));
  print('');
  print('听牌半诈唬样例:');
  for (final s in samples) {
    print('  $s');
  }
  print('');
  print('听牌未成牌时河牌的处理样例:');
  for (final s in riverSamples) {
    print('  $s');
  }
  print('');
  print('加注战样例:');
  for (final s in warSamples) {
    print('  $s');
  }
}
