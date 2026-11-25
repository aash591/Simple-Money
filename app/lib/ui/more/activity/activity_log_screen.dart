import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/backup/sync_activity.dart';
import '../../../data/db/app_database.dart';
import '../../../data/history/change_history.dart';
import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/transaction.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/sync_controller.dart';
import '../../../state/transaction_store.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_toast.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/more_popup_button.dart';
import '../../components/segmented_pill.dart';
import '../../components/transactions/transaction_day_header.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../transactions/transaction_widgets.dart';

/// The tabs, swiped between.
enum _Filter { all, added, edited, deleted }

/// The orders the ⋯ menu offers.
enum _Sort {
  newest('Newest change first', Icons.history_rounded),
  oldest('Oldest change first', Icons.update_rounded),
  date('Transaction date', Icons.event_rounded),
  amount('Amount', Icons.payments_rounded);

  const _Sort(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// More › History: every transaction added, edited or deleted, on this
/// phone or on the account's other phones, newest first, with sync events
/// (turned on, restored, problems) in between. Any change can be undone.
class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({
    super.key,
    required this.database,
    required this.accounts,
    required this.categories,
    this.transactions,
    this.sync,
    this.onLedgerChanged,
  });
  final AppDatabase database;
  final AccountStore accounts;
  final CategoryStore categories;

  /// For the icons the live transactions show (recurring payments, loans).
  final TransactionStore? transactions;
  final SyncController? sync;

  /// Reloads the ledger screens after an undo.
  final VoidCallback? onLedgerChanged;

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  static const _page = 300;
  late final _history = ChangeHistoryRepository(widget.database);
  List<RecordChange>? _changes;
  List<SyncActivity> _events = const [];
  bool _more = false;
  _Sort _sort = _Sort.newest;

  @override
  void initState() {
    super.initState();
    widget.sync?.addListener(_load);
    _loadAfterTransition();
  }

  Animation<double>? _routeAnimation;
  AnimationStatusListener? _routeListener;

  /// Reading the history and building its rows while the page is still
  /// sliding in makes the slide stutter, so the first load waits for it.
  void _loadAfterTransition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _load();
        return;
      }
      _routeAnimation = animation;
      _routeListener = (status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          animation.removeStatusListener(_routeListener!);
          _routeListener = null;
          if (mounted) _load();
        }
      };
      animation.addStatusListener(_routeListener!);
    });
  }

  @override
  void dispose() {
    widget.sync?.removeListener(_load);
    if (_routeListener != null) {
      _routeAnimation?.removeStatusListener(_routeListener!);
    }
    super.dispose();
  }

  Future<void> _load() async {
    await _history.prune();
    final changes = await _history.load(
      limit: _changes == null ? _page : _changes!.length.clamp(_page, 5000),
    );
    final events = await widget.sync?.repository.activity(limit: 200);
    if (!mounted) return;
    setState(() {
      _changes = changes;
      _more = changes.length >= _page;
      _events = [
        for (final event in events ?? const <SyncActivity>[])
          // What was sent and received shows as the changes themselves.
          if (event.kind != SyncActivityKind.sent &&
              event.kind != SyncActivityKind.received)
            event,
      ];
    });
  }

  Future<void> _loadOlder() async {
    final changes = _changes;
    if (changes == null || changes.isEmpty) return;
    final older = await _history.load(limit: _page, olderThan: changes.last.id);
    if (!mounted) return;
    setState(() {
      _changes = [...changes, ...older];
      _more = older.length >= _page;
    });
  }

  Account? _account(Object? id) =>
      widget.accounts.allAccounts.where((a) => a.id == id).firstOrNull;
  Category? _category(Object? id) =>
      widget.categories.categories.where((c) => c.id == id).firstOrNull;

  /// The transaction a change shows, as the rest of the app shows it.
  MoneyTransaction? _transaction(RecordChange change) {
    final row = change.record;
    final id = row['id'], amount = row['amount_minor'];
    final account = row['account_id'], date = row['date'];
    if (id is! int || amount is! int || account is! int || date is! int) {
      return null;
    }
    final live = widget.transactions?.transactions
        .where((t) => t.id == id)
        .firstOrNull;
    return MoneyTransaction(
      id: id,
      type: TransactionTypeStorage.fromStorage('${row['type']}'),
      isCreditCard: row['is_credit_card'] == 1,
      amountMinor: amount,
      accountId: account,
      toAccountId: row['to_account_id'] as int?,
      toAmountMinor: row['to_amount_minor'] as int?,
      categoryId: row['category_id'] as int?,
      title: row['title'] as String?,
      note: row['note'] as String?,
      date: DateTime.fromMillisecondsSinceEpoch(date),
      icon: live?.icon,
      badgeIcon: live?.badgeIcon,
    );
  }

  String _amount(MoneyTransaction t) {
    final source = _account(t.accountId);
    if (t.type == TransactionType.transfer) {
      final sent = formatTransactionMoney(t.amountMinor, source);
      final received = formatTransactionMoney(
        t.receivedMinor,
        _account(t.toAccountId),
      );
      return sent == received ? sent : '$sent → $received';
    }
    return '${t.type == TransactionType.income ? '+ ' : '- '}'
        '${formatTransactionMoney(t.amountMinor, source)}';
  }

  static String _verb(ChangeAction action) => switch (action) {
    ChangeAction.added => 'Added',
    ChangeAction.edited => 'Edited',
    ChangeAction.deleted => 'Deleted',
  };

  /// Readable names of the fields an edit changed.
  static const _fields = {
    'amount_minor': 'amount',
    'to_amount_minor': 'amount received',
    'category_id': 'category',
    'account_id': 'account',
    'to_account_id': 'to account',
    'title': 'title',
    'note': 'note',
    'date': 'date',
    'type': 'type',
  };

  /// "Edited · amount, category · 10:42 AM · Pixel 8"
  String _line(RecordChange change) {
    final changed = [
      for (final MapEntry(:key, :value) in _fields.entries)
        if (change.changedColumns.contains(key)) value,
    ];
    return [
      change.undone ? '${_verb(change.action)}, undone' : _verb(change.action),
      if (change.action == ChangeAction.edited && changed.isNotEmpty)
        changed.take(3).join(', '),
      DateFormat.jm().format(change.at),
      ?change.device,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final changes = _changes;
    return DefaultTabController(
      length: _Filter.values.length,
      child: FeaturePage(
        title: 'History',
        actions: [
          MorePopupButton<_Sort>(
            tooltip: 'Sort',
            items: [
              for (final sort in _Sort.values)
                MorePopupItem(
                  value: sort,
                  label: sort.label,
                  icon: sort == _sort ? Icons.check_rounded : sort.icon,
                ),
            ],
            onSelected: (sort) => setState(() => _sort = sort),
          ),
        ],
        child: changes == null
            ? const SizedBox.shrink()
            : changes.isEmpty && _events.isEmpty
            ? const Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(24),
                  child: EmptyState(
                    icon: Icons.history_rounded,
                    title: 'No changes yet',
                    message:
                        'Every transaction you add, edit or delete shows up '
                        'here, including ones from your other phones. You '
                        'can undo any of them.',
                  ),
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: SegmentedPillTabBar(
                          labels: ['All', 'Added', 'Edited', 'Deleted'],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            for (final filter in _Filter.values)
                              RefreshIndicator(
                                onRefresh: () async {
                                  await widget.sync?.syncNow();
                                  await _load();
                                },
                                child: _list(changes, filter),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// What [filter]'s tab shows, in the chosen order: grouped by the day of
  /// the change, or of the transaction, or (by amount) not grouped.
  Widget _list(List<RecordChange> changes, _Filter filter) {
    final matching = [
      for (final change in changes)
        if (filter == _Filter.all || filter.name == change.action.name) change,
    ];
    final byChange = _sort == _Sort.newest || _sort == _Sort.oldest;
    final List<Object> shown = [
      ...matching,
      // Sync events sit between the changes when they are ordered by time.
      if (filter == _Filter.all && byChange) ..._events,
    ];
    DateTime changed(Object item) => switch (item) {
      RecordChange change => change.at,
      SyncActivity event => event.at,
      _ => DateTime(0),
    };
    DateTime made(Object item) => item is RecordChange
        ? DateTime.fromMillisecondsSinceEpoch(
            item.record['date'] is int ? item.record['date'] as int : 0,
          )
        : changed(item);
    int amount(Object item) => item is RecordChange
        ? (item.record['amount_minor'] is int
              ? item.record['amount_minor'] as int
              : 0)
        : 0;
    switch (_sort) {
      case _Sort.newest:
        shown.sort((a, b) => changed(b).compareTo(changed(a)));
      case _Sort.oldest:
        shown.sort((a, b) => changed(a).compareTo(changed(b)));
      case _Sort.date:
        shown.sort((a, b) => made(b).compareTo(made(a)));
      case _Sort.amount:
        shown.sort((a, b) => amount(b).compareTo(amount(a)));
    }
    final groups = <(DateTime?, List<Object>)>[];
    for (final item in shown) {
      final day = switch (_sort) {
        _Sort.amount => null,
        _Sort.date => DateUtils.dateOnly(made(item)),
        _ => DateUtils.dateOnly(changed(item)),
      };
      if (groups.isEmpty || groups.last.$1 != day) {
        groups.add((day, [item]));
      } else {
        groups.last.$2.add(item);
      }
    }
    // An ungrouped list (by amount) would be one card of every row; cut it
    // into cards of a screenful so they can be built as they scroll into view.
    const cardRows = 20;
    final cards = <(DateTime?, List<Object>)>[
      for (final (day, items) in groups)
        if (day == null && items.length > cardRows)
          for (var i = 0; i < items.length; i += cardRows)
            (null, items.sublist(i, math.min(i + cardRows, items.length)))
        else
          (day, items),
    ];
    final empty = cards.isEmpty ? 1 : 0;
    // Built lazily: a long history would otherwise build every row on
    // opening the page, and stutter the transition.
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      itemCount: empty + cards.length + (_more ? 1 : 0),
      itemBuilder: (context, index) {
        if (empty == 1 && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Text(
              filter == _Filter.all
                  ? 'Nothing here yet.'
                  : 'Nothing ${filter.name} yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final at = index - empty;
        if (at >= cards.length) {
          return Center(
            child: TextButton(
              onPressed: _loadOlder,
              child: const Text('Show older changes'),
            ),
          );
        }
        final (day, items) = cards[at];
        return Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (day != null) TransactionDayHeader(date: day),
              MoneyCard(
                padding: EdgeInsets.zero,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      for (final (i, item) in items.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        switch (item) {
                          RecordChange change => _changeRow(change),
                          SyncActivity event => _EventRow(event: event),
                          _ => const SizedBox.shrink(),
                        },
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _changeRow(RecordChange change) {
    final t = _transaction(change);
    if (t == null) return const SizedBox.shrink();
    final category = _category(t.categoryId);
    final faded = change.action == ChangeAction.deleted || change.undone;
    return Opacity(
      opacity: faded ? 0.5 : 1,
      child: TransactionListRow(
        transaction: t,
        account: _account(t.accountId),
        toAccount: _account(t.toAccountId),
        category: category,
        parentCategory: _category(category?.parentId),
        formattedAmount: _amount(t),
        showDate: true,
        subtitle: _line(change),
        onTap: () => _details(change, t),
      ),
    );
  }

  Future<void> _details(
    RecordChange change,
    MoneyTransaction t,
  ) => showAdaptiveSheet<void>(
    context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      final text = Theme.of(context).textTheme;
      final edits = [
        for (final MapEntry(:key, :value) in _fields.entries)
          if (change.changedColumns.contains(key))
            (
              value[0].toUpperCase() + value.substring(1),
              _describe(key, change.before?[key], change.before),
              _describe(key, change.after?[key], change.after),
            ),
      ];
      final who = change.device ?? 'This phone';
      final when = DateFormat('d MMM yyyy, h:mm a').format(change.at);
      return SheetPage(
        header: SheetHeader('${_verb(change.action)} transaction'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                '$who · $when',
                style: text.bodySmall?.copyWith(height: 1.4),
              ),
            ),
            SheetCard(
              child: TransactionListRow(
                transaction: t,
                account: _account(t.accountId),
                toAccount: _account(t.toAccountId),
                category: _category(t.categoryId),
                parentCategory: _category(_category(t.categoryId)?.parentId),
                formattedAmount: _amount(t),
                showDate: true,
                onTap: () {},
              ),
            ),
            if (edits.isNotEmpty) ...[
              const SizedBox(height: 12),
              SheetCard(
                child: Column(
                  children: [
                    for (final (i, (field, was, now)) in edits.indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 96,
                              child: Text(
                                field,
                                style: text.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: was,
                                      style: TextStyle(
                                        color: scheme.onSurfaceVariant,
                                        decoration: TextDecoration.lineThrough,
                                      ),
                                    ),
                                    const TextSpan(text: '  →  '),
                                    TextSpan(
                                      text: now,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                style: text.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (change.undone)
              Text(
                'Already undone.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _undo(change);
                },
                icon: const Icon(Icons.undo_rounded),
                label: Text(switch (change.action) {
                  ChangeAction.added => 'Undo · delete it',
                  ChangeAction.edited => 'Undo this edit',
                  ChangeAction.deleted => 'Undo · bring it back',
                }),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  /// A field's value as the details sheet shows it.
  String _describe(String field, Object? value, Map<String, Object?>? row) {
    if (value == null || (value is String && value.trim().isEmpty)) {
      return 'None';
    }
    return switch (field) {
      'amount_minor' => formatTransactionMoney(
        value as int,
        _account(row?['account_id']),
      ),
      'to_amount_minor' => formatTransactionMoney(
        value as int,
        _account(row?['to_account_id']),
      ),
      'category_id' => _category(value)?.name ?? 'A deleted category',
      'account_id' ||
      'to_account_id' => _account(value)?.name ?? 'A deleted account',
      'date' when value is int => DateFormat(
        'd MMM yyyy, h:mm a',
      ).format(DateTime.fromMillisecondsSinceEpoch(value)),
      'type' => switch ('$value') {
        'income' => 'Income',
        'transfer' => 'Transfer',
        _ => 'Expense',
      },
      _ => '$value',
    };
  }

  Future<void> _undo(RecordChange change) async {
    final elsewhere = widget.sync?.status?.enabled == true
        ? ' Your other phones get the change too.'
        : '';
    final (title, message, label) = switch (change.action) {
      ChangeAction.added => (
        'Delete this transaction?',
        'Undoing the add deletes it.$elsewhere',
        'Delete',
      ),
      ChangeAction.edited => (
        'Undo this edit?',
        'The transaction goes back to how it was.$elsewhere',
        'Undo',
      ),
      ChangeAction.deleted => (
        'Bring this transaction back?',
        'It goes back where it was, and the balance moves with it.$elsewhere',
        'Bring back',
      ),
    };
    if (!await showConfirmationAlert(
          context,
          title: title,
          message: message,
          confirmLabel: label,
        ) ||
        !mounted) {
      return;
    }
    try {
      await _history.undo(change.id);
      widget.onLedgerChanged?.call();
      widget.sync?.changedLocally();
      if (!mounted) return;
      showAppToast(context, 'Undone', icon: Icons.undo_rounded);
      await _load();
    } on StateError catch (error) {
      if (mounted) showAppToast(context, error.message);
    }
  }
}

/// A sync event between the changes: turned on or off, a restore, a problem.
class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final SyncActivity event;

  String get _title => switch (event.kind) {
    SyncActivityKind.restored => 'Restored from Google Drive',
    SyncActivityKind.imported => 'Imported a backup file',
    SyncActivityKind.erased => 'Deleted the data on this phone',
    SyncActivityKind.connected => 'Sync turned on',
    SyncActivityKind.paused =>
      event.message == 'Signed out' ? 'Signed out of sync' : 'Sync turned off',
    SyncActivityKind.error => 'Sync didn’t go through',
    SyncActivityKind.sent => 'Sent to Google Drive',
    SyncActivityKind.received =>
      'Changes from ${event.device ?? 'another phone'}',
  };

  String? get _detail => switch (event.kind) {
    SyncActivityKind.connected => event.message,
    SyncActivityKind.restored || SyncActivityKind.imported =>
      event.count == 0
          ? null
          : '${event.count} transaction${event.count == 1 ? '' : 's'}',
    SyncActivityKind.error =>
      '${event.message ?? 'It retries by itself.'}'
          '${event.count > 1 ? ' (${event.count} times)' : ''}',
    _ => null,
  };

  IconData get _icon => switch (event.kind) {
    SyncActivityKind.sent => Icons.cloud_upload_rounded,
    SyncActivityKind.received => Icons.devices_rounded,
    SyncActivityKind.restored => Icons.cloud_download_rounded,
    SyncActivityKind.imported => Icons.file_open_rounded,
    SyncActivityKind.erased => Icons.delete_sweep_rounded,
    SyncActivityKind.connected => Icons.cloud_done_rounded,
    SyncActivityKind.paused => Icons.cloud_off_rounded,
    SyncActivityKind.error => Icons.error_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = event.kind == SyncActivityKind.error;
    final detail = _detail;
    final time = DateFormat.jm().format(event.at);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: (error ? scheme.error : scheme.primary).withValues(
                  alpha: 0.12,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _icon,
                size: 20,
                color: error ? scheme.error : scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail == null ? time : '$time · $detail',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
