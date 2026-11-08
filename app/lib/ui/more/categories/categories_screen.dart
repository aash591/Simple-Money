import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';

import '../../../domain/category.dart';
import '../../../state/category_store.dart';
import '../../components/settings_icon.dart';
import '../../components/common.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/search_field.dart';
import '../../components/secondary_header.dart';
import '../../components/segmented_pill.dart';
import '../../components/skeleton.dart';
import 'edit_category_screen.dart';

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key, required this.store});
  final CategoryStore store;
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

/// Debt/Loan categories are created and used by Debts and Loans themselves,
/// and kept out of income and spending totals, so there is nothing to manage
/// here.
const _tabTypes = [CategoryType.expense, CategoryType.income];

class _CategoriesScreenState extends State<CategoriesScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: _tabTypes.length, vsync: this)
    ..addListener(() => setState(() {}));
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;

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

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(BuildContext context, CategoryType type, [Category? category]) =>
      Navigator.of(context).push(
        FeatureRoute<void>(
          EditCategoryScreen(
            store: widget.store,
            type: type,
            category: category,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final type = _tabTypes[_tabs.index];
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _cancelSearch();
      },
      child: Scaffold(
        floatingActionButton: _searching
            ? null
            : AddFab(
                onPressed: () => _open(context, type),
                tooltip: 'Add category',
              ),
        body: SafeArea(
          child: Column(
            children: [
              SearchableHeader(
                searching: _searching,
                controller: _search,
                focusNode: _searchFocus,
                fieldKey: const Key('category-search'),
                hintText: 'Search categories',
                onChanged: (_) => setState(() {}),
                onCancel: _cancelSearch,
                header: Column(
                  children: [
                    SecondaryHeader(
                      title: 'Categories',
                      leading: Navigator.of(context).canPop()
                          ? const AppBackButton()
                          : null,
                      actions: [
                        AppSearchButton(
                          tooltip: 'Search categories',
                          onPressed: _openSearch,
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: SegmentedPillTabBar(
                        controller: _tabs,
                        labels: [for (final t in _tabTypes) t.label],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Column(
                      children: [
                        Expanded(
                          child: TabBarView(
                            controller: _tabs,
                            children: _tabTypes
                                .map(
                                  (t) => _CategoryList(
                                    store: widget.store,
                                    type: t,
                                    query: _search.text.trim().toLowerCase(),
                                    onTap: (category) =>
                                        _open(context, t, category),
                                    onAdd: () => _open(context, t),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.store,
    required this.type,
    required this.query,
    required this.onTap,
    required this.onAdd,
  });
  final CategoryStore store;
  final CategoryType type;
  final String query;
  final ValueChanged<Category> onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      if (store.loading) {
        return const SkeletonList(cards: 1, rows: 7);
      }
      if (store.loadError != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(store.loadError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: store.load,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        );
      }
      final all = store.categories.where((c) => c.type == type).toList();
      if (query.isNotEmpty) {
        final results = all
            .where((c) => c.name.toLowerCase().contains(query))
            .toList();
        if (results.isEmpty) {
          return const Align(
            alignment: Alignment.topCenter,
            child: NoResultsState('No categories found'),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
          itemCount: results.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MoneyCard(
              padding: EdgeInsets.zero,
              child: _CategoryRow(
                category: results[index],
                onTap: () => onTap(results[index]),
              ),
            ),
          ),
        );
      }
      final topLevel = all.where((c) => c.parentId == null).toList();
      if (topLevel.isEmpty) {
        return EmptyState(
          icon: Icons.grid_view_rounded,
          title: 'Give every transaction a place',
          message:
              'Group your ${type.label.toLowerCase()} into categories to see where your money goes.',
          actionLabel: 'Add a category',
          onAction: onAdd,
        );
      }
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
        itemCount: topLevel.length,
        itemBuilder: (context, index) {
          final parent = topLevel[index];
          final children = all.where((c) => c.parentId == parent.id).toList();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MoneyCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _CategoryRow(category: parent, onTap: () => onTap(parent)),
                  for (final child in children) ...[
                    const Padding(
                      padding: EdgeInsets.only(left: 68, right: 18),
                      child: Divider(height: 1),
                    ),
                    _CategoryRow(
                      category: child,
                      indent: true,
                      onTap: () => onTap(child),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.onTap,
    this.indent = false,
  });
  final Category category;
  final VoidCallback onTap;
  final bool indent;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(indent ? 50 : 18, 14, 18, 14),
        child: Row(
          children: [
            SettingsIcon(category.icon, size: indent ? 30 : 36),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                category.name,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontSize: indent ? 14 : 15),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    ),
  );
}
