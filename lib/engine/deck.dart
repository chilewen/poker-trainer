import 'dart:math';

import 'card.dart';

/// 52 张标准牌堆，支持带种子的洗牌，便于复现测试。
class Deck {
  Deck({int? seed}) : _random = Random(seed) {
    _cards = [
      for (final suit in Suit.values)
        for (final rank in Rank.values) Card(rank, suit),
    ];
  }

  Deck.fromCards(this._cards, {int? seed}) : _random = Random(seed);

  final Random _random;
  late List<Card> _cards;

  int get remaining => _cards.length;

  void shuffle() => _cards.shuffle(_random);

  Card draw() {
    if (_cards.isEmpty) {
      throw StateError('牌堆已空');
    }
    return _cards.removeLast();
  }

  List<Card> drawMany(int count) =>
      [for (var i = 0; i < count; i++) draw()];
}
