import 'card.dart';
import 'types.dart';

/// 单个决策/动作记录，是复盘与错局重玩的数据基础。
class ActionRecord {
  const ActionRecord({
    required this.street,
    required this.actorId,
    required this.type,
    this.amount = 0,
    required this.potAfter,
  });

  final Street street;
  final String actorId;
  final ActionType type;
  final int amount;
  final int potAfter;

  Map<String, Object?> toJson() => {
        'street': street.name,
        'actorId': actorId,
        'type': type.name,
        'amount': amount,
        'potAfter': potAfter,
      };

  factory ActionRecord.fromJson(Map<String, Object?> json) => ActionRecord(
        street: Street.values.byName(json['street'] as String),
        actorId: json['actorId'] as String,
        type: ActionType.values.byName(json['type'] as String),
        amount: (json['amount'] as num?)?.toInt() ?? 0,
        potAfter: (json['potAfter'] as num).toInt(),
      );
}

/// 一手完整的手牌记录：复盘、错局重玩、统计都依赖它。
class HandHistory {
  HandHistory({
    required this.id,
    required this.timestamp,
    required this.playerNames,
    required this.startingStacks,
    required this.holeCards,
    required this.buttonIndex,
    required this.smallBlind,
    required this.bigBlind,
  });

  final String id;
  final DateTime timestamp;
  final Map<String, String> playerNames; // id -> 名字
  final Map<String, int> startingStacks; // id -> 起始筹码
  final Map<String, List<Card>> holeCards; // id -> 两张底牌
  final int buttonIndex;
  final int smallBlind;
  final int bigBlind;

  final List<Card> board = [];
  final List<ActionRecord> actions = [];
  final Map<String, int> netResult = {}; // id -> 本手净赢输

  /// 最后一个动作之后的主池/底池总额（不含已赢走的边池）。
  int get finalPot =>
      actions.isEmpty ? 0 : actions.last.potAfter;

  Map<String, Object?> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'playerNames': playerNames,
        'startingStacks': startingStacks,
        'holeCards': {
          for (final e in holeCards.entries)
            e.key: e.value.map((c) => c.notation).toList(),
        },
        'buttonIndex': buttonIndex,
        'smallBlind': smallBlind,
        'bigBlind': bigBlind,
        'board': board.map((c) => c.notation).toList(),
        'actions': actions.map((a) => a.toJson()).toList(),
        'netResult': netResult,
      };

  factory HandHistory.fromJson(Map<String, Object?> json) {
    final h = HandHistory(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      playerNames:
          (json['playerNames'] as Map<String, Object?>).cast<String, String>(),
      startingStacks:
          (json['startingStacks'] as Map<String, Object?>)
              .map((k, v) => MapEntry(k, (v as num).toInt())),
      holeCards: (json['holeCards'] as Map<String, Object?>).map(
          (k, v) => MapEntry(
              k, (v as List).map((s) => Card.parse(s as String)).toList())),
      buttonIndex: (json['buttonIndex'] as num).toInt(),
      smallBlind: (json['smallBlind'] as num).toInt(),
      bigBlind: (json['bigBlind'] as num).toInt(),
    );
    h.board.addAll(
        (json['board'] as List).map((s) => Card.parse(s as String)));
    h.actions.addAll((json['actions'] as List)
        .map((a) => ActionRecord.fromJson((a as Map).cast<String, Object?>())));
    h.netResult.addAll((json['netResult'] as Map<String, Object?>)
        .map((k, v) => MapEntry(k, (v as num).toInt())));
    return h;
  }
}
