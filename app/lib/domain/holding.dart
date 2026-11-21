import 'dart:convert';
import 'dart:math' as math;

import 'metal.dart';

/// Units are kept as whole millionths of a unit, prices as ten-thousandths of
/// a currency unit, so no figure is ever a floating point number. Mutual fund
/// units run to 3–4 places, US stocks can be fractional, and NAVs to 4.
const unitScale = 1000000;
const priceScale = 10000;

/// Units for display: up to four places, no trailing zeros.
String formatUnits(int unitsE6) {
  final text = (unitsE6 / unitScale).toStringAsFixed(4);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// What a holding is. The database stores the [name] as free text (no CHECK),
/// and a newer version of the app may store a kind this one has never heard
/// of: [parse] reads those as [other] instead of throwing, and the row keeps
/// its original text (see [Holding.kindId]) so an older phone never rewrites
/// or loses it. To add an asset type, add an entry here, give it a price
/// source (see [PriceSourceId]) and, if people may pick it, list it in
/// [selectable].
enum HoldingKind {
  stock('Stock'),
  etf('ETF'),
  fund('Mutual fund'),
  crypto('Crypto'),
  metal('Metal'),

  /// Any kind this version doesn't know. Never offered when adding.
  other('Other');

  const HoldingKind(this.label);
  final String label;

  /// The kinds a person can choose from when adding a holding.
  static const selectable = [stock, etf, fund, crypto, metal];

  static HoldingKind parse(String? id) =>
      values.where((k) => k.name == id).firstOrNull ?? other;
}

/// Where a holding's price comes from, stored on the holding as free text.
/// A source this version doesn't know is left alone: such a holding is never
/// fetched, and never counted as a failure.
abstract final class PriceSourceId {
  /// Yahoo Finance's public chart data: stocks and ETFs worldwide.
  static const yahoo = 'yahoo';

  /// India's AMFI NAV file: mutual funds, by scheme code.
  static const amfi = 'amfi';

  /// CoinGecko's public price list: crypto coins, by CoinGecko id.
  static const coingecko = 'coingecko';

  /// The international price of gold, silver and platinum, from Yahoo's
  /// metal futures, turned into a price per gram.
  static const metalWorld = 'metal_world';

  /// The person types the price in; nothing is ever fetched.
  static const manual = 'manual';

  /// The source for a holding that doesn't name one (every holding saved
  /// before sources were stored, and any made by an older phone): a fund with
  /// an all-digit scheme code is AMFI's, anything else Yahoo's. Null for a
  /// kind this version doesn't know, which is left unfetched.
  static String? infer(HoldingKind kind, String? symbol) {
    if (kind == HoldingKind.other) return null;
    if (kind == HoldingKind.crypto) return coingecko;
    if (kind == HoldingKind.metal) return metalWorld;
    final code = symbol?.trim() ?? '';
    return kind == HoldingKind.fund && RegExp(r'^\d+$').hasMatch(code)
        ? amfi
        : yahoo;
  }
}

/// Whether a name reads like a fund that trades on an exchange. Some markets
/// (India's, for one) list their ETFs to Yahoo as ordinary equities, so the
/// name is all that tells them apart.
bool looksLikeEtf(String name) => RegExp(
  r'\b(etf|bees|index|tracker|trust|ishares|vanguard|spdr|amundi|lyxor|xtrackers|invesco|nifty|sensex|gold|silver)\b',
  caseSensitive: false,
).hasMatch(name);

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
    String? kindId,
    this.priceSource,
    this.meta,
    this.currency,
  }) : _kindId = kindId;
  final int id, accountId;
  final HoldingKind kind;
  final String name;

  /// The kind exactly as stored, which for a kind this version doesn't know
  /// is more than [kind] (then [HoldingKind.other]) can say.
  final String? _kindId;
  String get kindId => _kindId ?? kind.name;

  /// A [PriceSourceId], or null for a holding that never named one.
  final String? priceSource;

  /// Extra details a kind needs (JSON text), room for what later asset types
  /// carry. Kept as stored: this version neither reads nor rewrites it.
  final String? meta;

  /// A coin's logo address from the details, only when it is on CoinGecko's
  /// image host: the details can arrive from another phone.
  String? get imageUrl {
    final text = meta;
    if (text == null) return null;
    try {
      final image = (jsonDecode(text) as Map)['image'];
      final uri = image is String ? Uri.tryParse(image) : null;
      return uri != null &&
              uri.scheme == 'https' &&
              (uri.host == 'coin-images.coingecko.com' ||
                  uri.host == 'assets.coingecko.com')
          // Earlier versions saved the 25 px thumbnail, which looks soft.
          ? (image as String).replaceFirst('/thumb/', '/large/')
          : null;
    } catch (_) {
      return null;
    }
  }

  /// The details of a metal holding, or null for anything else.
  MetalDetails? get metalDetails =>
      kind == HoldingKind.metal ? MetalDetails.parse(meta) : null;

  /// An icon the person picked for it (an `appIconKeys` or brand key), kept
  /// in the details; it wins over any logo.
  String? get iconKey {
    final text = meta;
    if (text == null) return null;
    try {
      final key = (jsonDecode(text) as Map)['icon'];
      return key is String && key.isNotEmpty ? key : null;
    } catch (_) {
      return null;
    }
  }

  /// Where its price comes from, worded for the screen, or null when it is
  /// set by hand or unknown.
  String? get sourceNote {
    final metal = metalDetails?.metal.label.toLowerCase();
    return switch (effectivePriceSource) {
      PriceSourceId.yahoo => 'Source: Yahoo Finance',
      PriceSourceId.amfi => 'Source: AMFI',
      PriceSourceId.coingecko => 'Source: CoinGecko',
      PriceSourceId.metalWorld =>
        'Source: international ${metal ?? 'metal'} price, Yahoo Finance',
      _ => null,
    };
  }

  /// What the update button does, in few words: "Update from world gold
  /// price".
  String get updateLabel {
    final metal = metalDetails?.metal.label.toLowerCase();
    return switch (effectivePriceSource) {
      PriceSourceId.yahoo => 'Update from Yahoo Finance',
      PriceSourceId.amfi => 'Update from AMFI',
      PriceSourceId.coingecko => 'Update from CoinGecko',
      PriceSourceId.metalWorld => 'Update from world ${metal ?? 'metal'} price',
      _ => 'Update price',
    };
  }

  /// The same, once done: "Updated from world gold price".
  String get updatedLabel => updateLabel == 'Update price'
      ? 'Price updated'
      : updateLabel.replaceFirst('Update ', 'Updated ');

  /// Whether its price can be fetched: it has a ticker and a source.
  bool get canFetchPrice =>
      (symbol?.trim().isNotEmpty ?? false) && sourceNote != null;

  /// The currency its price is quoted in, or null for the account's own
  /// (every holding saved before this existed).
  final String? currency;

  /// The currency of this holding's price, given its account's.
  String currencyIn(String accountCurrency) => currency ?? accountCurrency;

  /// The source to fetch from: the stored one, else inferred.
  String? get effectivePriceSource =>
      priceSource ?? PriceSourceId.infer(kind, symbol);

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
        final removed = units == 0 ? 0 : ((cost * sold) / units).round();
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

/// The words a kind of holding uses for its units and price.
extension HoldingWording on HoldingKind {
  /// What is counted: shares, fund units or grams.
  String get unitsName => switch (this) {
    HoldingKind.fund => 'Units',
    HoldingKind.metal => 'Grams',
    _ => 'Shares',
  };

  String get priceName => switch (this) {
    HoldingKind.fund => 'NAV per unit',
    HoldingKind.metal => 'Price per gram',
    _ => 'Price per share',
  };

  /// A short unit after a figure: "12.5 units", "10 g".
  String unitsAfter(int unitsE6) => switch (this) {
    HoldingKind.fund => 'units',
    HoldingKind.metal => 'g',
    _ => unitsE6 == unitScale ? 'share' : 'shares',
  };
}
