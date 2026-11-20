import 'package:flutter/material.dart';

/// Where investments are held: the kind of an investment account.
///
/// Only [broker] exists so far. To add a place (a crypto wallet, gold in
/// hand…): add an entry here, list it in [selectable], and when it ships add
/// a nullable `place` column to `accounts` (an additive step, like the v53
/// holdings one). Until then a place is worked out from the stored flag, so
/// nothing is stored that nothing reads.
///
/// Compatibility: `accounts.broker` stays the "this is an investment account"
/// flag. Every future place must set it too, so an older version of the app
/// still lists the account under Portfolio instead of losing it.
enum AccountPlace {
  broker(
    label: 'Broker or app',
    tag: 'Broker',
    description: 'Stocks, ETFs and mutual funds',
    icon: Icons.show_chart_rounded,
    holdsCash: true,
  );

  const AccountPlace({
    required this.label,
    required this.tag,
    required this.description,
    required this.icon,
    required this.holdsCash,
  });

  /// What the person picks when adding an account.
  final String label;

  /// The short mark on an account's row in the portfolio.
  final String tag;
  final String description;
  final IconData icon;

  /// Whether the account keeps money of its own, so Deposit, Withdraw and a
  /// Cash figure apply. Places that don't (a wallet, gold in hand) are paid
  /// for from a bank instead.
  final bool holdsCash;

  /// The places a person can choose from when adding an account.
  static const selectable = [broker];
}
