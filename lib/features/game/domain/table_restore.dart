import 'dart:math';

import '../../../engine/game.dart';
import '../data/table_session.dart';
import 'ai_player.dart';

/// 按存档重建一张牌桌：座位顺序、名字、筹码、按钮位都照原样搬回来。
///
/// 唯一「不还原」的是 AI 的读人档案（谁爱开火、谁见注就弃）——那份状态活在
/// [AiPlayer] 内存里，没落盘；重开一局后 AI 会重新观察这桌人。
({GameEngine engine, Map<String, AiPlayer> ais}) restoreTable(
  TableSession session, {
  required String heroId,
  Random? random,
}) {
  final engine = GameEngine(config: session.config, random: random);
  final ais = <String, AiPlayer>{};
  var styleIndex = 0;
  for (final seat in session.seats) {
    engine.addPlayer(seat.id, seat.name, stack: seat.stack);
    if (seat.id == heroId) continue;
    ais[seat.id] = AiPlayer(_styleAt(session, styleIndex), random: random);
    styleIndex++;
  }
  engine.buttonIndex = session.buttonIndex;
  return (engine: engine, ais: ais);
}

/// 存档里第 [index] 个对手的风格；名字对不上（改过枚举/手改存档）就退回紧凶。
AiStyle _styleAt(TableSession session, int index) {
  if (index < 0 || index >= session.styles.length) {
    return AiStyle.tightAggressive;
  }
  final name = session.styles[index];
  for (final style in AiStyle.values) {
    if (style.name == name) return style;
  }
  return AiStyle.tightAggressive;
}
