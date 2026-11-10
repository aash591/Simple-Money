import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_currency_sheet.dart';
import 'package:simple_money/ui/transactions/transactions_screen.dart';

Future<void> swipeCurrency(WidgetTester tester, int pages) async {
  for (var i = 0; i < pages; i++) {
    await tester.drag(
      find.byKey(const Key('transaction-currency-summary')),
      const Offset(-350, 0),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  const capture = bool.fromEnvironment('CURRENCY_QA');
  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('currency-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/qa/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    bool onlySar = false,
    bool inactiveInr = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (capture) {
      await tester.runAsync(() async {
        for (final family in ['Roboto', 'Ahem']) {
          final font = FontLoader(family)
            ..addFont(
              File(Platform.environment['QA_FONT']!)
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes)),
            );
          await font.load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      transactions.dispose();
      categories.dispose();
      accounts.dispose();
      await tester.runAsync(db.close);
    });
    await tester.runAsync(() async {
      await accounts.load();
      await categories.load();
      await transactions.load();
      for (final code in ['INR', 'SAR', 'USD']) {
        await accounts.save(
          name: '$code account',
          currency: code,
          digits: 2,
          openingBalance: 100000,
        );
      }
      final cafe = categories.categories.firstWhere((c) => c.name == 'Cafe');
      for (final row in [
        ('INR', 10000, 'Rupee purchase', onlySar || inactiveInr ? 8 : 9),
        ('SAR', 2000, 'Riyal purchase', 9),
        ('SAR', 3000, 'Riyal lunch', 9),
        ('USD', 500, 'Dollar purchase', onlySar ? 8 : 9),
        ('INR', 700, 'Later purchase', 10),
      ]) {
        await transactions.addExpenseOrIncome(
          type: TransactionType.expense,
          amountMinor: row.$2,
          accountId: accounts.accounts
              .firstWhere((a) => a.currency == row.$1)
              .id,
          categoryId: cafe.id,
          title: row.$3,
          date: DateTime(2026, row.$4, 12),
        );
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('currency-capture'),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: TransactionsScreen(
              accountStore: accounts,
              categoryStore: categories,
              transactionStore: transactions,
              initialMonth: DateTime(2026, 9),
              onAddTransaction: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Currency swipes stay in the period at both edges and support large text',
    (tester) async {
      await mount(tester, textScale: 2);
      final summary = find.byKey(const Key('transaction-currency-summary'));
      expect(
        find.byKey(const Key('currency-scroll-indicator')),
        findsOneWidget,
      );
      await tester.drag(summary, const Offset(350, 0));
      await tester.pumpAndSettle();
      expect(find.text('Summary · INR').hitTestable(), findsOneWidget);
      await swipeCurrency(tester, 2);
      expect(find.text('Summary · USD').hitTestable(), findsOneWidget);
      expect(find.text('Balance · USD'), findsOneWidget);
      await swipeCurrency(tester, 1);
      expect(find.text('Summary · USD').hitTestable(), findsOneWidget);
      expect(find.text('Later purchase'), findsNothing);
      await tester.drag(summary, const Offset(350, 0));
      await tester.pumpAndSettle();
      expect(find.text('Summary · SAR').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Switching scopes every total but keeps native transaction rows; account filter resets it',
    (tester) async {
      await mount(tester);
      expect(find.text('Summary · INR').hitTestable(), findsOneWidget);
      expect(find.text('Balance · INR'), findsOneWidget);
      expect(find.byTooltip('Show balance · inr'), findsOneWidget);
      await tester.tap(find.byTooltip('Show balance · inr'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('₹893'), findsOneWidget);
      expect(find.text('₹900'), findsOneWidget);
      expect(find.text('₹1,000'), findsOneWidget);
      expect(find.text('Riyal purchase'), findsOneWidget);
      await screenshot(tester, 'currency-transactions');
      expect(
        find.byKey(const Key('currency-scroll-indicator')),
        findsOneWidget,
      );
      await screenshot(tester, 'currency-comparison');
      await swipeCurrency(tester, 1);
      await tester.pumpAndSettle();
      expect(find.text('Summary · SAR').hitTestable(), findsOneWidget);
      expect(find.text('Balance · SAR'), findsOneWidget);
      // Revealed once, it stays revealed across the whole app.
      expect(find.byTooltip('Hide balance · sar'), findsOneWidget);
      expect(find.bySemanticsLabel('SAR 950'), findsNWidgets(2));
      expect(find.text('SAR 50'), findsOneWidget);
      expect(find.text('- SAR 50'), findsOneWidget);
      expect(find.text('Rupee purchase'), findsOneWidget);
      expect(find.text('Dollar purchase'), findsOneWidget);
      await tester.tap(find.byKey(const Key('transaction-account-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('INR account'));
      await tester.pumpAndSettle();
      // The header is one surface: the account's name, then its balance.
      expect(
        find.descendant(
          of: find.byKey(const Key('transaction-account-filter')),
          matching: find.text('INR account'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Hide inr account balance'), findsOneWidget);
      expect(
        find.byKey(const Key('transaction-currency-summary')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('₹100'), findsOneWidget);
      expect(find.text('Riyal purchase'), findsNothing);
    },
  );

  testWidgets(
    'Single currency month hides entry point despite other currency accounts',
    (tester) async {
      await mount(tester, onlySar: true);
      expect(
        find.byKey(const Key('transaction-currency-summary')),
        findsNothing,
      );
      expect(find.text('Balance · SAR'), findsOneWidget);
      expect(find.text('SAR 50'), findsOneWidget);
      await tester.drag(find.byType(PageView), const Offset(-390, 0));
      await tester.pumpAndSettle();
      expect(find.text('Balance · INR'), findsOneWidget);
      expect(find.text('Later purchase'), findsOneWidget);
    },
  );

  testWidgets(
    'Uses the most frequent currency when main currency is absent; swiping changes selection inline',
    (tester) async {
      await mount(tester, inactiveInr: true);
      expect(find.text('Summary · SAR').hitTestable(), findsOneWidget);
      await swipeCurrency(tester, 2);
      await tester.pumpAndSettle();
      expect(find.text('Summary · USD').hitTestable(), findsOneWidget);
      expect(find.byType(TransactionCurrencySheet), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Summary · USD').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'Ten currencies scroll and large amounts remain readable at 200% text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final codes = [
        'INR',
        'SAR',
        'USD',
        'EUR',
        'GBP',
        'JPY',
        'AED',
        'CAD',
        'AUD',
        'CHF',
      ];
      TransactionCurrency? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showAdaptiveSheet<TransactionCurrency>(
                    context,
                    maxHeightFactor: .9,
                    builder: (_) => TransactionCurrencySheet(
                      period: 'September 2026',
                      selected: ('INR', 2),
                      summaries: [
                        for (final code in codes)
                          TransactionCurrencySummary(
                            currency: (code, 2),
                            income: 98765432100,
                            expenses: 12345678900,
                          ),
                      ],
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('select-currency-CHF')),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('CHF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CHF'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result, ('CHF', 2));
    },
  );

  testWidgets(
    'A day with nothing in the shown currency omits that side of its total',
    (tester) async {
      await mount(tester);
      // Sept 12 holds rupee, riyal and dollar spending but no income at all,
      // so the day header should carry the outgoing side only. ("- ₹100" is
      // found twice: the day's total, and the one rupee row that makes it up.)
      expect(find.text('- ₹100'), findsNWidgets(2));
      expect(find.textContaining('+ ₹0'), findsNothing);
      expect(find.textContaining('- ₹0'), findsNothing);
      // The riyal view of the same day has spending but likewise no income.
      await swipeCurrency(tester, 1);
      await tester.pumpAndSettle();
      expect(find.text('- SAR 50'), findsOneWidget);
      expect(find.textContaining('+ SAR 0'), findsNothing);
    },
  );

  testWidgets('A chosen currency survives paging to a month that has it', (
    tester,
  ) async {
    await mount(tester);
    await swipeCurrency(tester, 2);
    await tester.pumpAndSettle();
    expect(find.text('Summary · USD').hitTestable(), findsOneWidget);
    // October holds rupees alone, so the pick cannot apply there...
    await tester.drag(find.byType(PageView), const Offset(-390, 0));
    await tester.pumpAndSettle();
    expect(find.text('Balance · INR'), findsOneWidget);
    // ...but it is still the pick, and September can honour it again.
    await tester.drag(find.byType(PageView), const Offset(390, 0));
    await tester.pumpAndSettle();
    expect(find.text('Summary · USD').hitTestable(), findsOneWidget);
    expect(find.text('Balance · USD'), findsOneWidget);
  });

  test(
    'A transfer between two currencies is refused rather than guessed',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final accounts = AccountStore(AccountRepository(db));
      final transactions = TransactionStore(
        TransactionRepository(db),
        accounts,
      );
      addTearDown(() async {
        transactions.dispose();
        accounts.dispose();
        await db.close();
      });
      await accounts.load();
      await transactions.load();
      for (final code in ['INR', 'SAR']) {
        await accounts.save(
          name: '$code account',
          currency: code,
          digits: 2,
          openingBalance: 100000,
        );
      }
      final inr = accounts.accounts.firstWhere((a) => a.currency == 'INR');
      final sar = accounts.accounts.firstWhere((a) => a.currency == 'SAR');
      await expectLater(
        transactions.addTransfer(
          amountMinor: 50000,
          fromAccountId: inr.id,
          toAccountId: sar.id,
          date: DateTime(2026, 9, 12),
        ),
        throwsArgumentError,
      );
      // Neither balance moved, and no half-written transfer was left behind.
      expect(accounts.accounts.every((a) => a.balanceMinor == 100000), isTrue);
      expect(transactions.transactions, isEmpty);
    },
  );
}
