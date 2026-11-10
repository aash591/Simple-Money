import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/home/cards/accounts_card.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore transactions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    categories = CategoryStore(CategoryRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.load();
    await categories.load();
    await transactions.load();
  });
  tearDown(() async {
    accounts.dispose();
    categories.dispose();
    transactions.dispose();
    await db.close();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AccountsCard(
              accountStore: accounts,
              categoryStore: categories,
              transactionStore: transactions,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with no accounts it explains and offers to add one', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Add your first account'), findsOneWidget);
    expect(find.textContaining('a bank, a card, cash'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add account'), findsOneWidget);
    // No made-up example accounts any more.
    expect(find.text('Salary account'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with accounts it shows the strip and a dashed add card', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await accounts.save(
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
    });
    await show(tester);
    expect(find.text('SBI'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Add your first account'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
