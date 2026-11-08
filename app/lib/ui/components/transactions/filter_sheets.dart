/// The sheets behind a transaction list's options menu: time range, type,
/// category and account. Shared so every list filters the same way.
library;

import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/bank_institution_icon.dart';
import '../../../domain/category.dart';
import '../adaptive_sheet.dart';
import '../app_icon.dart';
import '../choice_list_sheet.dart';
import '../date_range_picker_sheet.dart';
import '../secondary_header.dart';
import '../segmented_pill.dart';
import 'period.dart';

/// Asks for a [PeriodKind] (and, for a custom one, its dates) and applies it
/// to [period]. True when something was picked.
Future<bool> pickPeriod(BuildContext context, PeriodController period) async {
  FocusManager.instance.primaryFocus?.unfocus();
  final selected = await showAdaptiveSheet<PeriodKind>(
    context,
    floating: true,
    builder: (context) => SelectionSheet<PeriodKind>(
      title: 'Select time range',
      selected: period.kind,
      items: [
        for (final kind in PeriodKind.values) (kind, kind.label, kind.icon),
      ],
    ),
  );
  if (selected == null || !context.mounted) return false;
  if (selected == PeriodKind.custom) {
    final picked = await showDateRangePickerSheet(
      context,
      initialRange: period.customRange,
    );
    if (picked == null || !context.mounted) return false;
    period.select(selected, customRange: picked);
    return true;
  }
  period.select(selected);
  return true;
}

enum TransactionTypeFilter {
  all('All transactions', Icons.receipt_long_outlined),
  expense('Expenses only', Icons.arrow_upward_rounded),
  income('Income only', Icons.arrow_downward_rounded),
  transfer('Transfers only', Icons.swap_horiz_rounded);

  const TransactionTypeFilter(this.label, this.icon);
  final String label;
  final IconData icon;
}

Future<TransactionTypeFilter?> pickTypeFilter(
  BuildContext context, {
  required TransactionTypeFilter selected,
  String title = 'Filter by type',
}) => showAdaptiveSheet<TransactionTypeFilter>(
  context,
  floating: true,
  builder: (context) => SelectionSheet<TransactionTypeFilter>(
    title: title,
    selected: selected,
    items: [
      for (final filter in TransactionTypeFilter.values)
        (filter, filter.label, filter.icon),
    ],
  ),
);

/// Expense and income tabs of [categories], parents with their children
/// indented, plus All categories. Returns a record so "All" (null) can be
/// told apart from a dismissed sheet (null record).
Future<(int?,)?> pickCategoryFilter(
  BuildContext context, {
  required List<Category> categories,
  required int? selected,
  String title = 'Filter by category',
  bool startOnIncome = false,
}) {
  final ordered = [
    for (final type in CategoryType.values)
      for (final parent in categories.where(
        (c) => c.type == type && c.parentId == null,
      )) ...[parent, ...categories.where((c) => c.parentId == parent.id)],
  ];
  final current = categories.where((c) => c.id == selected).firstOrNull;
  return showAdaptiveSheet<(int?,)>(
    context,
    floating: true,
    maxHeightFactor: .9,
    builder: (context) => DefaultTabController(
      length: 2,
      initialIndex:
          current?.type == CategoryType.income ||
              (current == null && startOnIncome)
          ? 1
          : 0,
      child: Column(
        children: [
          SheetHeader(title, onBack: () => Navigator.pop(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedPillTabBar(
              labels: [
                for (final type in [CategoryType.expense, CategoryType.income])
                  type.label,
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final type in [CategoryType.expense, CategoryType.income])
                  ChoicePickerPage<(int?,)>(
                    key: ValueKey(type),
                    header: const SizedBox.shrink(),
                    fillHeight: true,
                    selected: (selected,),
                    onSelected: (value) => Navigator.pop(context, value),
                    searchHint: 'Search categories',
                    items: [
                      ChoiceItem<(int?,)>(
                        value: (null,),
                        label: 'All categories',
                        icon: Icon(
                          Icons.category_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 28,
                        ),
                      ),
                      for (final category in ordered.where(
                        (c) => c.type == type,
                      ))
                        ChoiceItem<(int?,)>(
                          value: (category.id,),
                          label: category.name,
                          icon: AppIcon(category.icon, size: 28),
                          indent: category.parentId != null,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// What the account sheet returned: an account (null for All accounts), or
/// an unassigned SMS bank to sort out.
class AccountSelection {
  const AccountSelection(this.id, {this.unassigned});
  final int? id;
  final String? unassigned;
}

Future<AccountSelection?> pickAccountFilter(
  BuildContext context, {
  required List<Account> accounts,
  required int? selected,
  Map<String, int> unassigned = const {},
}) => showAdaptiveSheet<AccountSelection>(
  context,
  floating: true,
  builder: (context) => AccountSheet(
    accounts: accounts,
    selectedId: selected,
    unassigned: unassigned,
  ),
);

/// A short list of choices, the selected one ticked; pops the picked value.
class SelectionSheet<T> extends StatelessWidget {
  const SelectionSheet({
    super.key,
    required this.title,
    required this.selected,
    required this.items,
    this.leadingBuilder,
  });
  final String title;
  final T selected;
  final List<(T, String, IconData)> items;
  final Widget Function(T)? leadingBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterSheetHeader(title),
          const SizedBox(height: 14),
          Flexible(
            child: SheetCard(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var index = 0; index < items.length; index++) ...[
                      ListTile(
                        minLeadingWidth: 28,
                        leading:
                            leadingBuilder?.call(items[index].$1) ??
                            Icon(
                              items[index].$3,
                              color: items[index].$1 == selected
                                  ? Theme.of(context).colorScheme.primary
                                  : scheme.onSurface,
                            ),
                        title: Text(items[index].$2),
                        trailing: Icon(
                          items[index].$1 == selected
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          color: items[index].$1 == selected
                              ? Theme.of(context).colorScheme.primary
                              : scheme.onSurface.withValues(alpha: .13),
                        ),
                        selected: items[index].$1 == selected,
                        selectedTileColor: Theme.of(context).colorScheme.primary
                            .withValues(alpha: .07),
                        onTap: () => Navigator.pop(context, items[index].$1),
                      ),
                      if (index < items.length - 1)
                        const Padding(
                          padding: EdgeInsets.only(left: 56),
                          child: Divider(height: 1),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AccountSheet extends StatelessWidget {
  const AccountSheet({
    super.key,
    required this.accounts,
    required this.selectedId,
    this.unassigned = const {},
  });
  final Map<String, int> unassigned;
  final List<Account> accounts;
  final int? selectedId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FilterSheetHeader('Select account'),
          const SizedBox(height: 14),
          Flexible(
            child: SheetCard(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _AccountOption(
                      title: 'All accounts',
                      subtitle: accounts.length == 1
                          ? '1 account'
                          : '${accounts.length} accounts',
                      icon: const AllAccountsIcon(size: 34),
                      selected: selectedId == null,
                      onTap: () =>
                          Navigator.pop(context, const AccountSelection(null)),
                    ),
                    for (final account in accounts) ...[
                      const Padding(
                        padding: EdgeInsets.only(left: 62),
                        child: Divider(height: 1),
                      ),
                      _AccountOption(
                        title: account.name,
                        subtitle:
                            '${account.currency}  ${account.formattedBalance}',
                        icon: AppIcon(account.icon, size: 34),
                        selected: selectedId == account.id,
                        onTap: () => Navigator.pop(
                          context,
                          AccountSelection(account.id),
                        ),
                      ),
                    ],
                    if (unassigned.isNotEmpty) ...[
                      const Divider(height: 24, thickness: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Unassigned',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                      for (final entry in unassigned.entries)
                        ListTile(
                          leading: SizedBox.square(
                            dimension: 38,
                            child: Center(
                              child: AppIcon(
                                bankInstitutionIcon(
                                  entry.key.split(' · ').first,
                                  creditCard: entry.key.endsWith(' · Card'),
                                ),
                                size: 34,
                              ),
                            ),
                          ),
                          title: Text(
                            entry.key.split(' · ').first,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${entry.value} messages · ${entry.key.split(' · ').skip(1).join(' · ')}',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(
                            context,
                            AccountSelection(null, unassigned: entry.key),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Create an account to start tracking money.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _AccountOption extends StatelessWidget {
  const _AccountOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final Widget icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: SizedBox.square(dimension: 38, child: Center(child: icon)),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(subtitle),
    trailing: Icon(
      selected ? Icons.check_circle_rounded : Icons.circle_outlined,
      color: selected
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.onSurface.withValues(alpha: .13),
    ),
    selected: selected,
    selectedTileColor: Theme.of(context).colorScheme.primary
        .withValues(alpha: .07),
    onTap: onTap,
  );
}

class FilterSheetHeader extends StatelessWidget {
  const FilterSheetHeader(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => SecondaryHeader(
    title: title,
    actions: [
      IconButton(
        tooltip: 'Close',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded),
      ),
    ],
  );
}
