/// 牌局阶段。
enum Street {
  preflop('翻牌前'),
  flop('翻牌'),
  turn('转牌'),
  river('河牌'),
  showdown('摊牌');

  const Street(this.label);
  final String label;
}

/// 玩家动作。
enum ActionType {
  fold('弃牌'),
  check('过牌'),
  call('跟注'),
  bet('下注'),
  raise('加注');

  const ActionType(this.label);
  final String label;
}
