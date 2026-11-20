import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../data/prices/price_service.dart';
import '../../../data/prices/price_sources.dart';
import '../../../domain/account.dart';
import '../../../domain/holding.dart';
import '../../../state/account_store.dart';
import '../../../state/holding_store.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/date_picker_sheet.dart';
import '../../theme/sheet_colors.dart';

String _message(Object error) =>
    error is ArgumentError ? '${error.message}' : 'Could not save. Try again.';

/// A labelled text box that matches the rest of the sheets.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.number = false,
    this.onChanged,
    this.suffix,
    this.capitalize = TextCapitalization.words,
  });
  final String label;
  final String? hint, suffix;
  final TextEditingController controller;
  final bool number;
  final TextCapitalization capitalize;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textCapitalization: capitalize,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        inputFormatters: number
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
            : null,
        style: TextStyle(fontSize: 16, color: colors.text),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixText: suffix,
          filled: true,
          fillColor: colors.card,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// A tappable row that shows a choice, such as the date or the account.
class _PickRow extends StatelessWidget {
  const _PickRow({required this.label, required this.value, required this.onTap});
  final String label, value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Text(label, style: TextStyle(color: colors.muted)),
                const Spacer(),
                Flexible(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, color: colors.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.label, required this.onPressed, this.error});
  final String label;
  final String? error;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: onPressed,
            child: Text(label),
          ),
        ),
      ],
    ),
  );
}

// ---- Add a holding ----------------------------------------------------------

/// Returns the new holding's id.
Future<int?> showAddHoldingSheet(
  BuildContext context, {
  required HoldingStore store,
  required Account broker,
}) => showAdaptiveSheet<int>(
  context,
  builder: (_) => _AddHoldingSheet(store: store, broker: broker),
);

class _AddHoldingSheet extends StatefulWidget {
  const _AddHoldingSheet({required this.store, required this.broker});
  final HoldingStore store;
  final Account broker;

  @override
  State<_AddHoldingSheet> createState() => _AddHoldingSheetState();
}

class _AddHoldingSheetState extends State<_AddHoldingSheet> {
  final _name = TextEditingController();
  final _symbol = TextEditingController();
  final _exchange = TextEditingController();
  final _search = TextEditingController();
  HoldingKind _kind = HoldingKind.stock;
  String? _error;
  bool _saving = false;
  List<SymbolHit> _hits = const [];
  bool _searching = false, _searched = false;
  Timer? _debounce;

  /// Looks up what was typed, a moment after typing stops.
  void _onSearch(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() {
        _hits = const [];
        _searched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final service = widget.store.prices;
      if (service == null) return;
      setState(() => _searching = true);
      final hits = await service.search(
        text,
        indianFunds: widget.broker.currency == 'INR',
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
        _searched = true;
      });
    });
  }

  void _use(SymbolHit hit) {
    setState(() {
      _kind = hit.kind;
      _name.text = hit.name.length > 60 ? hit.name.substring(0, 60) : hit.name;
      _symbol.text = hit.symbol;
      _exchange.text = hit.kind == HoldingKind.fund && hit.exchange == 'AMFI'
          ? ''
          : hit.exchange ?? '';
      _hits = const [];
      _searched = false;
      _search.clear();
      _error = null;
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _name.dispose();
    _symbol.dispose();
    _exchange.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final id = await widget.store.saveHolding(
        accountId: widget.broker.id,
        kind: _kind,
        name: _name.text,
        symbol: _symbol.text,
        exchange: _exchange.text,
      );
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _message(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fund = _kind == HoldingKind.fund;
    return SheetPage(
      header: SheetHeader('Add to ${widget.broker.name}'),
      bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<HoldingKind>(
                showSelectedIcon: false,
                segments: [
                  for (final k in HoldingKind.values)
                    ButtonSegment(value: k, label: Text(k.label)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
            ),
          ),
          if (widget.store.prices != null) ...[
            _Field(
              label: 'Search by name or ticker',
              hint: fund ? 'Parag Parikh Flexi Cap' : 'TCS, Apple…',
              controller: _search,
              onChanged: _onSearch,
              capitalize: TextCapitalization.none,
              suffix: _searching ? '…' : null,
            ),
            for (final hit in _hits.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: SheetColors.of(context).card,
                  borderRadius: BorderRadius.circular(14),
                  child: ListTile(
                    dense: true,
                    title: Text(
                      hit.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${hit.kind.label} · ${hit.symbol}'
                      '${hit.exchange == null ? '' : ' · ${hit.exchange}'}',
                    ),
                    onTap: () => _use(hit),
                  ),
                ),
              ),
            if (_searched && _hits.isEmpty && !_searching)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Nothing found. You can type it in below.',
                  style: TextStyle(
                    fontSize: 13,
                    color: SheetColors.of(context).muted,
                  ),
                ),
              ),
            const SizedBox(height: 6),
          ],
          _Field(
            label: fund ? 'Fund name' : 'Company or ETF name',
            controller: _name,
            onChanged: (_) => setState(() => _error = null),
          ),
          _Field(
            label: fund ? 'Scheme code (optional)' : 'Ticker (optional)',
            hint: fund ? '120503' : 'TCS',
            controller: _symbol,
            capitalize: TextCapitalization.characters,
          ),
          if (!fund)
            _Field(
              label: 'Exchange (optional)',
              hint: 'NSE, BSE, NASDAQ…',
              controller: _exchange,
              capitalize: TextCapitalization.characters,
            ),
        ],
      ),
      actions: _SaveBar(
        label: 'Add',
        error: _error,
        onPressed: _saving || _name.text.trim().isEmpty ? null : _save,
      ),
    );
  }
}

// ---- Buy, sell and dividend -------------------------------------------------

Future<bool?> showTradeSheet(
  BuildContext context, {
  required HoldingStore store,
  required AccountStore accounts,
  required Holding holding,
  required TradeType type,
}) => showAdaptiveSheet<bool>(
  context,
  builder: (_) => _TradeSheet(
    store: store,
    accounts: accounts,
    holding: holding,
    type: type,
  ),
);

class _TradeSheet extends StatefulWidget {
  const _TradeSheet({
    required this.store,
    required this.accounts,
    required this.holding,
    required this.type,
  });
  final HoldingStore store;
  final AccountStore accounts;
  final Holding holding;
  final TradeType type;

  @override
  State<_TradeSheet> createState() => _TradeSheetState();
}

class _TradeSheetState extends State<_TradeSheet> {
  final _units = TextEditingController();
  final _price = TextEditingController();
  final _amount = TextEditingController();
  final _fees = TextEditingController();
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  int? _payAccountId;
  String? _error;
  bool _saving = false;

  Account get _broker => widget.accounts.byId(widget.holding.accountId)!;
  int get _digits => _broker.digits;
  bool get _dividend => widget.type == TradeType.dividend;

  @override
  void initState() {
    super.initState();
    final last = widget.holding.lastPriceE4;
    if (last != null && !_dividend) {
      _price.text = (last / priceScale).toStringAsFixed(
        last % priceScale == 0 ? 0 : 4,
      );
    }
  }

  @override
  void dispose() {
    _units.dispose();
    _price.dispose();
    _amount.dispose();
    _fees.dispose();
    super.dispose();
  }

  int? get _unitsE6 => parseScaled(_units.text, unitScale);
  int? get _priceE4 => parseScaled(_price.text, priceScale);
  int? get _feesMinor =>
      _fees.text.trim().isEmpty ? 0 : parseAccountAmount(_fees.text.replaceAll(',', ''), _digits);

  /// What the units cost or fetch, before fees.
  int? get _amountMinor {
    if (_dividend) {
      return parseAccountAmount(_amount.text.replaceAll(',', ''), _digits);
    }
    final units = _unitsE6, price = _priceE4;
    if (units == null || price == null || units == 0 || price == 0) return null;
    return tradeAmountMinor(unitsE6: units, priceE4: price, digits: _digits);
  }

  Future<void> _save() async {
    final amount = _amountMinor, fees = _feesMinor;
    if (amount == null || amount <= 0 || fees == null) {
      setState(() => _error = 'Check the numbers.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.store.addTrade(
        holding: widget.holding,
        type: widget.type,
        date: _date,
        unitsE6: _dividend ? 0 : _unitsE6!,
        priceE4: _dividend ? 0 : _priceE4!,
        amountMinor: amount,
        feesMinor: fees,
        payAccountId: _payAccountId,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _message(e);
        });
      }
    }
  }

  Future<void> _pickPayer() async {
    final broker = _broker;
    final items = [
      ChoiceItem<int>(
        value: broker.id,
        icon: const Icon(Icons.show_chart_rounded),
        label: '${broker.name} cash',
        subtitle: formatAccountMoney(
          broker.balanceMinor,
          digits: broker.digits,
          currency: broker.currency,
        ),
      ),
      for (final a in widget.accounts.accounts)
        if (!a.isBroker &&
            a.currency == broker.currency &&
            a.digits == broker.digits)
          ChoiceItem<int>(
            value: a.id,
            icon: const Icon(Icons.account_balance_rounded),
            label: a.name,
            subtitle: formatAccountMoney(
              a.balanceMinor,
              digits: a.digits,
              currency: a.currency,
            ),
          ),
    ];
    final picked = await showChoiceListSheet<int>(
      context,
      title: 'Pay from',
      items: items,
      selected: _payAccountId ?? broker.id,
    );
    if (picked != null && mounted) {
      setState(() => _payAccountId = picked == broker.id ? null : picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final broker = _broker;
    final colors = SheetColors.of(context);
    final amount = _amountMinor;
    final payer = _payAccountId == null
        ? '${broker.name} cash'
        : widget.accounts.byId(_payAccountId)?.name ?? broker.name;
    final money = amount == null
        ? null
        : formatAccountMoney(amount, digits: _digits, currency: broker.currency);
    return SheetPage(
      header: SheetHeader('${widget.type.label} · ${widget.holding.name}'),
      bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      body: Column(
        children: [
          if (_dividend)
            _Field(
              label: 'Dividend received',
              controller: _amount,
              number: true,
              suffix: broker.currency,
              onChanged: (_) => setState(() => _error = null),
            )
          else ...[
            _Field(
              label: 'Units',
              controller: _units,
              number: true,
              onChanged: (_) => setState(() => _error = null),
            ),
            _Field(
              label: widget.holding.kind == HoldingKind.fund
                  ? 'NAV per unit'
                  : 'Price per share',
              controller: _price,
              number: true,
              suffix: broker.currency,
              onChanged: (_) => setState(() => _error = null),
            ),
          ],
          _Field(
            label: 'Fees and taxes (optional)',
            controller: _fees,
            number: true,
            suffix: broker.currency,
            onChanged: (_) => setState(() => _error = null),
          ),
          _PickRow(
            label: 'Date',
            value: DateFormat('d MMM y').format(_date),
            onTap: () async {
              final picked = await showDatePickerSheet(
                context,
                initialDate: _date,
              );
              if (picked != null && mounted) {
                setState(() => _date = DateUtils.dateOnly(picked));
              }
            },
          ),
          if (widget.type == TradeType.buy)
            _PickRow(label: 'Pay from', value: payer, onTap: _pickPayer),
          if (money != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                '${widget.type == TradeType.buy ? 'Total' : 'You receive'} '
                '$money${(_feesMinor ?? 0) > 0 ? ' (fees extra)' : ''}',
                style: TextStyle(color: colors.muted, fontSize: 13),
              ),
            ),
        ],
      ),
      actions: _SaveBar(
        label: widget.type.label,
        error: _error,
        onPressed: _saving || amount == null ? null : _save,
      ),
    );
  }
}

// ---- Price by hand ----------------------------------------------------------

Future<void> showPriceSheet(
  BuildContext context, {
  required HoldingStore store,
  required Holding holding,
  required Account broker,
}) => showAdaptiveSheet<void>(
  context,
  builder: (_) => _PriceSheet(store: store, holding: holding, broker: broker),
);

class _PriceSheet extends StatefulWidget {
  const _PriceSheet({
    required this.store,
    required this.holding,
    required this.broker,
  });
  final HoldingStore store;
  final Holding holding;
  final Account broker;

  @override
  State<_PriceSheet> createState() => _PriceSheetState();
}

class _PriceSheetState extends State<_PriceSheet> {
  late final _price = TextEditingController(
    text: widget.holding.lastPriceE4 == null
        ? ''
        : (widget.holding.lastPriceE4! / priceScale).toStringAsFixed(
            widget.holding.lastPriceE4! % priceScale == 0 ? 0 : 4,
          ),
  );
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final price = parseScaled(_price.text, priceScale);
    if (price == null || price == 0) {
      setState(() => _error = 'Enter a price.');
      return;
    }
    try {
      await widget.store.setPrice(widget.holding, price, DateTime.now());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetPage(
      header: const SheetHeader('Latest price'),
      bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      body: _Field(
        label: widget.holding.kind == HoldingKind.fund
            ? 'NAV per unit'
            : 'Price per share',
        controller: _price,
        number: true,
        suffix: widget.broker.currency,
      ),
      actions: _SaveBar(label: 'Save price', error: _error, onPressed: _save),
    );
  }
}

/// Fetches the latest closes and says what happened.
Future<void> refreshPricesWithMessage(
  BuildContext context,
  HoldingStore store,
) async {
  final PriceRefreshResult? result = await store.refreshPrices(force: true);
  if (!context.mounted || result == null) return;
  final message = result.anyUpdated
      ? 'Prices updated'
      : result.mismatched > 0
      ? 'Prices are in a different currency than the broker'
      : 'Couldn’t get prices. Try again later.';
  showAppToast(context, message);
}
