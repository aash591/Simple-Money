import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/rates/exchange_rates.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/main_currency_controller.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transfer_sheet.dart';

/// A controller already holding a rate table, so the Received step has a
/// figure to pre-fill without any network.
class _StubCurrencies extends MainCurrencyController {
  _StubCurrencies(super.accounts, super.rates, {ExchangeRateTable? seed})
    : super(isOnline: _offline) {
    table = seed;
    loading = false;
  }
  static Future<bool> _offline() async => false;

  @override
  Future<void> start() async {}
  @override
  Future<bool> refresh({bool force = false}) async => table != null;
}

/// The rates service is constructed but never allowed to reach the network.
final _noNetwork = MockClient((_) async => http.Response('', 503));

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late TransactionStore transactions;
  late MainCurrencyController currencies;

  Future<void> setUpStores({ExchangeRateTable? rates}) async {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.load();
    await transactions.load();
    for (final code in ['SAR', 'INR']) {
      await accounts.save(
        name: '$code account',
        currency: code,
        digits: 2,
        openingBalance: 100000,
      );
    }
    currencies = _StubCurrencies(
      accounts,
      ExchangeRates(db, _noNetwork),
      seed: rates,
    );
  }

  tearDown(() async {
    currencies.dispose();
    transactions.dispose();
    accounts.dispose();
    await db.close();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: MainCurrencyScope(
          controller: currencies,
          child: Scaffold(
            body: TransferSheet(
              accountStore: accounts,
              transactionStore: transactions,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapDigits(WidgetTester tester, String digits) async {
    for (final digit in digits.split('')) {
      await tester.tap(
        find.descendant(
          of: find.byType(NumberKeypad),
          matching: find.text(digit),
        ),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> continueOn(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
    await tester.pumpAndSettle();
  }

  /// Walks From -> Amount -> To, leaving the flow on the Received step.
  Future<void> reachReceived(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ListTile, 'SAR account'));
    await tester.pumpAndSettle();
    await tapDigits(tester, '500');
    await continueOn(tester);
    await tester.tap(find.widgetWithText(ListTile, 'INR account'));
    await tester.pumpAndSettle();
  }

  int balanceOf(String code) =>
      accounts.accounts.firstWhere((a) => a.currency == code).balanceMinor;

  // Table base INR: 1 INR = 0.0449 SAR. SAR 500 -> ₹11,135.86.
  ExchangeRateTable inrTable() => ExchangeRateTable(
    base: 'INR',
    date: DateTime.now().toUtc(),
    fetchedOn: DateTime.now().toUtc(),
    rates: const {'INR': 1, 'SAR': 0.0449},
  );

  testWidgets('The rate pre-fills what arrived, and one tap accepts it', (
    tester,
  ) async {
    await setUpStores(rates: inrTable());
    await mount(tester);
    await reachReceived(tester);

    expect(find.text('How much arrived?'), findsOneWidget);
    expect(find.textContaining("At today's rate"), findsOneWidget);
    expect(find.textContaining('1 SAR = 22.2717 INR'), findsOneWidget);
    expect(find.textContaining('11,135.86'), findsWidgets);

    await continueOn(tester); // accept the rate
    await continueOn(tester); // keep today's date
    await tester.tap(find.widgetWithText(GlassButton, 'Save transfer'));
    await tester.pumpAndSettle();

    expect(balanceOf('SAR'), 100000 - 50000);
    expect(balanceOf('INR'), 100000 + 1113586);
    expect(transactions.transactions.single.toAmountMinor, 1113586);
  });

  testWidgets('Typing what really arrived records it, and shows the charge', (
    tester,
  ) async {
    await setUpStores(rates: inrTable());
    await mount(tester);
    await reachReceived(tester);

    // Clear the pre-filled figure and enter what the bank actually credited.
    await tester.longPress(
      find.descendant(
        of: find.byType(NumberKeypad),
        matching: find.byIcon(Icons.backspace_outlined),
      ),
    );
    await tester.pumpAndSettle();
    await tapDigits(tester, '11000');
    expect(find.textContaining('You got 1 SAR = 22 INR'), findsOneWidget);

    await continueOn(tester);
    await continueOn(tester);
    // ₹11,135.86 was due at the rate; ₹11,000 landed.
    expect(find.textContaining('Charge'), findsOneWidget);
    expect(find.textContaining('₹135.86'), findsOneWidget);
    expect(find.textContaining('SAR 500'), findsOneWidget);

    await tester.tap(find.widgetWithText(GlassButton, 'Save transfer'));
    await tester.pumpAndSettle();
    expect(balanceOf('SAR'), 50000);
    expect(balanceOf('INR'), 100000 + 1100000);
  });

  testWidgets('With no rate, the step asks rather than guessing', (
    tester,
  ) async {
    await setUpStores(); // no table at all
    await mount(tester);
    await reachReceived(tester);

    expect(find.text('How much arrived?'), findsOneWidget);
    expect(find.textContaining('No rate for SAR to INR'), findsOneWidget);
    // Nothing is pre-filled, so Continue stays disabled until it is typed.
    expect(
      tester
          .widget<GlassButton>(find.widgetWithText(GlassButton, 'Continue'))
          .onPressed,
      isNull,
    );
    await tapDigits(tester, '11000');
    await continueOn(tester);
    await continueOn(tester);
    await tester.tap(find.widgetWithText(GlassButton, 'Save transfer'));
    await tester.pumpAndSettle();
    expect(balanceOf('INR'), 100000 + 1100000);
  });

  testWidgets('Changing the destination to the same currency drops the step', (
    tester,
  ) async {
    await setUpStores(rates: inrTable());
    await accounts.save(
      name: 'Second SAR',
      currency: 'SAR',
      digits: 2,
      openingBalance: 0,
    );
    await mount(tester);
    await reachReceived(tester);
    expect(find.text('How much arrived?'), findsOneWidget);

    // Back to the destinations, and pick a riyal account instead.
    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Second SAR'));
    await tester.pumpAndSettle();

    expect(find.text('How much arrived?'), findsNothing);
    expect(find.text('When did you transfer it?'), findsOneWidget);
    await continueOn(tester);
    await tester.tap(find.widgetWithText(GlassButton, 'Save transfer'));
    await tester.pumpAndSettle();
    expect(transactions.transactions.single.toAmountMinor, isNull);
    expect(
      accounts.accounts.firstWhere((a) => a.name == 'Second SAR').balanceMinor,
      50000,
    );
  });

  testWidgets(
    'Every account shows what it currently holds, while choosing and after',
    (tester) async {
      await setUpStores(rates: inrTable());
      await mount(tester);

      // Picking a source: each candidate carries its own balance.
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'SAR account'),
          matching: find.text('SAR 1,000'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'INR account'),
          matching: find.text('₹1,000'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ListTile, 'SAR account'));
      await tester.pumpAndSettle();
      await tapDigits(tester, '500');
      await continueOn(tester);

      // The chosen source keeps its balance in the running summary.
      expect(find.text('SAR 1,000'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'INR account'));
      await tester.pumpAndSettle();
      expect(find.text('SAR 1,000'), findsOneWidget);
      expect(find.text('₹1,000'), findsOneWidget);

      // And both are still there to check against on Confirm.
      await continueOn(tester);
      await continueOn(tester);
      expect(find.text('SAR 1,000'), findsOneWidget);
      expect(find.text('₹1,000'), findsOneWidget);
    },
  );
}
