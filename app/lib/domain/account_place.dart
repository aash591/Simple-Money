import 'package:flutter/material.dart';

/// Where investments are kept: the kind of an investment account. Any kind of
/// holding (stocks, crypto, gold…) can sit in any place.
///
/// To add a place: add an entry here, list it in [selectable], and handle it
/// in the add-account screen. The stored `accounts.place` text is read with
/// [parse], so a place a newer version saved reads as [broker] here.
///
/// Compatibility: `accounts.broker` stays the "this is an investment account"
/// flag. Every place must set it too, so an older version of the app still
/// lists the account under Portfolio instead of losing it.
enum AccountPlace {
  broker(
    label: 'Broker, exchange or app',
    tag: 'Broker',
    description: 'Stocks, ETFs, funds and crypto',
    icon: Icons.show_chart_rounded,
    holdsCash: true,
  ),
  inHand(
    label: 'In hand, locker or wallet',
    tag: 'In hand',
    description: 'Gold, coins and things you keep yourself',
    icon: Icons.lock_outline_rounded,
    holdsCash: false,
  );

  const AccountPlace({
    required this.label,
    required this.tag,
    required this.description,
    required this.icon,
    required this.holdsCash,
  });

  /// The name AI tools use: `broker` or `in_hand`.
  String get toolName => switch (this) {
    inHand => 'in_hand',
    _ => name,
  };

  /// What the person picks when adding an account.
  final String label;

  /// The short mark on an account's row in the portfolio.
  final String tag;
  final String description;
  final IconData icon;

  /// Whether the account keeps money of its own, so Deposit, Withdraw and a
  /// Cash figure apply. Places that don't (a locker, a wallet) are paid for
  /// from a bank instead.
  final bool holdsCash;

  /// The places a person can choose from when adding an account.
  static const selectable = [broker, inHand];

  /// The place stored as [id]; anything unknown reads as [broker].
  static AccountPlace parse(String? id) =>
      values.where((p) => p.name == id).firstOrNull ?? broker;
}
