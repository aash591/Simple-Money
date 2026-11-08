import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/title_suggestions.dart';
import 'package:simple_money/domain/transaction.dart';

var _nextId = 1;

MoneyTransaction _tx(
  String? title, {
  TransactionType type = TransactionType.expense,
  int? categoryId = 1,
  int day = 1,
}) => MoneyTransaction(
  id: _nextId++,
  type: type,
  amountMinor: 100,
  accountId: 1,
  categoryId: type == TransactionType.transfer ? null : categoryId,
  title: title,
  date: DateTime(2026, 1, day),
);

void main() {
  test('matches the start of the title before the start of a later word', () {
    final suggestions = TitleSuggestions([
      _tx('Pay Uber'),
      _tx('Uber'),
      _tx('Rent'),
    ]);
    expect(suggestions.suggest('ub', type: TransactionType.expense), [
      'Uber',
      'Pay Uber',
    ]);
  });

  test(
    'ignores the middle of a word, transfers, blanks and the other type',
    () {
      final suggestions = TitleSuggestions([
        _tx('Pub'),
        _tx('Uber', type: TransactionType.transfer),
        _tx('  '),
        _tx(null),
        _tx('Ubiquiti', type: TransactionType.income),
      ]);
      expect(suggestions.suggest('ub', type: TransactionType.expense), isEmpty);
    },
  );

  test('offers each title once, in its latest casing', () {
    final suggestions = TitleSuggestions([
      _tx('coffee', day: 1),
      _tx('Coffee', day: 3),
      _tx('COFFEE', day: 2),
    ]);
    expect(suggestions.suggest('c', type: TransactionType.expense), ['Coffee']);
  });

  test('prefers the category, then the most used, then the most recent', () {
    final suggestions = TitleSuggestions([
      _tx('Snacks', categoryId: 2, day: 1),
      _tx('Salary advance', day: 1),
      _tx('Salary advance', day: 2),
      _tx('Shoes', day: 9),
      _tx('Socks', day: 5),
    ]);
    expect(
      suggestions.suggest('s', type: TransactionType.expense, categoryId: 2),
      ['Snacks', 'Salary advance', 'Shoes', 'Socks'],
    );
  });

  test('never offers back a title typed in full', () {
    final suggestions = TitleSuggestions([_tx('Rent'), _tx('Rental car')]);
    expect(suggestions.suggest('rent ', type: TransactionType.expense), [
      'Rental car',
    ]);
  });

  test('a blank query offers only titles used with the category', () {
    final suggestions = TitleSuggestions([
      _tx('Groceries', categoryId: 1),
      _tx('Fuel', categoryId: 2),
    ]);
    expect(
      suggestions.suggest('', type: TransactionType.expense, categoryId: 1),
      ['Groceries'],
    );
    expect(suggestions.suggest('', type: TransactionType.expense), isEmpty);
  });

  test('stops at the limit', () {
    final suggestions = TitleSuggestions([
      for (var i = 0; i < 8; i++) _tx('Item $i'),
    ]);
    expect(
      suggestions.suggest('item', type: TransactionType.expense, limit: 3),
      hasLength(3),
    );
  });
}
