import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart'
    show SmsSuggestedCategory;

import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/category_repository.dart';
import '../../../data/repositories/statement_import_repository.dart';
import '../../../data/statements/statement_reconciliation.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../domain/account.dart';
import '../../../domain/bank_institution_icon.dart';
import '../../../domain/category.dart';
import '../../../domain/party_category.dart';
import '../../../domain/transaction.dart';
import '../../../state/ad_gate.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/sms_import_store.dart';
import '../../../state/sync_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../components/more_popup_button.dart';
import '../../components/transactions/filter_sheets.dart';
import '../../components/transactions/period.dart';
import '../../components/transactions/period_pager.dart';
import '../../components/transactions/transaction_day_group.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../components/transactions/transaction_review_sheet.dart';
import '../../components/transactions/transaction_row.dart';
import '../../theme/app_theme.dart';
import 'statement_widgets.dart';

/// How many transactions an import added, how many recorded ones it
/// turned into transfers, and how many of its rows were already recorded.
typedef StatementImportResult = ({int added, int linked, int already});

/// The last step of every statement import, whatever the file: what the
/// statement would add — rows already in SimpleMoney set aside, transfers
/// between the user's accounts joined up, accounts and categories chosen —
/// and adds the ticked rows. Pops with a [StatementImportResult].
class StatementReviewScreen extends StatefulWidget {
  const StatementReviewScreen({
    super.key,
    required this.sync,
    required this.statement,
    this.step,
  });
  final SyncController sync;
  final UpiStatement statement;

  /// Where this file is among several imported together ("2 of 4"). A
  /// file with nothing new then moves on instead of stopping.
  final String? step;

  @override
  State<StatementReviewScreen> createState() => _StatementReviewScreenState();
}

/// Keys for an account the statement doesn't name: the account a payment
/// left, and a self transfer's destination.
const _unnamed = '?', _unnamedDestination = '?to';

class _StatementReviewScreenState extends State<StatementReviewScreen> {
  late final repository = StatementImportRepository(widget.sync.repository.db);
  UpiStatement get statement => widget.statement;

  /// The statement's rows as transfers between the user's accounts: money
  /// to or from their own name is one, and both legs of one are joined.
  List<UpiStatementRow> rows = const [];

  /// Who the user is, from this statement and every one imported before.
  StatementOwner owner = const StatementOwner();

  List<Account> accounts = [];
  List<Category> categories = [];

  /// Statement account key → app account id.
  Map<String, int> links = {};
  Map<String, int> history = {};
  List<LedgerCandidate> ledger = [];
  List<StatementMatch?> matches = [];
  final excluded = <int>{};

  /// Rows the user said don't complete a transfer the ledger has one leg
  /// of; they are added on their own instead.
  final keepSeparate = <int>{};
  final categoryOverrides = <int, int>{};

  /// Rows the user reviewed in the sheet: what they chose to record instead
  /// of what the statement implies.
  final rowEdits = <int, ReviewDraft>{};

  /// For the review sheet's pickers, which can also add an account or
  /// category. The app reloads its own stores once the import is done.
  late final accountStore = AccountStore(
    AccountRepository(widget.sync.repository.db),
  );
  late final categoryStore = CategoryStore(
    CategoryRepository(widget.sync.repository.db),
  );
  int? expenseCategory, incomeCategory;

  /// Each row's category by the shared rules ("MINA MED" is Pharmacy), when
  /// the user has it.
  List<int?> suggested = const [];
  bool loading = true, saving = false, showMatched = false;

  /// What the list shows, from the same menu as the Transactions screen.
  /// Filters only narrow the view: rows hidden by them keep their tick, so
  /// Add still adds everything selected.
  final period = PeriodController(kind: PeriodKind.all);
  TransactionTypeFilter typeFilter = TransactionTypeFilter.all;
  int? categoryFilter, accountFilter;

  /// Every account the statement mentions, in order of first appearance.
  late final Map<String, StatementAccount?> statementAccounts = {
    for (final row in rows) ...{
      _fromKey(row): row.account,
      ?_toKey(row): row.toAccount,
    },
  };

  String _fromKey(UpiStatementRow row) => row.account?.key ?? _unnamed;
  String? _toKey(UpiStatementRow row) =>
      row.direction == UpiStatementDirection.selfTransfer
      ? row.toAccount?.key ?? _unnamedDestination
      : null;

  StatementRowAccounts _accountsFor(UpiStatementRow row) => (
    account: links[_fromKey(row)],
    toAccount: switch (_toKey(row)) {
      final key? => links[key],
      null => null,
    },
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    period.dispose();
    accountStore.dispose();
    categoryStore.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = widget.sync.repository.db;
    owner = statement.owner.merge(await repository.owner());
    PartyCategorizer? categorizer;
    try {
      categorizer = await loadBundledCategorizer();
    } catch (_) {
      // Without the rules, rows take the payee's last category or Other.
    }
    SmsSuggestedCategory? suggest(UpiStatementRow row) => categorizer?.suggest(
      row.counterparty,
      credit: row.direction == UpiStatementDirection.credit,
      detail: row.narration ?? row.counterpartyId,
    );
    rows = pairTransferLegs(
      markCashMovements(
        markOwnTransfers(statement.rows, owner),
        (row) => switch (suggest(row)) {
          final s? => isCashMovement(s),
          null => false,
        },
      ),
    );
    final all = await AccountRepository(db).load();
    final loadedCategories = await CategoryRepository(db).load();
    suggested = [
      for (final row in rows)
        if (row.direction == UpiStatementDirection.selfTransfer)
          null
        else if (suggest(row) case final s? when !isCashMovement(s))
          resolveSuggestedCategory(s, loadedCategories)?.id
        else
          null,
    ];
    final saved = await repository.accountLinks();
    final loadedHistory = await repository.categoryHistory();
    final loadedLedger = await repository.candidates(rows);
    if (!mounted) return;
    final usable = all
        .where((a) => !a.isArchived && a.currency == 'INR' && a.digits == 2)
        .toList();
    int? named(CategoryType type, String name) => loadedCategories
        .where((c) => c.type == type && c.name.toLowerCase() == name)
        .firstOrNull
        ?.id;
    setState(() {
      accounts = usable;
      categories = loadedCategories;
      history = loadedHistory;
      ledger = loadedLedger;
      for (final MapEntry(:key, value: mentioned)
          in statementAccounts.entries) {
        final remembered = saved[key];
        final id = usable.any((a) => a.id == remembered)
            ? remembered
            : mentioned == null
            ? null
            : guessStatementAccount(mentioned, usable)?.id;
        if (id != null) links[key] = id;
      }
      expenseCategory = named(CategoryType.expense, 'other expense');
      incomeCategory = named(CategoryType.income, 'other income');
      _rematch();
      loading = false;
    });
  }

  void _rematch() => matches = matchStatementRows(
    rows,
    ledger,
    _accountsFor,
    keepSeparate: keepSeparate,
  );

  bool _self(UpiStatementRow row) =>
      row.direction == UpiStatementDirection.selfTransfer;

  TransactionType _type(UpiStatementRow row) => switch (row.direction) {
    UpiStatementDirection.debit => TransactionType.expense,
    UpiStatementDirection.credit => TransactionType.income,
    UpiStatementDirection.selfTransfer => TransactionType.transfer,
  };

  int? _categoryFor(int index) {
    if (rowEdits[index] case final edit?) {
      return edit.transfer ? null : edit.categoryId;
    }
    final row = rows[index];
    if (_self(row)) return null;
    final type = _type(row);
    final override = categoryOverrides[index];
    if (override != null) return override;
    final previous =
        history[StatementImportRepository.categoryHistoryKey(
          type,
          row.counterparty,
        )];
    if (previous != null) return previous;
    return suggested.elementAtOrNull(index) ??
        (type == TransactionType.income ? incomeCategory : expenseCategory);
  }

  /// What row [index] will be recorded as: the user's review if there is
  /// one, otherwise what the statement and the account links say.
  ({TransactionType type, int? account, int? toAccount, String title}) _plan(
    int index,
  ) {
    final row = rows[index];
    if (rowEdits[index] case final edit?) {
      return (
        type: edit.type,
        account: edit.accountId,
        toAccount: edit.transfer ? edit.toAccountId : null,
        title: edit.title,
      );
    }
    final accounts = _accountsFor(row);
    return (
      type: _type(row),
      account: accounts.account,
      toAccount: accounts.toAccount,
      title: row.counterparty,
    );
  }

  /// Why row [index] can't be added yet, or null when it can.
  String? _blocker(int index) {
    final plan = _plan(index);
    final reviewed = rowEdits.containsKey(index);
    if (plan.account == null) {
      return reviewed ? 'Choose its account' : 'Choose its account above';
    }
    if (plan.type == TransactionType.transfer) {
      if (plan.toAccount == null) {
        return reviewed ? 'Choose where it went' : 'Choose where it went above';
      }
      if (plan.toAccount == plan.account) {
        return 'Both sides are the same account';
      }
    } else if (_categoryFor(index) == null) {
      return 'Choose a category';
    }
    return null;
  }

  List<int> get _newIndices => [
    for (var i = 0; i < rows.length; i++)
      if (matches[i] == null) i,
  ];
  List<int> get _matchedIndices => [
    for (var i = 0; i < rows.length; i++)
      if (matches[i] case final match? when !match.completesTransfer) i,
  ];
  List<int> get _transferIndices => [
    for (var i = 0; i < rows.length; i++)
      if (matches[i]?.completesTransfer ?? false) i,
  ];
  List<int> get _selected => [
    for (final i in _newIndices)
      if (!excluded.contains(i) && _blocker(i) == null) i,
  ];

  String _accountName(int? id) =>
      accounts.where((a) => a.id == id).firstOrNull?.name ?? 'Choose account';

  String _categoryName(int? id) =>
      categories.where((c) => c.id == id).firstOrNull?.name ??
      'Choose category';

  String _statementAccountLabel(String key) => switch (key) {
    _unnamed => 'Account not named in the statement',
    _unnamedDestination => 'Self-transfer destination not named',
    _ => statementAccounts[key]!.label,
  };

  /// Adds an account from the picker, filled in from what the statement says
  /// about [key]'s account (its bank and last digits). Null if left.
  Future<int?> _addAccount(BuildContext sheetContext, String key) async {
    await accountStore.load();
    if (!sheetContext.mounted) return null;
    final mentioned = statementAccounts[key];
    final bank = mentioned?.bank;
    final digits = mentioned?.digits ?? '';
    final added = await addAccountAndSelect(
      sheetContext,
      accountStore,
      initialName: bank == null || bank == StatementAccount.cash.bank
          ? null
          : bank,
      initialIcon: bank == null ? null : bankInstitutionIcon(bank),
      initialCurrency: 'INR',
      initialLastDigits: digits.isEmpty ? null : digits,
      initialInstitution: bank,
    );
    if (added == null) return null;
    _useAccounts();
    return added.id;
  }

  /// The accounts the pickers offer, from the store: ones added from the
  /// sheet join them.
  void _useAccounts() => accounts = [
    for (final a in accountStore.accounts)
      if (!a.isArchived && a.currency == 'INR' && a.digits == 2) a,
  ];

  Future<void> _pickAccount(String key) async {
    final picked = await showChoiceListSheet<int>(
      context,
      title: _statementAccountLabel(key),
      selected: links[key],
      items: [
        for (final account in accounts)
          ChoiceItem(
            value: account.id,
            icon: AppIcon(account.icon, size: 28),
            label: account.name,
            subtitle: account.lastDigits == null
                ? account.type.label
                : '${account.type.label} •• ${account.lastDigits}',
          ),
      ],
      addLabel: 'Add account',
      onAdd: (sheetContext) => _addAccount(sheetContext, key),
    );
    if (picked == null || !mounted) return;
    setState(() {
      links[key] = picked;
      _rematch();
    });
    try {
      final saved = await repository.accountLinks();
      await repository.saveAccountLinks({...saved, key: picked});
    } catch (_) {
      // Only a convenience for the next import.
    }
  }

  Future<int?> _pickCategory(CategoryType type, int? selected) =>
      showChoiceListSheet<int>(
        context,
        title: type == CategoryType.income ? 'Income category' : 'Category',
        selected: selected,
        items: [
          for (final category in categoriesInDisplayOrder(
            categories.where((c) => c.type == type),
          ))
            ChoiceItem(
              value: category.id,
              icon: AppIcon(category.icon, size: 28),
              label: category.name,
              indent: category.parentId != null,
            ),
        ],
      );

  Future<void> _pickDefaultCategory(CategoryType type) async {
    final picked = await _pickCategory(
      type,
      type == CategoryType.income ? incomeCategory : expenseCategory,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (type == CategoryType.income) {
        incomeCategory = picked;
      } else {
        expenseCategory = picked;
      }
    });
  }

  /// Opens row [index] in the same review sheet as SMS: its amount and date
  /// are the statement's, the rest is the user's to correct.
  Future<void> _editRow(int index) async {
    final row = rows[index];
    final plan = _plan(index);
    await Future.wait([accountStore.load(), categoryStore.load()]);
    if (!mounted) return;
    await showTransactionReviewSheet(
      context,
      heading: 'Statement row',
      draft: ReviewDraft(
        type: plan.type,
        amountMinor: row.amountMinor,
        currency: 'INR',
        digits: 2,
        date: row.date,
        title: plan.title,
        categoryId: _categoryFor(index),
        accountId: plan.account,
        toAccountId: plan.toAccount,
      ),
      accounts: accountStore,
      categories: categoryStore,
      // A payment can be money moved between the user's own accounts and
      // back, but never income, nor a receipt an expense.
      types: [
        if (row.direction == UpiStatementDirection.credit)
          TransactionType.income
        else
          TransactionType.expense,
        TransactionType.transfer,
      ],
      editAmount: false,
      editDate: false,
      editNote: false,
      sourceHeading: '${statement.source.label} statement',
      sourceIcon: Icons.receipt_long_outlined,
      sourceText: row.narration ?? row.counterpartyId,
      saveLabel: 'Done',
      onSave: (draft) async {
        setState(() {
          rowEdits[index] = draft;
          excluded.remove(index);
          // Accounts or categories added from the sheet join the pickers.
          _useAccounts();
          categories = categoryStore.categories;
        });
      },
    );
  }

  Future<void> _add() async {
    final selected = _selected;
    final transfers = _transferIndices;
    if (selected.isEmpty && transfers.isEmpty || saving) return;
    setState(() => saving = true);
    try {
      final imports = [
        for (final i in selected)
          StatementImport(
            row: rows[i],
            accountId: _plan(i).account!,
            toAccountId: _plan(i).toAccount,
            categoryId: _categoryFor(i),
            type: rowEdits[i]?.type,
            title: rowEdits[i]?.title,
          ),
      ];
      await widget.sync.addStatementTransactions(
        () => repository.add(
          statement.source,
          imports,
          transfers: [
            for (final i in transfers)
              StatementTransfer(row: rows[i], match: matches[i]!),
          ],
        ),
      );
      try {
        await repository.rememberOwner(statement.owner);
      } catch (_) {
        // Only a convenience for the next import.
      }
      if (mounted) {
        Navigator.pop<StatementImportResult>(context, (
          added: imports.length,
          linked: transfers.length,
          already: _matchedIndices.length,
        ));
        // Among several files, once at the end instead (the batch).
        if (widget.step == null) {
          unawaited(AdGate.instance.after(AdMoment.statementImport));
        }
      }
    } catch (error) {
      if (mounted) {
        showAppToast(
          context,
          widget.sync.describeError(
            error,
            'Could not add these transactions. Please try again.',
          ),
          icon: Icons.error_outline_rounded,
        );
        setState(() => saving = false);
      }
    }
  }

  String _money(int minor) =>
      formatAccountMoney(minor, digits: 2, currency: 'INR');

  @override
  Widget build(BuildContext context) {
    return FeaturePage(
      title: widget.step == null
          ? '${statement.source.label} statement'
          : '${statement.source.label} · ${widget.step}',
      actions: [if (!loading && !saving) _menu()],
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  // Nothing changes under a save; the list dims to say so.
                  child: PopScope(
                    canPop: !saving,
                    child: IgnorePointer(
                      ignoring: saving,
                      child: AnimatedOpacity(
                        opacity: saving ? .5 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: PeriodPager(
                          controller: period,
                          onSelectRange: _pickPeriod,
                          pageBuilder: (context, anchor) =>
                              _list(context, period.rangeAt(anchor)),
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: PillButton(
                        label: saving ? _savingLabel : _buttonLabel,
                        loading: saving,
                        onPressed:
                            _selected.isNotEmpty || _transferIndices.isNotEmpty
                            ? _add
                            : _nothingNew
                            ? () => Navigator.pop<StatementImportResult>(
                                context,
                                (
                                  added: 0,
                                  linked: 0,
                                  already: _matchedIndices.length,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String get _savingLabel => _selected.isEmpty ? 'Linking…' : 'Adding…';

  /// Among several files, one whose every row is recorded already: it is
  /// done, not stuck.
  bool get _nothingNew =>
      widget.step != null && _newIndices.isEmpty && _transferIndices.isEmpty;

  String get _buttonLabel {
    final added = _selected.length, linked = _transferIndices.length;
    String plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
    if (_nothingNew) return 'All here already · continue';
    return switch ((added, linked)) {
      (0, 0) => 'Nothing to add',
      (_, 0) => 'Add ${plural(added, 'transaction')}',
      (0, _) => 'Link ${plural(linked, 'transfer')}',
      _ => 'Add $added · link $linked',
    };
  }

  Widget _list(BuildContext context, DateTimeRange range) {
    bool shown(int i) => _shown(i, range);
    final fresh = _newIndices.where(shown).toList();
    final matched = _matchedIndices.where(shown).toList();
    final transfers = _transferIndices.where(shown).toList();
    final hasPayments = _newIndices.any(
      (i) => rows[i].direction == UpiStatementDirection.debit,
    );
    final hasReceipts = _newIndices.any(
      (i) => rows[i].direction == UpiStatementDirection.credit,
    );
    final items = <WidgetBuilder>[
      (context) => _summary(
        context,
        _newIndices.length,
        _matchedIndices.length,
        _transferIndices.length,
      ),
      if (!statement.totalsMatch) (context) => _warning(context),
      (_) => const StatementSectionLabel('Accounts'),
      (_) => MoneyCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (final (n, key) in statementAccounts.keys.indexed) ...[
              if (n > 0) const StatementRowDivider(),
              StatementPickerRow(
                icon: AppIcon(
                  key.startsWith('?')
                      ? 'bank'
                      : bankInstitutionIcon(statementAccounts[key]!.bank ?? ''),
                  size: 28,
                ),
                title: _statementAccountLabel(key),
                value: _accountName(links[key]),
                missing: links[key] == null,
                onTap: () => _pickAccount(key),
              ),
            ],
          ],
        ),
      ),
      if (hasPayments || hasReceipts) ...[
        (_) => const StatementSectionLabel('Category for new payees'),
        (_) => MoneyCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              if (hasPayments)
                StatementPickerRow(
                  icon: const Icon(Icons.north_east_rounded, color: coral),
                  title: 'Payments',
                  value: _categoryName(expenseCategory),
                  missing: expenseCategory == null,
                  onTap: () => _pickDefaultCategory(CategoryType.expense),
                ),
              if (hasPayments && hasReceipts) const StatementRowDivider(),
              if (hasReceipts)
                StatementPickerRow(
                  icon: const Icon(Icons.south_west_rounded, color: green),
                  title: 'Money received',
                  value: _categoryName(incomeCategory),
                  missing: incomeCategory == null,
                  onTap: () => _pickDefaultCategory(CategoryType.income),
                ),
            ],
          ),
        ),
      ],
      if (fresh.isNotEmpty) ...[
        (_) => StatementSectionLabel(
          'New · ${fresh.length}',
          action: fresh.every((i) => !excluded.contains(i))
              ? 'Select none'
              : 'Select all',
          onAction: () => setState(() {
            if (fresh.every((i) => !excluded.contains(i))) {
              excluded.addAll(fresh);
            } else {
              excluded.removeAll(fresh);
            }
          }),
        ),
        ..._days(fresh, _rowTile),
      ],
      if (transfers.isNotEmpty) ...[
        (_) => StatementSectionLabel(
          'Transfers between your accounts · ${transfers.length}',
        ),
        ..._days(transfers, _transferTile),
      ],
      if (matched.isNotEmpty) ...[
        (_) => StatementSectionLabel(
          'Already in SimpleMoney · ${matched.length}',
          action: showMatched ? 'Hide' : 'Show',
          onAction: () => setState(() => showMatched = !showMatched),
        ),
        if (showMatched) ..._days(matched, _rowTile),
      ],
      if (fresh.isEmpty && transfers.isEmpty && matched.isEmpty)
        (context) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Text(
            'No transactions match these filters.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index](context),
    );
  }

  Widget _summary(BuildContext context, int fresh, int matched, int transfers) {
    final theme = Theme.of(context);
    final dates = rows.map((r) => r.date).toList()..sort();
    final range = dates.isEmpty
        ? ''
        : '${DateFormat.yMMMd().format(dates.first)} – '
              '${DateFormat.yMMMd().format(dates.last)}';
    return MoneyCard(
      child: Row(
        children: [
          const IconTile(Icons.receipt_long_rounded, size: 46),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${rows.length} transactions',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(range, style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
                Text(
                  [
                    '$fresh new',
                    if (transfers > 0)
                      '$transfers transfer${transfers == 1 ? '' : 's'} '
                          'to link',
                    '$matched already in SimpleMoney',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _warning(BuildContext context) {
    final sent = statement.reportedSentMinor;
    final received = statement.reportedReceivedMinor;
    final parts = [
      if (statement.unreadable > 0)
        '${statement.unreadable} transaction'
            '${statement.unreadable == 1 ? '' : 's'} couldn’t be read and '
            '${statement.unreadable == 1 ? 'is' : 'are'} left out.',
      if (sent != null && sent != statement.sentMinor)
        'The statement says ${_money(sent)} was sent; '
            '${_money(statement.sentMinor)} was read.',
      if (received != null && received != statement.receivedMinor)
        'It says ${_money(received)} was received; '
            '${_money(statement.receivedMinor)} was read.',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: MoneyCard(
        color: orange.withValues(alpha: .12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: orange),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${parts.join(' ')} Check the rows before adding them.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The accounts the statement's rows are linked to, for the account filter.
  List<Account> get _linkedAccounts => [
    for (final account in accounts)
      if (links.values.contains(account.id)) account,
  ];

  Widget _menu() => MorePopupButton<String>(
    tooltip: 'Statement options',
    onSelected: (action) => switch (action) {
      'range' => _pickPeriod(),
      'type' => _pickType(),
      'category' => _pickCategoryFilter(),
      _ => _pickAccountFilter(),
    },
    items: [
      const MorePopupItem(value: 'range', label: 'Select time range'),
      const MorePopupItem(value: 'type', label: 'Filter by type'),
      const MorePopupItem(value: 'category', label: 'Filter by category'),
      // A statement for one account has nothing to choose between.
      if (_linkedAccounts.length > 1)
        const MorePopupItem(value: 'account', label: 'Select account'),
    ],
  );

  Future<void> _pickPeriod() => pickPeriod(context, period);

  Future<void> _pickType() async {
    final picked = await pickTypeFilter(context, selected: typeFilter);
    if (picked != null && mounted) setState(() => typeFilter = picked);
  }

  Future<void> _pickCategoryFilter() async {
    final picked = await pickCategoryFilter(
      context,
      categories: categories,
      selected: categoryFilter,
      startOnIncome: typeFilter == TransactionTypeFilter.income,
    );
    if (picked != null && mounted) {
      setState(() => categoryFilter = picked.$1);
    }
  }

  Future<void> _pickAccountFilter() async {
    final picked = await pickAccountFilter(
      context,
      accounts: _linkedAccounts,
      selected: accountFilter,
    );
    if (picked != null && mounted) {
      setState(() => accountFilter = picked.id);
    }
  }

  /// Whether row [index] is in [range] and passes the menu's filters.
  bool _shown(int index, DateTimeRange range) {
    final row = rows[index];
    final day = DateUtils.dateOnly(row.date);
    if (day.isBefore(range.start) || day.isAfter(range.end)) return false;
    final transfer =
        _plan(index).type == TransactionType.transfer ||
        (matches[index]?.completesTransfer ?? false);
    final type = switch (typeFilter) {
      TransactionTypeFilter.all => true,
      TransactionTypeFilter.expense =>
        !transfer && row.direction == UpiStatementDirection.debit,
      TransactionTypeFilter.income =>
        !transfer && row.direction == UpiStatementDirection.credit,
      TransactionTypeFilter.transfer => transfer,
    };
    if (!type) return false;
    if (categoryFilter case final id?) {
      // A parent category takes in its subcategories, as on Transactions.
      final category = _category(_categoryFor(index));
      if (category == null || (category.id != id && category.parentId != id)) {
        return false;
      }
    }
    if (accountFilter case final id?) {
      final plan = _plan(index);
      if (plan.account != id && plan.toAccount != id) return false;
    }
    return true;
  }

  /// [indices] as day groups, newest first, each totalled like the
  /// Transactions screen.
  Iterable<WidgetBuilder> _days(
    List<int> indices,
    Widget Function(BuildContext, int) tile,
  ) sync* {
    for (final (day, group) in groupByDay(indices, (i) => rows[i].date)) {
      int total(UpiStatementDirection direction) => group
          .where((i) => rows[i].direction == direction)
          .fold(0, (sum, i) => sum + rows[i].amountMinor);
      final received = total(UpiStatementDirection.credit);
      final paid = total(UpiStatementDirection.debit);
      yield (context) => TransactionDayGroup(
        date: day,
        income: received == 0 ? null : _money(received),
        expenses: paid == 0 ? null : _money(paid),
        padding: const EdgeInsets.only(top: 8, bottom: 14),
        rows: [for (final i in group) tile(context, i)],
      );
    }
  }

  Category? _category(int? id) =>
      categories.where((c) => c.id == id).firstOrNull;

  Widget _rowTile(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    final row = rows[index];
    final matched = matches[index] != null;
    final blocker = matched ? null : _blocker(index);
    final plan = _plan(index);
    final self = plan.type == TransactionType.transfer;
    final category = self ? null : _category(_categoryFor(index));
    final amount = _money(row.amountMinor);
    return TransactionRow(
      icon: self
          ? Icon(Icons.swap_horiz_rounded, color: scheme.primary, size: 28)
          : AppIcon(category?.icon, size: 40),
      title: plan.title,
      subtitle: matched
          ? 'Already recorded'
          : blocker ??
                (self
                    ? '${_accountName(plan.account)} → '
                          '${_accountName(plan.toAccount)}'
                    : _categoryName(_categoryFor(index))),
      subtitleColor: blocker != null ? coral : null,
      amount: switch (row.direction) {
        UpiStatementDirection.credit => '+$amount',
        UpiStatementDirection.debit => '−$amount',
        UpiStatementDirection.selfTransfer => amount,
      },
      amountColor: switch (row.direction) {
        UpiStatementDirection.credit => green,
        UpiStatementDirection.debit => Colors.red,
        UpiStatementDirection.selfTransfer => scheme.onSurface,
      },
      stamp: transactionStamp(row.date),
      dimmed: matched,
      selected: matched ? null : blocker == null && !excluded.contains(index),
      onSelected: blocker != null
          ? null
          : (value) => setState(() {
              if (value) {
                excluded.remove(index);
              } else {
                excluded.add(index);
              }
            }),
      onTap: () => _editRow(index),
    );
  }

  /// A row that completes a transfer recorded one leg at a time. Unticking
  /// a payment or receipt says it isn't one: it moves to the new rows, to
  /// add on its own. A self transfer says so itself, so it stays ticked.
  Widget _transferTile(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    final row = rows[index];
    final match = matches[index]!;
    final recorded = switch (row.direction) {
      UpiStatementDirection.credit => 'its payment',
      UpiStatementDirection.debit => 'its receipt',
      UpiStatementDirection.selfTransfer => 'one side',
    };
    return TransactionRow(
      icon: Icon(Icons.swap_horiz_rounded, color: scheme.primary, size: 28),
      title:
          '${_accountName(match.fromAccountId)} → '
          '${_accountName(match.toAccountId)}',
      subtitle: 'SimpleMoney has $recorded',
      amount: _money(row.amountMinor),
      amountColor: scheme.onSurface,
      stamp: transactionStamp(row.date),
      selected: true,
      onSelected: row.direction == UpiStatementDirection.selfTransfer
          ? null
          : (_) => setState(() {
              keepSeparate.add(index);
              _rematch();
            }),
    );
  }
}
