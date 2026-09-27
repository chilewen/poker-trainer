import 'package:flutter/material.dart';

import '../../../engine/hand_history.dart';
import '../domain/session_summary.dart';
import 'chip_format.dart';
import 'hand_review_sheet.dart';
import 'table_controller.dart';

// 和牌桌页同一套深色底：从牌桌直接切过来，不该像换了个 App。
const _bg = Color(0xFF0A0E11);
const _plate = Color(0xFF13191F);
const _cyan = Color(0xFF3AD0CC);
const _green = Color(0xFF7CC98B);
const _red = Color(0xFFE56B6B);
const _grey = Color(0xFF8A9299);
const _btnGreen = Color(0xFF57C36C);

/// 对局总结页：本局收手之后看这一页。
///
/// 只读 [SessionSummary]（数字怎么来的在控制器里），自己不认识控制器——
/// 这样「再来一局 / 返回大厅」就是两个回调，页面本身可以直接拿假数据测。
class SessionSummaryScreen extends StatelessWidget {
  const SessionSummaryScreen({
    super.key,
    required this.summary,
    required this.onPlayAgain,
    required this.onLeave,
  });

  final SessionSummary summary;

  /// 再来一局：同样的桌名、盲注、人数，重新开一桌。
  final VoidCallback onPlayAgain;

  /// 返回大厅。
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white70,
        elevation: 0,
        // 这一页是「局终」的终点，没有可回退的上级页面（牌桌已经收手了）。
        automaticallyImplyLeading: false,
        title: const Text('对局总结', style: TextStyle(fontSize: 16)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            _Headline(summary: summary),
            const SizedBox(height: 12),
            _Facts(summary: summary),
            const SizedBox(height: 12),
            _Breakdown(summary: summary),
            if (summary.hands.isNotEmpty) ...[
              const SizedBox(height: 12),
              _HandList(summary: summary),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: _btnGreen,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: onPlayAgain,
                      icon: const Icon(Icons.replay),
                      label: const Text('再来一局',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: onLeave,
                      child: const Text('返回大厅',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部大字：本局净输赢 + 一句结论。
class _Headline extends StatelessWidget {
  const _Headline({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final net = summary.heroNet;
    final color = net > 0 ? _green : (net < 0 ? _red : _grey);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        color: _plate,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Text(summary.label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _grey, fontSize: 12)),
          const SizedBox(height: 8),
          const Text('本局净输赢',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            '${net > 0 ? '+' : ''}${compactChips(net)}',
            style: TextStyle(
                fontSize: 34, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 6),
          Text(summary.verdict,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// 四格事实：手数 / 时长 / 补码 / 结束原因。
class _Facts extends StatelessWidget {
  const _Facts({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: _plate,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Fact(label: '打了几手', value: '${summary.handsPlayed} 手'),
              _Fact(label: '这局坐了', value: summary.durationText),
              _Fact(
                label: '补码',
                value: '${summary.rebuys}/${summary.maxRebuys} 次',
                strong: summary.rebuysExhausted,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Text('结束原因',
                    style: TextStyle(color: _grey, fontSize: 11.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    summary.endReason,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.strong = false});

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: _grey, fontSize: 11.5)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: strong ? _cyan : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 拆细：赢输手数、胜率、单手最好/最差。
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: _plate,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Fact(label: '赢', value: '${summary.handsWon} 手', strong: true),
              _Fact(label: '输', value: '${summary.handsLost} 手'),
              _Fact(label: '平', value: '${summary.handsTied} 手'),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Fact(
                label: '胜率',
                value: '${(summary.winRate * 100).round()}%',
              ),
              _Fact(
                label: '单手最好',
                value: signedChips(summary.bestHandNet),
                strong: true,
              ),
              _Fact(
                label: '单手最惨',
                value: signedChips(summary.worstHandNet),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Text('每手均盈亏',
                    style: TextStyle(color: _grey, fontSize: 11.5)),
                const SizedBox(width: 8),
                Text(
                  signedChips(summary.netPerHand),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: summary.netPerHand > 0
                        ? _green
                        : (summary.netPerHand < 0 ? _red : _grey),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 本局明细：列最近几手，点整块进逐手复盘。
///
/// 只列最近 5 手——总结页不是复盘页，够看出「这局是怎么走的」就行，
/// 想看全部就点「逐手复盘」，那边复用牌桌上的那个复盘面板。
class _HandList extends StatelessWidget {
  const _HandList({required this.summary});

  final SessionSummary summary;

  static const _shown = 5;

  @override
  Widget build(BuildContext context) {
    final hands = summary.hands.take(_shown).toList();
    return Container(
      decoration: BoxDecoration(
        color: _plate,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
            child: Row(
              children: [
                const Text('最近几手',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: () => showHandReviewSheet(
                      context, summary.hands, TableController.heroId),
                  child: const Text('逐手复盘'),
                ),
              ],
            ),
          ),
          for (var i = 0; i < hands.length; i++)
            _HandRow(
              hand: hands[i],
              // 手牌在 summary.hands 里是最新在前，所以序号要倒着数。
              handNo: summary.handsPlayed - i,
              best: (hands[i].netResult[TableController.heroId] ?? 0) ==
                      summary.bestHandNet &&
                  summary.bestHandNet > 0,
              worst: (hands[i].netResult[TableController.heroId] ?? 0) ==
                      summary.worstHandNet &&
                  summary.worstHandNet < 0,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _HandRow extends StatelessWidget {
  const _HandRow({
    required this.hand,
    required this.handNo,
    required this.best,
    required this.worst,
  });

  final HandHistory hand;
  final int handNo;
  final bool best;
  final bool worst;

  @override
  Widget build(BuildContext context) {
    final net = hand.netResult[TableController.heroId] ?? 0;
    final color = net > 0 ? _green : (net < 0 ? _red : _grey);
    final tag = best ? '最佳' : (worst ? '最惨' : null);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text('第 $handNo 手',
                style: const TextStyle(color: _grey, fontSize: 11.5)),
          ),
          Expanded(
            child: Text(
              _holeText(hand),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (tag != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: (best ? _cyan : _grey).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(tag,
                  style: TextStyle(
                      fontSize: 10,
                      color: best ? _cyan : _grey,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            signedChips(net),
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

/// 英雄那一手的底牌：`A♥ K♦`；没有记录时退回牌面张数（比如直接弃牌）。
String _holeText(HandHistory hand) {
  final hole = hand.holeCards[TableController.heroId];
  if (hole == null || hole.isEmpty) return '-';
  return hole.map((c) => c.pretty).join(' ');
}
