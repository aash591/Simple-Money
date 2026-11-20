import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';
import 'package:simple_money/ui/more/portfolio/trade_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late HoldingStore store;
  late int holdingId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    store = HoldingStore(HoldingRepository(db), accountStore: accounts);
    await accounts.save(
      name: 'Zerodha', currency: 'INR', digits: 2,
      openingBalance: 1000000, broker: true,
    );
    await accounts.load();
    holdingId = await store.saveHolding(
      accountId: accounts.accounts.single.id,
      kind: HoldingKind.stock,
      name: 'TCS',
      symbol: 'TCS.NS',
    );
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    accounts.dispose();
    await db.close();
  });

  testWidgets('a purchase is asked one question at a time', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTradeSheet(
              context,
              store: store,
              accounts: accounts,
              holding: store.byId(holdingId)!,
              type: TradeType.buy,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('How many shares did you buy?'), findsOneWidget);
    await tester.tap(find.text('5'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('At what price per share?'), findsOneWidget);
    await tester.tap(find.text('2'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('When did you buy?'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm purchase'), findsOneWidget);
    expect(find.text('Fees and taxes'), findsOneWidget);
    expect(find.text('Paid from'), findsOneWidget);
    await tester.tap(find.text('Save purchase'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    final position = store.positionFor(store.byId(holdingId)!);
    expect(position.unitsE6, 5 * unitScale);
    expect(position.costMinor, 1000); // 5 × ₹2
  });
}
