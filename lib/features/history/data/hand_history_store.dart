import 'dart:convert';
import 'dart:io' show Platform;

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../engine/hand_history.dart';

/// 手牌历史 SQLite 存储：跨会话持久化每手完整记录（JSON）。
///
/// 存 JSON 而非拆表：手牌是整存整取的文档型结构，
/// 查询只需按时间排序/按 id 删除，没有按字段过滤的需求，
/// 且 [HandHistory.fromJson] 已有现成序列化。
class HandHistoryStore {
  HandHistoryStore();

  static const _table = 'hands';

  Database? _db;

  /// 打开（首次创建）数据库。
  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    // 桌面端（macOS/Linux/Windows）使用 FFI 版本的 SQLite。
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _db = await openDatabase(
      '${dir.path}/poker_trainer.db',
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE $_table(
          id TEXT PRIMARY KEY,
          timestamp INTEGER NOT NULL,
          json TEXT NOT NULL
        )
      '''),
    );
  }

  Database get _requireDb {
    final db = _db;
    if (db == null) {
      throw StateError('HandHistoryStore.init() 尚未调用');
    }
    return db;
  }

  /// 保存一只手牌（同 id 覆盖）。
  Future<void> save(HandHistory hand) {
    return _requireDb.insert(
      _table,
      {
        'id': hand.id,
        'timestamp': hand.timestamp.millisecondsSinceEpoch,
        'json': jsonEncode(hand.toJson()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 按时间从最新到最早读取全部手牌。
  Future<List<HandHistory>> loadAll() async {
    final rows = await _requireDb.query(_table, orderBy: 'timestamp DESC');
    return [
      for (final row in rows)
        HandHistory.fromJson(
          (jsonDecode(row['json']! as String) as Map).cast<String, Object?>(),
        ),
    ];
  }

  Future<void> delete(String id) {
    return _requireDb.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clear() {
    return _requireDb.delete(_table);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
