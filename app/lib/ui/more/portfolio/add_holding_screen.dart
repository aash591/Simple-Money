import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/prices/price_sources.dart';
import '../../../domain/account.dart';
import '../../../domain/holding.dart';
import '../../../domain/markets.dart';
import '../../../state/holding_store.dart';
import '../../components/action_buttons.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../components/search_field.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transaction_widgets.dart' show StepSlider;
import 'select_place_screen.dart';

/// What the add-holding flow hands back: the new holding, and whether the
/// person wants to record what they already own of it straight away.
typedef AddedHolding = ({int id, bool addPurchase});

enum _Step { type, find, details }

/// One thing a person can add. To offer another type, add a line here and a
/// [HoldingKind] for it.
typedef _KindChoice = ({
  HoldingKind kind,
  IconData icon,
  String title,
  String subtitle,
});

const List<_KindChoice> _kinds = [
  (
    kind: HoldingKind.stock,
    icon: Icons.show_chart_rounded,
    title: 'Stocks',
    subtitle: 'Shares of listed companies',
  ),
  (
    kind: HoldingKind.etf,
    icon: Icons.stacked_bar_chart_rounded,
    title: 'ETFs',
    subtitle: 'Exchange-traded funds',
  ),
  (
    kind: HoldingKind.fund,
    icon: Icons.pie_chart_outline_rounded,
    title: 'Mutual funds',
    subtitle: 'Priced by their daily NAV',
  ),
];

/// Adding a holding to an investment account as a full-screen flow: what
/// kind it is, finding it by name, checking its details and price, then
/// saving. Pops with an [AddedHolding].
class AddHoldingScreen extends StatefulWidget {
  const AddHoldingScreen({
    super.key,
    required this.store,
    required this.broker,
  });
  final HoldingStore store;
  final Account broker;

  @override
  State<AddHoldingScreen> createState() => _AddHoldingScreenState();
}

class _AddHoldingScreenState extends State<AddHoldingScreen> {
  _Step _step = _Step.type;
  bool _forward = true;
  HoldingKind _kind = HoldingKind.stock;

  // Find it
  final _search = TextEditingController();
  late Market? _market = defaultMarketFor(widget.broker.currency);
  List<SymbolHit> _hits = const [];
  bool _searching = false, _searched = false;
  Timer? _searchDebounce;
  int _searchRound = 0;
  SymbolHit? _picked;

  // Details
  final _name = TextEditingController();
  final _symbol = TextEditingController();
  final _exchange = TextEditingController();
  PriceQuote? _quote;
  bool _quoteLoading = false;
  Timer? _quoteDebounce;
  int _quoteRound = 0;

  bool _saving = false;
  String? _error;

  bool get _fund => _kind == HoldingKind.fund;
  bool get _canSearch => widget.store.prices != null;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _quoteDebounce?.cancel();
    _search.dispose();
    _name.dispose();
    _symbol.dispose();
    _exchange.dispose();
    super.dispose();
  }

  void _go(_Step step) => setState(() {
    _forward = step.index > _step.index;
    _step = step;
    _error = null;
  });

  void _back() {
    if (_saving) return;
    switch (_step) {
      case _Step.type:
        Navigator.of(context).pop();
      case _Step.find:
        _go(_Step.type);
      case _Step.details:
        _go(_Step.find);
    }
  }

  // ---- Type -----------------------------------------------------------------

  void _chooseKind(HoldingKind kind) {
    setState(() {
      _kind = kind;
      _hits = const [];
      _searched = false;
      _picked = null;
      _search.clear();
    });
    _go(_Step.find);
  }

  // ---- Find it --------------------------------------------------------------

  void _onSearch(String text) {
    _searchDebounce?.cancel();
    if (text.trim().length < 2) {
      setState(() {
        _hits = const [];
        _searched = false;
        _searching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 450), () async {
      final service = widget.store.prices;
      if (service == null) return;
      final round = ++_searchRound;
      setState(() => _searching = true);
      final hits = await service.search(text, currency: widget.broker.currency);
      if (!mounted || round != _searchRound) return;
      setState(() {
        _hits = hits;
        _searching = false;
        _searched = true;
      });
    });
  }

  /// What the search found, narrowed to the chosen type and market.
  List<SymbolHit> get _visibleHits => [
    for (final hit in _hits)
      if ((hit.kind == _kind ||
              (_kind == HoldingKind.etf &&
                  hit.kind == HoldingKind.stock &&
                  looksLikeEtf(hit.name))) &&
          (_fund || _market == null || marketOfSymbol(hit.symbol) == _market))
        hit,
  ];

  void _pick(SymbolHit hit) {
    _picked = hit;
    _name.text = hit.name.length > 60 ? hit.name.substring(0, 60) : hit.name;
    _symbol.text = hit.symbol;
    _exchange.text = hit.kind == HoldingKind.fund && hit.exchange == 'AMFI'
        ? ''
        : hit.exchange ?? '';
    _enterDetails();
  }

  void _addManually() {
    _picked = null;
    _name.clear();
    _symbol.clear();
    _exchange.clear();
    _enterDetails();
  }

  void _enterDetails() {
    _quote = null;
    _go(_Step.details);
    _loadQuote();
  }

  // ---- Details --------------------------------------------------------------

  /// What a saved holding would be priced from: the search result's source
  /// while the typed ticker still matches it, otherwise worked out from the
  /// kind.
  String? get _source {
    final hit = _picked;
    final matches =
        hit != null && hit.kind == _kind && hit.symbol == _symbol.text.trim();
    return matches ? hit.priceSource : null;
  }

  void _onTickerChanged(String _) {
    _quoteDebounce?.cancel();
    setState(() {
      _quote = null;
      _quoteLoading = _symbol.text.trim().isNotEmpty;
    });
    _quoteDebounce = Timer(const Duration(milliseconds: 700), _loadQuote);
  }

  Future<void> _loadQuote() async {
    final service = widget.store.prices;
    final symbol = _symbol.text.trim();
    if (service == null || symbol.isEmpty) {
      if (mounted) setState(() => _quoteLoading = false);
      return;
    }
    final round = ++_quoteRound;
    setState(() => _quoteLoading = true);
    final quote = await service.quoteFor(
      kind: _kind,
      symbol: symbol,
      exchange: _fund ? null : _exchange.text.trim(),
      priceSource: _source,
    );
    if (!mounted || round != _quoteRound) return;
    setState(() {
      _quote = quote;
      _quoteLoading = false;
    });
  }

  bool get _detailsValid => _name.text.trim().isNotEmpty;

  /// The holding already in this account with the ticker typed, if any.
  Holding? get _existing {
    final symbol = _symbol.text.trim().toLowerCase();
    if (symbol.isEmpty) return null;
    return widget.store
        .holdingsOf(widget.broker.id)
        .where((h) => h.symbol?.toLowerCase() == symbol)
        .firstOrNull;
  }

  // ---- Save -----------------------------------------------------------------

  Future<void> _save({required bool addPurchase}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // A price quoted in another currency is kept in that currency, and
      // converted for totals; null means the account's own.
      final quote = _quote;
      final quoteCurrency = quote?.currency;
      final other =
          quoteCurrency != null && quoteCurrency != widget.broker.currency;
      final id = await widget.store.saveHolding(
        accountId: widget.broker.id,
        kind: _kind,
        name: _name.text,
        symbol: _symbol.text,
        exchange: _fund ? '' : _exchange.text,
        priceSource: _source,
        currency: other ? quoteCurrency : null,
      );
      // The price the person just saw, so the holding is worth something
      // right away rather than after the next refresh.
      final holding = widget.store.byId(id);
      if (quote != null && holding != null) {
        await widget.store.setPrice(holding, quote.priceE4, quote.date);
      }
      if (!mounted) return;
      Navigator.of(context)
          .pop<AddedHolding>((id: id, addPurchase: addPurchase));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is ArgumentError
            ? '${e.message}'
            : 'Could not save. Please try again.';
      });
    }
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: FeaturePage(
      title: 'Add holding',
      // Pages slide in from the right going on, and from the left going back.
      child: StepSlider(
        stepKey: _step,
        forward: _forward,
        child: _page(context),
      ),
    ),
  );

  Widget _page(BuildContext context) => switch (_step) {
    _Step.type => _typePage(context),
    _Step.find => _findPage(context),
    _Step.details => _detailsPage(context),
  };

  // ---- Type page ------------------------------------------------------------

  Widget _typePage(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const Expanded(
          child: StepIntro(
            title: 'What are you adding?',
            message: 'Choose a type, then find it by name.',
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 32),
            children: [
              MoneyCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final (index, choice) in _kinds.indexed) ...[
                      if (index > 0)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 18),
                          child: Divider(height: 1),
                        ),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: Key('holding-type-${choice.kind.name}'),
                          onTap: () => _chooseKind(choice.kind),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                            child: Row(
                              children: [
                                IconTile(choice.icon, size: 40),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        choice.title,
                                        style: text.titleMedium,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        choice.subtitle,
                                        style: text.bodySmall?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Find page ------------------------------------------------------------

  /// Names to try before anything is typed, tappable.
  List<String> get _examples {
    if (_fund) {
      return widget.broker.currency == 'INR'
          ? ['Parag Parikh', 'Nifty 50 index', 'HDFC', 'SBI']
          : ['Vanguard', 'Fidelity', 'T. Rowe Price'];
    }
    final market = _market;
    if (market == null) return const ['Apple', 'Reliance', 'Toyota', 'Nestle'];
    // Funds are only suggested where some are known to turn up in a search.
    return _kind == HoldingKind.etf ? market.etfs : market.stocks;
  }

  Widget _findPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hits = _visibleHits;
    final typed = _search.text.trim().length >= 2;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 32),
      children: [
        if (_canSearch) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SearchField(
              key: const Key('holding-search'),
              controller: _search,
              autofocus: true,
              onChanged: _onSearch,
              hintText: _fund
                  ? 'Search funds by name'
                  : 'Search by name or ticker',
            ),
          ),
          if (!_fund) _marketChips(context),
          const SizedBox(height: 8),
          if (!typed)
            _prompt(context)
          else if (hits.isEmpty && _searching)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Searching…',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (hits.isEmpty && _searched && !_searching)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                _hits.isNotEmpty && !_fund && _market != null
                    ? 'Nothing in ${_market!.label}. Try All.'
                    : 'Nothing found.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            MoneyCard(
              padding: EdgeInsets.zero,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    for (final (i, hit) in hits.take(12).indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      _hitTile(context, hit),
                    ],
                  ],
                ),
              ),
            ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Search isn’t available right now.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            key: const Key('holding-manual'),
            onPressed: _addManually,
            child: const Text('Can’t find it? Add it manually'),
          ),
        ),
      ],
    );
  }

  /// Markets to narrow a search to, the account's own first.
  Widget _marketChips(BuildContext context) {
    final mine = defaultMarketFor(widget.broker.currency);
    final ordered = [
      if (mine != null) mine,
      for (final m in markets)
        if (m != mine) m,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _Pill(
              label: 'All',
              selected: _market == null,
              onTap: () => setState(() => _market = null),
            ),
            for (final market in ordered) ...[
              const SizedBox(width: 8),
              _Pill(
                key: Key('market-${market.id}'),
                label: market.label,
                selected: _market == market,
                onTap: () => setState(() => _market = market),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _prompt(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 28, 4, 8),
      child: Column(
        children: [
          Text(
            _fund ? 'Type a fund name' : 'Type a company name or a ticker',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final example in _examples)
                _Pill(
                  label: example,
                  selected: false,
                  onTap: () {
                    _search.text = example;
                    _onSearch(example);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hitTile(BuildContext context, SymbolHit hit) {
    final theme = Theme.of(context);
    final market = marketOfSymbol(hit.symbol);
    // A different currency won't price this account's holdings.
    final differs =
        !_fund && market != null && market.currency != widget.broker.currency;
    return ListTile(
      key: Key('hit-${hit.symbol}'),
      title: Text(hit.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [hit.symbol, if (hit.exchange != null) hit.exchange!].join(' · '),
      ),
      trailing: differs
          ? Text(
              market.currency,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          : null,
      onTap: () => _pick(hit),
    );
  }

  // ---- Details page ---------------------------------------------------------

  Widget _detailsPage(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            children: [
              MoneyCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _FormRow(
                      icon: _kinds.firstWhere((c) => c.kind == _kind).icon,
                      label: 'Type',
                      value: _kinds.firstWhere((c) => c.kind == _kind).title,
                    ),
                    const _FormDivider(),
                    _FormRow(
                      icon: Icons.drive_file_rename_outline_rounded,
                      fieldKey: const Key('holding-name'),
                      label: _fund ? 'Fund name' : 'Name',
                      hint: _fund
                          ? 'e.g. Parag Parikh Flexi Cap'
                          : 'e.g. Tata Consultancy Services',
                      controller: _name,
                      maxLength: 60,
                      capitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const _FormDivider(),
                    _FormRow(
                      icon: Icons.tag_rounded,
                      fieldKey: const Key('holding-symbol'),
                      label: _fund ? 'Scheme code' : 'Ticker',
                      hint: _fund ? 'e.g. 122639' : 'e.g. TCS.NS',
                      note: 'Optional · lets the price update by itself',
                      controller: _symbol,
                      capitalization: TextCapitalization.characters,
                      onChanged: _onTickerChanged,
                    ),
                    if (!_fund) ...[
                      const _FormDivider(),
                      _FormRow(
                        icon: Icons.account_balance_outlined,
                        fieldKey: const Key('holding-exchange'),
                        label: 'Exchange',
                        hint: 'NSE, BSE, NASDAQ…',
                        note: 'Optional',
                        controller: _exchange,
                        capitalization: TextCapitalization.characters,
                        onChanged: _onTickerChanged,
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _priceLine(context),
              if (_existing != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Already in ${widget.broker.name}. A purchase goes to the '
                  'holding you have.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
        ActionButtonBar(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          // Already held: nothing to save, only a purchase to add to it.
          secondaryLabel: _existing != null
              ? 'Back'
              : _saving
              ? 'Saving…'
              : 'Save',
          onSecondary: _existing != null
              ? _back
              : _detailsValid && !_saving
              ? () => _save(addPurchase: false)
              : null,
          primaryLabel: 'Add purchase',
          onPrimary: _detailsValid && !_saving
              ? () => _save(addPurchase: true)
              : null,
        ),
      ],
    );
  }

  String _priceText(PriceQuote quote) {
    final currency = quote.currency ?? widget.broker.currency;
    final price = NumberFormat.decimalPatternDigits(
      locale: currency == 'INR' ? 'en_IN' : 'en_US',
      decimalDigits: 2,
    ).format(quote.priceE4 / priceScale);
    return '${currencyPrefix(currency)} $price';
  }

  /// What the holding would be priced at, or why it can't be.
  Widget _priceLine(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final symbol = _symbol.text.trim();
    final quote = _quote;
    final Widget line;
    if (symbol.isEmpty) {
      line = Text(
        'No ticker, so the price stays as you set it until you add one.',
        style: muted,
      );
    } else if (_quoteLoading) {
      line = Text('Looking up the price…', style: muted);
    } else if (quote == null) {
      line = Text(
        'No price found. You can set one by hand later.',
        style: muted,
      );
    } else {
      final other =
          quote.currency != null && quote.currency != widget.broker.currency;
      line = Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '${_priceText(quote)} · closed ${DateFormat('d MMM').format(quote.date)}',
            key: const Key('holding-price'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: SheetColors.of(context).income,
            ),
          ),
          if (other) ...[
            const SizedBox(height: 4),
            Text(
              'Priced in ${quote.currency}. ${widget.broker.name} shows it '
              'with its value in ${widget.broker.currency} too.',
              textAlign: TextAlign.center,
              style: muted,
            ),
          ],
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        width: double.infinity,
        child: DefaultTextStyle.merge(textAlign: TextAlign.center, child: line),
      ),
    );
  }
}

/// A fully rounded choice: filled with the accent when selected, otherwise
/// the same body as the search bar above it.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? scheme.primary : SearchField.fill(context),
        shape: StadiumBorder(
          side: selected
              ? BorderSide.none
              : BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in a form card, laid out like the loan form: a coloured icon on
/// the left, a small label with the value beneath it, and optionally a
/// one-line note. Give it a [controller] for a field you can type in, or
/// just a [value] to show a fixed answer.
class _FormRow extends StatelessWidget {
  const _FormRow({
    required this.icon,
    required this.label,
    this.value,
    this.fieldKey,
    this.hint,
    this.controller,
    this.onChanged,
    this.note,
    this.maxLength,
    this.capitalization = TextCapitalization.none,
  });
  final IconData icon;
  final String label;
  final String? value, hint, note;
  final Key? fieldKey;
  final int? maxLength;
  final TextCapitalization capitalization;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;

  /// Width of the icon column, which the dividers also start after.
  static const iconColumn = 40.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final valueStyle = theme.textTheme.titleMedium;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: iconColumn,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Icon(icon, size: 22, color: scheme.primary),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                if (controller == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(value ?? '', style: valueStyle),
                  )
                else
                  TextField(
                    key: fieldKey,
                    controller: controller,
                    maxLength: maxLength,
                    textCapitalization: capitalization,
                    onChanged: onChanged,
                    style: valueStyle,
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: valueStyle?.copyWith(
                        color: muted.withValues(alpha: .75),
                        fontWeight: FontWeight.w400,
                      ),
                      isDense: true,
                      filled: false,
                      counterText: '',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      note!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted.withValues(alpha: .7),
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
}

/// The hairline between rows, starting after the icon column.
class _FormDivider extends StatelessWidget {
  const _FormDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(18 + _FormRow.iconColumn, 10, 18, 0),
    child: Divider(height: 1),
  );
}
