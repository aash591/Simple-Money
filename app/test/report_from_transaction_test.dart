import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';

const _sms =
    'Sender: JX-SBIUPI-S\n\nDear UPI user A/C X2199 debited by 40.00 on date '
    '31Oct26 trf to NIZAR AHAMMED KU Refno 630436719300';

void main() {
  group('the message a transaction was read from', () {
    final when = DateTime(2026, 10, 31, 17, 40);

    test('comes from the note', () {
      final message = ReportableSms.fromNote(_sms, when)!;
      expect(message.sms.sender, 'JX-SBIUPI-S');
      expect(message.sms.body, startsWith('Dear UPI user'));
      expect(message.sms.receivedAt, when);
      expect(message.fromNotification, isFalse);
    });

    test('is a notification when saved under an app sender', () {
      final message = ReportableSms.fromNote(
        'Sender: APP_1A2B3C4D5E\n\nPaid ₹40\nTo Nizar',
        when,
      )!;
      expect(message.fromNotification, isTrue);
      expect(message.sms.body, 'Paid ₹40\nTo Nizar');
    });

    test('is nothing for a transaction typed by hand', () {
      expect(ReportableSms.fromNote(null, when), isNull);
      expect(ReportableSms.fromNote('Lunch with Sam', when), isNull);
      expect(ReportableSms.fromNote('Sender: X', when), isNull);
      expect(ReportableSms.fromNote('Sender: X\n\n  ', when), isNull);
    });
  });

  group('the Report pill', () {
    late AppDatabase db;
    late AccountStore accounts;
    late CategoryStore categories;
    late TransactionStore transactions;
    late int sbi;
    final reports = <MethodCall>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      reports.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('simple_money/help_improve'),
            (call) async {
              reports.add(call);
              return 1;
            },
          );
      db = AppDatabase(NativeDatabase.memory(), false);
      final repository = AccountRepository(db);
      sbi = await repository.save(
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      accounts = AccountStore(repository);
      categories = CategoryStore(CategoryRepository(db));
      transactions = TransactionStore(TransactionRepository(db), accounts);
      await Future.wait([
        accounts.load(),
        categories.load(),
        transactions.load(),
      ]);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('simple_money/help_improve'),
            null,
          );
      transactions.dispose();
      await db.close();
    });

    Future<void> open(WidgetTester tester, String? note) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showViewTransactionSheet(
                  context,
                  transaction: MoneyTransaction(
                    id: 1,
                    type: TransactionType.expense,
                    amountMinor: 4000,
                    accountId: sbi,
                    title: 'NIZAR AHAMMED KU',
                    note: note,
                    date: DateTime(2026, 10, 31, 17, 40),
                  ),
                  accountStore: accounts,
                  categoryStore: categories,
                  transactionStore: transactions,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks first, then sends the message like an SMS report', (
      tester,
    ) async {
      await open(tester, _sms);
      expect(find.text('Report'), findsOneWidget);

      // Cancel sends nothing.
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(find.text('Report this SMS?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(reports, isEmpty);

      // OK sends it, through the same channel as every SMS report.
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(reports.where((c) => c.method == 'report'), hasLength(1));
      final sent = (reports.first.arguments as Map)['messages'] as List;
      expect((sent.single as Map)['address'], 'JX-SBIUPI-S');
      expect((sent.single as Map)['body'], contains('debited by 40.00'));
      expect(find.text('Thanks for reporting'), findsOneWidget);
    });

    testWidgets('is not there for a transaction typed by hand', (tester) async {
      await open(tester, 'Lunch');
      expect(find.text('Report'), findsNothing);
    });
  });
}
