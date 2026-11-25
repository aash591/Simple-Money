import '../../../data/platform_info.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/prices/price_sources.dart';
import '../../../domain/currency_digits.dart';
import '../../../domain/holding.dart';
import '../../components/app_icon.dart';
import '../../components/currency_flag.dart';

/// Where a holding's logo comes from, or null when there is none to find: a
/// coin's saved logo, else a listed stock or ETF's by its ticker from
/// Financial Modeling Prep's free image host (no account or key). Funds
/// priced by an Indian scheme code have no logo.
String? holdingLogoUrl(Holding h) {
  final saved = h.imageUrl;
  if (saved != null) return saved;
  final symbol = h.symbol?.trim() ?? '';
  final listed =
      h.kind == HoldingKind.stock ||
      h.kind == HoldingKind.etf ||
      (h.kind == HoldingKind.fund &&
          h.effectivePriceSource == PriceSourceId.yahoo);
  if (symbol.isEmpty || !listed) return null;
  return tickerLogoUrl(YahooQuotes.yahooSymbol(symbol, h.exchange));
}

/// The logo address for a Yahoo-style [ticker] such as `TCS.NS` or `AAPL`.
String tickerLogoUrl(String ticker) =>
    'https://financialmodelingprep.com/image-stock/'
    '${Uri.encodeComponent(ticker)}.png';

/// The flag to show for a currency [code], or null when it has none.
/// Currencies used in many countries get the one people think of: the
/// first country listed for the dollar is American Samoa.
String? currencyFlagTerritory(String? code) {
  final c = code?.trim().toUpperCase() ?? '';
  return switch (c) {
    'USD' => 'US',
    'EUR' => 'EU',
    'GBP' => 'GB',
    'AUD' => 'AU',
    'NZD' => 'NZ',
    'CHF' => 'CH',
    'XOF' => 'SN',
    'XAF' => 'CM',
    'XCD' => 'AG',
    _ => currencyTerritories[c]?.firstOrNull,
  };
}

/// A holding's logo: a coin round, a company on a light tile. While it loads,
/// offline, or if none exists it shows the icon for [kind].
class HoldingLogo extends StatelessWidget {
  const HoldingLogo(
    this.url, {
    super.key,
    required this.kind,
    this.size = 36,
    this.iconKey,
    this.symbol,
  });
  final String? url;

  /// The holding's symbol: for forex, the currency code whose flag is shown.
  final String? symbol;

  /// An icon the person picked, drawn instead of any logo.
  final String? iconKey;
  final HoldingKind kind;
  final double size;

  static IconData iconFor(HoldingKind kind) => switch (kind) {
    HoldingKind.fund => Icons.pie_chart_rounded,
    HoldingKind.crypto => Icons.currency_bitcoin_rounded,
    HoldingKind.metal => Icons.diamond_outlined,
    HoldingKind.forex => Icons.currency_exchange_rounded,
    _ => Icons.candlestick_chart_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final key = iconKey ?? (kind == HoldingKind.metal ? 'jewelry' : null);
    if (key != null) return AppIcon(key, size: size);
    if (kind == HoldingKind.forex) {
      if (currencyFlagTerritory(symbol) case final territory?) {
        return CurrencyFlag(
          territory,
          width: size,
          height: size,
          borderRadius: size * .28,
        );
      }
    }
    final scheme = Theme.of(context).colorScheme;
    final coin = kind == HoldingKind.crypto;
    final radius = BorderRadius.circular(coin ? size / 2 : size * .28);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: scheme.primary.withValues(alpha: .12),
      ),
      child: Icon(iconFor(kind), size: size * .55, color: scheme.primary),
    );
    // Widget tests have no cache folder or network, so they show the icon.
    if (url == null || isFlutterTest) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(coin ? 0 : size * .1),
        color: coin ? null : Colors.white,
        child: CachedNetworkImage(
          imageUrl: url!,
          fit: coin ? BoxFit.cover : BoxFit.contain,
          fadeInDuration: Duration.zero,
          placeholder: (_, _) => fallback,
          errorWidget: (_, _, _) => fallback,
        ),
      ),
    );
  }
}
