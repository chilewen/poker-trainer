import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poker_trainer/app_version.dart';

/// App 里显示的版本号必须跟 pubspec.yaml 一致。
///
/// 这个常量是 `tool/gen_app_version.sh` 生成的；用例在这儿盯着它，是为了
/// 不让「显示的版本」跟「实际打的包」走散——刚踩过的坑就是页面上是新版本、
/// 装上去还是旧包。走散了跑 `zsh tool/gen_app_version.sh`（或 bump 脚本）修好。
void main() {
  test('版本号：app_version.dart 跟 pubspec.yaml 对得上', () {
    final pubspec = _findPubspec();
    final m = RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里没有 version: 行');

    final want = m!.group(1)!;
    final parts = want.split('+');

    expect(appVersion, want,
        reason: 'lib/app_version.dart 跟 pubspec 走散了，跑一下 zsh tool/gen_app_version.sh');
    expect(appVersionShort, parts.first);
    expect(appBuildNumber, parts.length > 1 ? parts[1] : '');
    expect(appVersionText, contains(appVersionShort));
    if (appBuildNumber.isNotEmpty) {
      expect(appVersionText, contains('build $appBuildNumber'));
    }
  });
}

/// 从当前目录往上找 pubspec.yaml（用例的 CWD 不一定是项目根）。
String _findPubspec() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/pubspec.yaml');
    if (f.existsSync()) return f.readAsStringSync();
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('从 ${Directory.current.path} 往上没找到 pubspec.yaml');
}
