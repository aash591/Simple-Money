import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/holding.dart';

HoldingTrade trade(
  int id,
  TradeType type,
  int day, {
  int units = 0,
  int price = 0,
  int amount = 0,
  int fees = 0,
}) => HoldingTrade(
  id: id,
  holdingId: 1,
  type: type,
  date: DateTime(2026, 1, day),
  unitsE6: units * unitScale,
  priceE4: price * priceScale,
  amountMinor: amount,
  feesMinor: fees,
);

void main() {
  test('amount is units times price in minor units', () {
    expect(
      tradeAmountMinor(
        unitsE6: 12 * unitScale + 500000,
        priceE4: 101 * priceScale,
        digits: 2,
      ),
      126250,
    );
    expect(
      tradeAmountMinor(
        unitsE6: 3 * unitScale,
        priceE4: 250 * priceScale,
        digits: 0,
      ),
      750,
    );
  });

  test('parses plain decimals only, to the scale allowed', () {
    expect(parseScaled('12.5', unitScale), 12500000);
    expect(parseScaled('1,250.25', priceScale), 12502500);
    expect(parseScaled('0.0000001', unitScale), isNull);
    expect(parseScaled('-1', unitScale), isNull);
    expect(parseScaled('', unitScale), isNull);
  });

  test('buys add up cost with fees; value and gain follow the price', () {
    final p = positionOf([
      trade(
        1,
        TradeType.buy,
        1,
        units: 10,
        price: 100,
        amount: 100000,
        fees: 100,
      ),
      trade(2, TradeType.buy, 2, units: 10, price: 120, amount: 120000),
    ], digits: 2);
    expect(p.unitsE6, 20 * unitScale);
    expect(p.costMinor, 220100);
    final price = 130 * priceScale;
    expect(p.valueMinor(price, 2), 260000);
    expect(p.gainMinor(price, 2), 39900);
    expect(p.gainFraction(price, 2)! > .18, isTrue);
    expect(p.valueMinor(null, 2), isNull);
  });

  test('a sell takes its share of cost at the average and books the gain', () {
    final p = positionOf([
      trade(1, TradeType.buy, 1, units: 10, price: 100, amount: 100000),
      trade(2, TradeType.buy, 2, units: 10, price: 120, amount: 120000),
      trade(
        3,
        TradeType.sell,
        3,
        units: 5,
        price: 150,
        amount: 75000,
        fees: 500,
      ),
    ], digits: 2);
    expect(p.unitsE6, 15 * unitScale);
    expect(p.costMinor, 165000);
    expect(p.realizedMinor, 75000 - 500 - 55000);
  });

  test('selling more than held is clamped, and order follows dates', () {
    final p = positionOf([
      trade(2, TradeType.sell, 5, units: 99, price: 10, amount: 9900),
      trade(1, TradeType.buy, 1, units: 4, price: 10, amount: 4000),
    ], digits: 2);
    expect(p.isEmpty, isTrue);
    expect(p.costMinor, 0);
  });

  test('dividends are counted apart from cost and cash effect is signed', () {
    final d = trade(1, TradeType.dividend, 1, amount: 2500, fees: 250);
    expect(positionOf([d], digits: 2).dividendsMinor, 2250);
    expect(d.cashEffectMinor, 2250);
    expect(
      trade(
        2,
        TradeType.buy,
        1,
        units: 1,
        price: 1,
        amount: 100,
        fees: 5,
      ).cashEffectMinor,
      -105,
    );
  });
}
