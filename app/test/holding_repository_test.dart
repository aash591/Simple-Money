import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late HoldingStore store;
  late int broker, bank;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    store = HoldingStore(HoldingRepository(db), accountStore: accounts);
    await accounts.save(
      name: 'Zerodha',
      currency: 'INR',
      digits: 2,
      openingBalance: 1000000,
      broker: true,
    );
    await accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 500000,
    );
    await accounts.load();
    broker = accounts.accounts.firstWhere((a) => a.name == 'Zerodha').id;
    bank = accounts.accounts.firstWhere((a) => a.name == 'Bank').id;
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    accounts.dispose();
    await db.close();
  });

  int cash(int id) => accounts.byId(id)!.balanceMinor;

  Future<void> buy(
    Holding h,
    int units,
    int price, {
    int? from,
    int fees = 0,
  }) => store.addTrade(
    holding: h,
    type: TradeType.buy,
    date: DateTime(2026, 2, 1),
    unitsE6: units * unitScale,
    priceE4: price * priceScale,
    amountMinor: units * price * 100,
    feesMinor: fees,
    payAccountId: from,
  );

  test('a broker is flagged, and holdings only go under one', () async {
    expect(accounts.byId(broker)!.isBroker, isTrue);
    expect(accounts.byId(bank)!.isBroker, isFalse);
    expect(
      () => store.saveHolding(
        accountId: bank,
        kind: HoldingKind.stock,
        name: 'TCS',
      ),
      throwsArgumentError,
    );
  });

  test('buying and selling move the broker cash and the units', () async {
    final id = await store.saveHolding(
      accountId: broker,
      kind: HoldingKind.stock,
      name: 'TCS',
      symbol: 'TCS',
      exchange: 'NSE',
    );
    final h = store.byId(id)!;
    await buy(h, 10, 100, fees: 50);
    expect(cash(broker), 1000000 - 100000 - 50);
    expect(store.positionFor(h).unitsE6, 10 * unitScale);

    await store.addTrade(
      holding: h,
      type: TradeType.sell,
      date: DateTime(2026, 3, 1),
      unitsE6: 4 * unitScale,
      priceE4: 150 * priceScale,
      amountMinor: 60000,
    );
    expect(cash(broker), 1000000 - 100050 + 60000);
    expect(store.positionFor(h).unitsE6, 6 * unitScale);
    expect(store.holdingsValueMinor(accounts.byId(broker)!), 6 * 150 * 100);
  });

  test('a buy can be paid straight from a bank in the same currency', () async {
    final h = store.byId(
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.fund,
        name: 'Index fund',
      ),
    )!;
    await buy(h, 5, 200, from: bank);
    expect(cash(bank), 500000 - 100000);
    expect(cash(broker), 1000000);
  });

  test(
    'cannot sell what was not bought, and deleting a buy is checked',
    () async {
      final h = store.byId(
        await store.saveHolding(
          accountId: broker,
          kind: HoldingKind.stock,
          name: 'INFY',
        ),
      )!;
      await buy(h, 2, 100);
      await expectLater(
        store.addTrade(
          holding: h,
          type: TradeType.sell,
          date: DateTime(2026, 3, 1),
          unitsE6: 3 * unitScale,
          priceE4: 100 * priceScale,
          amountMinor: 30000,
        ),
        throwsArgumentError,
      );
      await store.addTrade(
        holding: h,
        type: TradeType.sell,
        date: DateTime(2026, 3, 1),
        unitsE6: 1 * unitScale,
        priceE4: 100 * priceScale,
        amountMinor: 10000,
      );
      final buyTrade = store
          .tradesOf(h.id)
          .firstWhere((t) => t.type == TradeType.buy);
      await expectLater(store.deleteTrade(buyTrade), throwsArgumentError);
    },
  );

  test('deleting a holding gives all its cash back', () async {
    final h = store.byId(
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.stock,
        name: 'ITC',
      ),
    )!;
    await buy(h, 10, 100, fees: 25);
    await store.addTrade(
      holding: h,
      type: TradeType.dividend,
      date: DateTime(2026, 4, 1),
      unitsE6: 0,
      priceE4: 0,
      amountMinor: 1000,
    );
    await store.deleteHolding(h);
    expect(cash(broker), 1000000);
    expect(store.holdings, isEmpty);
  });

  test('deleting a broker removes its holdings and trades', () async {
    final h = store.byId(
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.stock,
        name: 'ITC',
      ),
    )!;
    await buy(h, 1, 100, from: bank);
    await accounts.delete(broker);
    await store.load();
    expect(store.holdings, isEmpty);
    expect(await HoldingRepository(db).loadTrades(), isEmpty);
  });

  test('the newest price for a holding wins', () async {
    final h = store.byId(
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.stock,
        name: 'ITC',
      ),
    )!;
    await store.setPrice(h, 120 * priceScale, DateTime(2026, 5, 2));
    await store.setPrice(h, 90 * priceScale, DateTime(2026, 5, 1));
    expect(store.byId(h.id)!.lastPriceE4, 120 * priceScale);
  });
}
