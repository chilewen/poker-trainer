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
//
// 但保本线不是硬指标，它默认对手是个「只要没人下注就一定开火」的疯子。
// 真人不会这么打，我们对真人的范围也是按「连开三枪 = 真东西更多」收窄的，
// 所以下面三种情况刻意让开、Star 不用管：
//   * 对手连开三枪的大注（3/4 池往上）——「第二对面对连开三枪要尊重」；
//   * 一个满池起的大注——「底对面对一个底池的大注照样弃」；
//   * 超池——两极化的线，不硬接。
// 这三条都有 engine_test 的用例钉着，这里量的是「小注有没有被白抢」。
//
// 每个牌面还会多打一张「沿街筛选」表：AI 在翻牌、转牌面对开火时手里是什么
// 档、弃掉多少。河牌的防守范围不是凭空来的，它是前两条街一路筛出来的结果；
// 这张表用来看「是哪一条街把弱牌放进了河牌」——只有小注那档被白抢，才值得
// 去动前两条街；如果弱牌在前两条街已经被筛得很干净，那问题就不在范围构造上。
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
  /// 沿街筛选：翻牌/转牌「面对开火时手里是什么档、有没有继续」。
  /// 键是 "<街>:<档>"，只记到 AI 真的要做决定的那一手为止——上一街弃掉的
  /// 手不会出现在下一街，所以这组数字直接就是 AI 跟注范围的收窄过程。
  final Map<String, int> streetSeen = {};
  final Map<String, int> streetFold = {};
  final Map<String, int> streetRaise = {};
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
        final key = '${street.name}:'
            '${HandReading.of(p.player.holeCards, g.board).tier.name}';
        st.streetSeen[key] = (st.streetSeen[key] ?? 0) + 1;
        final d = ai.decide(g, p.player);
        if (d.type != ActionType.call) {
          // 加注和弃牌要分开记：把加注混进「弃」里，怪兽牌看上去就像在
          // 弃牌（它们全是加注），整张表就废了。
          if (d.type == ActionType.fold) {
            st.streetFold[key] = (st.streetFold[key] ?? 0) + 1;
          } else {
            st.streetRaise[key] = (st.streetRaise[key] ?? 0) + 1;
          }
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
  const funnelFrac = 0.66; // 「沿街筛选」那张表用哪个尺度看
  for (final sc in scenarios.entries) {
    print('== ${sc.key} ==');
    _Stats? funnel;
    for (final frac in fracs) {
      final st = _run(sc.value, frac, seeds);
      if (frac == funnelFrac) funnel = st;
      if (st.total == 0) {
        print('  ${frac.toStringAsFixed(2)} 池  （无样本）');
        continue;
      }
      final foldPct = 100 * st.fold / st.total;
      final needPct = 100 * st.needSum / st.total;
      final tiers = st.tierAll.keys.toList()..sort();
      // 样本太小时那几个百分数是噪声（「连开三枪 + 跟注两条街」这条线很窄，
      // 默认手数下常常只剩个位数手），别让人把它读成结论：40 手以下只报
      // 档位构成，不判「能不能被白抢」。要看准数字就给脚本传手数：
      //   dart tool/ai_river_defense_probe.dart 12000
      final enough = st.total >= 40;
      final verdict = !enough
          ? '~样本少'
          : (foldPct > needPct + 5
              ? '★可被任意两张白抢 +${(foldPct - needPct).toStringAsFixed(0)}pt'
              : 'OK');
      print('  ${frac.toStringAsFixed(2).padLeft(4)} 池 '
          '（实际 ${(st.fracSum / st.total * 100).toStringAsFixed(0)}%）  '
          '弃 ${foldPct.toStringAsFixed(0).padLeft(3)}%  '
          '跟 ${(100 * st.call / st.total).toStringAsFixed(0).padLeft(3)}%  '
          '加 ${(100 * st.raised / st.total).toStringAsFixed(0).padLeft(3)}%  '
          '| 保本线 ${needPct.toStringAsFixed(0).padLeft(3)}%  '
          '$verdict'
          '  | n=${st.total} 平均池 ${st.potSum ~/ st.total}');
      print('        ${tiers.map((t) => '$t ${st.tierAll[t]}'
          '（弃 ${st.tierFold[t] ?? 0}）').join(' / ')}');
    }
    if (funnel != null) _printFunnel(funnel);
    print('');
  }
}

/// 把「翻牌 → 转牌 → 河牌」这条线上 AI 手里的档位构成和被筛掉的数量打出来。
///
/// 河牌那份防守范围不是凭空来的：它是翻牌、转牌一路跟注筛出来的结果。
/// 如果翻牌就把一堆弱成牌放行，河牌能用来防守的就只剩弱牌，MDF 想守也守不住
/// （只能拿弱牌去凑频率）。这张表就是用来定位「是哪一条街把弱牌放进来的」。
void _printFunnel(_Stats st) {
  print('  -- 沿街筛选（2/3 池那条线，n 是走到这一街、面对开火的手数）--');
  for (final street in ['flop', 'turn']) {
    final keys = st.streetSeen.keys.where((k) => k.startsWith('$street:')).toList()
      ..sort();
    if (keys.isEmpty) continue;
    final parts = keys.map((k) {
      final tier = k.split(':')[1];
      final seen = st.streetSeen[k]!;
      final folded = st.streetFold[k] ?? 0;
      final raised = st.streetRaise[k] ?? 0;
      final tail = raised > 0 ? '，加 ${(100 * raised / seen).round()}%' : '';
      return '$tier $seen（弃 ${(100 * folded / seen).round()}%$tail）';
    }).join(' / ');
    print('     ${street == 'flop' ? '翻牌' : '转牌'} $parts');
  }
}
