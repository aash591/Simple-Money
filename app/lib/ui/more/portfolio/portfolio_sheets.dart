import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../data/prices/price_service.dart';
import '../../../domain/account.dart';
import '../../../domain/holding.dart';
import '../../../state/holding_store.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_toast.dart';
import '../../theme/sheet_colors.dart';

String _message(Object error) =>
    error is ArgumentError ? '${error.message}' : 'Could not save. Try again.';

/// A labelled text box that matches the rest of the sheets.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.number = false,
    this.onChanged,
    this.suffix,
    this.hint,
  });
  final String label;
  final String? suffix, hint;
  final TextEditingController controller;
  final bool number;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textCapitalization: TextCapitalization.words,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        inputFormatters: number
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
            : null,
        style: TextStyle(fontSize: 16, color: colors.text),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          hintText: hint,
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
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: onPressed,
            child: Text(label),
          ),
        ),
      ],
    ),
  );
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
  String? _error, _note;
  bool _fetching = false;
  DateTime? _fetchedDate;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  bool get _canFetch =>
      widget.store.prices != null && widget.holding.canFetchPrice;

  /// Asks the holding's own source for its latest price and fills it in; the
  /// person still saves it.
  Future<void> _fetch() async {
    final service = widget.store.prices;
    final h = widget.holding;
    if (service == null || _fetching) return;
    setState(() {
      _fetching = true;
      _error = null;
      _note = null;
    });
    final quote = await service.quoteFor(
      kind: h.kind,
      symbol: h.symbol,
      exchange: h.exchange,
      priceSource: h.priceSource,
      meta: h.meta,
      currency: h.currency,
    );
    if (!mounted) return;
    final want = h.currencyIn(widget.broker.currency);
    setState(() {
      _fetching = false;
      if (quote == null) {
        _error = 'Couldn’t get the latest price. Try again later.';
      } else if (quote.currency != null && quote.currency != want) {
        _error = 'The source prices it in ${quote.currency}, not $want.';
      } else {
        _price.text = (quote.priceE4 / priceScale).toStringAsFixed(
          quote.priceE4 % priceScale == 0 ? 0 : 4,
        );
        _fetchedDate = quote.date;
        _note =
            '${h.sourceNote ?? 'Latest'} · '
            '${DateFormat('d MMM').format(quote.date)}';
      }
    });
  }

  Future<void> _save() async {
    final price = parseScaled(_price.text, priceScale);
    if (price == null || price == 0) {
      setState(() => _error = 'Enter a price.');
      return;
    }
    try {
      await widget.store.setPrice(
        widget.holding,
        price,
        _fetchedDate ?? DateTime.now(),
        overwrite: true,
      );
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Field(
            label: widget.holding.kind.priceName,
            controller: _price,
            number: true,
            // Typing a price is a hand-set one, not the fetched day's.
            onChanged: (_) => _fetchedDate = null,
            suffix: widget.holding.currencyIn(widget.broker.currency),
          ),
          if (_canFetch) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('fetch-latest'),
                onPressed: _fetching ? null : _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(_fetching ? 'Fetching…' : 'Fetch latest price'),
              ),
            ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  _note!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: SheetColors.of(context).muted),
                ),
              ),
          ],
        ],
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
      ? 'Prices are in a different currency than the account'
      : 'Couldn’t get prices. Try again later.';
  showAppToast(context, message);
}
