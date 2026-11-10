import 'package:flutter/material.dart';

import 'glass_surface.dart';

import 'app_back_button.dart';

import '../../domain/app_icons.dart';
import '../../domain/brand_icons.dart';
import 'app_icon.dart';
import 'app_toast.dart';
import 'common.dart';
import 'empty_state.dart';
import 'search_field.dart';
import 'secondary_header.dart';
import 'segmented_pill.dart';

const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 5,
  mainAxisSpacing: 12,
  crossAxisSpacing: 12,
);

const _darkGridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 5,
  mainAxisSpacing: 6,
  crossAxisSpacing: 6,
);

// Only real logo assets are offered in the picker. Legacy text-wordmark
// keys still render for saved data, but are intentionally not selectable.
final _serviceKeys = brandIcons
    .where((brand) => !brand.isBank && !brand.isPayment)
    .map((brand) => brandIconKey(brand.key))
    .toList();

final _paymentKeys = brandIcons
    .where((brand) => brand.isPayment)
    .map((brand) => brandIconKey(brand.key))
    .toList();

const _bankCountryOrder = [
  'India',
  'Indonesia',
  'United States',
  'United Kingdom',
  'Germany',
  'Spain',
  'Switzerland',
  'Brazil',
];

final _bankSections = [
  for (final country in _bankCountryOrder)
    (
      title: 'Banks - $country',
      keys: brandIcons
          .where((brand) => brand.bankCountry == country)
          .map((brand) => brandIconKey(brand.key))
          .toList(),
    ),
];

/// Reusable icon picker — used for an account's icon today, and meant to be
/// reused for a category's icon later. Push with `FeatureRoute<String>` and
/// read the popped value: one of `appIconKeys`, a `brandIconKey(...)`, a
/// `wordmarkBrandKey(...)`, or null if the user backs out without picking.
///
/// The three sets are split across tabs rather than stacked in one long
/// scroll: banks alone run to eight country sections, which buried the
/// illustrated set under a scroll nobody finished.
///
/// Named as a screen (not just a dialog/sheet) so it composes the same way
/// `CurrencyScreen` does: push, await a result, done.
class SelectIconScreen extends StatefulWidget {
  const SelectIconScreen({super.key, this.selectedKey});
  final String? selectedKey;

  @override
  State<SelectIconScreen> createState() => _SelectIconScreenState();
}

class _SelectIconScreenState extends State<SelectIconScreen>
    with SingleTickerProviderStateMixin {
  // Opens on whichever tab already holds the current icon, so reopening the
  // picker lands where the user last chose from.
  late final _tabs = TabController(
    length: 3,
    initialIndex: _tabFor(widget.selectedKey),
    vsync: this,
  );

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

  static int _tabFor(String? key) {
    final brand = resolveBrandIcon(key);
    if (brand == null) return 0;
    return brand.isBank ? 2 : 1;
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness != Brightness.dark) return _buildPage(context);
    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: const Color(0xff101315),
        colorScheme: theme.colorScheme.copyWith(
          primary: const Color(0xff0095ff),
          onSurface: const Color(0xfff5f5f5),
          onSurfaceVariant: const Color(0xffc5cfd8),
        ),
        tabBarTheme: const TabBarThemeData(
          labelColor: Color(0xff0095ff),
          unselectedLabelColor: Color(0xffadb4bf),
          dividerColor: Color(0xff303437),
          indicatorColor: Color(0xff0095ff),
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          unselectedLabelStyle: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) => PopScope(
    canPop: !_searching,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _cancelSearch();
    },
    child: GlassPage(
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              SearchableHeader(
                searching: _searching,
                controller: _search,
                focusNode: _searchFocus,
                fieldKey: const Key('icon-search'),
                hintText: 'Search icons',
                onChanged: (_) => setState(() {}),
                onCancel: _cancelSearch,
                header: Column(
                  children: [
                    SecondaryHeader(
                      title: 'Choose an icon',
                      leading: Navigator.of(context).canPop()
                          ? const AppBackButton()
                          : null,
                      actions: [
                        AppSearchButton(
                          tooltip: 'Search icons',
                          onPressed: _openSearch,
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: SegmentedPillTabBar(
                        controller: _tabs,
                        labels: const ['3D', 'Services', 'Banks'],
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
                    child: TabBarView(
                      controller: _tabs,
                      children: [
                        _IconTab(
                          storageKey: '3d',
                          sections: [(title: null, keys: appIconKeys)],
                          selectedKey: widget.selectedKey,
                          query: _search.text.trim().toLowerCase(),
                        ),
                        _IconTab(
                          storageKey: 'brands',
                          sections: [
                            (
                              title: 'Services & subscriptions',
                              keys: _serviceKeys,
                            ),
                            (
                              title: 'Payments, cards & shopping',
                              keys: _paymentKeys,
                            ),
                          ],
                          selectedKey: widget.selectedKey,
                          query: _search.text.trim().toLowerCase(),
                        ),
                        _IconTab(
                          storageKey: 'banks',
                          sections: _bankSections
                              .map(
                                (s) =>
                                    (title: s.title as String?, keys: s.keys),
                              )
                              .toList(),
                          selectedKey: widget.selectedKey,
                          query: _search.text.trim().toLowerCase(),
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
    ),
  );
}

/// One tab's scroll view. A section with a null title renders as a bare grid,
/// which is what the illustrated set wants now that it has a tab of its own.
class _IconTab extends StatelessWidget {
  const _IconTab({
    required this.storageKey,
    required this.query,
    required this.sections,
    required this.selectedKey,
  });

  final String storageKey;
  final String query;
  final List<({String? title, List<String> keys})> sections;
  final String? selectedKey;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final filteredSections = sections
        .map((section) {
          final keys = section.keys.where((key) {
            final brand = resolveBrandIcon(key);
            final searchable = [
              key.replaceAll('_', ' '),
              if (brand != null) brand.title,
              if (brand?.bankCountry != null) brand!.bankCountry!,
            ].join(' ').toLowerCase();
            return query.split(RegExp(r'\s+')).every(searchable.contains);
          }).toList();
          return (title: section.title, keys: keys);
        })
        .where((section) => section.keys.isNotEmpty)
        .toList();
    if (filteredSections.isEmpty) {
      return const Align(
        alignment: Alignment.topCenter,
        child: NoResultsState('No icons found'),
      );
    }
    return CustomScrollView(
      // Keeps each tab's scroll offset across switches.
      key: PageStorageKey<String>('icon-tab-$storageKey'),
      slivers: [
        for (final (index, section) in filteredSections.indexed) ...[
          if (section.title case final title?)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(18, index == 0 ? 12 : 28, 18, 12),
              sliver: SliverToBoxAdapter(
                child: SectionTitle(
                  title,
                  key: ValueKey('icon-section-$title'),
                ),
              ),
            )
          else
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverGrid(
              gridDelegate: dark ? _darkGridDelegate : _gridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final key = section.keys[i];
                  final label =
                      resolveBrandIcon(key)?.title ?? key.replaceAll('_', ' ');
                  return Semantics(
                    label: label,
                    child: _IconChoice(
                      selected: key == selectedKey,
                      onTap: () => Navigator.pop(context, key),
                      onLongPress: () => showAppToast(context, label),
                      child: dark
                          ? _DarkPickerIcon(iconKey: key)
                          : AppIcon(key),
                    ),
                  );
                },
                childCount: section.keys.length,
                addAutomaticKeepAlives: false,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// Picker artwork sits directly on the dark card.
class _DarkPickerIcon extends StatelessWidget {
  const _DarkPickerIcon({required this.iconKey});

  final String iconKey;

  @override
  Widget build(BuildContext context) {
    final brand = resolveBrandIcon(iconKey);
    if (brand == null) return AppIcon(iconKey);
    final logo = Image.asset(
      brandIconAssetPath(brand.key, Brightness.dark),
      fit: BoxFit.contain,
    );
    return Padding(padding: const EdgeInsets.all(5), child: logo);
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.child,
  });
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(16);
    // A soft glass tile in the theme's own colours, tinted by its primary
    // when chosen, rather than a flat grey that ignores the theme.
    final fill = selected
        ? scheme.primary.withValues(alpha: dark ? .2 : .12)
        : scheme.onSurface.withValues(alpha: dark ? .07 : .04);
    return Material(
      color: fill,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: dark ? .1 : .06),
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}
