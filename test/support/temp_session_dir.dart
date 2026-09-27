import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/features/game/presentation/table_controller.dart';

/// 用例专用的临时存档目录：跑完自动删干净，不在 `$TMPDIR` 里留空壳。
///
/// 为什么不能只在 teardown 里 `dir.deleteSync(recursive: true)`：
/// [TableController] 每个动作都是 `unawaited(persistSession())`，teardown 把
/// 目录删掉之后那笔写才落地，而存档写入里的 `file.parent.create(recursive: true)`
/// 会把目录原样建回来——跑一轮回归就多留几个空壳（实测攒到过一千多个）。
/// 所以收尾按顺序来：
///
///   1. [TableController.dispose] 叫停这张桌（挂着的 AI 定时器作废，不然它们
///      醒来还会再排一次落盘）；
///   2. [TableController.flushWrites] 等已经排进写队列的跑完；
///   3. 删目录。
///
/// 建完目录之后，把用例里用到的每台控制器都用 [watch] 登记进来；别的一概不用管。
class TempSessionDir {
  TempSessionDir(String prefix)
      : dir = Directory.systemTemp.createTempSync(prefix) {
    addTearDown(() async {
      for (final t in _tables) {
        t.dispose();
      }
      for (final t in _tables) {
        await t.flushWrites();
      }
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
  }

  final Directory dir;

  final List<TableController> _tables = [];

  /// 把一台控制器纳入收尾；返回它本身，方便直接 `final t = tmp.watch(...)`。
  TableController watch(TableController table) {
    _tables.add(table);
    return table;
  }

  /// 存档文件（`<临时目录>/session.json`）。
  File get sessionFile => File('${dir.path}/session.json');
}
