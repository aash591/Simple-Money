import 'ai_assistant_guide.dart';
import 'loan_suggestion_card.dart';
import 'account_suggestion_card.dart';
import 'recurring_suggestion_card.dart';
import 'share_fix_prompt.dart';
import '../../../data/community/community_fixes.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/agent/agent_suggestion_repository.dart';
import '../../../data/db/app_database.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/category_repository.dart';
import '../../../data/repositories/transaction_repository.dart';
import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/transaction.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/app_toast.dart';
import '../../components/card_action.dart';
import '../../components/segmented_pill.dart';
import '../../components/common.dart';
import '../../components/empty_art.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../theme/app_theme.dart';
import '../../components/transactions/transaction_day_header.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/transaction_sheet.dart';
import '../../transactions/transaction_widgets.dart';

/// Changes a connected AI app suggested. Nothing reaches the ledger until the
/// user approves it here; an approved transaction edit or SMS rule can be
/// undone.
class AiSuggestionsScreen extends StatefulWidget {
  const AiSuggestionsScreen({
    super.key,
    required this.database,
    this.onLedgerChanged,
    this.onRulesChanged,
    this.onLayoutApproved,
    this.community,
  });
  final AppDatabase database;

  /// Called after approving or undoing, so the ledger screens reload.
  final VoidCallback? onLedgerChanged;

  /// Called after an SMS rule is approved or undone, so the inbox is read
  /// again with the new set of rules.
  final VoidCallback? onRulesChanged;

  /// Called with each approved statement layout's signature, to offer
  /// importing the file it was made for.
  final Future<void> Function(BuildContext context, String signature)?
  onLayoutApproved;

  /// Offers to share approved SMS formats and statement layouts with other
  /// users; null asks nothing.
  final CommunitySync? community;

  @override
  State<AiSuggestionsScreen> createState() => _AiSuggestionsScreenState();
}

class _AiSuggestionsScreenState extends State<AiSuggestionsScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: _Tab.values.length, vsync: this)
    ..addListener(() => setState(() {}));
  late final _repository = AgentSuggestionRepository(widget.database);

  /// For showing the transactions a suggestion edits, and opening them.
  late final _accounts = AccountStore(AccountRepository(widget.database));
  late final _categories = CategoryStore(CategoryRepository(widget.database));
  late final _transactions = TransactionStore(
    TransactionRepository(widget.database),
    _accounts,
  );
  bool _stores = false;
  List<AgentSuggestion>? _suggestions;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _transactions.dispose();
    _categories.dispose();
    _accounts.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final suggestions = await _repository.load();
      // The transactions behind edit and loan suggestions, so each shows as
      // the row it is in the app. Without them a card falls back to its text.
      if (suggestions.any(
        (s) =>
            s.kind == AgentSuggestionKind.transactionEdit ||
            s.kind == AgentSuggestionKind.transactionAdd ||
            s.kind == AgentSuggestionKind.parserRule ||
            s.kind == AgentSuggestionKind.recurringPayment ||
            s.kind == AgentSuggestionKind.account ||
            s.kind == AgentSuggestionKind.newLoan,
      )) {
        try {
          await Future.wait([
            _accounts.load(),
            _categories.load(),
            _transactions.load(),
          ]);
          _stores = true;
        } catch (_) {
          _stores = false;
        }
      }
      if (mounted) setState(() => _suggestions = suggestions);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load suggestions.');
    }
  }

  MoneyTransaction? _transactionOf(AgentSuggestion s) {
    final id = int.tryParse(s.target);
    return _transactions.transactions.where((t) => t.id == id).firstOrNull;
  }

  Future<void> _openTransaction(MoneyTransaction transaction) async {
    String fingerprint(MoneyTransaction? t) => t == null
        ? ''
        : '${t.amountMinor}|${t.accountId}|${t.toAccountId}|${t.categoryId}|'
              '${t.title}|${t.note}|${t.date}';
    final was = fingerprint(transaction);
    await showViewTransactionSheet(
      context,
      transaction: transaction,
      accountStore: _accounts,
      categoryStore: _categories,
      transactionStore: _transactions,
    );
    await _load();
    // Edited or deleted there: the ledger screens reload.
    final now = _transactions.transactions
        .where((t) => t.id == transaction.id)
        .firstOrNull;
    if (fingerprint(now) != was) widget.onLedgerChanged?.call();
  }

  Future<void> _editSuggested(AgentSuggestion s, MoneyTransaction t) async {
    final digits = _account(t.accountId)?.digits ?? 2;
    await showSuggestedTransactionSheet(
      context,
      draft: TransactionDraft(
        type: t.type,
        amountText: AmountTyping.fromMinor(t.amountMinor, digits),
        title: t.title,
        categoryId: t.categoryId,
        accountId: t.accountId,
        date: t.date,
        note: t.note,
      ),
      onSave: (draft) async {
        final account = _account(draft.accountId);
        final minor = parseAccountAmount(
          draft.amountText,
          account?.digits ?? 2,
        );
        if (account == null || minor == null || draft.categoryId == null) {
          throw ArgumentError('Fill in the amount, category and account.');
        }
        await _repository.editTransactionAdd(
          s.id,
          type: draft.type,
          amountMinor: minor,
          accountId: account.id,
          categoryId: draft.categoryId!,
          title: draft.title,
          note: draft.note,
          date: draft.date,
        );
      },
      accountStore: _accounts,
      categoryStore: _categories,
      transactionStore: _transactions,
    );
    await _load();
  }

  /// The day an "add transaction" suggestion's transaction falls on.
  DateTime? _dayOf(AgentSuggestion s) {
    final date = DateTime.tryParse('${s.payload['date']}');
    return date == null ? null : DateUtils.dateOnly(date);
  }

  /// The day header for each run of "add transaction" suggestions on the same
  /// day, keyed by the run's first suggestion — the same grouping as the
  /// Transactions list, with the day's totals when they share a currency.
  Map<int, Widget> _dayHeaders(List<AgentSuggestion> shown, Set<int> grouped) {
    final headers = <int, Widget>{};
    if (!_stores) return headers;
    var i = 0;
    while (i < shown.length) {
      final first = shown[i];
      final day = first.kind == AgentSuggestionKind.transactionAdd
          ? _dayOf(first)
          : null;
      var j = i + 1;
      if (day != null) {
        while (j < shown.length &&
            shown[j].kind == AgentSuggestionKind.transactionAdd &&
            _dayOf(shown[j]) == day) {
          j++;
        }
        if (j - i > 1) grouped.addAll(shown.sublist(i, j).map((s) => s.id));
        var income = 0, expenses = 0;
        final accounts = <Account>{};
        for (final s in shown.sublist(i, j)) {
          final account = _account(s.payload['accountId'] as int?);
          final amount = s.payload['amount'];
          if (account == null || amount is! int) continue;
          accounts.add(account);
          if (s.payload['type'] == 'income') {
            income += amount;
          } else {
            expenses += amount;
          }
        }
        final one = accounts.map((a) => a.currency).toSet().length == 1;
        final account = one ? accounts.first : null;
        headers[first.id] = TransactionDayHeader(
          date: day,
          income: account != null && income > 0
              ? formatTransactionMoney(income, account)
              : null,
          expenses: account != null && expenses > 0
              ? formatTransactionMoney(expenses, account)
              : null,
        );
      }
      i = j;
    }
    return headers;
  }

  /// [t] with the fields in [values] (a suggestion's payload, or what it
  /// replaced) put in.
  MoneyTransaction _with(MoneyTransaction t, Map<String, Object?> values) =>
      MoneyTransaction(
        id: t.id,
        type: t.type,
        amountMinor: t.amountMinor,
        accountId: values['accountId'] as int? ?? t.accountId,
        toAccountId: t.toAccountId,
        toAmountMinor: t.toAmountMinor,
        categoryId: values.containsKey('categoryId')
            ? values['categoryId'] as int?
            : t.categoryId,
        title: values.containsKey('title')
            ? values['title'] as String?
            : t.title,
        note: values.containsKey('note') ? values['note'] as String? : t.note,
        date: t.date,
        icon: t.icon,
        badgeIcon: t.badgeIcon,
        isCreditCard: t.isCreditCard,
      );

  Account? _account(int? id) =>
      _accounts.accounts.where((a) => a.id == id).firstOrNull;
  Category? _category(int? id) =>
      _categories.categories.where((c) => c.id == id).firstOrNull;

  /// A transaction as the row the rest of the app shows. [newCategory] names
  /// a category the AI suggested that doesn't exist yet.
  Widget _row(
    MoneyTransaction t, {
    String? newCategory,
    VoidCallback? onTap,
    bool showDate = true,
  }) {
    final category = newCategory == null
        ? _category(t.categoryId)
        : Category(
            id: -1,
            name: newCategory,
            type: t.type == TransactionType.income
                ? CategoryType.income
                : CategoryType.expense,
          );
    final source = _account(t.accountId);
    final String amount;
    if (t.type == TransactionType.transfer) {
      final to = _account(t.toAccountId);
      final sent = formatTransactionMoney(t.amountMinor, source);
      final received = formatTransactionMoney(t.receivedMinor, to);
      amount = sent == received ? sent : '$sent → $received';
    } else {
      amount =
          '${t.type == TransactionType.income ? '+ ' : '- '}'
          '${formatTransactionMoney(t.amountMinor, source)}';
    }
    return TransactionListRow(
      transaction: t,
      account: source,
      toAccount: _account(t.toAccountId),
      category: category,
      parentCategory: _category(category?.parentId),
      formattedAmount: amount,
      showDate: showDate,
      onTap: onTap ?? () => _openTransaction(t),
    );
  }

  /// A new SMS rule as the payment it would read, shown like an added
  /// transaction. With no account or category in the SMS the row asks for
  /// them; tapping it opens the transaction sheet, and saving there with them
  /// picked records the payment. Once saved, the row is that transaction.
  Widget _rulePreview(AgentSuggestion s, _RuleSample sample) {
    final scheme = Theme.of(context).colorScheme;
    final saved = _transactions.transactions
        .where((t) => t.id == s.payload['savedTransactionId'])
        .firstOrNull;
    final minor =
        ((double.tryParse(sample.amount.replaceAll(RegExp(r'[^0-9.]'), '')) ??
                    0) *
                100)
            .round();
    // The catch-all "Personal" says nothing, so it counts as no category.
    final known = switch (sample.category?.toLowerCase()) {
      null || 'personal' => null,
      _ => sample.category,
    };
    // What the user still picks on each payment when they review it.
    final todo = [
      if (sample.missingAccount) 'account',
      if (known == null) 'category',
    ];
    final t = MoneyTransaction(
      id: -1,
      type: sample.credit ? TransactionType.income : TransactionType.expense,
      amountMinor: minor,
      accountId: 0,
      title: sample.payee,
      note: sample.message,
      date: s.createdAt,
    );
    final row = saved != null
        ? _row(saved)
        : TransactionListRow(
            transaction: t,
            account: null,
            toAccount: null,
            category: known == null
                ? null
                : Category(
                    id: -1,
                    name: known,
                    type: sample.credit
                        ? CategoryType.income
                        : CategoryType.expense,
                  ),
            parentCategory: null,
            formattedAmount: '${sample.credit ? '+ ' : '- '}${sample.amount}',
            subtitle: todo.isEmpty
                ? null
                : '${known == null ? '' : '$known · '}Select ${todo.join(' and ')}',
            subtitleColor: todo.isEmpty ? null : coral,
            showDate: true,
            onTap: () => showSuggestedTransactionSheet(
              context,
              draft: TransactionDraft(
                type: t.type,
                amountText: AmountTyping.fromMinor(minor, 2),
                title: sample.payee,
                categoryId: _categories.categories
                    .where(
                      (c) =>
                          c.name.toLowerCase() == known?.toLowerCase() &&
                          c.type ==
                              (sample.credit
                                  ? CategoryType.income
                                  : CategoryType.expense),
                    )
                    .firstOrNull
                    ?.id,
                date: t.date,
                note: sample.message,
              ),
              onSave: (draft) async {
                final account = _account(draft.accountId);
                final minor = parseAccountAmount(
                  draft.amountText,
                  account?.digits ?? 2,
                );
                if (account == null ||
                    draft.categoryId == null ||
                    minor == null) {
                  throw ArgumentError(
                    'Pick an account and a category to save it.',
                  );
                }
                await _repository.saveRuleSample(
                  s.id,
                  type: draft.type,
                  amountMinor: minor,
                  accountId: account.id,
                  categoryId: draft.categoryId!,
                  title: draft.title,
                  note: draft.note,
                  date: draft.date,
                );
                widget.onLedgerChanged?.call();
              },
              accountStore: _accounts,
              categoryStore: _categories,
              transactionStore: _transactions,
            ).then((_) => _load()),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
          child: Row(
            children: [
              Icon(Icons.rule_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.summary,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        MoneyCard(
          padding: EdgeInsets.zero,
          child: Material(type: MaterialType.transparency, child: row),
        ),
      ],
    );
  }

  /// An edit suggestion as two rows, the transaction before and after; null
  /// when its transaction is gone.
  Widget? _preview(AgentSuggestion s) {
    if (s.kind == AgentSuggestionKind.newLoan) {
      final pending = s.status == AgentSuggestionStatus.pending;
      return LoanSuggestionPreview(
        payload: s.payload,
        pending: pending,
        accountOf: _account,
        rowFor: (id) {
          final t = _transactions.transactions
              .where((t) => t.id == id)
              .firstOrNull;
          return t == null || !_stores ? null : _row(t);
        },
        onUpdatesBalance: !pending || _busy
            ? null
            : (on) => _run(() async {
                await _repository.setUpdatesBalance(s.id, on);
                return false;
              }),
      );
    }
    if (s.kind == AgentSuggestionKind.account) {
      if (!_stores) return null;
      // Archived accounts too: restoring names one.
      return AccountSuggestionPreview.maybe(
        payload: s.payload,
        detail: s.detail,
        accountOf: _accounts.byId,
      );
    }
    if (s.kind == AgentSuggestionKind.recurringPayment) {
      return RecurringSuggestionPreview(
        payload: s.payload,
        account: _stores ? _account(s.payload['accountId'] as int?) : null,
        category: _stores
            ? _categories.categories
                  .where((c) => c.id == s.payload['categoryId'])
                  .firstOrNull
            : null,
        rowFor: (id) {
          final t = _transactions.transactions
              .where((t) => t.id == id)
              .firstOrNull;
          return t == null || !_stores ? null : _row(t);
        },
        accountOf: _stores ? _account : null,
        pending: s.status == AgentSuggestionStatus.pending,
        savedFromSms: s.status == AgentSuggestionStatus.applied
            ? [...?(s.before?['savedSms'] as List?)?.cast<int>()]
            : const [],
      );
    }
    if (s.kind == AgentSuggestionKind.parserRule) {
      final sample = _RuleSample.parse(s.detail);
      if (sample == null) return null;
      return _rulePreview(s, sample);
    }
    if (s.kind == AgentSuggestionKind.transactionAdd) {
      if (!_stores) return null;
      final p = s.payload;
      final amount = p['amount'];
      final accountId = p['accountId'];
      if (amount is! int || accountId is! int || _account(accountId) == null) {
        return null;
      }
      final t = MoneyTransaction(
        id: -1,
        type: TransactionTypeStorage.fromStorage('${p['type']}'),
        amountMinor: amount,
        accountId: accountId,
        categoryId: p['categoryId'] as int?,
        title: p['title'] as String?,
        note: p['note'] as String?,
        date: DateTime.tryParse('${p['date']}') ?? s.createdAt,
      );
      // Tapping opens the usual edit page, so a wrong detail can be fixed
      // before approving; saving rewrites the suggestion, not the ledger.
      final row = _row(
        t,
        newCategory: p['categoryName'] as String?,
        showDate: false,
        onTap: s.status == AgentSuggestionStatus.applied
            ? null
            : () => _editSuggested(s, t),
      );
      // The row in its card, as the Transactions list shows it (the day heads
      // the group of suggestions). The note is left to the view sheet.
      return MoneyCard(
        padding: EdgeInsets.zero,
        child: Material(type: MaterialType.transparency, child: row),
      );
    }
    if (s.kind != AgentSuggestionKind.transactionEdit || !_stores) return null;
    final current = _transactionOf(s);
    if (current == null) return null;
    final applied = s.status == AgentSuggestionStatus.applied;
    final newCategory = s.payload['categoryName'] as String?;
    final before = applied && s.before != null
        ? _with(current, s.before!)
        : current;
    final after = applied ? current : _with(current, s.payload);
    return _EditPreview(
      beforeLabel: applied ? 'Before' : 'Now',
      afterLabel: applied ? 'Now' : 'If approved',
      before: _row(before),
      after: _row(after, newCategory: applied ? null : newCategory),
    );
  }

  /// Runs [action], then reloads. [changed] says whether the ledger moved.
  Future<void> _run(Future<bool> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var changed = false;
    try {
      changed = await action();
    } catch (_) {
      _error = 'Something went wrong. Try again.';
    }
    if (changed) widget.onLedgerChanged?.call();
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    if (done != null && _error == null) {
      showAppToast(context, done, icon: Icons.check_circle_rounded);
    }
  }

  void _approve(AgentSuggestion s) async {
    var applied = false;
    await _run(() async {
      final error = await _repository.apply(s.id);
      if (error == null) _rulesChanged([s]);
      return applied = error == null;
    });
    if (applied) {
      await _offerToShare([s]);
      await _offerImports([s]);
    }
  }

  /// A well-done note for approved fixes, offering to share them.
  Future<void> _offerToShare(Iterable<AgentSuggestion> approved) async {
    final community = widget.community;
    if (community == null || !mounted) return;
    await offerToShareFixes(context, community, approved);
  }

  /// For each approved statement layout, offers to import its file now.
  Future<void> _offerImports(Iterable<AgentSuggestion> approved) async {
    for (final s in approved) {
      if (s.kind != AgentSuggestionKind.statementLayout || !mounted) continue;
      if (s.payload['signature'] case final String signature) {
        await widget.onLayoutApproved?.call(context, signature);
      }
    }
  }

  void _rulesChanged(Iterable<AgentSuggestion> changed) {
    if (changed.any((s) => s.kind == AgentSuggestionKind.parserRule)) {
      widget.onRulesChanged?.call();
    }
  }

  void _reject(AgentSuggestion s) => _run(() async {
    await _repository.reject(s.id);
    return false;
  });

  void _undo(AgentSuggestion s) => _run(() async {
    final error = await _repository.undo(s.id);
    if (error != null) _error = error;
    if (error == null) _rulesChanged([s]);
    return error == null;
  }, done: 'Change undone');

  void _approveAll() async {
    final fixes = [
      for (final s in _suggestions ?? const <AgentSuggestion>[])
        if (s.status == AgentSuggestionStatus.pending &&
            shareableFix(s) != null)
          s,
    ];
    await _approveEverything();
    final applied = {
      for (final s in _suggestions ?? const <AgentSuggestion>[])
        if (s.status == AgentSuggestionStatus.applied) s.id,
    };
    final approved = fixes.where((s) => applied.contains(s.id)).toList();
    await _offerToShare(approved);
    await _offerImports(
      approved.where((s) => s.kind == AgentSuggestionKind.statementLayout),
    );
  }

  Future<void> _approveEverything() => _run(() async {
    final rules = {
      for (final s in _suggestions ?? const <AgentSuggestion>[])
        if (s.status == AgentSuggestionStatus.pending &&
            s.kind == AgentSuggestionKind.parserRule)
          s.id,
    };
    final (applied, failed) = await _repository.applyAll();
    if (rules.isNotEmpty) {
      _rulesChanged(
        (await _repository.load(statuses: {AgentSuggestionStatus.applied}))
            .where((s) => rules.contains(s.id)),
      );
    }
    if (failed > 0) {
      _error = failed == 1
          ? 'One suggestion couldn’t be applied; it says why below.'
          : '$failed suggestions couldn’t be applied; each says why below.';
    }
    return applied > 0;
  }, done: 'Approved');

  void _rejectAll() => _run(() async {
    await _repository.rejectAll();
    return false;
  });

  @override
  Widget build(BuildContext context) =>
      FeaturePage(title: 'AI suggestions', child: _body(context));

  Widget _body(BuildContext context) {
    final suggestions = _suggestions;
    if (suggestions == null) {
      return _error == null
          ? const Center(child: CircularProgressIndicator())
          : EmptyState(
              icon: Icons.error_outline_rounded,
              title: 'Couldn’t load',
              message: _error!,
              actionLabel: 'Try again',
              onAction: _load,
            );
    }
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    List<AgentSuggestion> of(Set<AgentSuggestionStatus> statuses) => [
      for (final s in suggestions)
        if (statuses.contains(s.status)) s,
    ];
    final pending = of({AgentSuggestionStatus.pending});
    final applied = of({AgentSuggestionStatus.applied});
    // Undone ones are as good as rejected: not in effect, and can come back.
    final rejected = of({
      AgentSuggestionStatus.rejected,
      AgentSuggestionStatus.undone,
    });
    Widget page(_Tab tab) {
      final shown = switch (tab) {
        _Tab.pending => pending,
        _Tab.applied => applied,
        _Tab.rejected => rejected,
      };
      final grouped = <int>{};
      final headers = _dayHeaders(shown, grouped);
      return RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          // Pull to refresh works even when the list is short.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (tab == _Tab.pending && pending.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 0, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${pending.length} waiting for you',
                              style: muted,
                            ),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _rejectAll,
                            child: const Text('Reject all'),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _approveAll,
                            child: const Text('Approve all'),
                          ),
                        ],
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ),
                  for (final s in shown) ...[
                    ?headers[s.id],
                    Padding(
                      padding: const EdgeInsets.only(bottom: appCardGap),
                      child: _SuggestionCard(
                        key: ValueKey(s.id),
                        suggestion: s,
                        preview: _preview(s),
                        hideReason: grouped.contains(s.id),
                        bare:
                            s.kind == AgentSuggestionKind.transactionAdd ||
                            s.kind == AgentSuggestionKind.parserRule ||
                            (s.kind == AgentSuggestionKind.account && _stores),
                        // Rejected ones can still be applied, from their tab.
                        onApprove: _busy ? null : () => _approve(s),
                        onReject: _busy || tab != _Tab.pending
                            ? null
                            : () => _reject(s),
                        onUndo: s.canUndo && !_busy ? () => _undo(s) : null,
                      ),
                    ),
                  ],
                ]),
              ),
            ),
            // At the end of the list, or the foot of the screen when
            // the list is short.
            SliverFillRemaining(
              // Empty: a body of the viewport's height for the empty
              // state. Otherwise the footnote hugs the bottom.
              hasScrollBody: shown.isEmpty,
              child: Column(
                children: [
                  if (shown.isEmpty)
                    Expanded(
                      child: switch (tab) {
                        _Tab.pending => const EmptyState(
                          icon: Icons.auto_awesome_outlined,
                          art: EmptyArt.chat,
                          title: 'Nothing waiting',
                          message:
                              'Fixes from Claude or ChatGPT show up here. '
                              'Nothing changes until you approve.',
                        ),
                        _Tab.applied => const EmptyState(
                          icon: Icons.check_circle_outline_rounded,
                          art: EmptyArt.chatRead,
                          title: 'Nothing approved yet',
                          message: 'Suggestions you approve are listed here.',
                        ),
                        _Tab.rejected => const EmptyState(
                          icon: Icons.archive_outlined,
                          art: EmptyArt.archive,
                          title: 'Nothing rejected',
                          message: 'Suggestions you reject are listed here.',
                        ),
                      },
                    )
                  else
                    const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
                    child: Text(
                      'Suggestions are kept for 30 days after you decide.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: SegmentedPillTabBar(
            controller: _tabs,
            labels: [
              pending.isEmpty ? 'Pending' : 'Pending ${pending.length}',
              'Applied',
              'Rejected',
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [for (final tab in _Tab.values) page(tab)],
          ),
        ),
      ],
    );
  }
}

enum _Tab { pending, applied, rejected }

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    super.key,
    required this.suggestion,
    this.preview,
    this.bare = false,
    this.hideReason = false,
    this.onApprove,
    this.onReject,
    this.onUndo,
  });
  final AgentSuggestion suggestion;

  /// For a transaction edit: the transaction before and after, shown in
  /// place of the summary and the list of changes.
  final Widget? preview;

  /// Drawn without its own card, for a preview that is already a card (the
  /// day and row as the Transactions list shows them).
  final bool bare;

  /// Several suggestions share a day, so the AI's reason is left out; the
  /// AI is asked to give one only when an entry needs attention.
  final bool hideReason;
  final VoidCallback? onApprove, onReject, onUndo;

  IconData get _icon => switch (suggestion.kind) {
    AgentSuggestionKind.newCategory => Icons.create_new_folder_outlined,
    AgentSuggestionKind.smsCorrection => Icons.sms_outlined,
    AgentSuggestionKind.transactionEdit => Icons.edit_note_rounded,
    AgentSuggestionKind.parserRule => Icons.rule_rounded,
    AgentSuggestionKind.statementLayout => Icons.table_chart_outlined,
    AgentSuggestionKind.newLoan => Icons.account_balance_outlined,
    AgentSuggestionKind.debtEntry => Icons.handshake_outlined,
    AgentSuggestionKind.transactionAdd => Icons.add_card_rounded,
    AgentSuggestionKind.recurringPayment => Icons.autorenew_rounded,
    AgentSuggestionKind.account => Icons.account_balance_wallet_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = suggestion;
    final pending = s.status == AgentSuggestionStatus.pending;
    final preview = this.preview;
    // The rows carry their own padding, so the card's sits around the rest.
    final bare = this.bare && preview != null;
    // Claude's or ChatGPT's mark, for a suggestion that says who made it.
    final source = s.source;
    final logo = source == null ? null : AiAppLogo(source, size: 18);
    final inset = EdgeInsets.symmetric(horizontal: bare ? 6 : 16);
    Widget wrap(Widget child) => bare
        // A thin outline sets one suggestion apart from the next.
        ? Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            decoration: BoxDecoration(
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .6),
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: child,
          )
        : MoneyCard(
            padding: const EdgeInsets.only(top: 14, bottom: 10),
            child: child,
          );
    return wrap(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview != null) ...[
            if (!pending && !bare)
              Padding(
                padding: inset,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _Status(s.status),
                ),
              ),
            preview,
          ] else ...[
            Padding(
              padding: inset,
              child: Row(
                children: [
                  Icon(_icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      s.summary,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!pending) ...[
                    const SizedBox(width: 8),
                    _Status(s.status),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (final line in s.detail)
              Padding(
                padding: inset.copyWith(bottom: 2),
                child: Text(line, style: theme.textTheme.bodyMedium),
              ),
          ],
          if (s.reason != null && !hideReason) ...[
            const SizedBox(height: 6),
            Padding(
              padding: inset,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (logo != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: logo,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      '“${s.reason}”',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (s.error != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: inset,
              child: Text(
                s.error!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: inset,
            child: Row(
              children: [
                // With no reason to sit beside, the app's mark leads the date.
                if (logo != null && !(s.reason != null && !hideReason)) ...[
                  logo,
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    DateFormat('d MMM, HH:mm')
                        .format(s.decidedAt ?? s.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (bare && !pending) ...[
                  _Status(s.status),
                  const SizedBox(width: 10),
                ],
                if (pending) ...[
                  CardAction(
                    label: 'Reject',
                    icon: Icons.close_rounded,
                    color: scheme.onSurfaceVariant,
                    onTap: onReject,
                  ),
                  const SizedBox(width: 8),
                  CardAction(
                    label: 'Approve',
                    icon: Icons.check_rounded,
                    color: scheme.primary,
                    onTap: onApprove,
                  ),
                ] else if (s.canUndo)
                  CardAction(
                    label: 'Undo',
                    icon: Icons.undo_rounded,
                    color: scheme.primary,
                    outlined: true,
                    onTap: onUndo,
                  )
                else if (s.status != AgentSuggestionStatus.applied)
                  CardAction(
                    label: 'Apply',
                    icon: Icons.check_rounded,
                    color: scheme.primary,
                    onTap: onApprove,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What a "New SMS rule" suggestion says it read, taken back out of its
/// detail lines: the example ("₹216.00 credit · Meesho"), whether it reads an
/// account, and the sample message. Null when the lines aren't in that shape.
class _RuleSample {
  const _RuleSample(
    this.amount,
    this.credit,
    this.payee,
    this.message,
    this.category,
    this.missingAccount,
    this.missingCategory,
  );
  final String amount, payee, message;
  final bool missingAccount, missingCategory;

  /// What the parser filed it under, e.g. "Refunds"; null when it has no idea.
  final String? category;
  final bool credit;

  static _RuleSample? parse(List<String> detail) {
    String? value(String prefix) {
      for (final line in detail) {
        if (line.startsWith(prefix)) return line.substring(prefix.length);
      }
      return null;
    }

    final from = value('From: ');
    final reads = value('Reads: ');
    final read = value('Read all ');
    final sample = value('Sample: ');
    if (from == null || reads == null || read == null || sample == null) {
      return null;
    }
    final at = read.indexOf(', e.g. ');
    if (at < 0) return null;
    final pieces = read.substring(at + 7).split(' · ');
    final money = pieces.first.split(' ');
    return _RuleSample(
      money.first,
      money.length > 1 && money.last == 'credit',
      pieces.length > 1 ? pieces[1] : from.split(', ').first,
      sample,
      value('Category: '),
      value('Missing: account') != null ||
          !reads.split(', ').contains('account'),
      value('Missing: category') != null,
    );
  }
}

/// A transaction edit as the transaction before and after it, each the row
/// the rest of the app shows, joined by an arrow.
class _EditPreview extends StatelessWidget {
  const _EditPreview({
    required this.beforeLabel,
    required this.afterLabel,
    required this.before,
    required this.after,
  });
  final String beforeLabel, afterLabel;
  final Widget before, after;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(beforeLabel, style: label),
        ),
        before,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(afterLabel, style: label?.copyWith(color: scheme.primary)),
              const SizedBox(width: 6),
              Icon(
                Icons.arrow_downward_rounded,
                size: 16,
                color: scheme.primary,
              ),
            ],
          ),
        ),
        after,
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.status);
  final AgentSuggestionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      AgentSuggestionStatus.applied => ('Approved', scheme.primary),
      AgentSuggestionStatus.rejected => ('Rejected', scheme.onSurfaceVariant),
      AgentSuggestionStatus.undone => ('Undone', scheme.onSurfaceVariant),
      AgentSuggestionStatus.pending => ('Pending', scheme.onSurfaceVariant),
    };
    return Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
    );
  }
}
