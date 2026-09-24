import 'dart:convert';
import 'dart:io';

import 'table_session.dart';

/// 对局存档的落盘：一个 JSON 文件装一局，覆盖写。
///
/// 只依赖 `dart:io`，路径由调用方给（main() 里从 App 支持目录拼），
/// 这样存档逻辑不绑 Flutter，可以直接测。
class TableSessionStore {
  TableSessionStore(this.file);

  final File file;

  /// 读回上次的存档；没有存档或存档损坏时返回 null。
  Future<TableSession?> load() async {
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final session = TableSession.fromJson(raw.cast<String, Object?>());
      return session.isPlayable ? session : null;
    } catch (_) {
      // 存档损坏/版本不兼容就当没有：不该卡住用户，照样能开新局。
      return null;
    }
  }

  Future<void> save(TableSession session) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(session.toJson()), flush: true);
  }

  Future<void> clear() async {
    if (file.existsSync()) await file.delete();
  }
}
