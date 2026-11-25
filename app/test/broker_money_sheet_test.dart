import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/more/portfolio/broker_money_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  testWidgets('back from a flow slides to the choice, not out of the sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final accounts = AccountStore(AccountRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.save(
      name: 'Zerodha',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      broker: true,
    );
    await accounts.load();
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBrokerMoneySheet(
              context,
              accounts: accounts,
              transactions: transactions,
              broker: accounts.accounts.single,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Deposit'), findsOneWidget);
    expect(find.text('Withdraw'), findsOneWidget);

    await tester.tap(find.text('Withdraw'));
    await tester.pumpAndSettle();
    expect(find.text('How much did you withdraw?'), findsOneWidget);

    // The system back gesture steps back to the choice; the sheet stays.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Deposit'), findsOneWidget);
    expect(find.text('How much did you withdraw?'), findsNothing);

    await tester.tap(find.text('Deposit'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Withdraw'), findsOneWidget);

    // From the choice itself, back closes it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Withdraw'), findsNothing);
  });
}
