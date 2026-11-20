import 'package:drift/drift.dart';

import '../../domain/holding.dart';
import '../db/app_database.dart';

/// Holdings under a broker, and the trades that move cash in and out of the
/// broker (or the bank a buy was paid from). Every trade changes a balance in
/// the same database transaction, so cash and units never disagree.
class HoldingRepository {
  HoldingRepository(this.database);
  final AppDatabase database;

  Future<List<Holding>> loadHoldings() async =>
      (await database
              .customSelect('SELECT * FROM holdings ORDER BY name COLLATE NOCASE, id')
              .get())
          .map(
            (r) => Holding(
              id: r.read<int>('id'),
              accountId: r.read<int>('account_id'),
              kind: HoldingKind.values.byName(r.read<String>('kind')),
              name: r.read<String>('name'),
              symbol: r.readNullable<String>('symbol'),
              exchange: r.readNullable<String>('exchange'),
              lastPriceE4: r.readNullable<int>('last_price_e4'),
              priceDate: switch (r.readNullable<String>('price_date')) {
                final d? => DateTime.tryParse(d),
                null => null,
              },
              archivedAt: switch (r.readNullable<int>('archived_at')) {
                final at? => DateTime.fromMillisecondsSinceEpoch(at),
                null => null,
              },
            ),
          )
          .toList();

  Future<List<HoldingTrade>> loadTrades() async =>
      (await database
              .customSelect('SELECT * FROM holding_trades ORDER BY date, id')
              .get())
          .map(
            (r) => HoldingTrade(
              id: r.read<int>('id'),
              holdingId: r.read<int>('holding_id'),
              type: TradeType.values.byName(r.read<String>('type')),
              date: DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
              unitsE6: r.read<int>('units_e6'),
              priceE4: r.read<int>('price_e4'),
              amountMinor: r.read<int>('amount_minor'),
              feesMinor: r.read<int>('fees_minor'),
              payAccountId: r.readNullable<int>('pay_account_id'),
              note: r.readNullable<String>('note'),
            ),
          )
          .toList();

  Future<int> saveHolding({
    Holding? existing,
    required int accountId,
    required HoldingKind kind,
    required String name,
    String? symbol,
    String? exchange,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 60) {
      throw ArgumentError('Enter a name of 1–60 characters.');
    }
    final cleanSymbol = symbol?.trim().isEmpty ?? true ? null : symbol!.trim();
    final cleanExchange = exchange?.trim().isEmpty ?? true
        ? null
        : exchange!.trim();
    if (existing != null) {
      await database.customUpdate(
        'UPDATE holdings SET kind = ?, name = ?, symbol = ?, exchange = ? WHERE id = ?',
        variables: [
          Variable(kind.name),
          Variable(clean),
          Variable(cleanSymbol),
          Variable(cleanExchange),
          Variable(existing.id),
        ],
      );
      return existing.id;
    }
    final broker = await database
        .customSelect(
          'SELECT broker FROM accounts WHERE id = ?',
          variables: [Variable(accountId)],
        )
        .getSingleOrNull();
    if (broker == null || broker.read<int>('broker') == 0) {
      throw ArgumentError('Holdings can only be added under a broker.');
    }
    return database.customInsert(
      '''INSERT INTO holdings (id, account_id, kind, name, symbol, exchange)
         VALUES (${newRowId('holdings')}, ?, ?, ?, ?, ?)''',
      variables: [
        Variable(accountId),
        Variable(kind.name),
        Variable(clean),
        Variable(cleanSymbol),
        Variable(cleanExchange),
      ],
    );
  }

  /// Stores the last close for [holdingId]. An older price never replaces a
  /// newer one, so a slow response can't move a holding backwards in time.
  Future<void> setPrice(int holdingId, int priceE4, DateTime date) async {
    final day = _day(date);
    await database.customUpdate(
      '''UPDATE holdings SET last_price_e4 = ?, price_date = ?
         WHERE id = ? AND (price_date IS NULL OR price_date <= ?)''',
      variables: [
        Variable(priceE4),
        Variable(day),
        Variable(holdingId),
        Variable(day),
      ],
    );
  }

  static String _day(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  Future<void> archive(int id, {required bool archived}) =>
      database.customUpdate(
        'UPDATE holdings SET archived_at = ? WHERE id = ?',
        variables: [
          Variable(archived ? DateTime.now().millisecondsSinceEpoch : null),
          Variable(id),
        ],
      );

  /// Records a trade and moves its cash. A buy leaves the account it was paid
  /// from (the broker's cash unless [payAccountId] names another); a sell or
  /// dividend adds to the broker's cash.
  Future<int> addTrade({
    required int holdingId,
    required TradeType type,
    required DateTime date,
    required int unitsE6,
    required int priceE4,
    required int amountMinor,
    int feesMinor = 0,
    int? payAccountId,
    String? note,
  }) => database.transaction(() async {
    if (amountMinor <= 0 || feesMinor < 0) {
      throw ArgumentError('Enter an amount above zero.');
    }
    if (type != TradeType.dividend && unitsE6 <= 0) {
      throw ArgumentError('Enter the number of units.');
    }
    final holding = await _holding(holdingId);
    final broker = await _account(holding.accountId);
    final payer = type == TradeType.buy && payAccountId != null
        ? await _account(payAccountId)
        : broker;
    if (payer.currency != broker.currency || payer.digits != broker.digits) {
      throw ArgumentError(
        'Pay from an account in ${broker.currency}, the broker’s currency.',
      );
    }
    final trade = HoldingTrade(
      id: 0,
      holdingId: holdingId,
      type: type,
      date: date,
      unitsE6: type == TradeType.dividend ? 0 : unitsE6,
      priceE4: priceE4,
      amountMinor: amountMinor,
      feesMinor: feesMinor,
      payAccountId: payer.id == broker.id ? null : payer.id,
      note: note,
    );
    final existing = await loadTrades().then(
      (all) => all.where((t) => t.holdingId == holdingId).toList(),
    );
    _checkNeverNegative([...existing, trade]);
    final id = await database.customInsert(
      '''INSERT INTO holding_trades
         (id, holding_id, type, date, units_e6, price_e4, amount_minor,
          fees_minor, pay_account_id, note)
         VALUES (${newRowId('holding_trades')}, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      variables: [
        Variable(holdingId),
        Variable(type.name),
        Variable(date.millisecondsSinceEpoch),
        Variable(trade.unitsE6),
        Variable(priceE4),
        Variable(amountMinor),
        Variable(feesMinor),
        Variable(trade.payAccountId),
        Variable(note?.trim().isEmpty ?? true ? null : note!.trim()),
      ],
    );
    await _moveCash(payer.id, trade.cashEffectMinor);
    return id;
  });

  /// Removes a trade and gives its cash back, unless that would leave a later
  /// sell selling units that were never bought.
  Future<void> deleteTrade(int id) => database.transaction(() async {
    final all = await loadTrades();
    final trade = all.where((t) => t.id == id).firstOrNull;
    if (trade == null) return;
    final holding = await _holding(trade.holdingId);
    _checkNeverNegative(
      all.where((t) => t.holdingId == trade.holdingId && t.id != id),
    );
    await database.customUpdate(
      'DELETE FROM holding_trades WHERE id = ?',
      variables: [Variable(id)],
    );
    await _moveCash(
      trade.payAccountId ?? holding.accountId,
      -trade.cashEffectMinor,
    );
  });

  /// Removes a holding with all its trades, giving every trade's cash back.
  Future<void> deleteHolding(int id) => database.transaction(() async {
    final holding = await _holding(id);
    final trades = (await loadTrades()).where((t) => t.holdingId == id);
    for (final trade in trades) {
      await _moveCash(
        trade.payAccountId ?? holding.accountId,
        -trade.cashEffectMinor,
      );
    }
    await database.customUpdate(
      'DELETE FROM holding_trades WHERE holding_id = ?',
      variables: [Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM holdings WHERE id = ?',
      variables: [Variable(id)],
    );
  });

  /// Replays [trades] and throws if units ever go below zero.
  void _checkNeverNegative(Iterable<HoldingTrade> trades) {
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
        throw ArgumentError('That would sell more units than were held.');
      }
    }
  }

  Future<void> _moveCash(int accountId, int deltaMinor) => database.customUpdate(
    'UPDATE accounts SET balance_minor = balance_minor + ? WHERE id = ?',
    variables: [Variable(deltaMinor), Variable(accountId)],
  );

  Future<Holding> _holding(int id) async {
    final all = await loadHoldings();
    final found = all.where((h) => h.id == id).firstOrNull;
    if (found == null) throw StateError('This holding no longer exists.');
    return found;
  }

  Future<({int id, String currency, int digits})> _account(int id) async {
    final row = await database
        .customSelect(
          'SELECT id, currency, digits FROM accounts WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('This account no longer exists.');
    return (
      id: id,
      currency: row.read<String>('currency'),
      digits: row.read<int>('digits'),
    );
  }
}
