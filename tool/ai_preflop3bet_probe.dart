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

/// 8 人桌、AI 钉死在按钮位，量它面对「前面已经溜进来 [limpers] 家」时怎么打。
///
/// 桌子大小、座位、底池里的人数全都固定，只让「已经进池的家数」这一维动。
/// 这一点是必须的：要是靠改桌子人数来造溜入（早先那个临时脚本就是这么干的），
/// [_Spot] 里的 opponents 和位置会跟着一起变，量出来的差里混着「人多人少」，
/// 根本读不出溜入家数这一维——量法本身是假的，数字再整齐也不算数。
({Map<String, int> act, List<int> sizes, int n}) probeLimpers({
  required String hole,
  int limpers = 2,
  AiStyle style = AiStyle.tightAggressive,
  int seeds = 300,
}) {
  final act = <String, int>{};
  final sizes = <int>[];
  var n = 0;
  for (var seed = 0; seed < probeSeeds(seeds); seed++) {
    final rnd = Random(seed);
    final g = GameEngine(random: rnd)..addPlayer('ai', 'AI');
    final ai = AiPlayer(style, random: rnd);
    for (var i = 0; i < 7; i++) {
      g.addPlayer('p$i', 'P$i');
    }
    // players[0] 是 AI，buttonIndex 从 7 推到 0 → AI 坐按钮。8 人桌里
    // 按钮前面有 5 家（翻前顺序 3,4,5,6,7,0(我),1,2），够铺 0~4 家溜入。
    g.buttonIndex = 7;
    g.startHand(holeOverride: {'ai': cs(hole)});
    var guard = 0;
    var acted = 0;
    while (!g.handOver && guard++ < 80) {
      final p = g.pendingAction();
      final legal = p.actions;
      final facing = legal.any((a) => a.type == ActionType.call);
      if (p.player.id == 'ai') {
        final d = ai.decide(g, p.player);
        if (g.street == Street.preflop) {
          final key = switch (d.type) {
            ActionType.raise => '加注',
            ActionType.call => '跟注',
            ActionType.check => '过牌',
            _ => '弃牌',
          };
          act[key] = (act[key] ?? 0) + 1;
          if (d.type == ActionType.raise && d.amountTo != null) {
            sizes.add(d.amountTo!);
          }
          n++;
          break;
        }
        g.apply('ai', d.type, amount: d.amountTo);
        continue;
      }
      // 前面按顺序：前 [limpers] 家补齐进池，其余的弃牌——把「已经进来几家」
      // 钉死，不让 AI 面对的底池形状随手牌随机漂。
      final want = acted < limpers
          ? (facing ? ActionType.call : ActionType.check)
          : (legal.any((a) => a.type == ActionType.fold)
              ? ActionType.fold
              : ActionType.check);
      g.apply(p.player.id, want);
      acted++;
    }
  }
  return (act: act, sizes: sizes, n: n);
}

String _pct(int v, int n) => n == 0 ? '-' : '${(100 * v / n).round()}%';


/// 带一位小数的百分比：轻 4bet 这一档的频率低到两三个点，整数百分比在这条
/// 尾巴上分不开（4.3% 和 4.1% 都印成「4%」），坡度就看不见了。
String _pct1(int v, int n) =>
    n == 0 ? '-' : '${(100 * v / n).toStringAsFixed(1)}%';

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

  // 第四节：轻 4bet（A5s~A2s 这种没有摊牌价值、全靠阻断牌压回去的牌）
  // 的频率也得跟着 3bet 的价格走。
  //
  // 以前这一档是个跟价格无关的常数（`_p.lightThreeBet * 2.5`），实测 A5s
  // 对着 4.7 / 7.0 / 9.0 / 14.0bb 一律「加注 28%」——9bb 和 14bb 那两行连
  // 弃牌率都逐字相同。对手把 3bet 加到 14bb 就能稳定地拿 AA/KK 收下两成八
  // 个 30bb 的 4bet。
  //
  // 只补「贵了要收」还不够：收完之后 10bb 以下那一整段又成了新的常数区间
  // （实测 4.7 / 6.2 / 8.0 / 10.0bb 一律 28%，三种风格全一样）。可 4.7bb
  // 那档 4bet 出去只要投十几个 bb、14bb 那档要投三十个，「贵了要收」的理由
  // 在便宜那头是反过来成立的——压回去的成本越低越该压。所以现在便宜侧也铺
  // 了斜坡：拿离上限的余量按便宜程度补，紧凶 4.7bb 补到约 35%，松凶本来就
  // 在 55%（超过上限、余量为负），一个点不动。
  //
  // 点位在 [4.7, 10.0]bb 这一段故意排得比贵侧密：两处斜坡的接头都在 10bb
  // 附近，台阶最容易藏在那里，扫稀了看不出来。
  //
  // 但「贵了要收」收完也还是留了一段平台：14bb 收到基频的两成之后，价格
  // 再往上涨这个两成就不动了，实测 14 / 16 / 18 / 20bb 四行逐字相同的
  // 「加注 6%」（松凶 164/1500，也是逐字相同）。对手把 3bet 从 14bb 抬到
  // 20bb，我们 4bet 出去要投的筹码从三十个涨到五十几个、敢这么加的范围又
  // 硬得多，两头的期望一起往下走，频率却一个点不动。现在贵那侧接着收
  // （倒数衰减，见 AiPlayer 里 `lightExpensiveRamp`），20bb 收到六成、
  // 22bb 收到一半，一路往零收但收不到零。
  //
  // 这一节的样本提到 1200、百分比印一位小数：留下来的频率只有两三个点，
  // 400 手在这条尾巴上的噪声就有 ±1%（打印又是整数百分比），4.3% 和 4.1%
  // 会一起印成「4%」——量法本身把坡度抹平了，跟真的平台分不出来。
  print('== 轻 4bet（A5s）的频率随 3bet 价格下降（${seatLabel[rel]}开池）==');
  for (final sb in [
    470, 500, 560, 620, 700, 800, 900, 1000,
    1100, 1200, 1400, 1600, 1800, 2000, 2200, 2600,
  ]) {
    final r = probe(hole: 'Ah 5h', rel: rel, threeBet: sb, seeds: 1200);
    print('  3bet ${(sb / 100).toStringAsFixed(1)}bb   '
        '加注 ${_pct1(r.facing['加注'] ?? 0, r.n)}  '
        '跟注 ${_pct1(r.facing['跟注'] ?? 0, r.n)}  '
        '弃牌 ${_pct1(r.facing['弃牌'] ?? 0, r.n)}  n=${r.n}');
  }

  // 第五节：溜入家数。
  //
  // 这一节是「先修量法」的产物。早先有个临时脚本靠改**桌子人数**来造溜入，
  // 量出来「1/2/3/4 家溜入」下 87o 的加注率是 100/100/10/0，看着像一道硬
  // 台阶——可那个脚本里 AI 翻前其实是**先行动**的那一个（buttonIndex 推完
  // 落在自己头上，8 人桌的翻前顺序是 3,4,…,7,0(我),1,2），limp`ers 恒为 0，
  // 跟着变的只有桌子大小和位置。这里把桌子钉死 8 人、AI 钉死按钮，只让
  // 「已经溜进来几家」这一维动。
  //
  // 改前读数（600 手一格，桌子大小/座位固定）：整个维度是死的——6 手牌 ×
  // 两种风格，1 家 / 2 家 / 3 家 / 4 家溜入的动作**逐字相同**。55 / A5s 一律
  // 「加 41% / 补齐 59%」（松凶 62/38）；87o 从 1 家起就只剩「加 10% / 跟 12%
  // / 弃 79%」，2 家往后弃 100%；A8o / 99 / KQo 一律加 100%。加注**尺度**倒是
  // 活的（3.5 → 4.6 → 5.6 → 6.6bb），也就是说这批牌对人数唯一的反应是
  // 「加得更大」。
  //
  // 修法（两处，都是「锚点不动、往上铺」）：非同花开池范围那道布尔台阶
  // （`shiftedOffsuit(limpers >= 2 ? 2 : 1)`）换成按人数一档一档收、4 档封顶；
  // 两家以上再开一档中间档溜入表（PreflopRanges.limpMid：标准表 + 非同花连张
  // / 非同花大牌 / 弱 A），里面那批牌只**按比例**进来（AiPlayer 里的 midMix，
  // 0.45 起、随人数往上）——整档放开只是把台阶从「一律弃」挪成「一律补」，
  // 读起来还是一句话。
  //
  // 改后读数：87o 紧凶补齐 12% → 42% → 57% → 69%（1 → 4 家），松凶
  // 「加 63%/补 37%」→「加 63%/补 37%」→「加 14%/补 53%/弃 33%」→
  // 「补 69%/弃 31%」；A8o 紧凶 加 100/100/100 → 4 家「加 21%/补 56%/弃 23%」；
  // KQo 紧凶 加 100/100 → 3 家「加 21%/补 46%/弃 33%」→ 4 家「补 69%/弃 31%」。
  //
  // 还僵着两处，都留在这儿当下一轮的靶子：
  //   · 55 / A5s 的「加还是补」比例对人数仍然不敏感（1~4 家一律 41/59）——这是
  //     用例「翻前：面对溜入者，后位用边缘牌跟着溜入」故意的地板（7~8 家仍要
  //     > 25% 加注，不然「他补齐 = 他没牌」又成了新的破译点）。锚点 41% 加
  //     地板 25%，整条坡度最多十五个点；实测 0.05 的斜率就把 8 家压到 24% 报红，
  //     收到 0.03 只剩 41 → 37，落在项目自己划的噪声带里，所以没做。
  //   · 松凶那半边 87o 的 1 家与 2 家仍然相同：对它来说 87o 不是范围边界手
  //     （边界在 76o/65o 那一层），要看见得换手牌量。
  print('== 溜入家数：8 人桌 AI 按钮位，只有「已溜入几家」在变 ==');
  for (final style in [AiStyle.tightAggressive, AiStyle.looseAggressive]) {
    print('-- ${style.label} --');
    for (final hole in ['8h 7d', '5h 5d', 'Ah 5h', 'Ah 8d', '9h 9d', 'Kh Qs']) {
      final parts = <String>[];
      for (final k in [0, 1, 2, 3, 4]) {
        final r = probeLimpers(hole: hole, limpers: k, style: style, seeds: 600);
        final avgBb = r.sizes.isEmpty
            ? '-'
            : (r.sizes.reduce((a, b) => a + b) / r.sizes.length / 100)
                .toStringAsFixed(1);
        parts.add('$k家 加${_pct(r.act['加注'] ?? 0, r.n)}'
            '(${avgBb}bb) '
            '跟${_pct(r.act['跟注'] ?? 0, r.n)} '
            '弃${_pct(r.act['弃牌'] ?? 0, r.n)}');
      }
      print('  ${hole.padRight(8)} ${parts.join('  |  ')}');
    }
  }
}
