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
    required this.name,
    required this.config,
    required this.styles,
    required this.seats,
    required this.buttonIndex,
    required this.handsPlayed,
    required this.savedAt,
    this.heroNet = 0,
    this.handSnapshot,
  });

  /// 本局唯一标识：内存里的牌桌与它一致，说明「就是这一桌」，不必重建。
  final String id;

  /// 存档/大厅列表用的完整桌名，带盲注级别（如「实战 9人桌 · 50/100」）。
  final String label;

  /// 对局页标题用的桌名，**不带**盲注级别（如「实战 9人桌」）。
  ///
  /// 单独存一份是因为「继续上局」恢复牌桌时不能拿 [label] 当桌名——那样
  /// 标题里又会冒出 50/100。
  final String name;

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

  /// 英雄在本局的累计输赢（已完成手牌之和，不含存档时正在进行的那一手）。
  final int heroNet;

  /// 存档时正在进行的那手牌（[GameEngine.toSnapshotJson] 的结果）。
  ///
  /// 非空 = 这一手打到一半就退出了：接着打同一手牌。
  /// 空 = 停在两手之间：恢复后直接发下一手。
  final Map<String, Object?>? handSnapshot;

  /// 存档是不是「打到一半」的。
  bool get handInProgress => handSnapshot != null;

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
        'name': name,
        'startingStack': config.startingStack,
        'smallBlind': config.smallBlind,
        'bigBlind': config.bigBlind,
        'styles': styles,
        'seats': [for (final s in seats) s.toJson()],
        'buttonIndex': buttonIndex,
        'handsPlayed': handsPlayed,
        'heroNet': heroNet,
        'savedAt': savedAt.millisecondsSinceEpoch,
        if (handSnapshot != null) 'hand': handSnapshot,
      };

  factory TableSession.fromJson(Map<String, Object?> json) {
    final label = json['label']! as String;
    final sb = (json['smallBlind']! as num).toInt();
    final bb = (json['bigBlind']! as num).toInt();
    return TableSession(
        id: json['id']! as String,
        label: label,
        // 老存档没有 'name'：从 label 里把盲注后缀剪掉当桌名。
        name: (json['name'] as String?) ?? _nameWithoutBlinds(label, sb, bb),
        config: GameConfig(
          startingStack: (json['startingStack']! as num).toInt(),
          smallBlind: sb,
          bigBlind: bb,
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
        // 老存档没有 'heroNet'：按 0 处理（本局累计从这一手重新数）。
        heroNet: (json['heroNet'] as num?)?.toInt() ?? 0,
        savedAt:
            DateTime.fromMillisecondsSinceEpoch((json['savedAt']! as num).toInt()),
        // 老存档（或两手之间的存档）没有 'hand' 字段，按「两手之间」处理。
        handSnapshot: (json['hand'] as Map?)?.cast<String, Object?>(),
      );
  }

  /// 从「实战 9人桌 · 50/100」里剪掉盲注后缀；后缀对不上就原样返回。
  static String _nameWithoutBlinds(String label, int sb, int bb) {
    final suffix = ' · $sb/$bb';
    return label.endsWith(suffix)
        ? label.substring(0, label.length - suffix.length)
        : label;
  }
}
