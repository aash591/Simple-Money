import 'package:flutter/material.dart';

import '../../../domain/currency.dart';
import '../../components/currency_flag.dart';
import '../../components/feature_page.dart';
import '../../components/search_field.dart';

class CurrencyScreen extends StatefulWidget {
  const CurrencyScreen({
    super.key,
    required this.selectedCode,
    this.selectedTerritory,
  });
  final String selectedCode;

  /// The exact country the current selection was made for, if known.
  /// When set, only that country's row is highlighted, rather than every
  /// country that happens to share the same currency code (e.g. Bhutan and
  /// India both use INR).
  final String? selectedTerritory;
  @override
  State<CurrencyScreen> createState() => _CurrencyScreenState();
}

class _CurrencyScreenState extends State<CurrencyScreen> {
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  late Future<List<Currency>> _currencies = Currency.load();
  bool _scrolledToSelection = false;
  bool _revealed = false;

  // Used only to measure a fixed row height (see `prototypeItem` below),
  // never shown or tapped.
  static const _prototypeCurrency = Currency(
    country: 'Prototype country',
    territory: 'XX',
    code: 'XXX',
    name: 'Prototype currency name',
    digits: 2,
  );

  @override
  void dispose() {
    _search.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _isSelected(Currency currency) => widget.selectedTerritory != null
      ? currency.territory == widget.selectedTerritory
      : currency.code == widget.selectedCode;

  /// Brings the currently selected currency into view on first open, since
  /// the full list is long enough that the selection is often off-screen.
  ///
  /// The list is kept offstage (laid out, but not painted — see `build`)
  /// until this finishes, so the first frame the user actually sees is
  /// already positioned. Without that, the list would flash at the top for
  /// one frame and then visibly snap to the selection, since `jumpTo` isn't
  /// animated and only runs after that first frame has already painted.
  void _scrollToSelection(List<Currency> results) {
    if (_scrolledToSelection) return;
    _scrolledToSelection = true;
    final index = results.indexWhere(_isSelected);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (index != -1 && results.length > 1 && _scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        if (maxExtent > 0) {
          _scrollController.jumpTo(maxExtent * index / (results.length - 1));
        }
      }
      if (mounted) setState(() => _revealed = true);
    });
  }

  @override
  Widget build(BuildContext context) => FeaturePage(
    title: 'Currency',
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
          child: SearchField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            hintText: 'Search currency',
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Currency>>(
            future: _currencies,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not load currencies.'),
                      TextButton(
                        onPressed: () =>
                            setState(() => _currencies = Currency.load()),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final query = _search.text.trim().toLowerCase();
              final results = snapshot.data!
                  .where(
                    (c) => '${c.country} ${c.code} ${c.name}'
                        .toLowerCase()
                        .contains(query),
                  )
                  .toList();
              if (results.isEmpty) {
                return Padding(
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
                        'No currencies found',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Try a country, currency name, or code.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              }
              if (query.isEmpty) _scrollToSelection(results);
              final list = ListView.builder(
                key: ValueKey(query),
                controller: query.isEmpty ? _scrollController : null,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                // A fixed row height lets the list (and the jump in
                // _scrollToSelection) compute scroll offsets from arithmetic
                // instead of having to build every row in between.
                prototypeItem: _row(context, _prototypeCurrency, false),
                itemCount: results.length,
                itemBuilder: (context, index) =>
                    _row(context, results[index], _isSelected(results[index])),
              );
              // Only the unfiltered (query-empty) list needs positioning
              // before it's shown; search results always start at the top.
              final pending = query.isEmpty && !_revealed;
              return Stack(
                children: [
                  Offstage(offstage: pending, child: list),
                  if (pending) const Center(child: CircularProgressIndicator()),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );

  // A divider always renders (even after the last row) so every row has the
  // same height, which `prototypeItem` above relies on to size the list.
  Widget _row(
    BuildContext context,
    Currency currency,
    bool selected,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 7,
          ),
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.primary
              .withValues(alpha: .04),
          leading: CurrencyFlag(currency.territory),
          title: Text(
            currency.country,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              currency.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(height: 1.4),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                currency.code,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 20,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant
                          .withValues(alpha: .3),
              ),
            ],
          ),
          onTap: () => Navigator.pop(context, currency),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Divider(height: 1),
        ),
      ],
    ),
  );
}
