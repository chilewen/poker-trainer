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
