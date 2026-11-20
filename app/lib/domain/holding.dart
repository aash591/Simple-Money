import 'dart:math' as math;

/// Units are kept as whole millionths of a unit, prices as ten-thousandths of
/// a currency unit, so no figure is ever a floating point number. Mutual fund
/// units run to 3–4 places, US stocks can be fractional, and NAVs to 4.
const unitScale = 1000000;
const priceScale = 10000;

enum HoldingKind {
  stock('Stock'),
  etf('ETF'),
  fund('Mutual fund');

  const HoldingKind(this.label);
  final String label;
}

enum TradeType {
  buy('Buy'),
  sell('Sell'),
  dividend('Dividend');

  const TradeType(this.label);
  final String label;
}

/// A stock, ETF or fund held at a broker (an account with `isBroker`).
class Holding {
  const Holding({
    required this.id,
    required this.accountId,
    required this.kind,
    required this.name,
    this.symbol,
    this.exchange,
    this.lastPriceE4,
    this.priceDate,
    this.archivedAt,
  });
  final int id, accountId;
  final HoldingKind kind;
  final String name;

  /// Ticker, or the AMFI scheme code for an Indian mutual fund.
  final String? symbol, exchange;

  /// The last close (or NAV) in [priceScale] units, and the day it is for.
  final int? lastPriceE4;
  final DateTime? priceDate;
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;
}

/// One buy, sell or dividend. [amountMinor] is the gross cash value in the
/// broker's minor units (units × price, or the dividend received);
/// [fees] is charged on top of a buy and taken off a sell or dividend.
class HoldingTrade {
  const HoldingTrade({
    required this.id,
    required this.holdingId,
    required this.type,
    required this.date,
    required this.unitsE6,
    required this.priceE4,
    required this.amountMinor,
    this.feesMinor = 0,
    this.payAccountId,
    this.note,
  });
  final int id, holdingId, unitsE6, priceE4, amountMinor, feesMinor;
  final TradeType type;
  final DateTime date;

  /// A buy paid straight from this account (a bank, say) instead of the
  /// broker's own cash. Null means the broker's cash.
  final int? payAccountId;
  final String? note;

  /// How the trade changes the account that pays or receives the money.
  int get cashEffectMinor => switch (type) {
    TradeType.buy => -(amountMinor + feesMinor),
    TradeType.sell || TradeType.dividend => amountMinor - feesMinor,
  };
}

/// Units × price in the currency's minor units, rounded half up.
int tradeAmountMinor({
  required int unitsE6,
  required int priceE4,
  required int digits,
}) {
  final divisor = math.pow(10, 10 - digits).toInt();
  final product = unitsE6 * priceE4;
  return (product + divisor ~/ 2) ~/ divisor;
}

/// Parses "12.5" into [scale]-ths, or null when it isn't a plain positive
/// decimal with no more places than the scale allows.
int? parseScaled(String input, int scale) {
  final text = input.trim().replaceAll(',', '');
  final places = scale.toString().length - 1;
  if (!RegExp('^\\d{1,10}(\\.\\d{1,$places})?\$').hasMatch(text)) return null;
  final parts = text.split('.');
  final fraction = parts.length > 1 ? parts[1].padRight(places, '0') : '0';
  return int.parse(parts[0]) * scale + int.parse(fraction);
}

/// What a holding stands at after its trades, by average cost.
class HoldingPosition {
  const HoldingPosition({
    required this.unitsE6,
    required this.costMinor,
    required this.realizedMinor,
    required this.dividendsMinor,
  });

  /// Units still held.
  final int unitsE6;

  /// What the units still held cost, fees included.
  final int costMinor;

  /// Profit or loss already taken on units sold.
  final int realizedMinor;

  /// Dividends received in total, after fees.
  final int dividendsMinor;

  bool get isEmpty => unitsE6 <= 0;

  /// Market value at [priceE4], or null while no price is known.
  int? valueMinor(int? priceE4, int digits) => priceE4 == null
      ? null
      : tradeAmountMinor(unitsE6: unitsE6, priceE4: priceE4, digits: digits);

  /// Unrealized gain: value less cost.
  int? gainMinor(int? priceE4, int digits) {
    final value = valueMinor(priceE4, digits);
    return value == null ? null : value - costMinor;
  }

  /// Gain as a fraction of cost (0.16 for +16%), null with nothing invested.
  double? gainFraction(int? priceE4, int digits) {
    final gain = gainMinor(priceE4, digits);
    return gain == null || costMinor <= 0 ? null : gain / costMinor;
  }

  /// Average price paid per unit in [priceScale] units, or null when empty.
  /// For display only, so it is allowed to be a floating point sum.
  int? averagePriceE4(int digits) => unitsE6 <= 0
      ? null
      : (costMinor / math.pow(10, digits) / (unitsE6 / unitScale) * priceScale)
            .round();
}

/// Replays [trades] oldest first. A sell takes its share of the cost at the
/// running average; selling more than is held is clamped to what is held.
HoldingPosition positionOf(
  Iterable<HoldingTrade> trades, {
  required int digits,
}) {
  final ordered = trades.toList()
    ..sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
  var units = 0, cost = 0, realized = 0, dividends = 0;
  for (final trade in ordered) {
    switch (trade.type) {
      case TradeType.buy:
        units += trade.unitsE6;
        cost += trade.amountMinor + trade.feesMinor;
      case TradeType.sell:
        final sold = math.min(trade.unitsE6, units);
        final removed = units == 0
            ? 0
            : ((cost * sold) / units).round();
        realized += trade.amountMinor - trade.feesMinor - removed;
        units -= sold;
        cost -= removed;
      case TradeType.dividend:
        dividends += trade.amountMinor - trade.feesMinor;
    }
  }
  return HoldingPosition(
    unitsE6: units,
    costMinor: cost,
    realizedMinor: realized,
    dividendsMinor: dividends,
  );
}
