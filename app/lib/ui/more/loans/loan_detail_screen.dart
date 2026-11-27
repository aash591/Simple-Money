import 'package:flutter/material.dart';

import '../../components/advance_payment_notice.dart';

import 'package:intl/intl.dart';

import '../../../domain/loan.dart';
import '../../../state/loan_store.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_icon.dart';
import '../../components/common.dart';
import '../../components/app_toast.dart';
import '../../components/more_popup_button.dart';
import '../../components/segmented_pill.dart';
import '../../theme/app_theme.dart' show usesGlass;
import '../../theme/sheet_colors.dart';
import '../../components/confirmation_alert.dart';
import '../../components/detail_page.dart';
import '../../components/feature_page.dart';
import '../debts/debt_widgets.dart';
import 'loan_action_sheet.dart';
import 'loan_flow_screen.dart';
import 'loan_payoff_chart.dart';
import 'loan_review_card.dart';
import 'loan_widgets.dart';

class LoanDetailScreen extends StatefulWidget {
  const LoanDetailScreen({super.key, required this.store, required this.id});
  final LoanStore store;
  final int id;
  @override
  State<LoanDetailScreen> createState() => _LoanDetailScreenState();
}

class _LoanDetailScreenState extends State<LoanDetailScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);
  String? _error;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _menu(String action, Loan loan) async {
    if (widget.store.saving) return;
    setState(() => _error = null);
    try {
      if (action == 'delete') {
        final confirmed = await showDeleteConfirmation(
          context,
          title: 'Delete this loan?',
          message: 'Stops tracking and reminders. Payments stay in your account history.',
        );
        if (!confirmed || !mounted) return;
        await widget.store.save(() => widget.store.repository.delete(loan));
        if (!mounted) return;
        showAppToast(context, 'Loan deleted');
        Navigator.pop(context);
      } else if (action == 'undo') {
        final confirmed = await showConfirmationAlert(
          context,
          title: 'Undo latest action?',
          message: 'Brings back the previous balance and terms, and removes the linked payment.',
          confirmLabel: 'Undo',
        );
        if (!confirmed || !mounted) return;
        await widget.store.save(() => widget.store.repository.undo(loan));
        if (mounted) showAppToast(context, 'Latest action undone');
      } else if (action == 'edit') {
        await showEditLoanFlow(context, widget.store, loan);
      } else {
        await showLoanAction(
          context,
          widget.store,
          loan,
          LoanEventKind.values.byName(action),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = loanError(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final loan = widget.store.byId(widget.id);
      if (loan == null) {
        return const FeaturePage(
          title: 'Loan',
          child: Center(child: Text('This loan is no longer available.')),
        );
      }
      final theme = Theme.of(context);
      final colors = SheetColors.of(context);
      String money(int n) => loanMoney(loan.terms, n);
      final schedule = loan.schedule;
      final progress = loan.closed ? 1.0 : loan.progress.clamp(0.0, 1.0);
      final children = <Widget>[
        if (_error != null) LoanNote(_error!, error: true),
        LoanSummaryCard(
          leading: BadgedAppIcon(
            loan.icon,
            badgeKey: loan.icon == loan.terms.icon ? null : loan.terms.icon,
            size: 40,
          ),
          title: loan.title,
          subtitle: loan.terms.mode.label,
          amount: money(loan.terms.principal),
          progress: progress,
          repaid: money(loan.terms.principal - loan.outstanding),
          remaining: money(loan.outstanding),
        ),
        if (loan.closed) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 18, color: colors.income),
              const SizedBox(width: 8),
              Text(
                'Loan closed',
                style: TextStyle(
                  color: colors.income,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _closureSummary(loan),
        ],
        const SizedBox(height: 22),
        if (!loan.closed && schedule.isEmpty) ...[
          LoanSection(
            title: 'Payments',
            children: [
              if (loan.terms.mode.amortises) ...[
                LoanValue('Agreed monthly instalment', money(loan.emi)),
                LoanValue('Next instalment date', loanDate(loan.nextDue)),
              ],
              LoanValue(
                'Final due date',
                loan.terms.maturityDate == null
                    ? 'No fixed duration'
                    : loanDate(loan.terms.maturityDate!),
              ),
              const LoanNote(
                'Record the lender’s actual interest and principal allocation for each payment.',
              ),
              FilledButton.icon(
                onPressed: widget.store.saving
                    ? null
                    : () => _menu('emi', loan),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Record payment'),
              ),
            ],
          ),
        ],
        if (!loan.closed && schedule.isNotEmpty) ...[
          DetailSectionHeading(
            'Next ${loan.terms.mode.paymentNoun}',
            status: DueChip(loan.nextDue),
          ),
          const SizedBox(height: 10),
          MoneyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  money(schedule.first.amount),
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 14),
                LoanValue('Due date', loanDate(loan.nextDue)),
                LoanValue('Principal', money(schedule.first.principal)),
                LoanValue('Interest', money(schedule.first.interest)),
                const SizedBox(height: 12),
                DetailActions(
                  primaryLabel: isFuturePayment(loan.nextDue)
                      ? 'Record advance payment'
                      : 'Mark paid',
                  primaryIcon: Icons.check_circle_outline_rounded,
                  onPrimary: widget.store.saving
                      ? null
                      : () => _menu('emi', loan),
                  secondaryLabel: 'Make a part-payment',
                  secondaryIcon: Icons.add_card_rounded,
                  onSecondary: widget.store.saving
                      ? null
                      : () => _menu('partPayment', loan),
                ),
                if (loan.accountId == null)
                  const LoanNote(
                    'Choose a repayment account when recording your payment.',
                  ),
              ],
            ),
          ),
          const SizedBox(height: 22),
        ],
        if (!loan.closed && schedule.length > 1)
          LoanSection(
            title: 'Payoff',
            children: [
              LoanPayoffChart(
                payoff: LoanPayoff([loan]),
                currency: loan.terms.currency,
                digits: loan.terms.digits,
              ),
            ],
          ),
        ..._infoGrids(loan),
      ];
      return FeaturePage(
        title: 'Loan details',
        actions: [
          MorePopupButton<String>(
            items: widget.store.saving
                ? const []
                : [
                    const MorePopupItem(
                      value: 'edit',
                      label: 'Edit loan',
                      icon: Icons.edit_outlined,
                    ),
                    if (!loan.closed) ...[
                      const MorePopupItem(
                        value: 'rateChange',
                        label: 'Change rate',
                        icon: Icons.percent_rounded,
                      ),
                      const MorePopupItem(
                        value: 'closure',
                        label: 'Close loan',
                        icon: Icons.check_circle_outline_rounded,
                      ),
                    ],
                    if (loan.events.isNotEmpty)
                      const MorePopupItem(
                        value: 'undo',
                        label: 'Undo last',
                        icon: Icons.undo_rounded,
                        dividerBefore: true,
                      ),
                    const MorePopupItem(
                      value: 'delete',
                      label: 'Delete loan',
                      icon: Icons.delete_outline_rounded,
                      dividerBefore: true,
                    ),
                  ],
            onSelected: (action) => _menu(action, loan),
          ),
        ],
        child: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              sliver: SliverList.list(children: children),
            ),
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverPersistentHeader(
                pinned: true,
                delegate: _ActivityTabsHeader(
                  controller: _tabs,
                  // Glassy and Aurora paint their glow behind the page, so a
                  // solid band would show as black (and darken the first row
                  // through its blur).
                  background: usesGlass(context)
                      ? Colors.transparent
                      : theme.scaffoldBackgroundColor,
                  textScaler: MediaQuery.textScalerOf(context),
                ),
              ),
            ),
          ],
          body: TabBarView(
            controller: _tabs,
            children: [
              _ActivityList(name: 'history', rows: _historyRows(loan)),
              _ActivityList(name: 'schedule', rows: _scheduleRows(loan)),
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _infoGrids(Loan loan) {
    final t = loan.terms;
    final schedule = loan.schedule;
    String money(int n) => loanMoney(t, n);
    final emi = t.mode.amortises;
    final unpaid = loan.unpaidInterestAt(DateTime.now());
    final total = loan.totalOutstandingAt(DateTime.now());
    final rate = loan.rate.toStringAsFixed(loan.rate % 1 == 0 ? 0 : 2);
    final months = t.months;
    Widget section(String title, List<DetailFact> facts) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        DetailFacts(facts: facts),
      ],
    );
    final account = widget.store.accountStore.byId(loan.accountId);
    return [
      section('Loan terms', [
        DetailFact('Borrowed', money(t.principal)),
        DetailFact('Start date', loanDate(t.startDate ?? t.firstDue)),
        DetailFact(
          'Interest',
          !t.rateKnown
              ? 'Unknown'
              : t.rate == 0
              ? 'None'
              : '$rate% a year',
          quiet: !t.rateKnown,
        ),
        DetailFact(
          'Duration',
          months == 0
              ? 'No fixed term'
              : months % 12 == 0
              ? '${months ~/ 12} ${months == 12 ? 'year' : 'years'}'
              : '$months months',
          caption: t.maturityDate == null
              ? null
              : 'Ends ${loanDate(t.maturityDate!)}',
        ),
        if (t.tracked)
          DetailFact(
            'Opening balance',
            money(t.openingBalance),
            caption: 'As of ${loanDate(t.snapshotDate ?? t.startDate!)}',
          ),
      ]),
      section('Repayment', [
        DetailFact('Payments', t.mode.label),
        if (emi) DetailFact('Monthly EMI', money(loan.emi)),
        DetailFact(
          'Paid from',
          account?.name ?? 'Not set',
          leading: account == null ? null : AppIcon(account.icon, size: 24),
          quiet: account == null,
        ),
        if (!loan.closed && schedule.isNotEmpty)
          DetailFact('Payments left', '${schedule.length}'),
        if (!loan.closed && schedule.isNotEmpty)
          DetailFact('Estimated end', loanDate(schedule.last.due)),
      ]),
      section('Balance', [
        DetailFact('Remaining principal', money(loan.outstanding)),
        if (t.tracked) ...[
          DetailFact(
            'Unpaid interest (est.)',
            unpaid == null ? 'Unknown' : money(unpaid),
            quiet: unpaid == null,
          ),
          DetailFact(
            'Total outstanding',
            total == null ? 'Unknown' : money(total),
            emphasized: total != null,
            quiet: total == null,
            caption: total == null ? 'Interest not confirmed' : null,
          ),
        ],
      ]),
      section('Cost', [
        if (!loan.closed)
          DetailFact(
            'Future interest (est.)',
            schedule.isEmpty ? 'Not projected' : money(loan.futureInterest),
            quiet: schedule.isEmpty,
          ),
        DetailFact('Interest paid', money(loan.interestPaid)),
        DetailFact('Fees and charges', money(loan.charges)),
        DetailFact(
          loan.closed ? 'Loan cost' : 'Loan cost (est.)',
          !loan.closed && schedule.isEmpty
              ? 'Not projected'
              : money(loan.totalCost),
          emphasized: loan.closed || schedule.isNotEmpty,
          quiet: !loan.closed && schedule.isEmpty,
          caption: 'Interest and fees only',
        ),
      ]),
      const SizedBox(height: 22),
    ];
  }

  List<Widget> _historyRows(Loan loan) {
    final events = [...loan.events]
      ..sort((a, b) {
        final date = b.date.compareTo(a.date);
        return date == 0 ? b.id.compareTo(a.id) : date;
      });
    final rows = <Widget>[
      if (loan.terms.paidBefore > 0)
        LoanNote(
          '${loan.terms.paidBefore} earlier payments are in the opening balance. Their details weren’t imported.',
        ),
      if (events.isEmpty)
        const _LoanEmpty(
          icon: Icons.receipt_long_outlined,
          title: 'No payments recorded yet',
          message:
              'Record a payment to see its amount, account and breakdown here.',
        ),
    ];
    String money(int n) => loanMoney(loan.terms, n);
    // Payments are numbered as they happened, the first one as 1.
    final paidEvents = events
        .where((e) => e.kind != LoanEventKind.rateChange)
        .toList()
        .reversed
        .toList();
    final serial = {for (final (i, e) in paidEvents.indexed) e.id: i + 1};
    // The principal still owed once each payment was made.
    var owed = loan.terms.openingBalance;
    final left = <int, int>{};
    for (final e in paidEvents) {
      owed -= e.principal;
      left[e.id] = owed;
    }
    final months = <String, List<LoanEvent>>{};
    for (final event in events) {
      months
          .putIfAbsent(DateFormat('MMMM yyyy').format(event.date), () => [])
          .add(event);
    }
    for (final MapEntry(key: heading, value: items) in months.entries) {
      // What is still owed at the end of the month: after its latest payment.
      final latest = items
          .where((e) => e.kind != LoanEventKind.rateChange)
          .firstOrNull;
      rows.add(
        _ListHeading(
          heading,
          trailing: latest == null ? null : '${money(left[latest.id]!)} left',
        ),
      );
      final tiles = <Widget>[];
      for (final (i, event) in items.indexed) {
        final rateChange = event.kind == LoanEventKind.rateChange;
        tiles.add(
          _LoanEntryRow(
            icon: switch (event.kind) {
              LoanEventKind.rateChange => Icons.percent_rounded,
              _ => null,
            },
            number: serial[event.id],
            tone: rateChange ? _RowTone.accent : _RowTone.settled,
            title: switch (event.kind) {
              LoanEventKind.emi => '${loan.terms.mode.paymentNoun} paid',
              LoanEventKind.partPayment => 'Part-payment',
              LoanEventKind.rateChange => 'Interest rate changed',
              LoanEventKind.closure => 'Loan closed',
            },
            subtitle: [
              DateFormat('d MMM').format(event.date),
              ?event.accountName,
            ].join(' · '),
            amount: rateChange
                ? '${event.rateAfter}% p.a.'
                : money(event.amount),
            caption: rateChange
                ? loan.terms.mode.amortises && event.emiAfter != null
                      ? 'EMI ${money(event.emiAfter!)}'
                      : null
                : event.interest > 0
                ? '${money(event.interest)} interest'
                : null,
            first: i == 0,
            last: i == items.length - 1,
            onTap: () => rateChange
                ? _showRateChange(loan, event)
                : _showSplit(
                    loan,
                    'Payment details',
                    event.principal,
                    event.interest,
                    event.fee,
                    date: event.date,
                    account: event.accountName,
                    description: loanActionLabel(event.kind),
                    event: event,
                    balance: event.principalBefore == null
                        ? null
                        : event.principalBefore! - event.principal,
                  ),
          ),
        );
      }
      rows.add(_entryGroup(tiles));
    }
    if (paidEvents.isNotEmpty) {
      rows.add(
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LoanNote(
            'Numbers count your payments from the first. “Left” by each '
            'month is the principal still owed at its end, so interest and '
            'fees aren’t in it. Tap a payment to see them.',
          ),
        ),
      );
    }
    return rows;
  }

  Future<void> _showRateChange(
    Loan loan,
    LoanEvent event,
  ) => showAdaptiveSheet<void>(
    context,
    builder: (context) => SheetPage(
      header: SheetHeader(
        'Rate change',
        trailing: CloseButton(onPressed: () => Navigator.pop(context)),
      ),
      body: Column(
        children: [
          LoanIdentity(loan),
          LoanSection(
            children: [
              LoanValue('Effective date', loanDate(event.date)),
              LoanValue('Interest rate', '${event.rateAfter}% p.a.'),
              if (loan.terms.mode.amortises && event.emiAfter != null)
                LoanValue(
                  'Revised EMI',
                  loanMoney(loan.terms, event.emiAfter!),
                ),
              const LoanNote(
                'This updates the repayment schedule. No payment was recorded.',
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _closureSummary(Loan loan) {
    if (loan.terms.tracked) {
      return const Text(
        'Principal and interest settled.',
        textAlign: TextAlign.center,
      );
    }
    final baseline = loanSchedule(
      principal: loan.terms.openingBalance,
      rate: loan.terms.rate,
      emi: loan.terms.emi,
      first: loan.terms.firstDue,
      day: loan.terms.day,
      mode: loan.terms.mode,
      months: loan.terms.remainingMonths,
    ).fold(0, (n, r) => n + r.interest);
    final savings = baseline - loan.interestPaid;
    return Text(
      savings > 0
          ? 'You saved ${loanMoney(loan.terms, savings)} interest compared with the opening schedule.'
          : 'All principal repaid.',
      textAlign: TextAlign.center,
    );
  }

  /// A run of entries as one card. Glassy and Aurora draw it like every other
  /// card on the page; Simple keeps each entry's own surface.
  Widget _entryGroup(List<Widget> tiles) => usesGlass(context)
      ? MoneyCard(
          padding: EdgeInsets.zero,
          child: Column(children: [for (final tile in tiles) tile]),
        )
      : Column(children: tiles);

  List<Widget> _scheduleRows(Loan loan) {
    String installment(int number) =>
        loan.terms.mode.amortises ? 'EMI $number' : 'Payment $number';
    String money(int n) => loanMoney(loan.terms, n);
    final upcoming = loan.schedule;
    return [
      if (loan.closed)
        const _LoanEmpty(
          icon: Icons.check_circle_outline_rounded,
          title: 'All principal repaid',
          message: 'There are no upcoming payments.',
        ),
      if (!loan.closed && upcoming.isEmpty)
        const LoanNote(
          'No schedule for these terms. Your payments show in History.',
        ),
      if (!loan.closed && upcoming.isNotEmpty)
        const LoanNote(
          'Estimated at your current rate. Tap a payment for details.',
        ),
      if (loan.terms.paidBefore > 0)
        LoanNote(
          '${loan.terms.paidBefore} earlier payments are in the opening balance. Their split wasn’t imported.',
        ),
      if (upcoming.isNotEmpty)
        _ListHeading(
          'Upcoming · ${upcoming.length}',
          trailing: money(upcoming.fold(0, (n, r) => n + r.amount)),
        ),
      if (upcoming.isNotEmpty)
        _entryGroup([
          for (final (i, row) in upcoming.indexed)
            _LoanEntryRow(
              icon: i == 0 ? Icons.schedule_rounded : Icons.event_outlined,
              tone: i == 0 ? _RowTone.accent : _RowTone.neutral,
              title: installment(row.number),
              badge: i == 0 ? 'Next' : null,
              subtitle: 'Due ${loanDate(row.due)}',
              amount: money(row.amount),
              caption: '${money(row.balance)} left',
              first: i == 0,
              last: i == upcoming.length - 1,
              onTap: () => _showSplit(
                loan,
                installment(row.number),
                row.principal,
                row.interest,
                0,
                date: row.due,
                balance: row.balance,
                estimated: true,
              ),
            ),
        ]),
    ];
  }

  Future<void> _showSplit(
    Loan loan,
    String title,
    int principal,
    int interest,
    int fee, {
    DateTime? date,
    String? account,
    String? description,
    int? balance,
    LoanEvent? event,
    bool estimated = false,
  }) async {
    await showAdaptiveSheet<void>(
      context,
      builder: (context) => SheetPage(
        header: SheetHeader(
          title,
          trailing: CloseButton(onPressed: () => Navigator.pop(context)),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LoanIdentity(loan),
            LoanSection(
              children: [
                Text(
                  estimated
                      ? 'Estimated payment'
                      : description ?? 'Recorded payment',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Text(
                  loanMoney(loan.terms, principal + interest + fee),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                if (date != null)
                  LoanValue(
                    estimated ? 'Due date' : 'Payment date',
                    loanDate(date),
                  ),
                if (account != null) LoanValue('Paid from', account),
                const Divider(height: 24),
                LoanValue('Principal', loanMoney(loan.terms, principal)),
                LoanValue('Interest', loanMoney(loan.terms, interest)),
                if (fee > 0) LoanValue('Fees', loanMoney(loan.terms, fee)),
                if (balance != null) ...[
                  const Divider(height: 24),
                  if (event?.principalBefore != null)
                    LoanValue(
                      'Principal before payment',
                      loanMoney(loan.terms, event!.principalBefore!),
                    ),
                  LoanValue(
                    'Principal after payment',
                    loanMoney(loan.terms, balance),
                  ),
                ],
                if (event?.principalBefore != null) ...[
                  LoanValue(
                    'Unpaid interest before',
                    event!.interestBefore == null
                        ? 'Unknown'
                        : loanMoney(loan.terms, event.interestBefore!),
                  ),
                  LoanValue(
                    'Unpaid interest after',
                    event.interestAfter == null
                        ? 'Unknown'
                        : loanMoney(loan.terms, event.interestAfter!),
                  ),
                  if (event.interestBefore != null &&
                      event.interestAfter != null &&
                      event.interestAfter !=
                          event.interestBefore! - event.interest)
                    const LoanNote(
                      'The unpaid interest balance was confirmed against the lender’s statement.',
                    ),
                ],
              ],
            ),
            if (estimated)
              const LoanNote(
                'Estimated at today’s rate. Your lender’s amount may differ.',
              ),
          ],
        ),
      ),
    );
  }
}

class _ListHeading extends StatelessWidget {
  const _ListHeading(this.title, {this.trailing});
  final String title;
  final String? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Text(trailing!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// History / Schedule switch, pinned under the header while the lists scroll.
class _ActivityTabsHeader extends SliverPersistentHeaderDelegate {
  _ActivityTabsHeader({
    required this.controller,
    required this.background,
    required this.textScaler,
  });
  final TabController controller;
  final Color background;
  final TextScaler textScaler;

  @override
  double get minExtent => textScaler.scale(18) + 34;
  @override
  double get maxExtent => minExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      SizedBox(
        height: maxExtent,
        child: ColoredBox(
          color: background,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: Center(
              child: SegmentedPillTabBar(
                controller: controller,
                labels: const ['History', 'Schedule'],
                icons: const [
                  Icons.history_rounded,
                  Icons.calendar_month_outlined,
                ],
              ),
            ),
          ),
        ),
      );

  @override
  bool shouldRebuild(_ActivityTabsHeader old) =>
      old.controller != controller ||
      old.background != background ||
      old.textScaler != textScaler;
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.name, required this.rows});
  final String name;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: PageStorageKey(name),
    slivers: [
      SliverOverlapInjector(
        handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 32),
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (_, index) => rows[index],
        ),
      ),
    ],
  );
}

class _LoanEmpty extends StatelessWidget {
  const _LoanEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title, message;
  @override
  Widget build(BuildContext context) => LoanSection(
    children: [
      const SizedBox(height: 10),
      Icon(icon, size: 32, color: SheetColors.of(context).muted),
      const SizedBox(height: 14),
      Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
      ),
      const SizedBox(height: 10),
    ],
  );
}

enum _RowTone { settled, accent, neutral }

/// One row of a grouped card; [first] and [last] round the card's corners.
///
/// A thin adapter over [DetailHistoryTile], so a loan payment reads exactly
/// like a recurring payment charge or a debt repayment does.
class _LoanEntryRow extends StatelessWidget {
  const _LoanEntryRow({
    this.icon,
    this.number,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.onTap,
    required this.first,
    required this.last,
    this.caption,
    this.badge,
  });
  final IconData? icon;

  /// Shown in place of [icon] when set.
  final int? number;
  final _RowTone tone;
  final String title, subtitle, amount;
  final String? caption, badge;
  final VoidCallback onTap;
  final bool first, last;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final color = switch (tone) {
      _RowTone.settled => colors.income,
      _RowTone.accent => colors.primary,
      _RowTone.neutral => colors.muted,
    };
    return DetailHistoryTile(
      DetailEntry(
        leading: number != null
            ? DetailIconTile.number(number!, color: color)
            : DetailIconTile(icon!, color: color),
        title: title,
        caption: subtitle,
        badge: badge,
        amount: amount,
        amountCaption: caption,
        onTap: onTap,
      ),
      grouped: !usesGlass(context),
      first: first,
      last: last,
    );
  }
}
