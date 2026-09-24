import '../../../engine/game.dart';

/// 存档里的一个座位：谁、叫什么、还剩多少筹码。
class SessionSeat {
  const SessionSeat({required this.id, required this.name, required this.stack});

  final String id;
  final String name;
  final int stack;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'stack': stack};

  factory SessionSeat.fromJson(Map<String, Object?> json) => SessionSeat(
        id: json['id']! as String,
        name: json['name']! as String,
        stack: (json['stack']! as num).toInt(),
      );
}

/// 一桌对局的存档：桌面名、盲注级别、对手风格、各家筹码、按钮位与手数。
///
/// 只存「两手之间」的状态——正在打的那手牌不落盘（AI 的思考过程也没法存），
/// 所以恢复出来的是同一张桌、同一批筹码，然后从下一手接着打。
///
/// 纯 Dart（不依赖 Flutter），因此可以在没有引擎的环境里直接测。
class TableSession {
  const TableSession({
    required this.id,
    required this.label,
    required this.config,
    required this.styles,
    required this.seats,
    required this.buttonIndex,
    required this.handsPlayed,
    required this.savedAt,
  });

  /// 本局唯一标识：内存里的牌桌与它一致，说明「就是这一桌」，不必重建。
  final String id;

  final String label;
  final GameConfig config;

  /// 对手风格（取 `AiStyle.name`），顺序与 [seats] 里的非英雄座位一致。
  final List<String> styles;

  /// 座位（含英雄），顺序与开局时一致。
  final List<SessionSeat> seats;

  /// 上一手用的按钮位索引；继续时下一手会照常往前挪一格。
  final int buttonIndex;

  /// 这张桌已经打完多少手。
  final int handsPlayed;

  final DateTime savedAt;

  /// 取某个座位的筹码；没有这个座位时返回 null。
  int? stackOf(String id) {
    for (final s in seats) {
      if (s.id == id) return s.stack;
    }
    return null;
  }

  /// 存档能否用来重建一张牌桌（至少两张牌、筹码不为负）。
  bool get isPlayable =>
      seats.length >= 2 &&
      seats.every((s) => s.stack >= 0) &&
      buttonIndex >= -1;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'startingStack': config.startingStack,
        'smallBlind': config.smallBlind,
        'bigBlind': config.bigBlind,
        'styles': styles,
        'seats': [for (final s in seats) s.toJson()],
        'buttonIndex': buttonIndex,
        'handsPlayed': handsPlayed,
        'savedAt': savedAt.millisecondsSinceEpoch,
      };

  factory TableSession.fromJson(Map<String, Object?> json) => TableSession(
        id: json['id']! as String,
        label: json['label']! as String,
        config: GameConfig(
          startingStack: (json['startingStack']! as num).toInt(),
          smallBlind: (json['smallBlind']! as num).toInt(),
          bigBlind: (json['bigBlind']! as num).toInt(),
        ),
        styles: [
          for (final s in (json['styles']! as List)) s! as String,
        ],
        seats: [
          for (final s in (json['seats']! as List))
            SessionSeat.fromJson((s! as Map).cast<String, Object?>()),
        ],
        buttonIndex: (json['buttonIndex']! as num).toInt(),
        handsPlayed: (json['handsPlayed']! as num).toInt(),
        savedAt:
            DateTime.fromMillisecondsSinceEpoch((json['savedAt']! as num).toInt()),
      );
}
