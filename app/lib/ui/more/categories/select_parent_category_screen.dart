import 'package:flutter/material.dart';

import '../../../domain/category.dart';
import '../../components/settings_icon.dart';
import '../../components/feature_page.dart';
import '../../components/search_field.dart';

/// Distinguishes "picked no parent" from "backed out without picking" in the
/// popped result — both would otherwise be indistinguishable nulls.
const noParentSentinel = Object();

/// Full-page searchable picker for a category's optional parent, matching
/// the same "search field + checkmarked list" shape as `CurrencyScreen`.
/// Push with `FeatureRoute<Object?>` and read the popped value: `null` if
/// the user backed out, [noParentSentinel] for "no parent", or an `int`
/// category id otherwise.
class SelectParentCategoryScreen extends StatefulWidget {
  const SelectParentCategoryScreen({
    super.key,
    required this.choices,
    required this.selectedId,
  });

  /// Eligible parents: top-level categories of the same type, excluding the
  /// category being edited (see `EditCategoryScreen._parentChoices`).
  final List<Category> choices;
  final int? selectedId;
  @override
  State<SelectParentCategoryScreen> createState() =>
      _SelectParentCategoryScreenState();
}

class _SelectParentCategoryScreenState
    extends State<SelectParentCategoryScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final results = widget.choices
        .where((c) => c.name.toLowerCase().contains(query))
        .toList();
    return FeaturePage(
      title: 'Parent category',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
            child: SearchField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              hintText: "Type a category's name",
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                _Row(
                  icon: Icon(
                    Icons.horizontal_rule_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  title: 'None (top-level category)',
                  selected: widget.selectedId == null,
                  onTap: () => Navigator.pop(context, noParentSentinel),
                ),
                if (results.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.search_off_rounded,
                          size: 42,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No categories found',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  )
                else
                  for (final c in results)
                    _Row(
                      icon: SettingsIcon(c.icon, size: 32),
                      title: c.name,
                      selected: c.id == widget.selectedId,
                      onTap: () => Navigator.pop(context, c.id),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });
  final Widget icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 4,
          ),
          leading: SizedBox(width: 34, height: 34, child: icon),
          title: Text(title),
          trailing: Icon(
            selected ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 20,
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant
                      .withValues(alpha: .3),
          ),
          onTap: onTap,
        ),
        const Padding(
          padding: EdgeInsets.only(left: 68, right: 18),
          child: Divider(height: 1),
        ),
      ],
    ),
  );
}
