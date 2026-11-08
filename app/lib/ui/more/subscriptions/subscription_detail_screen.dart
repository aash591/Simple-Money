import 'package:flutter/material.dart';

import '../../components/advance_payment_notice.dart';

import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/subscription.dart';
import '../../../state/subscription_store.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';

import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/detail_page.dart';
import '../../components/feature_page.dart';
import '../../components/more_popup_button.dart';
import '../../theme/sheet_colors.dart';
import '../debts/debt_widgets.dart';
import 'mark_paid_sheet.dart';
import 'renewal_outcome.dart';
import 'subscription_sheet.dart';

/// Everything about one subscription: what it costs, when it renews next and
/// what to do about that, then the facts behind it and what has actually been
/// paid so far.
///
/// Reached by tapping a subscription anywhere it is listed. Editing stays in
/// its sheet, one step further in, so this page can answer "what am I paying
/// for and when" without asking anyone to read a form.
class SubscriptionDetailScreen extends StatefulWidget {
  const SubscriptionDetailScreen({
    super.key,
    required this.store,
    required this.id,
  });
  final SubscriptionStore store;
  final int id;

  @override
  State<SubscriptionDetailScreen> createState() =>
      _SubscriptionDetailScreenState();
}

class _SubscriptionDetailScreenState extends State<SubscriptionDetailScreen> {
  late Future<List<SubscriptionPayment>> _payments = _loadPayments();
  String? _error;

  SubscriptionStore get _store => widget.store;

  Future<List<SubscriptionPayment>> _loadPayments() =>
      _store.repository.payments(widget.id);

  @override
  void initState() {
    super.initState();
    // Marking paid or skipping from here writes new history.
    _store.addListener(_reloadPayments);
  }

  @override
  void dispose() {
    _store.removeListener(_reloadPayments);
    super.dispose();
  }

  void _reloadPayments() {
    if (mounted) setState(() => _payments = _loadPayments());
  }

  /// Runs a store action, surfacing whatever it refuses to do in place
  /// rather than as a toast that disappears before it can be read.
  Future<void> _run(Future<void> Function() action) async {
    if (_store.saving) return;
    setState(() => _error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ArgumentError || e is StateError
              ? '${(e as dynamic).message}'
              : 'That didn’t work. Please try again.',
        );
      }
    }
  }

  Future<void> _togglePause(Subscription s) => _run(() async {
    await _store.save(() => _store.repository.setPaused(s, !s.paused));
    if (mounted) {
      showAppToast(context, s.paused ? 'Subscription resumed' : 'Paused');
    }
  });

  Future<void> _skip(Subscription s) async {
    final colors = SheetColors.of(context);
    final confirmed = await showConfirmationAlert(
      context,
      title: 'Skip this renewal?',
      message: 'No payment recorded. Account balance unchanged.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RenewalOutcome(
            icon: Icons.event_repeat_rounded,
            color: colors.primary,
            label: 'Next renewal',
            value: DateFormat('d MMM yyyy').format(s.followingDue),
          ),
          RenewalOutcome(
            icon: Icons.money_off_rounded,
            color: colors.muted,
            label: 'Payment',
            value: 'Not recorded',
            caption: 'Account balance unchanged',
          ),
        ],
      ),
      confirmLabel: 'Skip',
      destructive: false,
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      await _store.save(() => _store.repository.skip(s));
      if (mounted) showAppToast(context, 'Renewal skipped');
    });
  }

  Future<void> _delete(Subscription s) async {
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete ${s.name}?',
      message:
          'Removes the subscription and its reminders. Past payments stay.',
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      await _store.save(() => _store.repository.delete(s.id));
      if (!mounted) return;
      showAppToast(context, 'Subscription deleted');
      Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final s = _store.byId(widget.id);
      if (s == null) {
        return const FeaturePage(
          title: 'Subscription',
          child: Center(child: Text('This subscription is no longer here.')),
        );
      }
      final colors = SheetColors.of(context);
      return FeaturePage(
        title: s.name,
        actions: [
          MorePopupButton<String>(
            items: [
              const MorePopupItem(
                value: 'edit',
                label: 'Edit subscription',
                icon: Icons.edit_outlined,
              ),
              MorePopupItem(
                value: 'pause',
                label: s.paused ? 'Resume subscription' : 'Pause subscription',
                icon: s.paused
                    ? Icons.play_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
              ),
              const MorePopupItem(
                value: 'delete',
                label: 'Delete subscription',
                icon: Icons.delete_outline_rounded,
                dividerBefore: true,
              ),
            ],
            onSelected: (value) => switch (value) {
              'edit' => showSubscriptionSheet(
                context,
                store: _store,
                existing: s,
              ),
              'pause' => _togglePause(s),
              _ => _delete(s),
            },
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
          children: [
            _Hero(subscription: s),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.expense),
              ),
            ],
            const SizedBox(height: 22),
            DetailSectionHeading(
              'Next renewal',
              status: s.paused ? null : DueChip(s.nextDue),
            ),
            const SizedBox(height: 10),
            _NextRenewal(
              subscription: s,
              account: _accountName(_store, s),
              saving: _store.saving,
              onMarkPaid: () =>
                  showMarkPaidSheet(context, store: _store, subscription: s),
              onSkip: () => _skip(s),
              onResume: () => _togglePause(s),
            ),
            const SizedBox(height: 22),
            const SectionTitle('Details'),
            const SizedBox(height: 10),
            _Details(subscription: s, store: _store),
            const SizedBox(height: 22),
            const SectionTitle('Payments'),
            const SizedBox(height: 10),
            _Payments(subscription: s, payments: _payments),
          ],
        ),
      );
    },
  );
}

/// The account it is charged to, or null once that account has been deleted.
String? _accountName(SubscriptionStore store, Subscription s) =>
    store.accountStore.byId(s.accountId)?.name;

/// The identity of the thing, and the one number that matters most.
class _Hero extends StatelessWidget {
  const _Hero({required this.subscription});
  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    final s = subscription;
    final colors = SheetColors.of(context);
    return DetailHero(
      leading: AppIcon(s.icon, size: 64),
      title: s.name,
      amount: formatAccountMoney(
        s.amountMinor,
        digits: s.digits,
        currency: s.currency,
      ),
      caption: '/ ${s.cycle.per}',
      banner: s.paused
          ? DetailBanner(
              icon: Icons.pause_circle_filled_rounded,
              color: colors.muted,
              text: 'Paused — nothing is being charged.',
            )
          : null,
    );
  }
}

/// When the next payment lands, and the two things worth doing about it.
class _NextRenewal extends StatelessWidget {
  const _NextRenewal({
    required this.subscription,
    required this.account,
    required this.saving,
    required this.onMarkPaid,
    required this.onSkip,
    required this.onResume,
  });
  final Subscription subscription;
  final String? account;
  final bool saving;
  final VoidCallback onMarkPaid, onSkip, onResume;

  @override
  Widget build(BuildContext context) {
    final s = subscription;
    if (s.paused) {
      return MoneyCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paused, so nothing is due. Resume to restart from the next renewal.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            DetailActions(
              primaryLabel: 'Resume subscription',
              primaryIcon: Icons.play_arrow_rounded,
              onPrimary: saving ? null : onResume,
            ),
          ],
        ),
      );
    }
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            DateFormat('EEEE, d MMMM y').format(s.nextDue),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            account == null ? 'No account chosen yet' : 'Charged to $account',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          DetailActions(
            primaryLabel: isFuturePayment(s.nextDue)
                ? 'Record advance payment'
                : 'Mark paid',
            primaryIcon: Icons.check_circle_outline_rounded,
            onPrimary: saving ? null : onMarkPaid,
            secondaryLabel: 'Skip this one',
            secondaryIcon: Icons.skip_next_rounded,
            onSecondary: saving ? null : onSkip,
          ),
        ],
      ),
    );
  }
}

/// The facts behind the headline, including what it works out to over
/// periods the billing cycle doesn't name.
class _Details extends StatelessWidget {
  const _Details({required this.subscription, required this.store});
  final Subscription subscription;
  final SubscriptionStore store;

  @override
  Widget build(BuildContext context) {
    final s = subscription;
    String money(int minor) =>
        formatAccountMoney(minor, digits: s.digits, currency: s.currency);
    final category = store.categoryStore.categories
        .where((c) => c.id == s.categoryId)
        .firstOrNull;
    final account = store.accountStore.byId(s.accountId);
    return DetailFacts(
      facts: [
        DetailFact('Billing', s.cycle.label),
        DetailFact('Renews on', _renewsOn(s)),
        DetailFact(
          'Paid from',
          account?.name ?? 'Not set',
          leading: account == null ? null : AppIcon(account.icon, size: 24),
          quiet: account == null,
        ),
        DetailFact(
          'Category',
          category?.name ?? 'Uncategorized',
          leading: category == null ? null : AppIcon(category.icon, size: 24),
          quiet: category == null,
        ),
        DetailFact('Reminder', s.remind ? 'On' : 'Off'),
        // A yearly plan's real monthly cost is the number people actually
        // want when comparing it against everything else.
        if (s.cycle != BillingCycle.monthly)
          DetailFact('Works out to', '${money(s.monthlyAmount)} a month'),
        DetailFact('Over a year', money(s.yearlyAmount)),
      ],
    );
  }

  /// Says the renewal date the way someone would say it out loud, which each
  /// cycle words differently — a yearly plan needs its month to mean anything,
  /// and a weekly one has no day of the month at all.
  static String _renewsOn(Subscription s) => switch (s.cycle) {
    BillingCycle.weekly => 'Every ${DateFormat('EEEE').format(s.nextDue)}',
    BillingCycle.monthly => '${_ordinal(s.day)} of each month',
    BillingCycle.quarterly => '${_ordinal(s.day)}, every 3 months',
    BillingCycle.yearly =>
      '${_ordinal(s.day)} ${DateFormat.MMMM().format(s.nextDue)}, every year',
  };

  static String _ordinal(int day) {
    // 11th, 12th and 13th break the pattern the last digit otherwise sets.
    if (day >= 11 && day <= 13) return '${day}th';
    return switch (day % 10) {
      1 => '${day}st',
      2 => '${day}nd',
      3 => '${day}rd',
      _ => '${day}th',
    };
  }
}

/// What has actually been charged, newest first.
class _Payments extends StatelessWidget {
  const _Payments({required this.subscription, required this.payments});
  final Subscription subscription;
  final Future<List<SubscriptionPayment>> payments;

  @override
  Widget build(BuildContext context) {
    final s = subscription;
    String money(int minor) =>
        formatAccountMoney(minor, digits: s.digits, currency: s.currency);
    return FutureBuilder<List<SubscriptionPayment>>(
      future: payments,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const DetailEmpty(
            icon: Icons.error_outline_rounded,
            title: 'Payments unavailable',
            message: 'That history could not be loaded just now.',
          );
        }
        if (!snapshot.hasData) {
          return const MoneyCard(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }
        final rows = snapshot.data!;
        final colors = SheetColors.of(context);
        return DetailHistoryCard(
          empty: const DetailEmpty(
            icon: Icons.receipt_long_outlined,
            title: 'No payments yet',
            message: 'Marking paid records it here and in its account.',
          ),
          footer: rows.length > 1
              ? '${rows.length} payments · '
                    '${money(rows.fold(0, (n, p) => n + p.amountMinor))} so far'
              : null,
          entries: [
            for (final payment in rows)
              DetailEntry(
                leading: DetailIconTile(
                  Icons.check_rounded,
                  color: colors.income,
                ),
                title: DateFormat.yMMMd().format(payment.date),
                caption: payment.account == null
                    ? 'Account deleted'
                    : 'Paid from ${payment.account}',
                amount: money(payment.amountMinor),
              ),
          ],
        );
      },
    );
  }
}
