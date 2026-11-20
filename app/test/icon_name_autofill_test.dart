import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/app_icons.dart';
import 'package:simple_money/domain/bank_institution_icon.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/app_icon.dart';
import 'package:simple_money/ui/more/accounts/edit_account_screen.dart';
import 'package:simple_money/ui/more/portfolio/add_broker_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// Choosing a bank, broker or service logo names an empty account after it,
/// and never overwrites a name that was typed.
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

  /// Opens the picker from the icon at the top of the form and picks [title]
  /// from [tab] by searching for it.
  Future<void> pick(WidgetTester tester, String tab, String title) async {
    await tester.tap(find.byType(AppIcon).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(tab));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search icons'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('icon-search')), title);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(title).first);
    await tester.pumpAndSettle();
  }

  String name(WidgetTester tester, Key key) =>
      tester.widget<TextField>(find.byKey(key)).controller!.text;

  Future<void> show(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: appTheme(Brightness.light), home: screen),
    );
    await tester.pumpAndSettle();
  }

  test('a name comes only from brand logos', () {
    expect(nameForIcon(brandIconKey('hdfcbank')), 'HDFC Bank');
    expect(nameForIcon(brandIconKey('netflix')), 'Netflix');
    expect(nameForIcon(brandIconKey('groww')), 'Groww');
    expect(nameForIcon(appIconKeys.first), isNull);
    expect(nameForIcon(null), isNull);
  });

  testWidgets('account: a bank or service logo names an empty account', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester, EditAccountScreen(store: accounts));
    const nameKey = Key('account-name');
    expect(name(tester, nameKey), isEmpty);

    await pick(tester, 'Banks', 'HDFC Bank');
    expect(name(tester, nameKey), 'HDFC Bank');

    // Another logo replaces a name it filled in itself.
    await pick(tester, 'Banks', 'ICICI Bank');
    expect(name(tester, nameKey), 'ICICI Bank');

    await pick(tester, 'Services', 'Netflix');
    expect(name(tester, nameKey), 'Netflix');

    // A name typed by hand is left alone.
    await tester.enterText(find.byKey(nameKey), 'My salary account');
    await pick(tester, 'Banks', 'HDFC Bank');
    expect(name(tester, nameKey), 'My salary account');
    semantics.dispose();
  });

  testWidgets('broker: a logo names the broker, a typed name stays', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester, AddBrokerScreen(accounts: accounts));
    const nameKey = Key('broker-name');

    await pick(tester, 'Services', 'Groww');
    expect(name(tester, nameKey), 'Groww');

    await pick(tester, 'Services', 'Upstox');
    expect(name(tester, nameKey), 'Upstox');

    await tester.enterText(find.byKey(nameKey), 'Dad’s account');
    await pick(tester, 'Services', 'Groww');
    expect(name(tester, nameKey), 'Dad’s account');
    semantics.dispose();
  });
}
