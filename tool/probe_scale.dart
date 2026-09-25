// 探针的「加速档」，tool/ 下几个探针共用。
//
//   PROBE_SEEDS_SCALE=0.25 dart run tool/ai_probe.dart
//
// 默认 1.0，输出跟以前一模一样。缩样本只够用来「改完快速看一眼有没有跑不
// 起来 / 结构性错误」：300 手抽到 ±6% 的抖动很正常，比例类结论必须跑全量。
import 'dart:io';
import 'dart:math';

final double probeSeedScale =
    double.tryParse(Platform.environment['PROBE_SEEDS_SCALE'] ?? '') ?? 1.0;

/// 按 PROBE_SEEDS_SCALE 缩放样本数；下限 15 手，免得小格子被抽成空样本。
int probeSeeds(int seeds) => probeSeedScale >= 1
    ? seeds
    : max(15, (seeds * probeSeedScale).round());

/// 并行分片：PROBE_SHARD=k/n 时只跑「哈希落在第 k 片」的用例。
///
/// 探针的每一格都是独立重放（自己的种子序列、自己的牌局），所以分片只改变
/// 「这一格谁来跑」，不改任何一格的结果：几片各自的输出按顺序拼起来，和整跑
/// 逐例一致，只是顺序按分片重排。
///
/// tool/regression.sh 用它把最重的 ai_probe 拆成 8 个进程并行
/// （整跑约 70s CPU → 墙钟 14s 上下，最重的那一片决定实际墙钟）。
/// 默认不设 = 整跑，行为跟以前完全一样。
final String _probeShard = Platform.environment['PROBE_SHARD'] ?? '';

int _parseShard(int part) {
  final bits = _probeShard.split('/');
  if (bits.length != 2) return part == 0 ? 0 : 1;
  return int.tryParse(bits[part]) ?? (part == 0 ? 0 : 1);
}

final int probeShardIndex = _parseShard(0);
final int probeShardTotal = _parseShard(1);

/// 分片键用自己算的 FNV-1a，不依赖 String.hashCode：哈希必须是**跨进程**
/// 确定的，否则几片各自算成不一样的分法，用例要么漏跑要么重跑。
bool probeShardMine(String key) {
  if (probeShardTotal <= 1) return true;
  var h = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return h % probeShardTotal == probeShardIndex;
}
