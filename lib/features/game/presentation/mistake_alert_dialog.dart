import 'package:flutter/material.dart';

import '../domain/hand_grade.dart';

/// 「这手打错了」提醒：说清哪儿错了、下次怎么改，点「继续」接着打。
///
/// 只在这手**输了**且**有失误**时弹（判定见 [mistakeAlertOf]）：赢着弹是噪音，
/// 输但没打错（被翻盘、被诈唬）也不该弹——那是结果不好，不是打法不好。
Future<void> showMistakeAlertDialog(
  BuildContext context,
  MistakeAlert alert,
) {
  return showDialog<void>(
    context: context,
    // 只留「继续」一个出口：这是教学提醒，不是让玩家做选择。
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.error_outline, size: 20, color: _alertRed),
          const SizedBox(width: 8),
          Expanded(child: Text('这手亏 ${alert.lost}，有失误')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${alert.mistake.street.label} · ${alert.mistake.kind.label}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(alert.mistake.detail),
          const SizedBox(height: 14),
          const Text('下次这样打', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(alert.mistake.kind.advice),
          if (alert.others > 0) ...[
            const SizedBox(height: 14),
            Text(
              '这手还有 ${alert.others} 处失误，本局结束后的总结里可以逐手看。',
              style: const TextStyle(fontSize: 12.5, color: Colors.black54),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('继续'),
        ),
      ],
    ),
  );
}

const _alertRed = Color(0xFFE5484E);

/// 复盘里的失误清单：一条失误一行「哪儿错了 + 下次怎么打」。
///
/// 牌桌上那个弹窗（[showMistakeAlertDialog]）一次只说最重的一条——正打着，
/// 说多了记不住。复盘不一样：这手已经结束了，玩家要的是把毛病一次看全，所以
/// 照单子摆出来，每条都把建议带上。
Future<void> showHandMistakesDialog(BuildContext context, HandGrade grade) {
  return _showMistakesDialog(
    context,
    title: '这手哪里打错了',
    items: [
      for (final m in grade.mistakes)
        _MistakeItem(
          title: '${m.street.label} · ${m.kind.label}',
          detail: m.detail,
          advice: m.kind.advice,
        ),
    ],
  );
}

/// 「本局打法」里那几类失误该怎么改：没有具体到某一手，只讲通例。
Future<void> showMistakeKindsDialog(
  BuildContext context,
  Iterable<MistakeKind> kinds,
) {
  return _showMistakesDialog(
    context,
    title: '这几类失误怎么改',
    items: [
      for (final k in kinds)
        _MistakeItem(title: k.label, detail: k.detail, advice: k.advice),
    ],
  );
}

/// 一条失误在清单里长什么样：标题（街 · 类型）、当时的情形、下次怎么打。
class _MistakeItem {
  const _MistakeItem({
    required this.title,
    required this.detail,
    required this.advice,
  });

  final String title;
  final String? detail;
  final String advice;
}

Future<void> _showMistakesDialog(
  BuildContext context, {
  required String title,
  required List<_MistakeItem> items,
}) {
  if (items.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(height: 22),
              _MistakeBlock(item: items[i]),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _MistakeBlock extends StatelessWidget {
  const _MistakeBlock({required this.item});

  final _MistakeItem item;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.title,
            style:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
        if (item.detail != null) ...[
          const SizedBox(height: 4),
          Text(item.detail!,
              style: const TextStyle(fontSize: 12.5, height: 1.4)),
        ],
        const SizedBox(height: 8),
        const Text('下次这样打',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
        const SizedBox(height: 4),
        Text(item.advice, style: const TextStyle(fontSize: 12.5, height: 1.4)),
      ],
    );
  }
}
