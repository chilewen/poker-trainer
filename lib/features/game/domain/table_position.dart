/// 牌桌上的位置命名（纯 Dart，不碰 Flutter）。
///
/// [order] 是按开局顺序排好的玩家 id（跟 `HandHistory.playerNames` 的键顺序
/// 一致），[buttonIndex] 是按钮位在其中的下标。
///
/// 中文位置名：庄位/小盲/大盲/枪口/中位/关煞/嗨加（单挑只分庄位、大盲）。
/// 前位/中位这一层不再细分——复盘里要的是「他坐在哪个位置」，不是 GTO 术语表。
String? cnPosition(List<String> order, int buttonIndex, String id) {
  final n = order.length;
  if (n < 2 || buttonIndex < 0) return null;
  final i = order.indexOf(id);
  if (i < 0) return null;
  if (n == 2) return i == buttonIndex ? '庄位' : '大盲';
  final d = (i - buttonIndex + n) % n;
  switch (d) {
    case 0:
      return '庄位';
    case 1:
      return '小盲';
    case 2:
      return '大盲';
    case 3:
      return '枪口';
    default:
      if (d == n - 1) return '关煞';
      if (d == n - 2 && n > 6) return '嗨加';
      return '中位';
  }
}

/// 玩家名短显示：去掉风格前缀（紧凶·AI1 → AI1）。
String shortPlayerName(String name) =>
    name.contains('·') ? name.split('·').last : name;
