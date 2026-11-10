import 'loan_suggestion_card.dart';
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
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/transactions/transaction_list_row.dart';
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

class _AiSuggestionsScreenState extends State<AiSuggestionsScreen> {
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
  _Tab _tab = _Tab.pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
            s.kind == AgentSuggestionKind.recurringPayment ||
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
  Widget _row(MoneyTransaction t, {String? newCategory}) {
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
      showDate: true,
      onTap: () => _openTransaction(t),
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
    if (s.kind == AgentSuggestionKind.recurringPayment) {
      return RecurringSuggestionPreview(
        payload: s.payload,
        account: _stores ? _account(s.payload['accountId'] as int?) : null,
        category: _stores
            ? _categories.categories
                  .where((c) => c.id == s.payload['categoryId'])
                  .firstOrNull
            : null,
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
    final shown = switch (_tab) {
      _Tab.pending => pending,
      _Tab.applied => applied,
      _Tab.rejected => rejected,
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: SegmentedPill<_Tab>(
            value: _tab,
            onChanged: (tab) => setState(() => _tab = tab),
            segments: [
              PillSegment(
                _Tab.pending,
                pending.isEmpty ? 'Pending' : 'Pending ${pending.length}',
              ),
              const PillSegment(_Tab.applied, 'Applied'),
              const PillSegment(_Tab.rejected, 'Rejected'),
            ],
          ),
        ),
        Expanded(
          child: SegmentSwipe<_Tab>(
            values: _Tab.values,
            value: _tab,
            onChanged: (tab) => setState(() => _tab = tab),
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 40),
                children: [
                  if (_tab == _Tab.pending && pending.length > 1)
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
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: Text(
                        switch (_tab) {
                          _Tab.pending =>
                            'Nothing waiting. Fixes from Claude or ChatGPT '
                                'show up here, and nothing changes until you '
                                'approve.',
                          _Tab.applied => 'Nothing approved yet.',
                          _Tab.rejected => 'Nothing rejected.',
                        },
                        textAlign: TextAlign.center,
                        style: muted,
                      ),
                    ),
                  for (final s in shown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: appCardGap),
                      child: _SuggestionCard(
                        key: ValueKey(s.id),
                        suggestion: s,
                        preview: _preview(s),
                        // Rejected ones can still be applied, from their tab.
                        onApprove: _busy ? null : () => _approve(s),
                        onReject: _busy || _tab != _Tab.pending
                            ? null
                            : () => _reject(s),
                        onUndo: s.canUndo && !_busy ? () => _undo(s) : null,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
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
    this.onApprove,
    this.onReject,
    this.onUndo,
  });
  final AgentSuggestion suggestion;

  /// For a transaction edit: the transaction before and after, shown in
  /// place of the summary and the list of changes.
  final Widget? preview;
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
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = suggestion;
    final pending = s.status == AgentSuggestionStatus.pending;
    final preview = this.preview;
    // The rows carry their own padding, so the card's sits around the rest.
    const inset = EdgeInsets.symmetric(horizontal: 16);
    return MoneyCard(
      padding: const EdgeInsets.only(top: 14, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview != null) ...[
            if (!pending)
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
          if (s.reason != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: inset,
              child: Text(
                '“${s.reason}”',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
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
                Expanded(
                  child: Text(
                    DateFormat('d MMM, HH:mm')
                        .format(s.decidedAt ?? s.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
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
