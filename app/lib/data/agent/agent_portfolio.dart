import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/account.dart';
import '../../domain/currency_digits.dart';
import '../../domain/holding.dart';
import '../../domain/metal.dart';
import '../db/app_database.dart';
import '../repositories/account_repository.dart';
import '../repositories/holding_repository.dart';
import 'agent_loans.dart' show isKnownIcon;
import 'agent_suggestion_repository.dart';

/// What an AI app can ask to do in the Portfolio. Every one waits for the
/// user's approval and goes through [HoldingRepository], the same code the
/// Portfolio screens use, so cash and units are checked the same way.
///
/// The accounts the holdings sit in (brokers, and in-hand places for gold or
/// a wallet) are added and changed with the account tool.
enum AgentPortfolioAction {
  addHolding('Add holding', 'add_holding'),
  editHolding('Edit holding', 'edit_holding'),
  buy('Buy', 'buy'),
  sell('Sell', 'sell'),
  dividend('Dividend', 'dividend'),
  setPrice('Set price', 'set_price'),
  removeTrade('Remove trade', 'remove_trade'),
  archiveHolding('Archive holding', 'archive_holding'),
  restoreHolding('Restore holding', 'restore_holding'),
  deleteHolding('Delete holding', 'delete_holding');

  const AgentPortfolioAction(this.label, this.toolName);
  final String label;

  /// The name tools use, e.g. `add_holding`.
  final String toolName;

  static AgentPortfolioAction? fromToolName(String? value) =>
      values.where((a) => a.toolName == value).firstOrNull;

  /// Deleting a holding removes its trades for good; the rest can be put
  /// back.
  bool get canUndo => this != deleteHolding;

  bool get isTrade => this == buy || this == sell || this == dividend;
}

/// The fields a portfolio suggestion may set. Null leaves a field as it is.
class AgentPortfolioFields {
  const AgentPortfolioFields({
    this.kind,
    this.name,
    this.symbol,
    this.exchange,
    this.priceSource,
    this.currency,
    this.metal,
    this.purity,
    this.icon,
    this.units,
    this.price,
    this.amount,
    this.fees,
    this.date,
    this.payFromAccountId,
    this.note,
  });
  final HoldingKind? kind;
  final String? name, symbol, exchange, priceSource, currency, icon, note;

  /// For a metal: gold, silver, platinum or palladium, and its purity as
  /// the app reads it ("22K", "916").
  final String? metal, purity;

  /// Decimal strings: units held, the price of one unit (in the holding's
  /// currency), and what it came to in the account's currency (when the
  /// holding is priced in another currency, or to override units × price).
  final String? units, price, amount, fees;
  final DateTime? date;
  final int? payFromAccountId;
}

class AgentPortfolio {
  AgentPortfolio(this.database);
  final AppDatabase database;

  HoldingRepository get _holdings => HoldingRepository(database);

  Future<AgentSuggestionDraft> prepare({
    required AgentPortfolioAction action,
    int? accountId,
    int? holdingId,
    int? tradeId,
    AgentPortfolioFields fields = const AgentPortfolioFields(),
    String? reason,
  }) async {
    final accounts = await AccountRepository(database).load();
    final holdings = await _holdings.loadHoldings();
    final trades = await _holdings.loadTrades();

    Account account(int? id, String role) {
      if (id == null) throw ArgumentError('Give $role.');
      return accounts.where((a) => a.id == id).firstOrNull ??
          (throw ArgumentError('There is no account $id. See list_accounts.'));
    }

    Account broker(int? id) {
      final a = account(id, 'account_id (the broker or place)');
      if (!a.isBroker) {
        throw ArgumentError(
          '“${a.name}” is not an investment account. Holdings go under a '
          'broker or an in-hand place: see list_portfolio, or add one with '
          'suggest_account_changes (place).',
        );
      }
      if (a.isArchived) {
        throw ArgumentError('“${a.name}” is archived; restore it first.');
      }
      return a;
    }

    Holding holdingOf(int? id) {
      if (id == null)
        throw ArgumentError('Give holding_id. See list_portfolio.');
      return holdings.where((h) => h.id == id).firstOrNull ??
          (throw ArgumentError('There is no holding $id. See list_portfolio.'));
    }

    final payload = <String, Object?>{'action': action.toolName};
    final detail = <String>[];
    late final String target;
    late final String summary;

    switch (action) {
      case AgentPortfolioAction.addHolding:
        final place = broker(accountId);
        final kind = fields.kind ?? (throw ArgumentError('Give kind.'));
        if (!HoldingKind.selectable.contains(kind)) {
          throw ArgumentError(
            'kind must be stock, etf, fund, crypto or metal.',
          );
        }
        final name = _name(fields.name);
        String? symbol = _clean(fields.symbol);
        String? meta;
        String? priceSource = _source(fields.priceSource);
        String? currency = _currency(fields.currency, place);
        if (kind == HoldingKind.metal) {
          final type = MetalType.values
              .where((m) => m.id == fields.metal?.trim().toLowerCase())
              .firstOrNull;
          if (type == null) {
            throw ArgumentError(
              'Give metal: ${MetalType.values.map((m) => m.id).join(', ')}.',
            );
          }
          final fineness = fields.purity == null
              ? type.defaultPurity
              : (type.parsePurity(fields.purity!) ??
                    (throw ArgumentError(
                      'purity must be like 22K, or 916 (parts per thousand).',
                    )));
          final details = MetalDetails(metal: type, fineness: fineness);
          symbol = details.symbol;
          meta = jsonEncode({
            ...details.toJson(),
            if (_icon(fields.icon) case final icon?) 'icon': icon,
          });
          priceSource ??= PriceSourceId.metalWorld;
          // Metal is bought in the account's own currency.
          currency = null;
        } else {
          if (symbol == null) {
            throw ArgumentError(
              'Give symbol (find it with find_security): a ticker, an AMFI '
              'scheme code or a CoinGecko id.',
            );
          }
          if (_icon(fields.icon) case final icon?) {
            meta = jsonEncode({'icon': icon});
          }
        }
        priceSource ??= PriceSourceId.infer(kind, symbol);
        if (holdings.any(
          (h) =>
              h.accountId == place.id &&
              h.symbol?.toLowerCase() == symbol!.toLowerCase(),
        )) {
          throw ArgumentError(
            '“$name” is already in ${place.name}. Use buy or sell on it.',
          );
        }
        final exchange = _clean(fields.exchange);
        payload.addAll({
          'accountId': place.id,
          'kind': kind.name,
          'name': name,
          'symbol': symbol,
          'exchange': exchange,
          'priceSource': priceSource,
          'currency': currency == place.currency ? null : currency,
          'meta': meta,
        });
        target = 'new:${place.id}:${symbol.toLowerCase()}';
        summary = '${action.label} · $name';
        detail.addAll([
          '${kind.label} in ${place.name}',
          'Symbol $symbol${exchange == null ? '' : ' · $exchange'}',
        ]);
        final holding = Holding(
          id: -1,
          accountId: place.id,
          kind: kind,
          name: name,
          symbol: symbol,
          exchange: exchange,
          priceSource: priceSource,
          meta: meta,
          currency: currency == place.currency ? null : currency,
        );
        var position = positionOf(const [], digits: place.digits);
        int? priceE4;
        // An opening purchase, so the holding starts with what is owned.
        if (fields.units != null || fields.price != null) {
          final trade = _trade(
            type: TradeType.buy,
            holding: holding,
            place: place,
            accounts: accounts,
            fields: fields,
            detail: detail,
          );
          payload['buy'] = trade.json;
          position = positionOf([trade.trade], digits: place.digits);
          priceE4 = trade.trade.priceE4;
        }
        payload['view'] = _view(holding, place, position, priceE4);

      case AgentPortfolioAction.editHolding:
        final holding = holdingOf(holdingId);
        final place = broker(holding.accountId);
        final name = fields.name == null ? null : _name(fields.name);
        final symbol = _clean(fields.symbol);
        final exchange = fields.exchange == null
            ? null
            : fields.exchange!.trim();
        final priceSource = _source(fields.priceSource);
        final icon = _icon(fields.icon);
        void change(String label, Object? before, Object? after) {
          if (after != null && after != before) {
            detail.add('$label: ${before ?? '—'} → $after');
          }
        }

        change('Name', holding.name, name);
        change('Symbol', holding.symbol, symbol);
        change('Exchange', holding.exchange, exchange);
        change('Price from', holding.priceSource, priceSource);
        if (icon != null && icon != holding.iconKey) detail.add('New icon');
        if (detail.isEmpty) {
          throw ArgumentError('Nothing to change on “${holding.name}”.');
        }
        String? meta;
        if (icon != null) {
          final current = _metaMap(holding.meta);
          current['icon'] = icon;
          meta = jsonEncode(current);
        }
        payload.addAll({
          'holdingId': holding.id,
          'name': ?name,
          'symbol': ?symbol,
          'exchange': ?exchange,
          'priceSource': ?priceSource,
          'meta': ?meta,
        });
        target = 'holding:${holding.id}:edit';
        summary = '${action.label} · ${holding.name}';
        final edited = Holding(
          id: holding.id,
          accountId: holding.accountId,
          kind: holding.kind,
          name: name ?? holding.name,
          symbol: symbol ?? holding.symbol,
          exchange: exchange ?? holding.exchange,
          lastPriceE4: holding.lastPriceE4,
          priceDate: holding.priceDate,
          priceSource: priceSource ?? holding.priceSource,
          meta: meta ?? holding.meta,
          currency: holding.currency,
        );
        payload['view'] = _view(
          edited,
          place,
          _position(trades, holding.id, place.digits),
          null,
        );

      case AgentPortfolioAction.buy ||
          AgentPortfolioAction.sell ||
          AgentPortfolioAction.dividend:
        final holding = holdingOf(holdingId);
        final place = broker(holding.accountId);
        final type = switch (action) {
          AgentPortfolioAction.buy => TradeType.buy,
          AgentPortfolioAction.sell => TradeType.sell,
          _ => TradeType.dividend,
        };
        final before = _position(trades, holding.id, place.digits);
        final made = _trade(
          type: type,
          holding: holding,
          place: place,
          accounts: accounts,
          fields: fields,
          detail: detail,
        );
        if (type == TradeType.sell && made.trade.unitsE6 > before.unitsE6) {
          throw ArgumentError(
            'That sells more than the ${formatUnits(before.unitsE6)} held in '
            '“${holding.name}”.',
          );
        }
        final position = positionOf([
          ...trades.where((t) => t.holdingId == holding.id),
          made.trade,
        ], digits: place.digits);
        payload
          ..['holdingId'] = holding.id
          ..['trade'] = made.json;
        target =
            'holding:${holding.id}:${type.name}:${made.trade.date.millisecondsSinceEpoch}:${made.trade.unitsE6}';
        summary = '${action.label} · ${holding.name}';
        payload['view'] = _view(
          holding,
          place,
          position,
          type == TradeType.dividend ? null : made.trade.priceE4,
        );

      case AgentPortfolioAction.setPrice:
        final holding = holdingOf(holdingId);
        final place = broker(holding.accountId);
        final price = _scaled(fields.price, priceScale, 'price');
        final date = _day(fields.date ?? DateTime.now());
        if (price == holding.lastPriceE4) {
          throw ArgumentError('“${holding.name}” already has that price.');
        }
        final code = holding.currencyIn(place.currency);
        detail.add(
          '${holding.lastPriceE4 == null ? 'No price' : _price(holding.lastPriceE4!, code)} → ${_price(price, code)}',
        );
        payload
          ..['holdingId'] = holding.id
          ..['priceE4'] = price
          ..['date'] = date.millisecondsSinceEpoch;
        target = 'holding:${holding.id}:price';
        summary = '${action.label} · ${holding.name}';
        payload['view'] = _view(
          holding,
          place,
          _position(trades, holding.id, place.digits),
          price,
        );

      case AgentPortfolioAction.removeTrade:
        final trade =
            trades.where((t) => t.id == tradeId).firstOrNull ??
            (throw ArgumentError(
              'There is no trade ${tradeId ?? ''}. See list_portfolio with '
              'holding_id.',
            ));
        final holding = holdingOf(trade.holdingId);
        final place = broker(holding.accountId);
        final rest = trades.where(
          (t) => t.holdingId == holding.id && t.id != trade.id,
        );
        _checkNeverNegative(rest);
        payload
          ..['tradeId'] = trade.id
          ..['holdingId'] = holding.id
          ..['trade'] = _tradeJson(trade);
        target = 'trade:${trade.id}:remove';
        summary = '${action.label} · ${holding.name}';
        detail.add(
          '${trade.type.label} ${trade.type == TradeType.dividend ? '' : '${formatUnits(trade.unitsE6)} '}'
          'on ${_dayText(trade.date)} · '
          '${_money(trade.amountMinor, place)}',
        );
        detail.add('Its cash goes back to where it came from');
        payload['view'] = _view(
          holding,
          place,
          positionOf(rest, digits: place.digits),
          null,
        );

      case AgentPortfolioAction.archiveHolding ||
          AgentPortfolioAction.restoreHolding:
        final holding = holdingOf(holdingId);
        final place = broker(holding.accountId);
        final archiving = action == AgentPortfolioAction.archiveHolding;
        if ((holding.archivedAt != null) == archiving) {
          throw ArgumentError(
            '“${holding.name}” is ${archiving ? 'already' : 'not'} archived.',
          );
        }
        payload['holdingId'] = holding.id;
        target = 'holding:${holding.id}:archive';
        summary = '${action.label} · ${holding.name}';
        detail.add(
          archiving
              ? 'Hidden from the portfolio and totals; its trades are kept'
              : 'Back in the portfolio and totals',
        );
        payload['view'] = _view(
          holding,
          place,
          _position(trades, holding.id, place.digits),
          null,
        );

      case AgentPortfolioAction.deleteHolding:
        final holding = holdingOf(holdingId);
        final place = broker(holding.accountId);
        final count = trades.where((t) => t.holdingId == holding.id).length;
        payload['holdingId'] = holding.id;
        target = 'holding:${holding.id}:delete';
        summary = '${action.label} · ${holding.name}';
        detail.addAll([
          '$count ${count == 1 ? 'trade is' : 'trades are'} deleted with it',
          'Their cash goes back to where it came from',
        ]);
        payload['view'] = _view(
          holding,
          place,
          _position(trades, holding.id, place.digits),
          null,
        );
    }

    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.portfolio,
      target: target,
      payload: payload,
      summary: summary,
      detail: detail,
      reason: switch (reason?.trim()) {
        null || '' => null,
        final r when r.length > 280 => '${r.substring(0, 279)}…',
        final r => r,
      },
    );
  }

  // ── Applying. ──

  /// Carries out an approved suggestion. Returns what undoing needs.
  Future<Map<String, Object?>> apply(Map<String, Object?> p) async {
    final action = AgentPortfolioAction.fromToolName(p['action'] as String?)!;
    switch (action) {
      case AgentPortfolioAction.addHolding:
        final id = await _holdings.saveHolding(
          accountId: p['accountId'] as int,
          kind: HoldingKind.values.byName(p['kind'] as String),
          name: p['name'] as String,
          symbol: p['symbol'] as String?,
          exchange: p['exchange'] as String?,
          priceSource: p['priceSource'] as String?,
          currency: p['currency'] as String?,
          meta: p['meta'] as String?,
        );
        int? tradeId;
        if (p['buy'] case final Map buy) {
          tradeId = await _addTrade(id, Map<String, Object?>.from(buy));
        }
        return {'holdingId': id, 'tradeId': ?tradeId};

      case AgentPortfolioAction.editHolding:
        final before = await _holding(p['holdingId'] as int);
        await _holdings.saveHolding(
          existing: before,
          accountId: before.accountId,
          kind: before.kind,
          name: p['name'] as String? ?? before.name,
          symbol: p.containsKey('symbol')
              ? p['symbol'] as String?
              : before.symbol,
          exchange: p.containsKey('exchange')
              ? p['exchange'] as String?
              : before.exchange,
          priceSource: p['priceSource'] as String?,
          meta: p['meta'] as String?,
        );
        return {
          'holdingId': before.id,
          'previous': {
            'name': before.name,
            'symbol': before.symbol,
            'exchange': before.exchange,
            'priceSource': before.priceSource,
            'meta': before.meta,
          },
        };

      case AgentPortfolioAction.buy ||
          AgentPortfolioAction.sell ||
          AgentPortfolioAction.dividend:
        final id = p['holdingId'] as int;
        final tradeId = await _addTrade(
          id,
          Map<String, Object?>.from(p['trade'] as Map),
        );
        return {'holdingId': id, 'tradeId': tradeId};

      case AgentPortfolioAction.setPrice:
        final before = await _holding(p['holdingId'] as int);
        await _holdings.setPrice(
          before.id,
          p['priceE4'] as int,
          DateTime.fromMillisecondsSinceEpoch(p['date'] as int),
          overwrite: true,
        );
        return {
          'holdingId': before.id,
          'priceE4': before.lastPriceE4,
          'date': before.priceDate?.millisecondsSinceEpoch,
        };

      case AgentPortfolioAction.removeTrade:
        await _holdings.deleteTrade(p['tradeId'] as int);
        return {'holdingId': p['holdingId'], 'trade': p['trade']};

      case AgentPortfolioAction.archiveHolding:
        await _holdings.archive(p['holdingId'] as int, archived: true);
        return {'holdingId': p['holdingId']};

      case AgentPortfolioAction.restoreHolding:
        await _holdings.archive(p['holdingId'] as int, archived: false);
        return {'holdingId': p['holdingId']};

      case AgentPortfolioAction.deleteHolding:
        await _holdings.deleteHolding(p['holdingId'] as int);
        return {};
    }
  }

  /// Puts back what [apply] changed, from what it returned.
  Future<void> undo(String actionName, Map<String, Object?> before) async {
    final action = AgentPortfolioAction.fromToolName(actionName);
    switch (action) {
      case AgentPortfolioAction.addHolding:
        // Only while nothing else was recorded on it since.
        final id = before['holdingId'] as int;
        final ours = before['tradeId'] as int?;
        final others = (await _holdings.loadTrades()).where(
          (t) => t.holdingId == id && t.id != ours,
        );
        if (others.isNotEmpty) {
          throw StateError(
            'Trades were recorded on this holding since. Delete it from its '
            'own screen.',
          );
        }
        await _holdings.deleteHolding(id);
      case AgentPortfolioAction.editHolding:
        final current = await _holding(before['holdingId'] as int);
        final previous = Map<String, Object?>.from(before['previous'] as Map);
        await _holdings.saveHolding(
          existing: current,
          accountId: current.accountId,
          kind: current.kind,
          name: previous['name'] as String,
          symbol: previous['symbol'] as String?,
          exchange: previous['exchange'] as String?,
          priceSource: previous['priceSource'] as String?,
          meta: previous['meta'] as String?,
        );
      case AgentPortfolioAction.buy ||
          AgentPortfolioAction.sell ||
          AgentPortfolioAction.dividend:
        await _holdings.deleteTrade(before['tradeId'] as int);
      case AgentPortfolioAction.setPrice:
        await database.customUpdate(
          'UPDATE holdings SET last_price_e4 = ?, price_date = ? WHERE id = ?',
          variables: [
            Variable(before['priceE4'] as int?),
            Variable(switch (before['date'] as int?) {
              final ms? => _dayKey(DateTime.fromMillisecondsSinceEpoch(ms)),
              null => null,
            }),
            Variable(before['holdingId'] as int),
          ],
        );
      case AgentPortfolioAction.removeTrade:
        await _addTrade(
          before['holdingId'] as int,
          Map<String, Object?>.from(before['trade'] as Map),
        );
      case AgentPortfolioAction.archiveHolding:
        await _holdings.archive(before['holdingId'] as int, archived: false);
      case AgentPortfolioAction.restoreHolding:
        await _holdings.archive(before['holdingId'] as int, archived: true);
      case AgentPortfolioAction.deleteHolding || null:
        throw StateError('This change can’t be undone.');
    }
  }

  // ── Helpers. ──

  Future<Holding> _holding(int id) async =>
      (await _holdings.loadHoldings()).where((h) => h.id == id).firstOrNull ??
      (throw StateError('This holding no longer exists.'));

  /// Records a trade, and for a buy at a price the price too, the way the
  /// Portfolio screen does (a market-priced holding keeps its market price).
  Future<int> _addTrade(int holdingId, Map<String, Object?> t) async {
    final holding = await _holding(holdingId);
    final type = TradeType.values.byName(t['type'] as String);
    final date = DateTime.fromMillisecondsSinceEpoch(t['date'] as int);
    final priceE4 = t['priceE4'] as int;
    final id = await _holdings.addTrade(
      holdingId: holdingId,
      type: type,
      date: date,
      unitsE6: t['unitsE6'] as int,
      priceE4: priceE4,
      amountMinor: t['amountMinor'] as int,
      feesMinor: t['feesMinor'] as int? ?? 0,
      payAccountId: t['payAccountId'] as int?,
      note: t['note'] as String?,
    );
    final source = holding.effectivePriceSource;
    final marketPriced =
        (holding.symbol?.trim().isNotEmpty ?? false) &&
        source != null &&
        source != PriceSourceId.manual;
    if (type != TradeType.dividend &&
        priceE4 > 0 &&
        !(marketPriced && holding.lastPriceE4 != null)) {
      await _holdings.setPrice(holdingId, priceE4, date);
    }
    return id;
  }

  /// Checks a trade and describes it. The amount is units × price in the
  /// account's currency, or [AgentPortfolioFields.amount] when the holding is
  /// priced in another currency.
  ({HoldingTrade trade, Map<String, Object?> json}) _trade({
    required TradeType type,
    required Holding holding,
    required Account place,
    required List<Account> accounts,
    required AgentPortfolioFields fields,
    required List<String> detail,
  }) {
    final dividend = type == TradeType.dividend;
    final date = _day(fields.date ?? DateTime.now());
    final fees = _minor(fields.fees, place.digits, 'fees') ?? 0;
    final code = holding.currencyIn(place.currency);
    int unitsE6 = 0, priceE4 = 0;
    if (!dividend) {
      unitsE6 = _scaled(fields.units, unitScale, 'units');
      priceE4 = _scaled(fields.price, priceScale, 'price');
    }
    var amount = _minor(fields.amount, place.digits, 'amount');
    if (amount == null) {
      if (dividend) {
        throw ArgumentError('Give amount: the dividend received.');
      }
      if (code != place.currency) {
        throw ArgumentError(
          '“${holding.name}” is priced in $code, so give amount: what it '
          'came to in ${place.currency}.',
        );
      }
      amount = tradeAmountMinor(
        unitsE6: unitsE6,
        priceE4: priceE4,
        digits: place.digits,
      );
    }
    if (amount <= 0) throw ArgumentError('That comes to nothing.');
    int? payFrom;
    if (type == TradeType.buy && fields.payFromAccountId != null) {
      final payer = accounts
          .where((a) => a.id == fields.payFromAccountId)
          .firstOrNull;
      if (payer == null || payer.isBroker || payer.isArchived) {
        throw ArgumentError(
          'pay_from_account_id must be one of the user’s bank, card or cash '
          'accounts. See list_accounts.',
        );
      }
      if (payer.currency != place.currency || payer.digits != place.digits) {
        throw ArgumentError(
          'Pay from an account in ${place.currency}, the broker’s currency.',
        );
      }
      payFrom = payer.id == place.id ? null : payer.id;
    }
    final trade = HoldingTrade(
      id: 0,
      holdingId: holding.id,
      type: type,
      date: date,
      unitsE6: unitsE6,
      priceE4: priceE4,
      amountMinor: amount,
      feesMinor: fees,
      payAccountId: payFrom,
      note: _clean(fields.note),
    );
    if (dividend) {
      detail.add('${_money(amount, place)} received on ${_dayText(date)}');
    } else {
      detail.add(
        '${type.label} ${formatUnits(unitsE6)} '
        '${holding.kind == HoldingKind.metal ? 'g' : 'units'} at '
        '${_price(priceE4, code)} on ${_dayText(date)}',
      );
      detail.add(
        'Comes to ${_money(amount, place)}'
        '${fees > 0 ? ' + ${_money(fees, place)} fees' : ''}',
      );
    }
    final from = payFrom == null
        ? '${place.name} funds'
        : accounts.firstWhere((a) => a.id == payFrom).name;
    final cash = trade.cashEffectMinor;
    if (type == TradeType.buy) {
      detail.add('Paid from $from');
    } else {
      detail.add('${_money(cash, place)} goes into ${place.name} funds');
    }
    return (trade: trade, json: _tradeJson(trade));
  }

  static Map<String, Object?> _tradeJson(HoldingTrade t) => {
    'type': t.type.name,
    'date': t.date.millisecondsSinceEpoch,
    'unitsE6': t.unitsE6,
    'priceE4': t.priceE4,
    'amountMinor': t.amountMinor,
    'feesMinor': t.feesMinor,
    'payAccountId': t.payAccountId,
    'note': t.note,
  };

  static HoldingPosition _position(
    List<HoldingTrade> trades,
    int holdingId,
    int digits,
  ) =>
      positionOf(trades.where((t) => t.holdingId == holdingId), digits: digits);

  /// What the preview card needs to draw the holding as the app does, so it
  /// never has to load the stores.
  static Map<String, Object?> _view(
    Holding h,
    Account place,
    HoldingPosition position,
    int? priceE4,
  ) {
    final price = priceE4 ?? h.lastPriceE4;
    return {
      'name': h.name,
      'kind': h.kind.name,
      'symbol': h.symbol,
      'exchange': h.exchange,
      'priceSource': h.priceSource,
      'meta': h.meta,
      'currency': h.currencyIn(place.currency),
      'brokerName': place.name,
      'brokerCurrency': place.currency,
      'digits': place.digits,
      'unitsE6': position.unitsE6,
      'costMinor': position.costMinor,
      'priceE4': price,
      'archived': h.archivedAt != null,
    };
  }

  static void _checkNeverNegative(Iterable<HoldingTrade> trades) {
    final ordered = trades.toList()
      ..sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    var units = 0;
    for (final t in ordered) {
      if (t.type == TradeType.buy) units += t.unitsE6;
      if (t.type == TradeType.sell) units -= t.unitsE6;
      if (units < 0) {
        throw ArgumentError(
          'Removing that would leave a later sale selling units that were '
          'never bought.',
        );
      }
    }
  }

  static Map<String, Object?> _metaMap(String? meta) {
    if (meta == null) return {};
    try {
      return Map<String, Object?>.from(jsonDecode(meta) as Map);
    } catch (_) {
      return {};
    }
  }

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  static String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  static String _dayText(DateTime t) => _dayKey(t);

  static String _name(String? value) {
    final clean = value?.trim() ?? '';
    if (clean.isEmpty || clean.length > 60) {
      throw ArgumentError('Give a name of 1–60 characters.');
    }
    return clean;
  }

  static String? _clean(String? value) {
    final clean = value?.trim() ?? '';
    return clean.isEmpty ? null : clean;
  }

  static String? _currency(String? value, Account place) {
    final code = value?.trim().toUpperCase();
    if (code == null || code.isEmpty) return null;
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
      throw ArgumentError('currency must be a 3-letter code such as USD.');
    }
    return code;
  }

  static String? _source(String? value) {
    final clean = value?.trim().toLowerCase();
    if (clean == null || clean.isEmpty) return null;
    const known = [
      PriceSourceId.yahoo,
      PriceSourceId.amfi,
      PriceSourceId.coingecko,
      PriceSourceId.metalWorld,
      PriceSourceId.manual,
    ];
    if (!known.contains(clean)) {
      throw ArgumentError('price_source must be one of: ${known.join(', ')}.');
    }
    return clean;
  }

  static String? _icon(String? key) {
    final clean = key?.trim();
    if (clean == null || clean.isEmpty) return null;
    if (!isKnownIcon(clean)) {
      throw ArgumentError('Unknown icon “$clean”. Pick one from list_icons.');
    }
    return clean;
  }

  static int _scaled(String? value, int scale, String field) =>
      (value == null ? null : parseScaled(value, scale)) ??
      (throw ArgumentError(
        '$field must be a positive number like 12.5'
        '${scale == unitScale ? ' (up to 6 decimals)' : ' (up to 4 decimals)'}.',
      ));

  static int? _minor(String? value, int digits, String field) {
    if (value == null) return null;
    final minor = parseAccountAmount(value.replaceAll(',', ''), digits);
    if (minor == null || minor < 0) {
      throw ArgumentError('$field must be an amount like 1250.00.');
    }
    return minor;
  }

  static String _money(int minor, Account a) =>
      formatAccountMoney(minor, digits: a.digits, currency: a.currency);

  /// A unit price in its own currency, without trailing zeros.
  static String _price(int priceE4, String currency) {
    final digits = currencyDigitsOtherThanTwo[currency] ?? 2;
    var text = (priceE4 / priceScale).toStringAsFixed(4);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    final dot = text.indexOf('.');
    if (dot >= 0 && text.length - dot - 1 < digits) {
      text = (priceE4 / priceScale).toStringAsFixed(digits);
    }
    return '$text $currency';
  }
}
