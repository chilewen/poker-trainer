import 'ai_player.dart';

/// 牌桌上的位置命名（纯 Dart，不碰 Flutter）。
///
/// [order] 是按开局顺序排好的玩家 id（跟 `HandHistory.playerNames` 的键顺序
/// 一致），[buttonIndex] 是按钮位在其中的下标。
///
/// 座位位置（相对按钮位），中英文各一套口径都从这里出。
enum TableSeat { button, smallBlind, bigBlind, utg, middle, hijack, cutoff }

/// 中文位置名：庄位/小盲/大盲/枪口/中位/关煞/嗨加（单挑只分庄位、大盲）。
/// 前位/中位这一层不再细分——复盘里要的是「他坐在哪个位置」，不是 GTO 术语表。
String? cnPosition(List<String> order, int buttonIndex, String id) {
  final seat = _seatOf(order, buttonIndex, id);
  return seat == null ? null : _cnSeat[seat];
}

/// 位置英文缩写：BTN/SB/BB/UTG/MP/HJ/CO（跟 [cnPosition] 同一套口径）。
String? enPosition(List<String> order, int buttonIndex, String id) {
  final seat = _seatOf(order, buttonIndex, id);
  return seat == null ? null : _enSeat[seat];
}

const Map<TableSeat, String> _cnSeat = {
  TableSeat.button: '庄位',
  TableSeat.smallBlind: '小盲',
  TableSeat.bigBlind: '大盲',
  TableSeat.utg: '枪口',
  TableSeat.middle: '中位',
  TableSeat.hijack: '嗨加',
  TableSeat.cutoff: '关煞',
};

const Map<TableSeat, String> _enSeat = {
  TableSeat.button: 'BTN',
  TableSeat.smallBlind: 'SB',
  TableSeat.bigBlind: 'BB',
  TableSeat.utg: 'UTG',
  TableSeat.middle: 'MP',
  TableSeat.hijack: 'HJ',
  TableSeat.cutoff: 'CO',
};

TableSeat? _seatOf(List<String> order, int buttonIndex, String id) {
  final n = order.length;
  if (n < 2 || buttonIndex < 0) return null;
  final i = order.indexOf(id);
  if (i < 0) return null;
  if (n == 2) {
    return i == buttonIndex ? TableSeat.button : TableSeat.bigBlind;
  }
  final d = (i - buttonIndex + n) % n;
  switch (d) {
    case 0:
      return TableSeat.button;
    case 1:
      return TableSeat.smallBlind;
    case 2:
      return TableSeat.bigBlind;
    case 3:
      return TableSeat.utg;
    default:
      if (d == n - 1) return TableSeat.cutoff;
      if (d == n - 2 && n > 6) return TableSeat.hijack;
      return TableSeat.middle;
  }
}

/// 玩家名短显示：去掉风格前缀（紧凶·AI1 → AI1）。
String shortPlayerName(String name) =>
    name.contains('·') ? name.split('·').last : name;

/// 座位头像里的字：英雄显示自己的「我」，电脑玩家显示类型的那两个字。
///
/// 以前取的是名字首字，于是松被动和松凶都只剩一个「松」，牌桌上根本看不出
/// 对手是什么类型；现在镶的是 [AiStyle.shortLabel]（紧凶 / 松弱 / 松凶）。
/// 牌桌座位和手牌回顾共用这一份。
String avatarLabel(String name) {
  final parts = name.split('·');
  if (parts.length < 2) return name.isEmpty ? '?' : name.substring(0, 1);
  return AiStyle.byLabel(parts.first)?.shortLabel ?? parts.first;
}
