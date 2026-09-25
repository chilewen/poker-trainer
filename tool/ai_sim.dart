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
  // 面对下注（翻后）时的动作，按「有没有位置」拆开：真人没位置时明显
  // 更少漂浮、更少薄跟，这一格就是用来盯这个差别的。
  final Map<AiStyle, int> faceIp = {};
  final Map<AiStyle, int> faceOop = {};
  final Map<AiStyle, int> faceIpCall = {};
  final Map<AiStyle, int> faceOopCall = {};
  final Map<AiStyle, int> faceIpFold = {};
  final Map<AiStyle, int> faceOopFold = {};
  // 上面那四格把「面对下注」和「面对加注」混在一起，看不出跟注站最标志性的
  // 那一面：一手小对陪你三条街的黏是**对着下注**的，对面加注出来连他们也会
  // 收手（见 ai_player 里 callSlack 的说明）。所以再拆出一档：对面这条街已经
  // 有人加注过的那些决策。剩下的（faceIp/faceOop 减去这档）就是纯面对下注。
  final Map<AiStyle, int> faceIpRaise = {};
  final Map<AiStyle, int> faceOopRaise = {};
  final Map<AiStyle, int> faceIpRaiseCall = {};
  final Map<AiStyle, int> faceOopRaiseCall = {};
  final Map<AiStyle, int> faceIpRaiseFold = {};
  final Map<AiStyle, int> faceOopRaiseFold = {};

  void bump(Map<AiStyle, int> m, AiStyle s) => m[s] = (m[s] ?? 0) + 1;

  static String _ratio(Map<AiStyle, int> a, Map<AiStyle, int> b, AiStyle s) {
    final d = b[s] ?? 0;
    if (d == 0) return '-';
    return '${(100 * (a[s] ?? 0) / d).toStringAsFixed(0)}%';
  }

  static String header() => '  ${''.padRight(18)}${_cells((s) => s.label)}';

  String pctLine(String label, Map<AiStyle, int> m, Map<AiStyle, int> denom) =>
      '  ${label.padRight(18)}${_cells((s) => _ratio(m, denom, s))}';

  String countLine(String label, Map<AiStyle, int> m) =>
      '  ${label.padRight(18)}${_cells((s) => '${m[s] ?? 0}')}';

  static String _cells(String Function(AiStyle) render) {
    final buf = StringBuffer();
    for (final s in AiStyle.values) {
      buf.write(render(s).padLeft(9));
    }
    return buf.toString();
  }
}

/// 和 ai_player 里同一套判断：后面还有没有活人（没活人 = 有位置）。
bool _inPosition(GameEngine game, PlayerState me) {
  final n = game.players.length;
  final rel = (game.players.indexOf(me) - game.buttonIndex + n) % n;
  final myOrder = rel == 0 ? n : rel;
  for (var i = 0; i < n; i++) {
    final other = game.players[i];
    if (other.id == me.id || other.folded) continue;
    final otherRel = (i - game.buttonIndex + n) % n;
    if ((otherRel == 0 ? n : otherRel) > myOrder) return false;
  }
  return true;
}

List<Card> _boardAt(List<Card> board, Street s) => switch (s) {
      Street.preflop => const [],
      Street.flop => board.take(3).toList(),
      Street.turn => board.take(4).toList(),
      _ => board.take(5).toList(),
    };

/// 用法：dart tool/ai_sim.dart [手数] [随机种子]
///
/// 种子可换是关键：整个模拟共用一条随机流，任何一处多掷一次随机数都会
/// 把后面所有决策重新洗一遍。只跑一个种子的话，「改前改后」的差别里
/// 分不清哪些是策略变化、哪些只是随机重排，所以要比就多换几个种子看均值。
void main(List<String> args) {
  final total = args.isEmpty ? 800 : int.tryParse(args[0]) ?? 800;
  final seed = args.length > 1 ? int.tryParse(args[1]) ?? 42 : 42;
  final rnd = Random(seed);
  final g = GameEngine(random: rnd);
  final ais = <String, AiPlayer>{};
  final styles = <String, AiStyle>{};
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
    styles[id] = style;
  }

  final st = _Stats();
  var showdowns = 0;
  var potSum = 0;
  var biggestPot = 0;
  var raiseWars = 0;
  var sawFlopSum = 0;
  var flopDealt = 0; // 真发到翻牌的牌局数
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
    // 这条街到现在为止有没有人加过注（用来把「面对下注」和「面对加注」分开）。
    final raiseSeen = <Street, bool>{};
    while (!g.handOver && guard++ < 600) {
      final p = g.pendingAction();
      final facingBet =
          g.street != Street.preflop && g.currentBet > p.player.streetBet;
      final vsRaise = facingBet && (raiseSeen[g.street] ?? false);
      final styleNow = styles[p.player.id]!;
      final ip = facingBet ? _inPosition(g, p.player) : false;
      final d = ais[p.player.id]!.decide(g, p.player);
      if (facingBet) {
        st.bump(ip ? st.faceIp : st.faceOop, styleNow);
        if (vsRaise) st.bump(ip ? st.faceIpRaise : st.faceOopRaise, styleNow);
        if (d.type == ActionType.call) {
          st.bump(ip ? st.faceIpCall : st.faceOopCall, styleNow);
          if (vsRaise) {
            st.bump(ip ? st.faceIpRaiseCall : st.faceOopRaiseCall, styleNow);
          }
        } else if (d.type == ActionType.fold) {
          st.bump(ip ? st.faceIpFold : st.faceOopFold, styleNow);
          if (vsRaise) {
            st.bump(ip ? st.faceIpRaiseFold : st.faceOopRaiseFold, styleNow);
          }
        }
      }
      if (d.type == ActionType.raise) raiseSeen[g.street] = true;
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
    //
    // 翻前就结束的牌局（所有人弃到盲注）**没有翻牌可看**，不能算成「1 个人
    // 看了翻牌」——以前直接拿 `人数 - 翻前弃牌数` 平均，这些牌局各自贡献一个
    // 1，把平均值从 2.6 压到 2.2，读起来像是牌桌偏紧。分开报：一个「只看
    // 真发到翻牌的那些牌局」的平均（玩家在牌桌上实际感受到的「几个人看
    // 翻牌」），另一个是「所有牌局摊下来」的口径（跟线上统计的 Saw Flop
    // 对齐，翻前结束的牌局记 0）。
    final foldedPre = <String>{};
    for (final a in hand.actions) {
      if (a.street != Street.preflop) break;
      if (a.type == ActionType.fold) foldedPre.add(a.actorId);
    }
    final flopPlayers =
        hand.board.isEmpty ? 0 : g.players.length - foldedPre.length;

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
    if (hand.board.isNotEmpty) flopDealt++;
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
  final perFlop = flopDealt == 0 ? 0.0 : sawFlopSum / flopDealt;
  print('平均看翻牌人数: ${(sawFlopSum / total).toStringAsFixed(2)}'
      '（全部牌局摊平）  |  发到翻牌的牌局 ${(100 * flopDealt / total).round()}%，'
      '其中平均 ${perFlop.toStringAsFixed(2)} 人看翻牌');
  print('打到摊牌: $showdowns (${(100 * showdowns / total).toStringAsFixed(0)}%)');
  print('有人全下的牌局: $allInHands');
  print('平均底池: ${potSum ~/ total}  最大底池: $biggestPot');
  print('翻后单街 >=3 次加注: $raiseWars');
  print('结束街: ${endStreet.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}');
  print('');
  print('=== 按风格 ===${_Stats.header()}');
  print(st.pctLine('翻前 弃牌率', st.preFold, st.preDecisions));
  print(st.pctLine('翻前 跟注/溜入率', st.preLimp, st.preDecisions));
  print(st.pctLine('翻前 加注率', st.preRaise, st.preDecisions));
  print(st.pctLine('翻后 弃牌率', st.postFold, st.postDecisions));
  print(st.pctLine('翻后 跟注率', st.postCall, st.postDecisions));
  print(st.countLine('翻后 下注次数', st.postBet));
  print(st.countLine('翻后 加注次数', st.postRaise));
  print(st.countLine('面对注(有位置)', st.faceIp));
  print(st.pctLine('  其中 跟注', st.faceIpCall, st.faceIp));
  print(st.pctLine('  其中 弃牌', st.faceIpFold, st.faceIp));
  print(st.countLine('面对注(没位置)', st.faceOop));
  print(st.pctLine('  其中 跟注', st.faceOopCall, st.faceOop));
  print(st.pctLine('  其中 弃牌', st.faceOopFold, st.faceOop));
  // 拆出「对面这条街已经加过注」那一档：faceXxx 减去它就是纯面对下注。
  Map<AiStyle, int> minus(Map<AiStyle, int> a, Map<AiStyle, int> b) =>
      {for (final s in AiStyle.values) s: (a[s] ?? 0) - (b[s] ?? 0)};
  void faceSplit(String label, Map<AiStyle, int> total, Map<AiStyle, int> raiseN,
      Map<AiStyle, int> foldN, Map<AiStyle, int> raiseFoldN) {
    print(st.pctLine('面对下注$label 弃牌', minus(foldN, raiseFoldN),
        minus(total, raiseN)));
    print(st.pctLine('面对加注$label 弃牌', raiseFoldN, raiseN));
  }

  faceSplit('(有位置)', st.faceIp, st.faceIpRaise, st.faceIpFold,
      st.faceIpRaiseFold);
  faceSplit('(没位置)', st.faceOop, st.faceOopRaise, st.faceOopFold,
      st.faceOopRaiseFold);
  print(st.pctLine('翻牌 c-bet 率', st.cbets, st.cbetChances));
  print(st.countLine('翻牌听牌次数', st.flopDraws));
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
