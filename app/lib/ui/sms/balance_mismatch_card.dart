import 'package:flutter/material.dart';

import '../../data/repositories/balance_report_repository.dart';
import '../../domain/account.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/sms_import_store.dart';
import '../../state/transaction_store.dart';
import '../components/app_icon.dart';
import '../components/app_toast.dart';
import '../components/card_action.dart';
import '../theme/sheet_colors.dart';
import '../theme/surface_style.dart';
import '../components/private_amount.dart';
import '../home/cards/home_card.dart';

/// Home's question for each account whose bank reports a different balance.
/// Takes no room while every balance agrees.
class BalanceMismatchCards extends StatefulWidget {
  const BalanceMismatchCards({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.smsStore,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final SmsImportStore smsStore;

  @override
  State<BalanceMismatchCards> createState() => _BalanceMismatchCardsState();
}

class _BalanceMismatchCardsState extends State<BalanceMismatchCards> {
  late final BalanceReportRepository _reports = BalanceReportRepository(
    widget.transactionStore.repository.database,
  );
  late final Listenable _changes = Listenable.merge([
    widget.accountStore,
    widget.transactionStore,
    widget.smsStore,
  ]);
  List<BalanceMismatch> _mismatches = const [];
  bool _saving = false;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    _changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final version = ++_version;
    // Mid-save the ledger and balances may not agree yet.
    if (widget.accountStore.loading ||
        widget.accountStore.saving ||
        widget.transactionStore.loading ||
        widget.transactionStore.saving ||
        widget.smsStore.scanning ||
        widget.smsStore.importing) {
      return;
    }
    try {
      final found = await _reports.mismatches();
      if (mounted && version == _version) {
        setState(() => _mismatches = found);
      }
    } catch (_) {
      // Asked again on the next change.
    }
  }

  Future<void> _answer(BalanceMismatch mismatch, {required bool update}) async {
    if (_saving) return;
    setState(() => _saving = true);
    var message = update
        ? 'Balance updated'
        : 'Balance not updated';
    try {
      if (update) {
        await _reports.adjust(mismatch);
        await widget.categoryStore.load();
        await widget.accountStore.load();
        await widget.transactionStore.load();
      } else {
        await _reports.keep(mismatch);
      }
    } on StateError catch (e) {
      message = e.message;
    } catch (_) {
      message = 'The balance could not be updated. Try again.';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showAppToast(context, message);
    await _load();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final mismatch in _mismatches)
        Padding(
          key: ValueKey(mismatch.account.id),
          padding: const EdgeInsets.only(top: homeCardGap),
          child: _card(context, mismatch),
        ),
    ],
  );

  /// Shaped like Home's reminder cards: what it is, then what can be done.
  Widget _card(BuildContext context, BalanceMismatch mismatch) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final account = mismatch.account;
    String money(int minor) => formatAccountMoney(
      minor,
      currency: account.currency,
      digits: account.digits,
    );
    const figure = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
    return HomeCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppIcon(account.icon, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Bank balance differs',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // One eye for both figures.
          PrivateAmount(
            label: 'Balances',
            height: 30,
            maskStyle: figure,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${money(mismatch.appMinor)}  →  ',
                    style: TextStyle(
                      color: colors.muted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(text: money(mismatch.reportedMinor)),
                ],
              ),
              style: figure,
              semanticsLabel:
                  'App ${money(mismatch.appMinor)}, '
                  'bank ${money(mismatch.reportedMinor)}',
            ),
          ),
          const SizedBox(height: 10),
          Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CardAction(
                label: 'Ignore',
                icon: Icons.close_rounded,
                color: colors.muted,
                onTap: _saving ? null : () => _answer(mismatch, update: false),
              ),
              CardAction(
                label: 'Update balance',
                icon: Icons.check_rounded,
                color: theme.colorScheme.primary,
                outlined: true,
                onTap: _saving ? null : () => _answer(mismatch, update: true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
