// 由 tool/gen_app_version.sh 从 pubspec.yaml 生成，别手改。
//
// 改版本号：用 zsh tool/ota/bump_version.sh（改完会自动重跑这个生成器），
// 或者手改 pubspec 后再跑一次 zsh tool/gen_app_version.sh。
// test/app_version_test.dart 会拿 pubspec.yaml 对一遍，走散了用例会红。

/// 完整版本，跟 pubspec 的 `version:` 一字不差，如 `0.1.0+12`。
const appVersion = '0.1.0+15';

/// 短版本，如 `0.1.0`。
const appVersionShort = '0.1.0';

/// 构建号（pubspec 里 `+` 后面那一位），如 `12`；没有就是空串。
const appBuildNumber = '15';

/// 给人看的版本文字：`0.1.0（build 12）`。
const appVersionText = '0.1.0（build 15）';
