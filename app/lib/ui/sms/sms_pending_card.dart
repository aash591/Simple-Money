import 'sms_review_card.dart';
import 'sms_scan_card.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import 'sms_results_page.dart';
import 'sms_suggestions.dart';
import 'sms_amount_style.dart';

import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../domain/account.dart';
import '../../state/sms_import_store.dart';
import '../components/app_icon.dart';
import '../components/feature_page.dart';
import '../components/transactions/transaction_day_group.dart';
import '../components/transactions/transaction_list_row.dart';
import '../components/transactions/transaction_row.dart';
import '../home/cards/home_card.dart';

class SmsPendingTile extends StatelessWidget {
  const SmsPendingTile({super.key, required this.sms, required this.onTap});
  final PendingSmsImport sms;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => TransactionRow(
    icon: AppIcon(smsBankIcon(sms), size: 40),
    title: sms.title,
    subtitle: [
      sms.credit ? 'Received' : 'Paid',
      if (sms.accountLast4 case final last4?) '${sms.bankName} ••$last4',
    ].join(' · '),
    amount:
        '${sms.credit ? '+' : '−'}'
        '${formatAccountMoney(sms.amountMinor, currency: sms.currency, digits: sms.digits)}',
    amountColor: smsAmountColor(sms),
    stamp: transactionStamp(sms.receivedAt),
    onTap: onTap,
  );
}

/// One waiting message on a single line, for the Home card: the bank's icon,
/// who and which bank, and the amount at the right.
class SmsCompactTile extends StatelessWidget {
  const SmsCompactTile({super.key, required this.sms, required this.onTap});
  final PendingSmsImport sms;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            AppIcon(smsBankIcon(sms), size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sms.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${sms.credit ? 'Received' : 'Paid'} · ${sms.bankName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${sms.credit ? '+' : '−'}'
                  '${formatAccountMoney(sms.amountMinor, currency: sms.currency, digits: sms.digits)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: smsAmountColor(sms),
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SmsPendingCard extends StatelessWidget {
  const SmsPendingCard({
    super.key,
    required this.store,
    required this.onReview,
    this.accounts,
    this.categories,
    this.transactions,
  });
  final AccountStore? accounts;
  final CategoryStore? categories;
  final TransactionStore? transactions;
  final SmsImportStore store;
  final ValueChanged<PendingSmsImport> onReview;
  Widget results() =>
      accounts != null && categories != null && transactions != null
      ? SmsResultsPage(
          store: store,
          accounts: accounts!,
          categories: categories!,
          transactions: transactions!,
          onReview: onReview,
        )
      : SmsPendingPage(store: store, onReview: onReview);
  Future<void> open(BuildContext context, {bool scan = false}) async {
    if (scan) {
      await store.enable();
      return;
    }
    if (!context.mounted) return;
    await Navigator.push(context, FeatureRoute<void>(results()));
  }

  Future<void> _scanAgain() =>
      store.enabled ? store.scan(full: true) : store.enable();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([store, ?accounts]),
    builder: (context, _) {
      // SMS off (or unsupported) and nothing left to review: no card. It is
      // turned on again in More › Settings › Transactions from SMS.
      if (!store.enabled && store.pending.isEmpty) {
        return const SizedBox.shrink();
      }
      final unlinked = accounts == null
          ? 0
          : store.detectedAccounts
                .where(
                  (sms) => smsAccount(sms, store, accounts!.accounts) == null,
                )
                .map((sms) => sms.bankKey)
                .toSet()
                .length;
      // Only what still needs you earns a place on Home: a scan underway,
      // then the messages and banks waiting on an answer. When that is
      // nothing the card steps aside.
      final waiting = store.pendingCount > 0 || unlinked > 0;
      if (!store.scanning && !waiting) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: HomeCard(
          child: store.scanning
              ? SmsScanCard(
                  store: store,
                  onScan: _scanAgain,
                  onReview: () => open(context),
                  unlinked: unlinked,
                )
              : SmsReviewCard(
                  store: store,
                  unlinked: unlinked,
                  onOpen: () => open(context),
                  onReview: onReview,
                  onScan: _scanAgain,
                ),
        ),
      );
    },
  );
}

class SmsPendingPage extends StatelessWidget {
  const SmsPendingPage({
    super.key,
    required this.store,
    required this.onReview,
  });
  final SmsImportStore store;
  final ValueChanged<PendingSmsImport> onReview;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => FeaturePage(
      title: 'Bank SMS to categorize',
      actions: [
        if (store.supported)
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'stop') {
                store.disable();
              } else {
                store.scan(full: true);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'scan',
                child: Text('Rescan entire inbox'),
              ),
              if (store.enabled)
                const PopupMenuItem(
                  value: 'stop',
                  child: Text('Stop reading SMS'),
                ),
            ],
          ),
      ],
      child: Column(
        children: [
          if (store.busy) const LinearProgressIndicator(),
          if (store.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(store.error!),
            ),
          if (!store.enabled && store.supported)
            TextButton(
              onPressed: store.busy ? null : store.enable,
              child: const Text('Read bank SMS'),
            ),
          Expanded(
            child: _SmsPendingList(store: store, onReview: onReview),
          ),
        ],
      ),
    ),
  );
}

/// The lightweight review route also pages, including when no ledger stores
/// were supplied by the caller.
class _SmsPendingList extends StatefulWidget {
  const _SmsPendingList({required this.store, required this.onReview});
  final SmsImportStore store;
  final ValueChanged<PendingSmsImport> onReview;
  @override
  State<_SmsPendingList> createState() => _SmsPendingListState();
}

class _SmsPendingListState extends State<_SmsPendingList> {
  List<PendingSmsImport> _rows = [];
  int _request = 0, _revision = -1;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (_revision == widget.store.reviewRevision) return;
    _revision = widget.store.reviewRevision;
    _request++;
    setState(() {
      _rows = List.of(widget.store.pending);
      _loading = false;
      _error = null;
    });
  }

  Future<void> _loadMore() async {
    if (_loading || _rows.length >= widget.store.pendingCount) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.store.review.page(offset: _rows.length);
      if (!mounted || request != _request) return;
      setState(() {
        _rows.addAll(rows.map((row) => row.sms));
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = 'Could not load messages. Try again.';
      });
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (_error != null)
        TextButton(onPressed: _loadMore, child: Text(_error!)),
      Expanded(
        child: _rows.isEmpty
            ? const Center(
                child: Text('No bank transactions waiting for review.'),
              )
            : NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.metrics.extentAfter < 400) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _loadMore();
                    });
                  }
                  return false;
                },
                child: Builder(
                  builder: (context) {
                    final days = groupByDay(_rows, (sms) => sms.receivedAt);
                    return ListView.builder(
                      padding: const EdgeInsets.only(top: 12),
                      itemCount: days.length,
                      itemBuilder: (context, i) => TransactionDayGroup(
                        date: days[i].$1,
                        rows: [
                          for (final sms in days[i].$2)
                            SmsPendingTile(
                              sms: sms,
                              onTap: () => widget.onReview(sms),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    ],
  );
}
