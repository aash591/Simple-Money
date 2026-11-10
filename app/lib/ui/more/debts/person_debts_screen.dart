import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/people_platform.dart';
import '../../../domain/account.dart';
import '../../../domain/debt.dart';
import '../../../state/debt_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/common.dart';
import '../../components/detail_page.dart';
import '../../components/confirmation_alert.dart';
import '../../components/feature_page.dart';
import '../../components/more_popup_button.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transaction_widgets.dart';
import 'debt_sheet.dart';
import 'debt_widgets.dart';

enum _PersonAction { lend, borrow, sort, edit, delete }

/// How History is ordered: by each entry's date, or by when it was added
/// (its id), newest first either way.
enum _HistorySort { date, added }

/// One person: what's owed and when, a way to record a payment or send a
/// reminder, and everything that happened with them.
class PersonDebtsScreen extends StatefulWidget {
  const PersonDebtsScreen({
    super.key,
    required this.store,
    required this.personId,
  });
  final DebtStore store;
  final int personId;

  @override
  State<PersonDebtsScreen> createState() => _PersonDebtsScreenState();
}

class _PersonDebtsScreenState extends State<PersonDebtsScreen> {
  static const _sortKey = 'debt_history_sort';
  var _sort = _HistorySort.date;

  DebtStore get store => widget.store;
  int get personId => widget.personId;

  @override
  void initState() {
    super.initState();
    _restoreSort();
  }

  Future<void> _restoreSort() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_sortKey);
      if (!mounted) return;
      setState(
        () => _sort = _HistorySort.values.firstWhere(
          (sort) => sort.name == saved,
          orElse: () => _HistorySort.date,
        ),
      );
    } catch (_) {
      // Falls back to date order.
    }
  }

  Future<void> _chooseSort() async {
    final picked = await showChoiceListSheet<_HistorySort>(
      context,
      title: 'Sort history by',
      items: const [
        ChoiceItem(
          value: _HistorySort.date,
          icon: Icon(Icons.calendar_today_rounded),
          label: 'Date',
        ),
        ChoiceItem(
          value: _HistorySort.added,
          icon: Icon(Icons.history_rounded),
          label: 'Recently added',
        ),
      ],
      selected: _sort,
    );
    if (picked == null || !mounted) return;
    setState(() => _sort = picked);
    try {
      await (await SharedPreferences.getInstance()).setString(
        _sortKey,
        picked.name,
      );
    } catch (_) {
      // Only this session keeps the choice.
    }
  }

  /// Entries arrive newest date first.
  List<DebtEntry> _sorted(List<DebtEntry> entries) => switch (_sort) {
    _HistorySort.date => entries,
    _HistorySort.added => [...entries]..sort((a, b) => b.id.compareTo(a.id)),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final debts = store.personById(personId);
      // Deleted while open; the delete action pops this page.
      if (debts == null) {
        return const FeaturePage(title: '', child: SizedBox.shrink());
      }
      final entries = _sorted(debts.entries);
      return FeaturePage(
        title: debts.person.name,
        actions: [
          MorePopupButton<_PersonAction>(
            items: const [
              MorePopupItem(
                value: _PersonAction.lend,
                label: 'Lend more',
                icon: Icons.north_east_rounded,
              ),
              MorePopupItem(
                value: _PersonAction.borrow,
                label: 'Borrow more',
                icon: Icons.south_west_rounded,
              ),
              MorePopupItem(
                value: _PersonAction.sort,
                label: 'Sort by',
                icon: Icons.sort_rounded,
                dividerBefore: true,
              ),
              MorePopupItem(
                value: _PersonAction.edit,
                label: 'Edit',
                icon: Icons.edit_outlined,
                dividerBefore: true,
              ),
              MorePopupItem(
                value: _PersonAction.delete,
                label: 'Delete',
                icon: Icons.delete_outline_rounded,
              ),
            ],
            onSelected: (action) => _onAction(context, debts, action),
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
          children: [
            _Summary(debts: debts),
            const SizedBox(height: 22),
            DetailSectionHeading(
              debts.settled ? 'Start again' : 'Settle up',
              status: !debts.settled && debts.dueDate != null
                  ? DueChip(debts.dueDate!)
                  : null,
            ),
            const SizedBox(height: 10),
            MoneyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    debts.settled
                        ? 'All settled. Add a debt if you lend or borrow again.'
                        : debts.owesYou
                        ? 'Record what they pay back, or send them a nudge.'
                        : 'Record what you pay back to clear this.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  _actions(context, debts),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const SectionTitle('Details'),
            const SizedBox(height: 10),
            DetailFacts(
              facts: [
                DetailFact(
                  debts.owesYou ? 'Owed to you' : 'You owe',
                  formatDebtAmounts(debts.balances),
                  valueColor: debts.settled
                      ? null
                      : owedColor(context, toYou: debts.owesYou),
                ),
                if (debts.person.phone case final phone?)
                  DetailFact('Phone', phone),
                if (entries.isNotEmpty)
                  DetailFact(
                    'Since',
                    DateFormat('d MMM yyyy')
                        .format(entries.map((e) => e.date).reduce(_earlier)),
                  ),
                DetailFact('Entries', '${entries.length}'),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'History',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: _chooseSort,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.sort_rounded, size: 18),
                  label: Text(
                    _sort == _HistorySort.date ? 'Date' : 'Recently added',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DetailHistoryCard(
              empty: const DetailEmpty(
                icon: Icons.receipt_long_outlined,
                title: 'Nothing recorded yet',
                message: 'Lending, borrowing and payments all show up here.',
              ),
              entries: [
                for (final entry in entries)
                  DetailEntry(
                    leading: DetailIconTile(
                      entry.kind.icon,
                      color: debtKindColor(context, entry.kind),
                    ),
                    title: entry.kind.describe(debts.person.name),
                    caption: [
                      DateFormat('d MMM yyyy').format(entry.date),
                      ?_accountOf(entry)?.name,
                      ?entry.note,
                    ].join(' · '),
                    amount: formatAccountMoney(
                      entry.amountMinor,
                      digits: entry.digits,
                      currency: entry.currency,
                    ),
                    onTap: () => showAdaptiveSheet<void>(
                      context,
                      builder: (sheetContext) => _EntrySheet(
                        store: store,
                        person: debts.person,
                        entry: entry,
                        account: _accountOf(entry),
                        onEdit: () {
                          Navigator.pop(sheetContext);
                          showEditDebtEntrySheet(
                            context,
                            store: store,
                            entry: entry,
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );

  static DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

  Account? _accountOf(DebtEntry entry) =>
      store.accountStore.byId(entry.accountId);

  /// Primary-first actions shared with recurring payments and loans.
  Widget _actions(BuildContext context, PersonDebts debts) {
    if (debts.settled) {
      return DetailActions(
        primaryLabel: 'Add debt',
        primaryIcon: Icons.add_rounded,
        onPrimary: () =>
            showAddDebtSheet(context, store: store, personId: personId),
      );
    }
    return DetailActions(
      primaryLabel: debts.owesYou ? 'Got paid' : 'Pay back',
      primaryIcon: debts.owesYou
          ? Icons.south_west_rounded
          : Icons.north_east_rounded,
      onPrimary: () =>
          showDebtPaymentSheet(context, store: store, personId: personId),
      secondaryLabel: debts.owesYou ? 'Remind' : null,
      secondaryIcon: Icons.notifications_active_outlined,
      onSecondary: () => _remind(context, debts),
    );
  }

  Future<void> _remind(BuildContext context, PersonDebts debts) async {
    final amount = formatDebtAmounts(
      debts.balances.where((balance) => balance.amountMinor > 0),
    );
    final due = debts.dueDate;
    final firstName = debts.person.name.split(' ').first;
    final message =
        'Hi $firstName, just a friendly reminder about the $amount I lent you'
        '${due == null ? '' : ', due ${DateFormat('d MMM').format(due)}'}. '
        'Thanks!';
    try {
      await const PeoplePlatform().shareText(message);
    } catch (_) {
      if (context.mounted) {
        showAppToast(context, 'Could not open sharing. Please try again.');
      }
    }
  }

  Future<void> _onAction(
    BuildContext context,
    PersonDebts debts,
    _PersonAction action,
  ) async {
    final name = debts.person.name;
    switch (action) {
      case _PersonAction.sort:
        await _chooseSort();
      case _PersonAction.lend:
      case _PersonAction.borrow:
        await showAddDebtSheet(
          context,
          store: store,
          personId: personId,
          kind: action == _PersonAction.lend ? DebtKind.lend : DebtKind.borrow,
        );
      case _PersonAction.edit:
        await showEditPersonSheet(context, store: store, person: debts.person);
      case _PersonAction.delete:
        final linked = debts.entries.any(
          (entry) => entry.transactionId != null,
        );
        final confirmed = await showDeleteConfirmation(
          context,
          title: 'Delete $name?',
          message: linked
              ? 'Deletes everything with $name and the transactions it added. Balances update to match.'
              : 'This deletes everything recorded with $name.',
        );
        if (!confirmed || !context.mounted) return;
        final navigator = Navigator.of(context);
        try {
          await store.deletePerson(debts);
          navigator.pop();
          if (navigator.mounted) {
            showAppToast(navigator.context, '$name deleted');
          }
        } catch (_) {
          if (context.mounted) {
            showAppToast(context, 'Could not delete $name. Please try again.');
          }
        }
    }
  }
}

/// Who this is and what it comes to, in the same shape the recurring payment and
/// loan pages open with.
class _Summary extends StatelessWidget {
  const _Summary({required this.debts});
  final PersonDebts debts;

  @override
  Widget build(BuildContext context) {
    final name = debts.person.name;
    final colors = SheetColors.of(context);
    return DetailHero(
      leading: PersonAvatar(name, size: 64),
      title: name,
      amount: debts.settled ? 'All settled' : formatDebtAmounts(debts.balances),
      caption: debts.settled
          ? null
          : (debts.owesYou ? 'owed to you' : 'you owe'),
      amountColor: debts.settled
          ? colors.income
          : owedColor(context, toYou: debts.owesYou),
      banner: debts.settled
          ? DetailBanner(
              icon: Icons.check_circle_rounded,
              color: colors.income,
              text: 'Nothing outstanding with $name.',
            )
          : null,
    );
  }
}

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({
    required this.store,
    required this.person,
    required this.entry,
    required this.account,
    required this.onEdit,
  });
  final DebtStore store;
  final DebtPerson person;
  final DebtEntry entry;
  final Account? account;
  final VoidCallback onEdit;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  var _deleting = false;

  Future<void> _delete() async {
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete this entry?',
      message: widget.entry.transactionId != null
          ? 'Also deletes the transaction it added. Your balance updates to match.'
          : 'This entry will be permanently deleted.',
    );
    if (!confirmed || !mounted) return;
    final navigator = Navigator.of(context);
    setState(() => _deleting = true);
    try {
      await widget.store.deleteEntry(widget.entry);
      if (!mounted) return;
      showAppToast(context, 'Entry deleted');
      navigator.pop();
    } catch (_) {
      if (mounted) {
        setState(() => _deleting = false);
        showAppToast(context, 'Could not delete this entry. Please try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final entry = widget.entry;
    final account = widget.account;
    final due = entry.dueDate;
    final note = entry.note;
    final dateFormat = DateFormat('MMM d, yyyy');
    return SheetPage(
      header: const SheetHeader('Debt entry'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          AmountHero(
            amount: formatAccountMoney(
              entry.amountMinor,
              digits: entry.digits,
              currency: entry.currency,
            ),
            caption: entry.kind.describe(widget.person.name),
            color: debtKindColor(context, entry.kind),
          ),
          const SizedBox(height: 20),
          TransactionDetailsCard(
            rows: [
              TransactionDetailRow(
                leading: SheetIconTile(child: PersonAvatar(widget.person.name)),
                label: 'Person',
                value: widget.person.name,
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: account != null,
                  iconKey: account?.icon,
                  fallback: Icons.edit_note_rounded,
                ),
                label: entry.kind.paysOut ? 'Paid from' : 'Received in',
                value: account?.name ?? 'No account, just a record',
              ),
              TransactionDetailRow(
                leading: const SheetIconTile(
                  icon: Icons.calendar_today_rounded,
                ),
                label: 'Date',
                value: dateFormat.format(entry.date),
              ),
              if (due != null)
                TransactionDetailRow(
                  leading: const SheetIconTile(
                    icon: Icons.event_available_rounded,
                  ),
                  label: 'Due date',
                  value: dateFormat.format(due),
                ),
              if (note != null)
                TransactionDetailRow(
                  leading: const SheetIconTile(icon: Icons.notes_rounded),
                  label: 'Note',
                  value: note,
                  maxLines: 6,
                ),
            ],
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Delete',
        onSecondary: _deleting ? null : _delete,
        secondaryForegroundColor: colors.expense,
        primaryLabel: 'Edit',
        onPrimary: _deleting ? null : widget.onEdit,
      ),
    );
  }
}
