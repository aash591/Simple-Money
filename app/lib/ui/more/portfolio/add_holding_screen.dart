import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/prices/price_sources.dart';
import '../../../domain/account.dart';
import '../../../domain/currency.dart';
import '../../../domain/currency_digits.dart';
import '../../../domain/holding.dart';
import '../../../domain/markets.dart';
import '../../../domain/metal.dart';
import '../../../state/holding_store.dart';
import '../../../state/pro_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/app_icon.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/app_toast.dart';
import '../../components/currency_flag.dart';
import '../../components/feature_page.dart';
import '../../components/watch_ad.dart';
import '../../components/search_field.dart';
import '../../components/segmented_pill.dart';
import '../../components/select_icon_screen.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transaction_widgets.dart' show StepSlider;
import '../pro/pro_screen.dart';
import 'holding_logo.dart';
import 'step_intro.dart';

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
  (
    kind: HoldingKind.crypto,
    icon: Icons.currency_bitcoin_rounded,
    title: 'Crypto',
    subtitle: 'Bitcoin and other coins',
  ),
  (
    kind: HoldingKind.metal,
    icon: Icons.diamond_outlined,
    title: 'Metal',
    subtitle: 'Gold, silver and platinum',
  ),
  (
    kind: HoldingKind.forex,
    icon: Icons.currency_exchange_rounded,
    title: 'Forex',
    subtitle: 'Dollars, euros and other currencies',
  ),
];

/// Currencies suggested first when adding forex.
const _popularCurrencies = [
  'USD', 'EUR', 'GBP', 'AED', 'SGD', 'JPY', 'CAD', 'AUD', 'CHF', 'SAR', //
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
  String? _icon;

  // A metal: which one, its purity, and where its price comes from. A metal
  // added by hand has no type, and is priced by hand.
  MetalType? _metalType;
  int _fineness = 0;
  final _purity = TextEditingController();
  bool _purityOk = true;
  String _metalSource = PriceSourceId.metalWorld;
  bool _nameEdited = false;

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
  bool get _crypto => _kind == HoldingKind.crypto;
  bool get _metal => _kind == HoldingKind.metal;
  bool get _forex => _kind == HoldingKind.forex;

  /// Funds, coins, metals and currencies aren't listed on a stock exchange
  /// or market.
  bool get _unlisted => _fund || _crypto || _metal || _forex;

  MetalDetails get _metalDetails =>
      MetalDetails(metal: _metalType!, fineness: _fineness);
  bool get _canSearch => widget.store.prices != null;

  // Names and flags for the currency list, and today's rate for each one
  // shown, filled in as they arrive.
  Map<String, Currency> _currencyInfo = const {};
  final Map<String, PriceQuote?> _rates = {};
  final Set<String> _rateAsked = {};

  bool _currencyLoading = false;

  /// Loads the names and flags the first time they are needed.
  void _loadCurrencyInfo() {
    if (_currencyLoading || _currencyInfo.isNotEmpty) return;
    _currencyLoading = true;
    Currency.load()
        .then((all) {
          if (!mounted) return;
          // Reversed so the first country listed for a code wins.
          setState(
            () => _currencyInfo = {for (final c in all.reversed) c.code: c},
          );
        })
        .catchError((_) {
          _currencyLoading = false;
        });
  }

  Widget _currencyFlag(String code, {double size = 36}) {
    final territory = currencyFlagTerritory(code);
    return territory == null
        ? HoldingLogo(null, kind: HoldingKind.forex, size: size)
        : CurrencyFlag(
            territory,
            width: size,
            height: size,
            borderRadius: size * .28,
          );
  }

  /// How many of each currency a dollar buys, asked once each and shared by
  /// every row, so a row needs one lookup rather than up to three.
  final Map<String, Future<PriceQuote?>> _perDollar = {};

  /// Lookups waiting their turn, and how many are running: a few at a time,
  /// because a screenful at once gets refused.
  final List<String> _rateWaiting = [];
  int _rateRunning = 0;
  static const _rateParallel = 4;

  Future<PriceQuote?> _dollarRate(String code) {
    final client = widget.store.prices!.client;
    final future = _perDollar[code] ??= ForexSource.perDollar(client, code);
    // A failed lookup is forgotten, so the next row that needs it asks again.
    return future.then((q) {
      if (q == null) _perDollar.remove(code);
      return q;
    });
  }

  /// Whether the one-request table answered. Until it has, or if it can't,
  /// rows are priced one by one from Yahoo instead.
  bool _tableLoading = false, _tableFailed = false;

  /// Fills every row's rate from one request, and names where it came from.
  Future<void> _loadRateTable() async {
    final service = widget.store.prices;
    if (service == null || _tableLoading) return;
    _tableLoading = true;
    final table = await ForexTable.load(service.client, widget.broker.currency);
    _tableLoading = false;
    if (!mounted) return;
    setState(() {
      if (table == null) {
        _tableFailed = true;
      } else {
        for (final code in knownCurrencyCodes) {
          if (table.rateOf(code) case final quote?) _rates[code] = quote;
        }
      }
    });
    showAppToast(
      context,
      table == null
          ? 'Rates from Yahoo Finance'
          : 'Rates from ${ForexTable.sourceName}',
      icon: Icons.currency_exchange_rounded,
    );
  }

  /// Asks for the rate of each of [codes] not asked for yet.
  void _fetchRates(Iterable<String> codes) {
    if (widget.store.prices == null) return;
    for (final c in codes) {
      if (_rateAsked.add(c)) _rateWaiting.add(c);
    }
    _runRates();
  }

  /// Failed tries per code. Yahoo now and then refuses or drops a lookup, so
  /// a failed one is tried again by itself after a short wait, a little
  /// longer each time; a code it doesn't have stays blank after the last.
  final Map<String, int> _rateTries = {};
  static const _rateMaxTries = 4;

  void _retryRate(String code) {
    final tries = _rateTries[code] = (_rateTries[code] ?? 0) + 1;
    if (tries >= _rateMaxTries) return;
    Timer(Duration(milliseconds: 800 * tries), () {
      if (!mounted) return;
      _rateWaiting.add(code);
      _runRates();
    });
  }

  void _runRates() {
    while (_rateRunning < _rateParallel && _rateWaiting.isNotEmpty) {
      final code = _rateWaiting.removeAt(0);
      _rateRunning++;
      final broker = widget.broker.currency;
      (_dollarRate(code), _dollarRate(broker)).wait
          .then((pair) {
            final (from, to) = pair;
            final rate = from == null || to == null
                ? null
                : ForexSource.cross(from, to, broker);
            if (!mounted) return;
            if (rate == null) return _retryRate(code);
            setState(() => _rates[code] = rate);
          })
          .catchError((_) => _retryRate(code))
          .whenComplete(() {
            _rateRunning--;
            if (mounted) _runRates();
          });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _quoteDebounce?.cancel();
    _search.dispose();
    _name.dispose();
    _purity.dispose();
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

  /// What the free limit for [kind] is called in its prompt.
  static String _limitName(HoldingKind kind) => switch (kind) {
    HoldingKind.etf => 'ETFs',
    HoldingKind.fund => 'mutual funds',
    HoldingKind.crypto => 'crypto holdings',
    HoldingKind.metal => 'metal holdings',
    HoldingKind.forex => 'forex holdings',
    _ => 'holdings',
  };

  /// A kind the free plan has used up its holdings of ends here, with the way
  /// to Pro. What is already held stays; only adding more is held back.
  Future<bool> _mayAdd(HoldingKind kind) async {
    final held = widget.store.holdings.where((h) => h.kind == kind).length;
    if (ProController.instance.mayAddHolding(kind, held)) return true;
    final limit = ProController.freeHoldingsOf(kind)!;
    if (await showConfirmationAlert(
          context,
          title: '$limit ${_limitName(kind)} is the free limit',
          message: 'With Pro you can add as many as you like.',
          confirmLabel: 'See Pro',
          cancelLabel: 'Not now',
          destructive: false,
        ) &&
        mounted) {
      await Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
    }
    return false;
  }

  Future<void> _chooseKind(HoldingKind kind) async {
    if (!await _mayAdd(kind) || !mounted) return;
    setState(() {
      _metalType = null;
      _kind = kind;
      _hits = const [];
      _searched = false;
      _picked = null;
      _icon = null;
      _search.clear();
    });
    _go(_Step.find);
    if (kind == HoldingKind.forex) _loadRateTable();
  }

  // ---- Find it --------------------------------------------------------------

  void _onSearch(String text) {
    _searchDebounce?.cancel();
    // The metals and currencies are short lists kept here, filtered as you type.
    if (_metal || _forex) {
      setState(() {});
      return;
    }
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
      final hits = await service.search(
        text,
        currency: widget.broker.currency,
        kind: _kind,
      );
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
          // A fund's ticker often says nothing about its country (`0P…`
          // codes), so funds are not narrowed by market.
          (_unlisted ||
              _market == null ||
              hit.kind == HoldingKind.fund ||
              marketOfSymbol(hit.symbol) == _market))
        hit,
  ];

  void _pick(SymbolHit hit) {
    _picked = hit;
    _icon = null;
    _name.text = hit.name.length > 60 ? hit.name.substring(0, 60) : hit.name;
    _symbol.text = hit.symbol;
    _exchange.text = hit.kind == HoldingKind.fund && hit.exchange == 'AMFI'
        ? ''
        : hit.exchange ?? '';
    _enterDetails();
  }

  /// A currency from the list: its code is the name and the symbol.
  void _pickCurrency(String code) {
    _picked = null;
    _icon = null;
    _nameEdited = false;
    _name.text = code;
    _symbol.text = code;
    _exchange.clear();
    _enterDetails();
  }

  /// A metal from the list: its name, symbol and price source follow it.
  void _pickMetal(MetalType metal) {
    _picked = null;
    _icon = null;
    _nameEdited = false;
    _metalType = metal;
    _fineness = metal.defaultPurity;
    _purity.text = metal.purityLabel(_fineness);
    _purityOk = true;
    _metalSource = PriceSourceId.metalWorld;
    _syncMetal();
    _exchange.clear();
    _enterDetails();
  }

  /// The name (unless typed) and symbol of the metal chosen.
  void _syncMetal() {
    _symbol.text = _metalDetails.symbol;
    if (!_nameEdited) {
      _name.text = '${_metalType!.label} ${_metalDetails.purityLabel}';
    }
  }

  /// The purity typed: once it reads as one, the name and price follow.
  void _onPurityChanged(String text) {
    final fineness = _metalType!.parsePurity(text);
    _quoteDebounce?.cancel();
    setState(() {
      _error = null;
      _purityOk = fineness != null;
      if (fineness == null) {
        _quote = null;
        _quoteLoading = false;
        return;
      }
      _fineness = fineness;
      _syncMetal();
      _quoteLoading = true;
    });
    if (fineness != null) {
      _quoteDebounce = Timer(const Duration(milliseconds: 600), _loadQuote);
    }
  }

  void _changeMetalSource(String source) {
    setState(() => _metalSource = source);
    _loadQuote();
  }

  void _addManually() {
    _picked = null;
    _icon = null;
    _nameEdited = false;
    _metalType = null;
    _metalSource = PriceSourceId.manual;
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
    if (_metal) return _metalType == null ? PriceSourceId.manual : _metalSource;
    if (_forex) return PriceSourceId.forexRate;
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
    if (_metal &&
        (service == null ||
            _metalType == null ||
            _metalSource == PriceSourceId.manual)) {
      setState(() {
        _quote = null;
        _quoteLoading = false;
      });
      return;
    }
    if (service == null || symbol.isEmpty) {
      if (mounted) setState(() => _quoteLoading = false);
      return;
    }
    final round = ++_quoteRound;
    setState(() => _quoteLoading = true);
    final quote = await service.quoteFor(
      kind: _kind,
      symbol: symbol,
      exchange: _unlisted ? null : _exchange.text.trim(),
      priceSource: _source,
      meta: _metal ? jsonEncode(_metalDetails.toJson()) : null,
      // Metal is bought in the account's own currency, so it is priced there.
      currency: _metal || _forex ? widget.broker.currency : null,
    );
    if (!mounted || round != _quoteRound) return;
    setState(() {
      _quote = quote;
      _quoteLoading = false;
    });
  }

  bool get _detailsValid =>
      _name.text.trim().isNotEmpty &&
      (!_metal || _metalType == null || _purityOk);

  /// Details kept with the holding: a coin's logo and any icon picked.
  String? _meta() {
    final details = {
      if (_crypto && _source != null && _picked?.image != null)
        'image': _picked!.image,
      if (_metal && _metalType != null) ..._metalDetails.toJson(),
      if (_icon != null) 'icon': _icon,
    };
    return details.isEmpty ? null : jsonEncode(details);
  }

  Future<void> _pickIcon() async {
    FocusScope.of(context).unfocus();
    final icon = await Navigator.of(context)
        .push(FeatureRoute<String>(SelectIconScreen(selectedKey: _icon)));
    if (icon != null && mounted) setState(() => _icon = icon);
  }

  /// The logo of what was picked, or of the ticker typed, once there is one.
  Widget? _detailsLogo() {
    if (_icon != null) return AppIcon(_icon, size: 26);
    if (_metal) return const AppIcon('jewelry', size: 26);
    if (_forex)
      return _currencyFlag(_symbol.text.trim().toUpperCase(), size: 26);
    final symbol = _symbol.text.trim();
    final url = _crypto
        ? (_source != null ? _picked?.image : null)
        : symbol.isEmpty ||
              (_fund && _source == null && RegExp(r'^\d+$').hasMatch(symbol))
        ? null
        : tickerLogoUrl(YahooQuotes.yahooSymbol(symbol, _exchange.text.trim()));
    return url == null ? null : HoldingLogo(url, kind: _kind, size: 26);
  }

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

  /// A new holding of the free plan may take a short ad, as budgets do: every
  /// second one of its kind. True when it may be saved. A purchase on a
  /// holding already held adds nothing new, so it never asks.
  Future<bool> _mayAddNew() async {
    if (_existing != null) return true;
    final held = widget.store.holdings.where((h) => h.kind == _kind).length;
    if (!ProController.instance.holdingTakesAd(held)) return true;
    final limit = ProController.freeHoldingsOf(_kind);
    void openPro() =>
        Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
    final watch = await showConfirmationAlert(
      context,
      title: 'Watch a short ad to add this holding',
      message: limit == null
          ? 'Every second one takes a short ad on the free plan. With Pro, '
                'add as many as you like, with no ads.'
          : '${_kind.label} ${held + 1} of $limit on the free plan. With Pro, '
                'add as many as you like, with no ads.',
      confirmLabel: 'Watch ad',
      extraActionLabel: 'Get Pro instead',
      onExtraAction: openPro,
      destructive: false,
    );
    if (!watch || !mounted) return false;
    // Offline, or the user declined: nothing is saved.
    if (!await watchAd(context)) return false;
    return mounted;
  }

  Future<void> _save({required bool addPurchase}) async {
    if (_saving) return;
    if (!await _mayAddNew()) return;
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
        exchange: _unlisted ? '' : _exchange.text,
        priceSource: _source,
        currency: _metal || _forex
            ? widget.broker.currency
            : (other ? quoteCurrency : null),
        meta: _meta(),
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
        // The types sit at the bottom at their own height; the intro is
        // centered in the space above them.
        const Expanded(
          child: StepIntro(
            compact: true,
            title: 'What are you adding?',
            message: 'Choose a type, then find it by name.',
          ),
        ),
        SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
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
                              vertical: 11,
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

  /// Where to look for funds: the names suggested for each country. Search
  /// covers every country; this only changes what is suggested.
  static const _fundCountries = <String, (String, List<String>)>{
    'in': ('India', ['Parag Parikh', 'Nifty 50 index', 'HDFC', 'SBI']),
    'us': ('US', ['Vanguard 500', 'Fidelity Contrafund', 'Wellington']),
    'uk': ('UK', ['Fundsmith Equity', 'Fidelity Index World', 'LifeStrategy']),
    'sg': ('Singapore', ['Fullerton', 'Fidelity Asia Pacific']),
    'eu': ('Europe', ['Robeco', 'Eurizon', 'DWS Top Dividende']),
    'ca': ('Canada', ['RBC Canadian Equity', 'TD Canadian Index']),
    'hk': ('Hong Kong', ['Hong Kong fund', 'Schroder Asia', 'Fidelity China']),
    'ch': ('Switzerland', ['Fidelity Switzerland']),
    'za': ('South Africa', ['Coronation']),
    'latam': ('Latin America', ['Latin America fund']),
  };

  late String _fundCountry = switch (widget.broker.currency) {
    'INR' => 'in',
    'GBP' => 'uk',
    'SGD' => 'sg',
    'EUR' => 'eu',
    'CAD' => 'ca',
    'HKD' => 'hk',
    'CHF' => 'ch',
    'ZAR' => 'za',
    _ => 'us',
  };

  /// Names to try before anything is typed, tappable.
  List<String> get _examples {
    if (_crypto) return const ['Bitcoin', 'Ethereum', 'Solana', 'XRP'];
    if (_fund) return _fundCountries[_fundCountry]!.$2;
    final market = _market;
    if (market == null) return const ['Apple', 'Reliance', 'Toyota', 'Nestle'];
    // Funds are only suggested where some are known to turn up in a search.
    return _kind == HoldingKind.etf ? market.etfs : market.stocks;
  }

  /// The metals ready to pick, narrowed by what is typed.
  Widget _metalFindPage(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final metals = [
      for (final m in MetalType.values)
        if (query.isEmpty || m.label.toLowerCase().contains(query)) m,
    ];
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SearchField(
            key: const Key('holding-search'),
            controller: _search,
            onChanged: _onSearch,
            hintText: 'Search metals',
          ),
        ),
        const SizedBox(height: 8),
        if (metals.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Nothing found.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
                  for (final (i, m) in metals.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      key: Key('hit-${m.id}'),
                      leading: const HoldingLogo(
                        null,
                        kind: HoldingKind.metal,
                        size: 36,
                      ),
                      title: Text(m.label),
                      subtitle: const Text('Priced per gram'),
                      onTap: () => _pickMetal(m),
                    ),
                  ],
                ],
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

  /// Currencies to pick, the popular ones first, narrowed by what is typed.
  /// The list is built lazily, and a rate is only asked for once its row is
  /// on screen, so opening it stays smooth with every currency in it.
  Widget _forexFindPage(BuildContext context) {
    final theme = Theme.of(context);
    _loadCurrencyInfo();
    final query = _search.text.trim().toUpperCase();
    final codes =
        [
          ..._popularCurrencies,
          for (final c in knownCurrencyCodes.toList()..sort())
            if (!_popularCurrencies.contains(c)) c,
        ].where((c) {
          if (c == widget.broker.currency) return false;
          return c.contains(query) ||
              (_currencyInfo[c]?.name.toUpperCase().contains(query) ?? false);
        }).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SearchField(
              key: const Key('holding-search'),
              controller: _search,
              onChanged: _onSearch,
              hintText: 'Search currencies, like USD',
            ),
          ),
          const SizedBox(height: 8),
          if (codes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Nothing found.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: MoneyCard(
                  padding: EdgeInsets.zero,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(appCardRadius),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListView.separated(
                        // Remembers where it was scrolled to, so coming back
                        // from a currency's details lands in the same place.
                        key: const PageStorageKey('forex-list'),
                        // A short search result keeps the card to its rows.
                        shrinkWrap: codes.length <= 12,
                        padding: EdgeInsets.zero,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: codes.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) =>
                            _currencyTile(context, codes[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Codes whose row has been built and whose rate is still to be asked.
  final Set<String> _rateQueue = {};

  /// One currency: its flag and name, and on the right what one unit of it
  /// is in the account's currency.
  Widget _currencyTile(BuildContext context, String code) {
    final theme = Theme.of(context);
    if (_tableFailed && !_rateAsked.contains(code) && _rateQueue.add(code)) {
      // After this frame, all at once: asking changes state.
      if (_rateQueue.length == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final batch = _rateQueue.toList();
          _rateQueue.clear();
          if (mounted) _fetchRates(batch);
        });
      }
    }
    final rate = _rates[code];
    return ListTile(
      key: Key('hit-$code'),
      leading: _currencyFlag(code),
      title: Text(code),
      subtitle: Text(
        _currencyInfo[code]?.name ?? 'Currency',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: rate == null
          ? null
          : Text(_priceText(rate), style: theme.textTheme.titleSmall),
      onTap: () => _pickCurrency(code),
    );
  }

  Widget _findPage(BuildContext context) {
    if (_metal) return _metalFindPage(context);
    if (_forex) return _forexFindPage(context);
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
                  : _crypto
                  ? 'Search coins by name'
                  : 'Search by name or ticker',
            ),
          ),
          if (_fund)
            _fundCountryChips(context)
          else if (!_unlisted)
            _marketChips(context),
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
                _hits.isNotEmpty && !_unlisted && _market != null
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

  /// Countries to get fund suggestions for.
  Widget _fundCountryChips(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, e) in _fundCountries.entries.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            HoldingPill(
              key: Key('fund-country-${e.key}'),
              label: e.value.$1,
              selected: _fundCountry == e.key,
              onTap: () => setState(() => _fundCountry = e.key),
            ),
          ],
        ],
      ),
    ),
  );

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
            HoldingPill(
              label: 'All',
              selected: _market == null,
              onTap: () => setState(() => _market = null),
            ),
            for (final market in ordered) ...[
              const SizedBox(width: 8),
              HoldingPill(
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
            _fund
                ? 'Type a fund name'
                : _crypto
                ? 'Type a coin name'
                : 'Type a company name or a ticker',
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
                HoldingPill(
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
        !_unlisted &&
        market != null &&
        market.currency != widget.broker.currency;
    return ListTile(
      key: Key('hit-${hit.symbol}'),
      leading: HoldingLogo(
        hit.kind == HoldingKind.crypto
            ? hit.image
            : hit.kind == HoldingKind.fund && hit.exchange == 'AMFI'
            ? null
            : tickerLogoUrl(hit.symbol),
        kind: hit.kind,
        size: 36,
      ),
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
                    HoldingFormRow(
                      icon: _kinds.firstWhere((c) => c.kind == _kind).icon,
                      label: 'Type',
                      value: _kinds.firstWhere((c) => c.kind == _kind).title,
                    ),
                    const HoldingFormDivider(),
                    HoldingFormRow(
                      icon: Icons.drive_file_rename_outline_rounded,
                      leading: _detailsLogo(),
                      onLeadingTap: _saving ? null : _pickIcon,
                      fieldKey: const Key('holding-name'),
                      label: _fund ? 'Fund name' : 'Name',
                      hint: _fund
                          ? 'e.g. Parag Parikh Flexi Cap'
                          : _crypto
                          ? 'e.g. Bitcoin'
                          : _metal
                          ? 'e.g. Wedding necklace'
                          : _forex
                          ? 'e.g. US dollars'
                          : 'e.g. Tata Consultancy Services',
                      controller: _name,
                      maxLength: 60,
                      capitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {
                        _nameEdited = true;
                        _error = null;
                      }),
                    ),
                    if (_metal) ...[
                      if (_metalType != null) ...[
                        const HoldingFormDivider(),
                        _purityRow(context),
                      ] else
                        const SizedBox(height: 8),
                    ] else ...[
                      const HoldingFormDivider(),
                      HoldingFormRow(
                        icon: Icons.tag_rounded,
                        fieldKey: const Key('holding-symbol'),
                        label: _fund
                            ? 'Scheme code'
                            : _crypto
                            ? 'Coin ID'
                            : _forex
                            ? 'Currency code'
                            : 'Ticker',
                        hint: _fund
                            ? 'e.g. 122639'
                            : _crypto
                            ? 'e.g. bitcoin'
                            : _forex
                            ? 'e.g. USD'
                            : 'e.g. TCS.NS',
                        note: 'Optional · lets the price update by itself',
                        controller: _symbol,
                        capitalization: _crypto
                            ? TextCapitalization.none
                            : TextCapitalization.characters,
                        onChanged: _onTickerChanged,
                      ),
                      if (!_unlisted) ...[
                        const HoldingFormDivider(),
                        HoldingFormRow(
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
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (_metal) _metalPriceSection(context) else _priceLine(context),
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

  /// The purity of the metal chosen, typed in.
  Widget _purityRow(BuildContext context) {
    return HoldingFormRow(
      icon: Icons.verified_outlined,
      fieldKey: const Key('metal-purity'),
      label: 'Purity',
      hint: _metalType == MetalType.gold ? 'e.g. 22K or 916' : 'e.g. 925',
      note: _purityOk
          ? _metalType!.purityEquals(_purity.text, _fineness)
          : 'Enter carats like 22K (1 to 24), or a number like 916',
      noteColor: _purityOk ? SheetColors.of(context).income : null,
      controller: _purity,
      capitalization: TextCapitalization.characters,
      onChanged: _onPurityChanged,
    );
  }

  /// Where a metal's price comes from, and what it comes to.
  Widget _metalPriceSection(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );
    final type = _metalType;
    if (type == null) {
      return Text(
        'No live price for this one. Set the price when you add a purchase.',
        textAlign: TextAlign.center,
        style: muted,
      );
    }
    final quote = _quote;
    final Widget line;
    if (_metalSource == PriceSourceId.manual) {
      line = Text(
        'You set the price yourself, when you add a purchase or on the '
        'holding.',
        textAlign: TextAlign.center,
        style: muted,
      );
    } else if (_quoteLoading) {
      line = Text(
        'Looking up the price…',
        textAlign: TextAlign.center,
        style: muted,
      );
    } else if (quote == null) {
      line = Text(
        'No price found. You can set one by hand later.',
        textAlign: TextAlign.center,
        style: muted,
      );
    } else {
      final other =
          quote.currency != null && quote.currency != widget.broker.currency;
      line = Column(
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${_priceText(quote)} / g'),
                TextSpan(
                  text: ' · as of ${DateFormat('d MMM').format(quote.date)}',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
            key: const Key('holding-price'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: SheetColors.of(context).income,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The international price in ${widget.broker.currency}. A local '
            'shop charges more for duty, tax and making.',
            textAlign: TextAlign.center,
            style: muted,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('Price from', style: theme.textTheme.titleSmall),
        ),
        SegmentedPill<String>(
          segments: [
            const PillSegment(PriceSourceId.metalWorld, 'International'),
            const PillSegment(PriceSourceId.manual, 'By hand'),
          ],
          value: _metalSource,
          onChanged: _changeMetalSource,
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: line,
        ),
      ],
    );
  }

  String _priceText(PriceQuote quote) {
    final currency = quote.currency ?? widget.broker.currency;
    final price = NumberFormat.decimalPatternDigits(
      locale: currency == 'INR' ? 'en_IN' : 'en_US',
      // A rate under one (a yen in rupees) needs more places to say anything.
      decimalDigits: quote.priceE4 < priceScale ? 4 : 2,
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
            '${_priceText(quote)} · ${_crypto ? 'updated' : 'closed'} ${DateFormat('d MMM').format(quote.date)}',
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
class HoldingPill extends StatelessWidget {
  const HoldingPill({
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
class HoldingFormRow extends StatelessWidget {
  const HoldingFormRow({
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
    this.leading,
    this.onLeadingTap,
    this.noteColor,
  });
  final IconData icon;

  /// The note's colour, where it should stand out from the muted default.
  final Color? noteColor;

  /// Makes the icon column tappable, such as to pick another icon.
  final VoidCallback? onLeadingTap;

  /// Shown in place of the [icon], such as a coin's logo.
  final Widget? leading;
  final String label;
  final String? value, hint, note;
  final Key? fieldKey;
  final int? maxLength;
  final TextCapitalization capitalization;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;

  /// Width of the icon column, which the dividers also start after.
  static const iconColumn = 42.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final valueStyle = theme.textTheme.titleMedium;
    final value = controller == null
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(this.value ?? '', style: valueStyle),
          )
        : TextField(
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
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 18, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: iconColumn),
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
          // The icon shares the value's line, so it is centered on it.
          Row(
            children: [
              SizedBox(
                width: iconColumn,
                // Left-aligned in a column 16 wider than the icon, so the gap
                // to the card's edge and to the text are the same.
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkResponse(
                    onTap: onLeadingTap,
                    radius: 22,
                    child:
                        leading ?? Icon(icon, size: 26, color: scheme.primary),
                  ),
                ),
              ),
              Expanded(child: value),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: iconColumn, bottom: 4),
              child: Text(
                note!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: noteColor ?? muted.withValues(alpha: .7),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The hairline between rows, starting after the icon column.
class HoldingFormDivider extends StatelessWidget {
  const HoldingFormDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(16 + HoldingFormRow.iconColumn, 10, 18, 0),
    child: Divider(height: 1),
  );
}
