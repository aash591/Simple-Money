import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/currency_scope.dart';
import '../../../domain/debt.dart';
import '../../../domain/loan.dart';
import '../../../domain/recurring_payment.dart';
import '../../../state/account_store.dart';
import '../../../state/debt_store.dart';
import '../../../state/loan_store.dart';
import '../../../state/recurring_payment_store.dart';
import '../../components/charts/charts.dart';
import '../../components/common.dart';
import '../../components/currency_notice.dart';
import '../../components/add_prompt_card.dart';
import '../../more/loans/loan_flow_screen.dart';
import '../../more/recurring/recurring_payment_sheet.dart';
import 'home_card.dart';

/// What goes out and what comes in over the next 30 days, drawn as a
/// timeline: money you get rises above a centre line, money you pay drops
/// below it, each day as tall as its amount.
class CommittedCard extends StatelessWidget {
  const CommittedCard({
    super.key,
    required this.accountStore,
    required this.currency,
    this.loanStore,
    this.recurringPaymentStore,
    this.debtStore,
    this.now,
  });
  final AccountStore accountStore;
  final LoanStore? loanStore;
  final RecurringPaymentStore? recurringPaymentStore;
  final DebtStore? debtStore;
  final CurrencyScope currency;

  /// Stands in for the clock in tests.
  final DateTime? now;

  static const days = 30;

  String _money(num minor) => homeMoney(minor.round(), currency);

  /// Whether anything is set up that could fall due: an open loan, a
  /// recurring payment, or a debt with a due date.
  bool get _configured =>
      (loanStore?.loans.any((l) => !l.closed) ?? false) ||
      (recurringPaymentStore?.recurringPayments.isNotEmpty ?? false) ||
      (debtStore?.people.any((p) => p.dueDate != null) ?? false);

  /// Every payment that falls in the window, as the day it lands (0 is
  /// today; anything overdue counts as today) and its amount.
  List<_Flow> _flows(CurrencyTotals totals) {
    final today = now ?? DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final horizon = DateTime(today.year, today.month, today.day + days + 1);
    final flows = <_Flow>[];
    int dayOf(DateTime d) => math.max(0, d.difference(start).inDays);
    void add(
      DateTime due,
      int native,
      String code,
      int digits,
      bool incoming,
      String label,
    ) {
      final converted = totals.convert(native, code, digits);
      if (converted != null && converted > 0) {
        flows.add(_Flow(dayOf(due), converted, incoming, label));
      }
    }

    for (final loan in loanStore?.loans ?? const <Loan>[]) {
      if (loan.closed ||
          !currency.includes(loan.terms.currency, loan.terms.digits)) {
        continue;
      }
      for (final row in loan.schedule) {
        if (!row.due.isBefore(horizon)) break;
        add(
          row.due,
          row.amount,
          loan.terms.currency,
          loan.terms.digits,
          false,
          '${loan.terms.lender} EMI',
        );
      }
    }
    for (final s
        in recurringPaymentStore?.recurringPayments ??
            const <RecurringPayment>[]) {
      if (s.paused || !currency.includes(s.currency, s.digits)) continue;
      for (
        var due = s.nextDue;
        due.isBefore(horizon);
        due = s.cycle.after(due, s.day)
      ) {
        add(due, s.amountMinor, s.currency, s.digits, s.incoming, s.name);
      }
    }
    for (final person in debtStore?.people ?? const <PersonDebts>[]) {
      final due = person.dueDate;
      if (due == null || !due.isBefore(horizon)) continue;
      for (final balance in person.balances) {
        if (balance.amountMinor == 0) continue;
        // Negative is money you owe; positive is money owed to you.
        add(
          due,
          balance.amountMinor.abs(),
          balance.currency,
          balance.digits,
          balance.amountMinor > 0,
          person.person.name,
        );
      }
    }
    return flows;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      accountStore,
      ?loanStore,
      ?recurringPaymentStore,
      ?debtStore,
    ]),
    builder: (context, _) {
      // Until a loan, a recurring payment or a dated debt exists there is nothing
      // to plan around: invite adding one instead of showing an empty chart.
      if (!_configured) {
        if (loanStore == null && recurringPaymentStore == null) {
          return const SizedBox.shrink();
        }
        return AddPromptCard(
          icon: Icons.lock_clock_outlined,
          title: 'Plan the next $days days',
          message: 'Add a loan or recurring payment to see what\'s due.',
          actions: [
            if (loanStore != null)
              AddPromptAction(
                icon: Icons.account_balance_outlined,
                label: 'Add loan',
                onTap: () => showAddLoanFlow(context, loanStore!),
              ),
            if (recurringPaymentStore != null)
              AddPromptAction(
                icon: Icons.autorenew_rounded,
                label: 'Add recurring payment',
                onTap: () => showRecurringPaymentSheet(
                  context,
                  store: recurringPaymentStore!,
                ),
              ),
          ],
        );
      }
      final palette = ChartPalette.of(context);
      final totals = CurrencyTotals(currency);
      final flows = _flows(totals);
      final pay = flows
          .where((f) => !f.incoming)
          .fold(0, (sum, f) => sum + f.amount);
      final get = flows
          .where((f) => f.incoming)
          .fold(0, (sum, f) => sum + f.amount);
      final today = now ?? DateTime.now();
      return HomeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle('Coming up'),
            const SizedBox(height: 12),
            CurrencyNotice(scope: currency, missing: totals.missing),
            _Plan(
              start: DateTime(today.year, today.month, today.day),
              days: days,
              flows: flows,
              pay: pay,
              get: get,
              money: _money,
              out: palette.expense,
              incoming: palette.income,
            ),
          ],
        ),
      );
    },
  );
}

class _Flow {
  const _Flow(this.day, this.amount, this.incoming, this.label);
  final int day, amount;
  final bool incoming;
  final String label;
}

/// The calendar, what is due in total, and in words either the next payment
/// or, once a day is tapped, everything due that day.
class _Plan extends StatefulWidget {
  const _Plan({
    required this.start,
    required this.days,
    required this.flows,
    required this.pay,
    required this.get,
    required this.money,
    required this.out,
    required this.incoming,
  });
  final DateTime start;
  final int days, pay, get;
  final List<_Flow> flows;
  final String Function(num) money;
  final Color out, incoming;

  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final flows = widget.flows;
    final selected = _selected;
    final chosen = selected == null
        ? const <_Flow>[]
        : [
            for (final f in flows)
              if (f.day == selected) f,
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (flows.isNotEmpty) ...[
          const SizedBox(height: 4),
          Semantics(
            label:
                '${widget.money(widget.pay)} to pay and '
                '${widget.money(widget.get)} to get over the next '
                '${widget.days} days',
            child: _Calendar(
              start: widget.start,
              days: widget.days,
              flows: flows,
              out: widget.out,
              incoming: widget.incoming,
              selected: selected,
              onSelect: (day) =>
                  setState(() => _selected = day == selected ? null : day),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: _Key(
                color: widget.out,
                label: 'To pay',
                amount: widget.money(widget.pay),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: _Key(
                color: widget.incoming,
                label: 'To get',
                amount: widget.money(widget.get),
                end: true,
              ),
            ),
          ],
        ),
        if (flows.isEmpty) ...[
          const SizedBox(height: 14),
          Text(
            'Nothing due in the next ${widget.days} days.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ] else ...[
          const SizedBox(height: 14),
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: chosen.isEmpty
                ? _NextUp(
                    flow: flows.reduce((a, b) => b.day < a.day ? b : a),
                    money: widget.money,
                  )
                : _DayInfo(
                    flows: chosen,
                    money: widget.money,
                    out: widget.out,
                    incoming: widget.incoming,
                  ),
          ),
        ],
      ],
    );
  }
}

/// A coloured dot, a label and an amount; [end] aligns it to the right.
class _Key extends StatelessWidget {
  const _Key({
    required this.color,
    required this.label,
    required this.amount,
    this.end = false,
  });
  final Color color;
  final String label, amount;
  final bool end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            amount,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// Everything due on the tapped day.
class _DayInfo extends StatelessWidget {
  const _DayInfo({
    required this.flows,
    required this.money,
    required this.out,
    required this.incoming,
  });
  final List<_Flow> flows;
  final String Function(num) money;
  final Color out, incoming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in flows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: f.incoming ? incoming : out,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    f.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${f.incoming ? '+' : '-'} ${money(f.amount)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The next 30 days as a calendar: a filled day has money going out (red) or
/// coming in (green); one with both is split half and half.
class _Calendar extends StatelessWidget {
  const _Calendar({
    required this.start,
    required this.days,
    required this.flows,
    required this.out,
    required this.incoming,
    required this.selected,
    required this.onSelect,
  });
  final DateTime start;
  final int days;
  final List<_Flow> flows;
  final Color out, incoming;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    // Weekday columns, Monday first; the first row starts at today's column.
    final lead = start.weekday - 1;
    final cells = lead + days + 1;
    final rows = (cells / 7).ceil();
    bool has(int day, bool inc) =>
        flows.any((f) => f.day == day && f.incoming == inc);
    Widget cell(int index) {
      final day = index - lead;
      if (day < 0 || day > days) return const SizedBox.shrink();
      final date = DateTime(start.year, start.month, start.day + day);
      final pays = has(day, false), gets = has(day, true);
      final fill = pays ? out : (gets ? incoming : null);
      final chosen = selected == day;
      final cell = Padding(
        padding: const EdgeInsets.all(2),
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: pays && gets ? null : fill,
              // Money both ways: half red, half green.
              gradient: pays && gets
                  ? LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: const [0, .5, .5, 1],
                      colors: [out, out, incoming, incoming],
                    )
                  : null,
              border: chosen
                  ? Border.all(color: theme.colorScheme.onSurface, width: 2.5)
                  : day == 0 && fill == null
                  ? Border.all(color: muted ?? Colors.grey, width: 1.5)
                  : null,
            ),
            child: Center(
              child: Text(
                '${date.day}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: fill == null ? FontWeight.w400 : FontWeight.w700,
                  color: fill == null ? muted : Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
      if (fill == null) return cell;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(day),
        child: cell,
      );
    }

    return Column(
      children: [
        Row(
          children: [
            for (final letter in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(
                child: Center(
                  child: Text(letter, style: theme.textTheme.bodySmall),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        for (var r = 0; r < rows; r++)
          Row(
            children: [
              for (var c = 0; c < 7; c++) Expanded(child: cell(r * 7 + c)),
            ],
          ),
      ],
    );
  }
}

/// The soonest payment, in words.
class _NextUp extends StatelessWidget {
  const _NextUp({required this.flow, required this.money});
  final _Flow flow;
  final String Function(num) money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = switch (flow.day) {
      0 => 'today',
      1 => 'tomorrow',
      final d => 'in $d days',
    };
    return Text(
      'Next: ${flow.label} ${flow.incoming ? 'is expected' : 'is due'} $when · '
      '${money(flow.amount)}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium,
    );
  }
}
