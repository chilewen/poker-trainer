/// 花色与牌面模型，纯 Dart，无 Flutter 依赖。
enum Suit {
  spades('s', '♠'),
  hearts('h', '♥'),
  diamonds('d', '♦'),
  clubs('c', '♣');

  const Suit(this.short, this.symbol);
  final String short;
  final String symbol;
}

/// 点数，2 = 2 ... 14 = A。
enum Rank {
  two(2, '2'),
  three(3, '3'),
  four(4, '4'),
  five(5, '5'),
  six(6, '6'),
  seven(7, '7'),
  eight(8, '8'),
  nine(9, '9'),
  ten(10, '10'),
  jack(11, 'J'),
  queen(12, 'Q'),
  king(13, 'K'),
  ace(14, 'A');

  const Rank(this.value, this.label);
  final int value;
  final String label;
}

class Card {
  const Card(this.rank, this.suit);

  final Rank rank;
  final Suit suit;

  /// 例如 'As'、'Kd'、'10h'。
  String get notation => '${rank.label}${suit.short}';

  /// 例如 'A♠'。
  String get pretty => '${rank.label}${suit.symbol}';

  static Card parse(String notation) {
    final s = notation.trim();
    if (s.length < 2 || s.length > 3) {
      throw FormatException('非法牌面: $s');
    }
    final rank = Rank.values.firstWhere(
      (r) => r.label == s.substring(0, s.length - 1),
      orElse: () => throw FormatException('非法点数: $s'),
    );
    final suit = Suit.values.firstWhere(
      (t) => t.short == s[s.length - 1],
      orElse: () => throw FormatException('非法花色: $s'),
    );
    return Card(rank, suit);
  }

  @override
  bool operator ==(Object other) =>
      other is Card && other.rank == rank && other.suit == suit;

  @override
  int get hashCode => Object.hash(rank, suit);

  @override
  String toString() => pretty;
}
