import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用例分片开关：`TEST_SHARD=k/n` 时本进程只跑「第 k 片」的用例。
///
/// 给单体用例文件用的：`engine_test.dart` 有 96 条用例、其中 80 条要重放几百手
/// AI 牌局，占掉整套回归一半以上的墙钟，而 flutter test 只按**文件**并行、拆不开
/// 它。用例之间没有任何共享状态（各自建引擎、各自的随机种子），所以分片只是换个
/// 「谁来跑哪条」：跑到的用例跟整跑逐条一致（对拍过 96 条，无丢失无重复），任意
/// 一片失败整体就失败。不设这个变量 = 整跑，行为跟以前完全一样。
///
/// 想分片的用例文件：`import 'support/test_shard.dart';`，然后把 `test(` 换成
/// `t(`。导入这个文件就是「我支持分片」的声明——离线 runner 只对导入它的文件拆片。
final (int, int) _shard = () {
  final bits = (Platform.environment['TEST_SHARD'] ?? '').split('/');
  if (bits.length != 2) return (-1, 1);
  return (int.tryParse(bits[0]) ?? -1, int.tryParse(bits[1]) ?? 1);
}();

/// 按**声明顺序**轮转分配，不用哈希：单体文件里重量级的用例往往连续一大段
/// （engine_test 里是第 16~50 条），按名字哈希只会均分条数、均不了耗时——实测
/// 有一片抽到 5 秒、另两片各 2 秒。轮转会把连续的重用例摊到每片。
///
/// 序号在每条 t() 上都自增，跟这条用例注不注册无关，所以各进程算出来一致。
var _testIndex = 0;

/// 快速档开关：`TEST_FAST=1` 时只跑标了 [fast] 的结构性冒烟用例，其余标记为跳过。
///
/// 为什么不用「缩样本」做快速档：那些比例类断言（「加注率 > 0.4」之类）的余量
/// 本来就是按全量样本留的，样本砍一半噪声涨 1.4 倍，会稳定地假失败几条——一个
/// 必然报红的快速档等于没有。改成「只跑冒烟」之后它快且可信：跑得起来的用例
/// 一定真的跑过，跳过的会明确报成 skipped（输出里的 `~N`）。
final bool _fast = Platform.environment['TEST_FAST'] == '1';

/// 单条过滤：`TEST_ONLY=河牌` 时只注册名字里含这个子串的用例。
///
/// 用途是「改哪条就试哪条」：全量回归的墙钟下限是「编译 2.5 秒 + 重放 5 秒」，
/// 而单条用例通常 1 秒内就出结果。设了它就不再分片（分片是为了摊全量），
/// 只跑命中的那几条——所以它跟 TEST_FAST 一样，**不是**回归门禁，
/// 只能用来确认「我改的这条是活的」，别拿它当「全部没坏」。
final String _only = Platform.environment['TEST_ONLY'] ?? '';

/// `test()` 的分片版本：不属于本片的用例直接不注册；不设 TEST_SHARD 时等价于
/// `test()`。[fast] 标记「这条在快速档里也跑」——只有不需要重放牌局的结构性
/// 用例（发牌、牌型评估、存档、标题）才该标它。
void t(String name, dynamic Function() body, {bool fast = false}) {
  final index = _testIndex++;
  if (_only.isNotEmpty && !name.contains(_only)) return;
  final (shard, total) = _only.isEmpty ? _shard : (-1, 1);
  if (_fast && !fast) {
    test(name, body, skip: '--fast 档只跑结构性冒烟用例');
    return;
  }
  if (shard < 0 || total <= 1 || index % total == shard) test(name, body);
}
