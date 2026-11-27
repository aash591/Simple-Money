import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_scope.dart';
import '../../components/common.dart';

/// The surface every Home section sits on: a [MoneyCard] with ink support so
/// taps inside it ripple.
class HomeCard extends StatelessWidget {
  const HomeCard({
    super.key,
    required this.child,
    this.featured = false,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final bool featured;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final card = MoneyCard(
      padding: padding,
      featured: featured,
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (MediaQuery.disableAnimationsOf(context)) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      // Its own layer: the entrance fades and slides pixels already painted
      // instead of repainting the card (charts and all) on every frame.
      child: RepaintBoundary(child: card),
      builder: (context, progress, child) => Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - progress)),
          child: child,
        ),
      ),
    );
  }
}

/// [minor] in the currency Home is currently showing.
String homeMoney(int minor, CurrencyScope currency) =>
    '${currency is CombinedCurrency ? '≈ ' : ''}${formatAccountMoney(minor, currency: currency.code, digits: currency.digits)}';

/// [minor] shortened for an axis tick or a tight label: "₹1.2K".
String homeCompactMoney(num minor, CurrencyScope currency) =>
    '${currencyPrefix(currency.code)}'
    '${NumberFormat.compact().format(minor / math.pow(10, currency.digits))}';

/// A chart card's title, with the one sentence that says what the chart
/// shows underneath.
class HomeChartHeader extends StatelessWidget {
  const HomeChartHeader({
    super.key,
    required this.title,
    required this.headline,
    this.action,
    this.onTap,
  });
  final String title;
  final String headline;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionTitle(title, action: action, onTap: onTap, compact: true),
      const SizedBox(height: 6),
      Text(
        headline,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(fontSize: 14, height: 1.45),
      ),
      const SizedBox(height: 24),
    ],
  );
}
