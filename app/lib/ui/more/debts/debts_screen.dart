import 'package:flutter/material.dart';

import '../../components/glass_surface.dart';

import '../../components/app_back_button.dart';

import 'package:intl/intl.dart';

import '../../../domain/debt.dart';
import '../../../state/debt_store.dart';
import '../../components/common.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/reminder_card.dart';
import '../../components/search_field.dart';
import '../../components/secondary_header.dart';
import '../../components/skeleton.dart';
import '../../theme/sheet_colors.dart';
import 'debt_sheet.dart';
import 'debt_widgets.dart';
import 'person_debts_screen.dart';

/// Everyone you've lent money to or borrowed from: what's owed each way at
/// the top, then one swipeable page per side. The totals double as tabs for
/// those pages, and say how many people and how many are overdue. Each side
/// lists its people most urgent first, with anyone already settled at the end.
class DebtsScreen extends StatefulWidget {
  const DebtsScreen({super.key, required this.store});
  final DebtStore store;

  @override
  State<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends State<DebtsScreen> {
  final _pages = PageController();

  /// 0 shows who owes you, 1 who you owe.
  var _page = 0;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  var _searching = false;

  DebtStore get _store => widget.store;

  @override
  void dispose() {
    _pages.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _cancelSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _search.clear();
    });
  }

  void _showPage(int page) {
    if (!_pages.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _add() => showAddDebtSheet(context, store: _store);

  void _open(PersonDebts debts) => Navigator.of(context).push(
    FeatureRoute<void>(
      PersonDebtsScreen(store: _store, personId: debts.person.id),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelSearch();
      },
      child: GlassPage(
        child: Scaffold(
          floatingActionButton: _searching
              ? null
              : AddFab(onPressed: _add, tooltip: 'Add debt'),
          body: SafeArea(
            child: Column(
              children: [
                SearchableHeader(
                  searching: _searching,
                  controller: _search,
                  focusNode: _searchFocus,
                  fieldKey: const Key('debt-search'),
                  hintText: 'Search people or notes',
                  onChanged: (_) => setState(() {}),
                  onCancel: _cancelSearch,
                  header: SecondaryHeader(
                    title: 'Debts',
                    leading: Navigator.of(context).canPop()
                        ? const AppBackButton()
                        : null,
                    actions: [
                      AppSearchButton(
                        tooltip: 'Search debts',
                        onPressed: _openSearch,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: ListenableBuilder(
                        listenable: _store,
                        builder: (context, _) => _body(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_store.loading) {
      return const SkeletonList();
    }
    if (_store.loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_store.loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _store.load,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final people = _store.people;
    if (people.isEmpty) {
      return EmptyState(
        icon: Icons.handshake_outlined,
        title: 'No debts. Nice.',
        message: 'Track money you lend or borrow. Get reminded when it’s due.',
        actionLabel: 'Add your first debt',
        onAction: _add,
      );
    }
    final query = _search.text.trim().toLowerCase();
    final account = _store.accountStore.accounts.firstOrNull;
    String total({required bool owedToYou}) => formatDebtAmounts(
      totalDebts(people, owedToYou: owedToYou),
      currency: account?.currency ?? 'INR',
      digits: account?.digits ?? 2,
    );
    // Everyone on a side, and how many of them are open or overdue: the
    // counts describe all the debts, not what a search has narrowed to.
    List<PersonDebts> all({required bool owedToYou}) =>
        people.where((debts) => debts.onOwedToYouSide == owedToYou).toList();
    List<PersonDebts> side({required bool owedToYou}) =>
        all(owedToYou: owedToYou)
            .where((debts) => _matches(debts, query))
            .toList()
          ..sort(_byUrgency);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          // Both totals stand the same height, however long their captions.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _TotalCard(
                    label: 'Owed to you',
                    amount: total(owedToYou: true),
                    icon: Icons.south_west_rounded,
                    people: all(owedToYou: true),
                    color: owedColor(context, toYou: true),
                    selected: _page == 0,
                    onTap: () => _showPage(0),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TotalCard(
                    label: 'You owe',
                    amount: total(owedToYou: false),
                    icon: Icons.north_east_rounded,
                    people: all(owedToYou: false),
                    color: owedColor(context, toYou: false),
                    selected: _page == 1,
                    onTap: () => _showPage(1),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: PageView(
            controller: _pages,
            onPageChanged: (page) => setState(() => _page = page),
            children: [
              _PeopleList(
                key: const PageStorageKey('debts-owed-to-you'),
                owedToYou: true,
                people: side(owedToYou: true),
                searching: query.isNotEmpty,
                store: _store,
                onTap: _open,
              ),
              _PeopleList(
                key: const PageStorageKey('debts-you-owe'),
                owedToYou: false,
                people: side(owedToYou: false),
                searching: query.isNotEmpty,
                store: _store,
                onTap: _open,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// By name, phone number, or any entry's note.
  static bool _matches(PersonDebts debts, String query) {
    if (query.isEmpty) return true;
    if (debts.person.name.toLowerCase().contains(query)) return true;
    final digits = query.replaceAll(RegExp(r'[\s-]'), '');
    final phone = debts.person.phone?.replaceAll(RegExp(r'[\s-]'), '');
    if (digits.isNotEmpty && phone != null && phone.contains(digits)) {
      return true;
    }
    return debts.entries.any(
      (entry) => entry.note?.toLowerCase().contains(query) ?? false,
    );
  }

  /// Open debts before settled ones; open ones soonest due first, then
  /// whoever owes the most; settled ones most recent first.
  static int _byUrgency(PersonDebts a, PersonDebts b) {
    if (a.settled != b.settled) return a.settled ? 1 : -1;
    if (a.settled) {
      final aDate = a.entries.firstOrNull?.date,
          bDate = b.entries.firstOrNull?.date;
      if (aDate == null || bDate == null) return 0;
      return bDate.compareTo(aDate);
    }
    final aDue = a.dueDate, bDue = b.dueDate;
    if (aDue != null && bDue == null) return -1;
    if (aDue == null && bDue != null) return 1;
    if (aDue != null && bDue != null && aDue != bDue) {
      return aDue.compareTo(bDue);
    }
    return b.balances.first.amountMinor.abs().compareTo(
      a.balances.first.amountMinor.abs(),
    );
  }
}

/// Whether a debt's due date has passed.
bool _overdue(PersonDebts debts) {
  final due = debts.dueDate;
  if (due == null || debts.settled) return false;
  final now = DateTime.now();
  return due.isBefore(DateTime(now.year, now.month, now.day));
}

class _PeopleList extends StatelessWidget {
  const _PeopleList({
    super.key,
    required this.owedToYou,
    required this.people,
    required this.searching,
    required this.store,
    required this.onTap,
  });
  final bool owedToYou, searching;
  final List<PersonDebts> people;
  final DebtStore store;
  final ValueChanged<PersonDebts> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              owedToYou ? 'People who owe you' : 'People you owe',
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (people.isNotEmpty)
            Text(
              '${people.length}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: SheetColors.of(context).muted,
              ),
            ),
        ],
      ),
    );
    if (people.isEmpty) {
      // The message sits in the middle of the space under the heading.
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 104),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: Center(
                child: Text(
                  searching
                      ? 'No one matches your search.'
                      : owedToYou
                      ? 'Nobody owes you anything right now.'
                      : 'You don’t owe anyone.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 104),
      children: [
        header,
        const SizedBox(height: 10),
        for (final person in people)
          _PersonCard(debts: person, store: store, onTap: () => onTap(person)),
      ],
    );
  }
}

/// One side's total, which is also the tab for that side's list: the arrow
/// says which way the money goes, and the line under the amount how many
/// people are involved and whether any of them are overdue.
class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.label,
    required this.amount,
    required this.icon,
    required this.people,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String label, amount;

  /// Which way the money goes: back into your pocket, or out of it.
  final IconData icon;
  final List<PersonDebts> people;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final radius = BorderRadius.circular(24);
    final open = people.where((debts) => !debts.settled).length;
    final overdue = people.where(_overdue).length;
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: selected
              ? Color.alphaBlend(
                  color.withValues(alpha: .07),
                  theme.colorScheme.surface,
                )
              : theme.colorScheme.surface,
          borderRadius: radius,
          border: Border.all(
            color: selected ? color.withValues(alpha: .5) : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .025),
              blurRadius: 22,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconTile(icon, color: color, size: 28),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      amount,
                      maxLines: 1,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    open == 0
                        ? people.isEmpty
                              ? 'No one'
                              : 'All settled'
                        : overdue > 0
                        ? '$open open · $overdue overdue'
                        : '$open ${open == 1 ? 'person' : 'people'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: overdue > 0 ? colors.expense : colors.muted,
                      fontWeight: overdue > 0
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One person in the list. The same [ReminderCard] Home shows for a debt
/// falling due, so a person reads identically in both places.
class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.debts,
    required this.store,
    required this.onTap,
  });
  final PersonDebts debts;
  final DebtStore store;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = debts.person.name;
    final owesYou = debts.owesYou;
    final latest = debts.entries.firstOrNull?.date;
    return ReminderCard(
      icon: null,
      leading: PersonAvatar(name, size: 40),
      title: name,
      subtitle: latest == null
          ? (owesYou ? 'Owes you' : 'You owe')
          : '${owesYou ? 'Owes you' : 'You owe'} · since '
                '${DateFormat('d MMM').format(latest)}',
      amount: formatDebtAmounts(debts.balances),
      // Everyone is listed here, including people with no agreed date.
      due: debts.settled ? null : debts.dueDate,
      status: debts.settled ? (label: 'Settled', done: true) : null,
      actionLabel: owesYou ? 'Got paid' : 'Pay back',
      onTap: onTap,
      onMarkPaid: store.saving
          ? null
          : () => showDebtPaymentSheet(
              context,
              store: store,
              personId: debts.person.id,
            ),
    );
  }
}
