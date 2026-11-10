import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/debt.dart';
import '../../theme/sheet_colors.dart';

/// Neither side of a debt is good news — money owed to you is still money
/// you're waiting on — so it's orange, and what you owe red. Never green,
/// which is kept for being settled.
Color owedColor(BuildContext context, {required bool toYou}) {
  if (!toYou) return SheetColors.of(context).expense;
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xffff9a52)
      : const Color(0xffe0701f);
}

/// An entry takes the colour of the side it concerns; its arrow shows which
/// way the money moved.
Color debtKindColor(BuildContext context, DebtKind kind) =>
    owedColor(context, toYou: kind.concernsOwedToYou);

extension DebtKindLabels on DebtKind {
  /// What happened, always from your side and naming the other person, so
  /// no two kinds read alike.
  String describe(String name) => switch (this) {
    DebtKind.lend => 'Lent to $name',
    DebtKind.borrow => 'Borrowed from $name',
    DebtKind.collect => 'Received from $name',
    DebtKind.repay => 'Paid to $name',
  };

  /// Out of your pocket, or into it.
  IconData get icon =>
      paysOut ? Icons.north_east_rounded : Icons.south_west_rounded;
}

/// e.g. "₹1,500", or "₹1,500 + $20" across currencies. Always unsigned: the
/// words around it say which way it's owed. Nothing at all shows as zero in
/// [currency].
String formatDebtAmounts(
  Iterable<DebtBalance> balances, {
  String currency = 'INR',
  int digits = 2,
}) {
  if (balances.isEmpty) {
    return formatAccountMoney(0, digits: digits, currency: currency);
  }
  return balances
      .map(
        (balance) => formatAccountMoney(
          balance.amountMinor.abs(),
          digits: balance.digits,
          currency: balance.currency,
        ),
      )
      .join(' + ');
}

/// Everything owed to you (or by you) across [people], per currency.
List<DebtBalance> totalDebts(
  Iterable<PersonDebts> people, {
  required bool owedToYou,
}) {
  final totals = <(String, int), int>{};
  for (final debts in people) {
    for (final balance in debts.balances) {
      if ((balance.amountMinor > 0) != owedToYou) continue;
      final key = (balance.currency, balance.digits);
      totals[key] = (totals[key] ?? 0) + balance.amountMinor;
    }
  }
  return [
    for (final MapEntry(key: (currency, digits), :value) in totals.entries)
      DebtBalance(currency, digits, value),
  ];
}

/// A person's initials on a soft tint picked from their name, so the same
/// person always looks the same.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar(this.name, {super.key, this.size = 42});
  final String name;
  final double size;

  static const _palette = [
    Color(0xff087cff),
    Color(0xff16a36e),
    Color(0xffef7b2d),
    Color(0xff8b5cf6),
    Color(0xffdb4a8f),
    Color(0xff0e9f9d),
  ];

  static String initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    final first = words.first.characters.first;
    final last = words.length > 1 ? words.last.characters.first : '';
    return '$first$last'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        _palette[name.codeUnits.fold(0, (sum, unit) => sum + unit) %
            _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: .14),
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          fontSize: size * .36,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// When something is due, and the colour to say it in: muted while it's a
/// while off, amber in the last few days, red once overdue.
(String, Color) dueStatus(BuildContext context, DateTime due) {
  const soon = Color(0xffd98a00);
  final colors = SheetColors.of(context);
  final now = DateTime.now();
  final days = DateTime.utc(
    due.year,
    due.month,
    due.day,
  ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  return switch (days) {
    < 0 => (
      'Overdue · ${-days} ${days == -1 ? 'day' : 'days'}',
      colors.expense,
    ),
    0 => ('Due today', soon),
    1 => ('Due tomorrow', soon),
    <= 3 => ('Due in $days days', soon),
    _ => (
      'Due ${DateFormat(due.year == now.year ? 'd MMM' : 'd MMM yyyy').format(due)}',
      colors.muted,
    ),
  };
}

/// [dueStatus] as a tinted pill.
class DueChip extends StatelessWidget {
  const DueChip(this.due, {super.key, this.minHeight = 0});
  final DateTime due;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final (label, color) = dueStatus(context, due);
    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      // Scales down instead of overflowing when the space left beside a
      // neighbouring button is tighter than the label.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
