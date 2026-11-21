import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_digits.dart';
import '../../../domain/holding.dart';
import '../../../state/account_store.dart';
import '../../../state/holding_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/number_keypad.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/transaction_pages.dart';
import '../../transactions/transaction_widgets.dart';

/// Records a buy, sell or dividend as a short flow, in the same shape as the
/// transfer sheet: one question a page, then a page to check and save.
Future<bool?> showTradeSheet(
  BuildContext context, {
  required HoldingStore store,
  required AccountStore accounts,
  required Holding holding,
  required TradeType type,
}) => showAdaptiveSheet<bool>(
  context,
  builder: (_) => TradeSheet(
    store: store,
    accounts: accounts,
    holding: holding,
    type: type,
  ),
);

enum _Step { units, price, paid, fees, date, confirm }

class TradeSheet extends StatefulWidget {
  const TradeSheet({
    super.key,
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
  State<TradeSheet> createState() => _TradeSheetState();
}

class _TradeSheetState extends State<TradeSheet> {
  static const _unitDecimals = 6;
  static const _priceDecimals = 4;

  late _Step _step = _dividend ? _Step.paid : _Step.units;
  bool _forward = true, _reviewing = false, _saving = false;
  String _unitsText = '', _priceText = '', _paidText = '', _feesText = '';

  /// A figure that came pre-filled is replaced by the first key pressed, not
  /// added to.
  bool _priceFresh = false, _paidFresh = false, _paidTyped = false;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  int? _payAccountId;
  String? _error;

  Account get _broker => widget.accounts.byId(widget.holding.accountId)!;
  int get _digits => _broker.digits;
  bool get _dividend => widget.type == TradeType.dividend;
  bool get _buy => widget.type == TradeType.buy;
  bool get _fund => widget.holding.kind == HoldingKind.fund;
  HoldingKind get _kind => widget.holding.kind;

  /// The currency the price is quoted in, when it isn't the account's.
  String? get _ownCurrency {
    final code = widget.holding.currencyIn(_broker.currency);
    return code == _broker.currency ? null : code;
  }

  String get _priceCurrency => _ownCurrency ?? _broker.currency;

  @override
  void initState() {
    super.initState();
    final last = widget.holding.lastPriceE4;
    if (last != null && !_dividend) {
      _priceText = (last / priceScale)
          .toStringAsFixed(4)
          .replaceFirst(RegExp(r'\.?0+$'), '');
      _priceFresh = true;
    }
  }

  // ---- Figures ---------------------------------------------------------------

  int? get _unitsE6 => parseScaled(_unitsText, unitScale);
  int? get _priceE4 => parseScaled(_priceText, priceScale);
  int get _feesMinor => parseAccountAmount(_feesText, _digits) ?? 0;

  /// Units × price in the holding's own currency (foreign holdings only).
  int? get _ownAmountMinor {
    final code = _ownCurrency, units = _unitsE6, price = _priceE4;
    if (code == null || units == null || price == null) return null;
    return tradeAmountMinor(
      unitsE6: units,
      priceE4: price,
      digits: currencyDigits(code),
    );
  }

  /// That, at today's rate, in the account's currency; null without a rate.
  int? get _estimatedMinor {
    final code = _ownCurrency, own = _ownAmountMinor;
    if (code == null || own == null) return null;
    return widget.store.converter?.call(
      own,
      from: code,
      fromDigits: currencyDigits(code),
      to: _broker.currency,
      toDigits: _digits,
    );
  }

  int? get _typedPaidMinor => parseAccountAmount(_paidText, _digits);

  /// What the units cost or fetch before fees, in the account's currency. For
  /// a holding in another currency that is what really left or arrived, so
  /// the person confirms it; it starts from today's rate.
  int? get _amountMinor {
    if (_dividend) return _typedPaidMinor;
    final units = _unitsE6, price = _priceE4;
    if (units == null || price == null || units == 0 || price == 0) return null;
    if (_ownCurrency != null) {
      return _paidTyped || _paidText.isNotEmpty
          ? _typedPaidMinor
          : _estimatedMinor;
    }
    return tradeAmountMinor(unitsE6: units, priceE4: price, digits: _digits);
  }

  bool get _valid => (_amountMinor ?? 0) > 0;

  String _money(int minor) =>
      formatAccountMoney(minor, digits: _digits, currency: _broker.currency);

  String get _unitsLabel {
    final units = _unitsE6;
    if (units == null) return '';
    final text = (units / unitScale)
        .toStringAsFixed(_unitDecimals)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    return '$text ${_kind.unitsAfter(units)}';
  }

  String get _priceLabel {
    final price = _priceE4;
    return price == null ? '' : _formatPrice(price);
  }

  /// A price with 4 places when it needs them; [places] fixes the count, as
  /// for a converted price, which is only ever an estimate.
  String _formatPrice(int price, [String? currency, int? places]) {
    final code = currency ?? _priceCurrency;
    final text = NumberFormat.decimalPatternDigits(
      locale: code == 'INR' ? 'en_IN' : 'en_US',
      decimalDigits:
          places ?? (price % priceScale == 0 ? 0 : (price % 100 == 0 ? 2 : 4)),
    ).format(price / priceScale);
    return '${currencyPrefix(code)} $text';
  }

  /// The price typed, at today's rate in the account's currency, for a holding
  /// priced in another one; null without a rate.
  int? get _convertedPriceE4 {
    final code = _ownCurrency, price = _priceE4;
    if (code == null || price == null || price == 0) return null;
    return widget.store.converter?.call(
      price,
      from: code,
      fromDigits: 4,
      to: _broker.currency,
      toDigits: 4,
    );
  }

  /// Where the last price on record came from.
  String? get _sourceLine =>
      widget.holding.sourceNote ??
      (widget.holding.effectivePriceSource == PriceSourceId.manual
          ? 'Set by hand'
          : null);

  /// Under the price: what it comes to in the account's currency, and the last
  /// close on record.
  String? get _priceHint {
    final converted = _convertedPriceE4;
    final lines = [
      if (converted != null)
        '≈ ${_formatPrice(converted, _broker.currency, 2)} in ${_broker.currency}',
      ?_lastClosedHint,
      if (_lastClosedHint != null) ?_sourceLine,
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// The last close on record, so the price asked for has something to be
  /// compared with.
  String? get _lastClosedHint {
    final last = widget.holding.lastPriceE4;
    if (last == null) return null;
    final day = widget.holding.priceDate;
    return 'Last closed ${_formatPrice(last)}'
        '${day == null ? '' : ' · ${DateFormat('d MMM').format(day)}'}';
  }

  // ---- Wording ----------------------------------------------------------------

  String get _title => switch (widget.type) {
    TradeType.buy => 'Buy',
    TradeType.sell => 'Sell',
    TradeType.dividend => 'Dividend',
  };

  String get _noun => _kind == HoldingKind.metal
      ? 'grams'
      : _fund
      ? 'units'
      : 'shares';

  // ---- Steps ------------------------------------------------------------------

  List<_Step> get _flow => [
    if (!_dividend) ...[_Step.units, _Step.price],
    // A holding in another currency uses today's rate, shown on the check
    // page to correct, and only asks when there is no rate.
    if (_dividend || (_ownCurrency != null && _estimatedMinor == null))
      _Step.paid,
    _Step.date,
    _Step.confirm,
  ];

  void _goTo(_Step step) {
    setState(() {
      _forward = step.index > _step.index;
      _step = step;
      _error = null;
      if (step == _Step.confirm) _reviewing = true;
      if (step == _Step.paid && !_paidTyped && !_dividend) {
        // Opens on today's rate so accepting it is one tap.
        final estimate = _estimatedMinor;
        _paidText = estimate == null
            ? ''
            : AmountTyping.fromMinor(estimate, _digits);
        _paidFresh = estimate != null;
      }
    });
  }

  void _advance() {
    if (_reviewing) return _goTo(_Step.confirm);
    final flow = _flow;
    _goTo(flow[flow.indexOf(_step) + 1]);
  }

  void _back() {
    if (_saving) return;
    if (_step == _Step.fees || (_reviewing && _step != _Step.confirm)) {
      return _goTo(_Step.confirm);
    }
    final flow = _flow;
    final at = flow.indexOf(_step);
    if (at <= 0) {
      Navigator.of(context).pop();
    } else {
      _reviewing = false;
      _goTo(flow[at - 1]);
    }
  }

  bool get _canContinue => switch (_step) {
    _Step.units => (_unitsE6 ?? 0) > 0,
    _Step.price => (_priceE4 ?? 0) > 0,
    _Step.paid => (_typedPaidMinor ?? 0) > 0,
    _ => true,
  };

  // ---- Typing -----------------------------------------------------------------

  void _digit(String d) => setState(() {
    switch (_step) {
      case _Step.units:
        _unitsText = AmountTyping.digit(_unitsText, d, _unitDecimals);
      case _Step.price:
        if (_priceFresh) _priceText = '';
        _priceFresh = false;
        _priceText = AmountTyping.digit(_priceText, d, _priceDecimals);
      case _Step.paid:
        if (_paidFresh) _paidText = '';
        _paidFresh = false;
        _paidTyped = true;
        _paidText = AmountTyping.digit(_paidText, d, _digits);
      case _Step.fees:
        _feesText = AmountTyping.digit(_feesText, d, _digits);
      default:
    }
  });

  void _point() => setState(() {
    switch (_step) {
      case _Step.units:
        _unitsText = AmountTyping.point(_unitsText, _unitDecimals);
      case _Step.price:
        if (_priceFresh) _priceText = '';
        _priceFresh = false;
        _priceText = AmountTyping.point(_priceText, _priceDecimals);
      case _Step.paid:
        if (_paidFresh) _paidText = '';
        _paidFresh = false;
        _paidTyped = true;
        _paidText = AmountTyping.point(_paidText, _digits);
      case _Step.fees:
        _feesText = AmountTyping.point(_feesText, _digits);
      default:
    }
  });

  void _backspace() => setState(() {
    switch (_step) {
      case _Step.units:
        _unitsText = AmountTyping.backspace(_unitsText);
      case _Step.price:
        _priceFresh = false;
        _priceText = AmountTyping.backspace(_priceText);
      case _Step.paid:
        _paidFresh = false;
        _paidTyped = true;
        _paidText = AmountTyping.backspace(_paidText);
      case _Step.fees:
        _feesText = AmountTyping.backspace(_feesText);
      default:
    }
  });

  void _clear() => setState(() {
    switch (_step) {
      case _Step.units:
        _unitsText = '';
      case _Step.price:
        _priceFresh = false;
        _priceText = '';
      case _Step.paid:
        _paidFresh = false;
        _paidTyped = true;
        _paidText = '';
      case _Step.fees:
        _feesText = '';
      default:
    }
  });

  // ---- Save -------------------------------------------------------------------

  Future<void> _save() async {
    final amount = _amountMinor;
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Check the numbers.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.addTrade(
        holding: widget.holding,
        type: widget.type,
        date: _date,
        unitsE6: _dividend ? 0 : _unitsE6!,
        priceE4: _dividend ? 0 : _priceE4!,
        amountMinor: amount,
        feesMinor: _feesMinor,
        payAccountId: _payAccountId,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ArgumentError
              ? '${e.message}'
              : 'Could not save this. Please try again.';
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
        subtitle: _money(broker.balanceMinor),
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
      title: 'Paid from',
      items: items,
      selected: _payAccountId ?? broker.id,
    );
    if (picked != null && mounted) {
      setState(() => _payAccountId = picked == broker.id ? null : picked);
    }
  }

  void _pickDate(DateTime picked) {
    setState(() => _date = DateUtils.dateOnly(picked));
    _advance();
  }

  // ---- Pages ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && _step == _flow.first && !_reviewing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: StepSlider(
      stepKey: _step,
      forward: _forward,
      modal: _reviewing,
      child: switch (_step) {
        _Step.units => _keypad(
          question: 'How many $_noun did you ${widget.type.name}?',
          text: _unitsText,
          display: _unitsText.isEmpty
              ? '0'
              : AmountTyping.display(
                  _unitsText,
                  currency: _broker.currency,
                  decimals: _unitDecimals,
                  showCurrency: false,
                ),
          decimals: _unitDecimals,
        ),
        _Step.price => _keypad(
          question: switch (_kind) {
            HoldingKind.fund => 'At what NAV per unit?',
            HoldingKind.metal => 'At what price per gram?',
            _ => 'At what price per share?',
          },
          summary: _summary([_unitsLabel]),
          text: _priceText,
          display: AmountTyping.display(
            _priceText,
            currency: _priceCurrency,
            decimals: 2,
          ),
          decimals: _priceDecimals,
          hint: _priceHint,
        ),
        _Step.paid => _keypad(
          question: _dividend
              ? 'How much dividend did you receive?'
              : _buy
              ? 'How much did you pay in ${_broker.currency}?'
              : 'How much did you receive in ${_broker.currency}?',
          summary: _dividend
              ? null
              : _summary([
                  '$_unitsLabel at $_priceLabel',
                  if (_ownAmountMinor != null)
                    '= ${formatAccountMoney(_ownAmountMinor!, digits: currencyDigits(_priceCurrency), currency: _priceCurrency)}',
                ]),
          text: _paidText,
          display: AmountTyping.display(
            _paidText,
            currency: _broker.currency,
            decimals: _digits,
          ),
          decimals: _digits,
          hint: _dividend || _estimatedMinor == null
              ? (_dividend ? null : 'No rate yet. Enter what it came to.')
              : _paidTyped
              ? 'Today\'s rate says about ${_money(_estimatedMinor!)}'
              : 'At today\'s rate. Change it to what you really paid.',
        ),
        _Step.fees => _keypad(
          question: 'What were the fees and taxes?',
          summary: _summary(['Brokerage, charges, taxes']),
          text: _feesText,
          display: AmountTyping.display(
            _feesText,
            currency: _broker.currency,
            decimals: _digits,
          ),
          decimals: _digits,
          continueLabel: 'Done',
          allowEmpty: true,
        ),
        _Step.date => DateStepPage(
          header: _title,
          summary: _summary(_lines()),
          question: switch (widget.type) {
            TradeType.buy => 'When did you buy?',
            TradeType.sell => 'When did you sell?',
            TradeType.dividend => 'When did you receive it?',
          },
          date: _date,
          onPick: _pickDate,
          onBack: _back,
          onCancel: () => Navigator.of(context).pop(),
          onContinue: _advance,
        ),
        _Step.confirm => _confirm(context),
      },
    ),
  );

  /// The answers so far, as quiet lines above the question.
  Widget _summary(List<String> lines) => Column(
    children: [
      Text(
        widget.holding.name,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      for (final line in lines.where((l) => l.isNotEmpty))
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            line,
            textAlign: TextAlign.center,
            style: TextStyle(color: SheetColors.of(context).muted),
          ),
        ),
    ],
  );

  List<String> _lines() => _dividend
      ? [_amountMinor == null ? '' : _money(_amountMinor!)]
      : ['$_unitsLabel at $_priceLabel'];

  Widget _keypad({
    required String question,
    required String text,
    required String display,
    required int decimals,
    Widget? summary,
    String? hint,
    String continueLabel = 'Continue',
    bool allowEmpty = false,
  }) => SheetPage(
    startAtBottom: true,
    header: SheetHeader.flow(_title, onBack: _back),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summary ?? _summary(const []),
        const SizedBox(height: 20),
        SheetStepHeading(question),
        const SizedBox(height: 20),
        AmountDisplayCard(amount: display, empty: text.isEmpty),
        if (hint != null) ...[
          const SizedBox(height: 10),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: SheetColors.of(context).muted,
            ),
          ),
        ],
        const SizedBox(height: 20),
        NumberKeypad(
          onDigit: _digit,
          onDecimalPoint: _point,
          onBackspace: _backspace,
          onClear: _clear,
          decimalEnabled: decimals > 0 && !text.contains('.'),
        ),
      ],
    ),
    actions: ActionButtonBar(
      secondaryLabel: 'Cancel',
      onSecondary: () => Navigator.of(context).pop(),
      primaryLabel: continueLabel,
      onPrimary: allowEmpty || _canContinue ? _advance : null,
      primaryColor: SheetColors.of(context).primary,
    ),
  );

  Widget _confirm(BuildContext context) {
    final colors = SheetColors.of(context);
    final amount = _amountMinor;
    final fees = _feesMinor;
    final payer = _payAccountId == null
        ? '${_broker.name} cash'
        : widget.accounts.byId(_payAccountId)?.name ?? _broker.name;
    VoidCallback? edit(VoidCallback onEdit) => _saving ? null : onEdit;
    final total = amount == null
        ? ''
        : _money(_buy ? amount + fees : amount - fees);
    return SheetPage(
      header: SheetHeader.flow(_title, onBack: _back),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetStepHeading(switch (widget.type) {
            TradeType.buy => 'Confirm purchase',
            TradeType.sell => 'Confirm sale',
            TradeType.dividend => 'Confirm dividend',
          }),
          const SizedBox(height: 12),
          AmountHero(
            amount: total,
            caption: _buy ? 'Total paid' : 'You receive',
            color: colors.primary,
          ),
          const SizedBox(height: 16),
          TransactionDetailsCard(
            rows: [
              TransactionDetailRow(
                leading: const SheetIconTile(icon: Icons.show_chart_rounded),
                label: widget.holding.kind.label,
                value: widget.holding.name,
              ),
              if (!_dividend) ...[
                TransactionDetailRow(
                  leading: const SheetIconTile(icon: Icons.pin_outlined),
                  label: _kind.unitsName,
                  value: _unitsLabel.split(' ').first,
                  onTap: edit(() => _goTo(_Step.units)),
                ),
                TransactionDetailRow(
                  leading: const SheetIconTile(icon: Icons.sell_outlined),
                  label: _kind.priceName,
                  value: _priceLabel,
                  onTap: edit(() => _goTo(_Step.price)),
                ),
              ],
              if (_dividend || _ownCurrency != null)
                TransactionDetailRow(
                  leading: const SheetIconTile(icon: Icons.payments_outlined),
                  label: _dividend
                      ? 'Dividend received'
                      : _buy
                      ? 'Amount paid'
                      : 'Amount received',
                  value: amount == null ? '' : _money(amount),
                  onTap: edit(() => _goTo(_Step.paid)),
                ),
              if (!_dividend)
                TransactionDetailRow(
                  leading: const SheetIconTile(
                    icon: Icons.receipt_long_outlined,
                  ),
                  label: _kind == HoldingKind.metal
                      ? 'Making charges and tax'
                      : 'Fees and taxes',
                  value: fees == 0 ? 'None' : _money(fees),
                  placeholder: fees == 0,
                  onTap: edit(() => _goTo(_Step.fees)),
                ),
              if (_buy)
                TransactionDetailRow(
                  leading: const SheetIconTile(
                    icon: Icons.account_balance_wallet_outlined,
                  ),
                  label: 'Paid from',
                  value: payer,
                  onTap: edit(_pickPayer),
                ),
              TransactionDetailRow(
                leading: const SheetIconTile(
                  icon: Icons.calendar_today_rounded,
                ),
                label: 'Date',
                value: formatTransactionDate(_date),
                onTap: edit(() => _goTo(_Step.date)),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _saving ? null : () => Navigator.of(context).pop(),
        primaryLabel: _saving
            ? 'Saving…'
            : switch (widget.type) {
                TradeType.buy => 'Save purchase',
                TradeType.sell => 'Save sale',
                TradeType.dividend => 'Save dividend',
              },
        onPrimary: _saving || !_valid ? null : _save,
        primaryColor: colors.primary,
      ),
    );
  }
}
