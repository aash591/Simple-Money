import 'package:flutter/widgets.dart';

import '../data/prices/price_service.dart';
import '../data/repositories/holding_repository.dart';
import '../domain/account.dart';
import '../domain/holding.dart';
import 'account_store.dart';

class HoldingStoreScope extends InheritedNotifier<HoldingStore> {
  const HoldingStoreScope({
    super.key,
    required HoldingStore store,
    required super.child,
  }) : super(notifier: store);

  static HoldingStore? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HoldingStoreScope>()?.notifier;
}

/// Holdings and trades for the Portfolio screens. A trade changes a broker's
/// (or a bank's) balance, so the account store is reloaded after each one.
class HoldingStore extends ChangeNotifier {
  HoldingStore(this.repository, {required this.accountStore, this.prices});
  final HoldingRepository repository;
  final AccountStore accountStore;

  /// Where closing prices come from. Null in tests and previews, where
  /// nothing goes out to the network.
  final PriceService? prices;

  /// True while closes are being fetched.
  bool refreshing = false;

  List<Holding> _holdings = [];
  List<HoldingTrade> _trades = [];
  final Map<int, HoldingPosition> _positions = {};
  bool loading = true;

  /// Holdings still in use; archived ones stay out of lists and totals.
  List<Holding> get holdings =>
      List.unmodifiable(_holdings.where((h) => !h.isArchived));

  List<Holding> holdingsOf(int accountId) =>
      holdings.where((h) => h.accountId == accountId).toList();

  Holding? byId(int id) => _holdings.where((h) => h.id == id).firstOrNull;

  List<HoldingTrade> tradesOf(int holdingId) =>
      _trades.where((t) => t.holdingId == holdingId).toList().reversed.toList();

  /// Where a holding stands after its trades.
  HoldingPosition positionFor(Holding holding) =>
      _positions[holding.id] ??
      const HoldingPosition(
        unitsE6: 0,
        costMinor: 0,
        realizedMinor: 0,
        dividendsMinor: 0,
      );

  /// What a broker's holdings are worth, at their last prices. Holdings with
  /// no price yet count at what they cost, so a missing price never makes
  /// money seem to disappear.
  int holdingsValueMinor(Account broker) {
    var total = 0;
    for (final h in holdingsOf(broker.id)) {
      final position = positionFor(h);
      total += position.valueMinor(h.lastPriceE4, broker.digits) ??
          position.costMinor;
    }
    return total;
  }

  int holdingsCostMinor(Account broker) => holdingsOf(broker.id).fold(
    0,
    (sum, h) => sum + positionFor(h).costMinor,
  );

  /// Cash plus holdings: what the broker account is worth.
  int totalValueMinor(Account broker) =>
      broker.balanceMinor + holdingsValueMinor(broker);

  Future<void> load() async {
    try {
      _holdings = await repository.loadHoldings();
      _trades = await repository.loadTrades();
      _recompute();
    } catch (_) {
      // Keep what is shown.
    }
    loading = false;
    notifyListeners();
  }

  void _recompute() {
    _positions.clear();
    for (final h in _holdings) {
      _positions[h.id] = positionOf(
        _trades.where((t) => t.holdingId == h.id),
        digits: accountStore.byId(h.accountId)?.digits ?? 2,
      );
    }
  }

  Future<void> _reload() async {
    _holdings = await repository.loadHoldings();
    _trades = await repository.loadTrades();
    _recompute();
    notifyListeners();
    await accountStore.load();
  }

  Future<int> saveHolding({
    Holding? existing,
    required int accountId,
    required HoldingKind kind,
    required String name,
    String? symbol,
    String? exchange,
  }) async {
    final id = await repository.saveHolding(
      existing: existing,
      accountId: accountId,
      kind: kind,
      name: name,
      symbol: symbol,
      exchange: exchange,
    );
    await _reload();
    return id;
  }

  /// Fetches the latest close for every holding in use. Without [force] it
  /// does nothing once today's refresh has succeeded, so opening the app
  /// again doesn't ask again. Returns null when nothing was attempted.
  Future<PriceRefreshResult?> refreshPrices({bool force = false}) async {
    final service = prices;
    if (service == null || refreshing) return null;
    final targets = [
      for (final h in holdings)
        if (accountStore.byId(h.accountId) case final broker?)
          (holding: h, currency: broker.currency),
    ];
    if (targets.isEmpty) return null;
    if (!force && !await service.due()) return null;
    refreshing = true;
    notifyListeners();
    try {
      final result = await service.fetch(targets);
      for (final entry in result.updated.entries) {
        await repository.setPrice(
          entry.key,
          entry.value.priceE4,
          entry.value.date,
        );
      }
      // Not counted as done when nothing came back, so the next open tries
      // again instead of waiting a day.
      if (result.anyUpdated) await service.markRefreshed();
      _holdings = await repository.loadHoldings();
      return result;
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  Future<void> setPrice(Holding holding, int priceE4, DateTime date) async {
    await repository.setPrice(holding.id, priceE4, date);
    await _reload();
  }

  Future<void> addTrade({
    required Holding holding,
    required TradeType type,
    required DateTime date,
    required int unitsE6,
    required int priceE4,
    required int amountMinor,
    int feesMinor = 0,
    int? payAccountId,
    String? note,
  }) async {
    await repository.addTrade(
      holdingId: holding.id,
      type: type,
      date: date,
      unitsE6: unitsE6,
      priceE4: priceE4,
      amountMinor: amountMinor,
      feesMinor: feesMinor,
      payAccountId: payAccountId,
      note: note,
    );
    // A trade at a price is also the latest price known for the day.
    if (type != TradeType.dividend && priceE4 > 0) {
      await repository.setPrice(holding.id, priceE4, date);
    }
    await _reload();
  }

  Future<void> deleteTrade(HoldingTrade trade) async {
    await repository.deleteTrade(trade.id);
    await _reload();
  }

  Future<void> deleteHolding(Holding holding) async {
    await repository.deleteHolding(holding.id);
    await _reload();
  }

  Future<void> archive(Holding holding, {required bool archived}) async {
    await repository.archive(holding.id, archived: archived);
    await _reload();
  }
}
