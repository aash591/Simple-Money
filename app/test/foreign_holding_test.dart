import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/convert_minor.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late HoldingStore store;

  /// 1 US dollar = 84 rupees, in a table whose base is rupees.
  int? convert(
    int minor, {
    required String from,
    required int fromDigits,
    required String to,
    required int toDigits,
  }) {
    double? perMain(String c) => switch (c) {
      'INR' => 1,
      'USD' => 1 / 84,
      _ => null,
    };
    return crossConvertMinor(
      minor,
      fromDigits: fromDigits,
      toDigits: toDigits,
      perMainFrom: perMain(from),
      perMainTo: perMain(to),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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
    await accounts.load();
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    accounts.dispose();
    await db.close();
  });

  test('a holding in another currency is valued and totalled in the '
      'account\'s', () async {
    final broker = accounts.accounts.single;
    final id = await store.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'Apple',
      symbol: 'AAPL',
      currency: 'USD',
    );
    final apple = store.byId(id)!;
    expect(apple.currency, 'USD');
    // 10 shares bought for ₹70,000 (what was actually debited).
    await store.addTrade(
      holding: apple,
      type: TradeType.buy,
      date: DateTime(2026, 11, 1),
      unitsE6: 10 * unitScale,
      priceE4: 1000000, // $100 a share
      amountMinor: 7000000,
    );
    await store.setPrice(store.byId(id)!, 1100000, DateTime(2026, 11, 20));

    // Without rates the holding counts at what it cost.
    expect(store.valueMinor(store.byId(id)!, broker), isNull);
    expect(store.holdingsValueMinor(broker), 7000000);

    store.converter = convert;
    final held = store.byId(id)!;
    expect(store.valueInOwnCurrency(held, broker), 110000); // $1,100.00
    expect(store.valueMinor(held, broker), 9240000); // ₹92,400.00
    expect(store.holdingsValueMinor(broker), 9240000);
    final totals = store.foreignTotals(broker);
    expect(totals['USD']?.own, 110000);
    expect(totals['USD']?.converted, 9240000);
    expect(store.foreignCurrencies, {'USD'});
  });

  test('a holding with no currency is in its account\'s', () async {
    final broker = accounts.accounts.single;
    final id = await store.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'TCS',
      symbol: 'TCS.NS',
    );
    expect(store.byId(id)!.currency, isNull);
    expect(store.byId(id)!.currencyIn('INR'), 'INR');
    expect(store.foreignCurrencies, isEmpty);
    // Editing without naming a currency leaves what is stored.
    await store.saveHolding(
      existing: store.byId(id),
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'TCS Ltd',
      symbol: 'TCS.NS',
    );
    expect(store.byId(id)!.name, 'TCS Ltd');
    expect(store.byId(id)!.currency, isNull);
  });

  test('the same ticker in one account is one holding', () async {
    final broker = accounts.accounts.single;
    final first = await store.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'Tesla, Inc.',
      symbol: 'TSLA',
    );
    final second = await store.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'Tesla, Inc.',
      symbol: 'tsla',
    );
    expect(second, first);
    expect(store.holdings, hasLength(1));
  });

  test('a trade never overwrites the market close it is compared with', () async {
    final broker = accounts.accounts.single;
    final id = await store.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'TCS',
      symbol: 'TCS.NS',
    );
    await store.setPrice(store.byId(id)!, 35500000, DateTime(2026, 11, 19));
    await store.addTrade(
      holding: store.byId(id)!,
      type: TradeType.buy,
      date: DateTime(2026, 11, 20),
      unitsE6: unitScale,
      priceE4: 30000000, // paid ₹3,000, the market closed at ₹3,550
      amountMinor: 300000,
    );
    expect(store.byId(id)!.lastPriceE4, 35500000);

    // With no close yet, the price paid stands in until one arrives.
    final bare = await store.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'Infosys',
      symbol: 'INFY.NS',
    );
    await store.addTrade(
      holding: store.byId(bare)!,
      type: TradeType.buy,
      date: DateTime(2026, 11, 20),
      unitsE6: unitScale,
      priceE4: 15000000,
      amountMinor: 150000,
    );
    expect(store.byId(bare)!.lastPriceE4, 15000000);
  });
}
