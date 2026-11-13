import 'unassigned_sms_page.dart';
import 'account_creation_help.dart';
import '../components/empty_state.dart';
import '../components/info_guide.dart';
import '../components/app_icon.dart';
import '../components/action_buttons.dart';

import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../domain/account.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import '../../state/sms_import_store.dart';
import '../components/feature_page.dart';
import '../components/choice_list_sheet.dart';
import '../components/more_popup_button.dart';
import '../transactions/transactions_screen.dart';
import 'sms_suggestions.dart';
import '../more/accounts/account_card.dart';
import '../../domain/currency_digits.dart';

class SmsResultsPage extends StatefulWidget {
  const SmsResultsPage({
    super.key,
    required this.store,
    required this.accounts,
    required this.categories,
    required this.transactions,
    required this.onReview,
  });
  final SmsImportStore store;
  final AccountStore accounts;
  final CategoryStore categories;
  final TransactionStore transactions;
  final ValueChanged<PendingSmsImport> onReview;
  @override
  State<SmsResultsPage> createState() => _SmsResultsPageState();
}

class _SmsResultsPageState extends State<SmsResultsPage> {
  bool matching = false, saving = false;
  String? linkingBankKey;
  String? error;
  final Map<String, TextEditingController> _balanceInputs = {};
  final Map<String, TextEditingController> _availableInputs = {};
  final Map<String, TextEditingController> _limitInputs = {};
  final Set<String> _selectedBankKeys = {};
  final Set<String> _knownBankKeys = {};

  Widget limitInput(String bankKey, {bool total = false}) {
    final style = total
        ? Theme.of(context).textTheme.labelLarge
        : Theme.of(context).textTheme.headlineSmall;
    return SizedBox(
      width: 150,
      child: TextField(
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        key: ValueKey('sms-${total ? 'total' : 'available'}-limit-$bankKey'),
        controller: (total ? _limitInputs : _availableInputs).putIfAbsent(
          bankKey,
          () => TextEditingController(),
        ),
        enabled: !saving && !widget.store.busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        textAlign: total ? TextAlign.end : TextAlign.start,
        style: style,
        decoration: InputDecoration(
          hintText: 'Set limit',
          hintStyle: style?.copyWith(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: .38),
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.categories.addListener(_invalidateCategories);
    matching =
        groups.any((sms) => account(sms) == null) ||
        missingCashCurrencies.isNotEmpty;
  }

  List<PendingSmsImport>? _groupSource;
  List<PendingSmsImport> _groups = [];
  List<PendingSmsImport> get groups {
    if (!identical(_groupSource, widget.store.detectedAccounts)) {
      _groupSource = widget.store.detectedAccounts;
      final latest = <String, PendingSmsImport>{};
      for (final sms in widget.store.detectedAccounts) {
        if (sms.ambiguousAccount) continue;
        final previous = latest[sms.bankKey];
        if (previous == null || sms.receivedAt.isAfter(previous.receivedAt)) {
          latest[sms.bankKey] = sms;
        }
      }
      _groups = latest.values.toList();
      final current = _groups.map((sms) => sms.bankKey).toSet();
      _selectedBankKeys.retainAll(current);
      _knownBankKeys.retainAll(current);
      for (final key in current.difference(_knownBankKeys)) {
        _knownBankKeys.add(key);
      }
    }
    return _groups;
  }

  Account? account(PendingSmsImport sms) =>
      smsAccount(sms, widget.store, widget.accounts.accounts);
  Set<String> get missingCashCurrencies => widget.store.cashCurrencies
      .where(
        (currency) => !widget.accounts.accounts.any(
          (a) =>
              a.type == AccountType.cash &&
              !a.isArchived &&
              a.currency == currency &&
              a.digits == currencyDigits(a.currency),
        ),
      )
      .toSet();

  void _invalidateCategories() {
    widget.store.reload();
  }

  void toggleAccount(PendingSmsImport sms, bool selected) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (selected) {
        _selectedBankKeys.add(sms.bankKey);
      } else {
        _selectedBankKeys.remove(sms.bankKey);
      }
    });
  }

  @override
  void dispose() {
    for (final controller in [
      ..._balanceInputs.values,
      ..._availableInputs.values,
      ..._limitInputs.values,
    ]) {
      controller.dispose();
    }
    widget.categories.removeListener(_invalidateCategories);
    super.dispose();
  }

  Future<void> pickAccount(PendingSmsImport sms) async {
    if (linkingBankKey != null) return;
    final id = await showChoiceListSheet<int>(
      context,
      title: 'Match ${sms.bankName}',
      selected: account(sms)?.id,
      items: [
        for (final a in widget.accounts.accounts)
          if (a.currency == sms.currency &&
              a.digits == currencyDigits(a.currency) &&
              a.archivedAt == null)
            ChoiceItem(
              value: a.id,
              icon: AppIcon(a.icon, size: 28),
              label: a.name,
              subtitle: a.currency,
            ),
      ],
    );
    if (id == null || !mounted) return;
    setState(() {
      linkingBankKey = sms.bankKey;
      error = null;
    });
    try {
      await widget.store.linkAccount(sms, id);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not save the account match. Try again.');
      }
    } finally {
      if (mounted) setState(() => linkingBankKey = null);
    }
  }

  /// Decimal places for amounts typed for the bank group [bankKey].
  int _digitsOf(String bankKey) =>
      groups.where((g) => g.bankKey == bankKey).firstOrNull?.digits ?? 2;

  Future<void> createAccounts() async {
    if (saving || widget.store.busy) return;
    final openingBalances = <String, int>{};
    for (final entry in _balanceInputs.entries) {
      if (entry.value.text.trim().isEmpty) continue;
      final digits = _digitsOf(entry.key);
      final amount = parseAccountAmount(entry.value.text.trim(), digits);
      if (amount == null) {
        setState(
          () => error =
              'Enter a valid balance with up to $digits decimal places.',
        );
        return;
      }
      openingBalances[entry.key] = amount;
    }
    FocusScope.of(context).unfocus();
    final availableLimits = <String, int>{};
    final creditLimits = <String, int>{};
    for (final pair in [
      (_availableInputs, availableLimits),
      (_limitInputs, creditLimits),
    ]) {
      for (final entry in pair.$1.entries) {
        if (entry.value.text.trim().isEmpty) continue;
        final digits = _digitsOf(entry.key);
        final amount = parseAccountAmount(entry.value.text.trim(), digits);
        if (amount == null || amount < 0) {
          setState(
            () => error =
                'Enter a valid limit with up to $digits decimal places.',
          );
          return;
        }
        pair.$2[entry.key] = amount;
      }
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final selectedGroups = groups
          .where(
            (sms) =>
                account(sms) != null || _selectedBankKeys.contains(sms.bankKey),
          )
          .toList();
      await widget.store.repository.createDetectedAccounts(
        selectedGroups,
        icons: {
          for (final sms in selectedGroups) sms.bankKey: smsBankIcon(sms),
        },
        openingBalances: openingBalances,
        availableLimits: availableLimits,
        creditLimits: creditLimits,
      );
      for (final currency in missingCashCurrencies) {
        await widget.accounts.repository.save(
          name: 'Cash',
          currency: currency,
          digits: currencyDigits(currency),
          openingBalance: 0,
          type: AccountType.cash,
          icon: 'wallet_one',
        );
      }
      await widget.store.reload();
      await widget.accounts.load();
      if (mounted) setState(() => matching = false);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not create accounts. Please try again.');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> saveAll() async {
    if (saving || widget.store.busy) return;
    if (widget.store.pendingCount == 0) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final saved = await widget.store.saveReady();
      await Future.wait([
        widget.store.reload(),
        widget.accounts.load(),
        widget.transactions.load(),
        widget.categories.load(),
      ]);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Saved $saved transactions')));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Could not save all transactions. Refresh and try again.',
        );
      }
      await widget.store.reload();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget reviewBrowser() => IgnorePointer(
    ignoring: saving || widget.store.busy,
    child: TransactionsScreen(
      accountStore: widget.accounts,
      categoryStore: widget.categories,
      transactionStore: widget.transactions,
      onAddTransaction: () {},
      initialMonth: widget.store.pending.firstOrNull?.receivedAt,
      preview: TransactionPreview(
        title: 'SMS review',
        guide: smsImportGuide,
        loadUnassigned: () => unassignedSmsGroups(widget.store),
        onUnassigned: (group) async {
          await Navigator.of(context).push(
            FeatureRoute<void>(
              UnassignedSmsPage(
                store: widget.store,
                accounts: widget.accounts,
                initialGroup: group,
              ),
            ),
          );
          await widget.store.reload();
        },
        load: widget.store.review.browse,
        revision: widget.store.reviewRevision,
        onRefresh: widget.store.reload,
        onOpen: (transaction) async {
          try {
            final row = await widget.store.review.byPreviewId(transaction.id);
            if (mounted && row != null) widget.onReview(row.sms);
          } catch (_) {
            if (mounted) {
              setState(() => error = 'Could not open this message. Try again.');
            }
          }
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.store,
      widget.accounts,
      widget.categories,
    ]),
    builder: (context, _) {
      final bankGroups = groups;
      final cashCurrencies = missingCashCurrencies.toList();
      final createCount =
          bankGroups
              .where(
                (sms) =>
                    account(sms) == null &&
                    _selectedBankKeys.contains(sms.bankKey),
              )
              .length +
          cashCurrencies.length;
      final hasSelectedAccounts =
          createCount > 0 || bankGroups.any((sms) => account(sms) != null);
      final showMatching = matching;
      final total = widget.store.pendingCount;
      final ready = showMatching ? 0 : widget.store.readyCount;
      final unresolved = total - ready;
      return PopScope(
        canPop: !saving,
        child: FeaturePage(
          // The review list brings its own header; nothing else does.
          showHeader: showMatching || total == 0,
          title: showMatching ? 'Review accounts' : 'SMS review',
          actions: showMatching || total == 0
              ? [const InfoGuideButton(smsImportGuide)]
              : null,
          child: Column(
            children: [
              if (widget.store.busy || saving) const LinearProgressIndicator(),
              if (error != null || widget.store.error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error ?? widget.store.error!),
                ),
              if (showMatching) ...[
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                    itemCount: bankGroups.length + cashCurrencies.length,
                    itemBuilder: (context, i) {
                      if (i >= bankGroups.length) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: AccountCard(
                            account: Account(
                              id: -i - 1,
                              name: 'Cash',
                              currency: cashCurrencies[i - bankGroups.length],
                              digits: currencyDigits(
                                cashCurrencies[i - bankGroups.length],
                              ),
                              balanceMinor: 0,
                              type: AccountType.cash,
                              icon: 'wallet_one',
                            ),
                            leading: const Icon(Icons.lock_outline, size: 18),
                            subtitle:
                                '${widget.store.cashMessageCounts[cashCurrencies[i - bankGroups.length]] ?? 0} SMS · Needed for ATM cash',
                            showTransactionCount: false,
                          ),
                        );
                      }
                      final sms = bankGroups[i];
                      final linkedAccount = account(sms);
                      final selected =
                          linkedAccount != null ||
                          _selectedBankKeys.contains(sms.bankKey);
                      final messageCount =
                          widget.store.accountMessageCounts[sms.bankKey] ?? 1;
                      final balance = widget.store.smsBalances[sms.bankKey];
                      final available =
                          widget.store.smsCreditLimits[sms.bankKey];
                      final total =
                          widget.store.smsTotalCreditLimits[sms.bankKey];
                      final preview =
                          linkedAccount ??
                          Account(
                            id: -i - 1,
                            name: sms.bankName,
                            currency: sms.currency,
                            territory: sms.data['countryCode'] as String?,
                            icon: smsBankIcon(sms),
                            digits: sms.digits,
                            balanceMinor: balance ?? 0,
                            type: sms.creditCard
                                ? AccountType.creditCard
                                : AccountType.bank,
                            lastDigits: sms.accountLast4,
                            creditLimitMinor: total,
                            availableCreditLimitMinor: available,
                          );
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: AccountCard(
                          account: preview,
                          selected: selected,
                          actions: Row(
                            children: [
                              Expanded(
                                child: TextButton(
                                  onPressed: () => Navigator.of(context).push(
                                    FeatureRoute<void>(
                                      FeaturePage(
                                        title: '',
                                        showHeader: false,
                                        child: TransactionsScreen(
                                          accountStore: widget.accounts,
                                          categoryStore: widget.categories,
                                          transactionStore: widget.transactions,
                                          onAddTransaction: () {},
                                          preview: TransactionPreview(
                                            title:
                                                '${sms.bankName} transactions',
                                            load: (query) =>
                                                widget.store.review.browse(
                                                  query,
                                                  accountGroup: sms,
                                                ),
                                            onRefresh: widget.store.reload,
                                            onOpen: (transaction) async {
                                              final row = await widget
                                                  .store
                                                  .review
                                                  .byPreviewId(transaction.id);
                                              if (mounted && row != null) {
                                                widget.onReview(row.sms);
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    'View $messageCount transactions',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              MorePopupButton<String>(
                                icon: const Icon(Icons.more_vert_rounded),
                                tooltip: 'Account options',
                                items: saving || widget.store.busy
                                    ? []
                                    : [
                                        const MorePopupItem(
                                          value: 'link',
                                          label: 'Link existing account',
                                        ),
                                        if (linkedAccount == null)
                                          const MorePopupItem(
                                            value: 'create',
                                            label: 'Create account',
                                          ),
                                      ],
                                onSelected: (action) async {
                                  if (action == 'link') {
                                    await pickAccount(sms);
                                    return;
                                  }
                                  await widget.store.repository
                                      .createDetectedAccounts(
                                        [sms],
                                        icons: {sms.bankKey: smsBankIcon(sms)},
                                      );
                                  await widget.accounts.load();
                                  await widget.store.reload();
                                },
                              ),
                            ],
                          ),
                          balanceKnown:
                              linkedAccount != null || balance != null,
                          subtitle: linkedAccount == null
                              ? '$messageCount SMS'
                              : 'Already linked · $messageCount SMS',
                          showTransactionCount: false,
                          creditLimitEditor:
                              linkedAccount == null &&
                                  sms.creditCard &&
                                  total == null
                              ? limitInput(sms.bankKey, total: true)
                              : null,
                          balanceEditor:
                              linkedAccount == null &&
                                  balance == null &&
                                  !sms.creditCard
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width: 180,
                                    child: TextField(
                                      onTapOutside: (_) => FocusManager
                                          .instance
                                          .primaryFocus
                                          ?.unfocus(),
                                      key: ValueKey(
                                        'sms-balance-${sms.bankKey}',
                                      ),
                                      controller: _balanceInputs.putIfAbsent(
                                        sms.bankKey,
                                        () => TextEditingController(),
                                      ),
                                      enabled: !saving && !widget.store.busy,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                            signed: true,
                                          ),
                                      textInputAction: TextInputAction.done,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall,
                                      decoration: InputDecoration(
                                        hintText: 'Set balance',
                                        hintStyle: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: .38),
                                            ),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                )
                              : linkedAccount == null &&
                                    sms.creditCard &&
                                    available == null
                              ? limitInput(sms.bankKey)
                              : null,
                          onTap:
                              saving ||
                                  widget.store.busy ||
                                  linkingBankKey != null
                              ? null
                              : () => toggleAccount(sms, !selected),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: PillButton(
                      onPressed:
                          saving || widget.store.busy || !hasSelectedAccounts
                          ? null
                          : createAccounts,
                      label: saving
                          ? 'Creating accounts...'
                          : !hasSelectedAccounts
                          ? 'Select accounts'
                          : createCount == 0
                          ? 'Continue'
                          : 'Create $createCount ${createCount == 1 ? 'account' : 'accounts'}',
                    ),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: total == 0
                      ? const EmptyState(
                          icon: Icons.mark_chat_read_outlined,
                          title: 'All caught up',
                          message: 'Nothing to check. New ones show up here.',
                        )
                      : reviewBrowser(),
                ),
                if (total > 0) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'Total transactions: $total',
                      key: const Key('sms-bulk-save-total'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: PillButton(
                        onPressed: saving || widget.store.busy || ready == 0
                            ? null
                            : saveAll,
                        label: saving
                            ? 'Saving...'
                            : unresolved == 0
                            ? 'Save all transactions'
                            : 'Save $ready ready transactions',
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      );
    },
  );
}
