import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/realtime_sms.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/realtime_sms_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/components/choice_list_sheet.dart';
import 'package:simple_money/ui/sms/sms_notification_screen.dart';
import 'package:simple_money/ui/sms/sms_notification_preview.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/more/accounts/edit_account_screen.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late LiveSms live;
  final notifications = <Map<dynamic, dynamic>>[];
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    notifications.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsNotificationChannel, (call) async {
          if (call.method == 'show') notifications.add(call.arguments as Map);
          return call.method == 'activeIds' ? <String>[] : null;
        });
    final engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
    final message = BankSms(
      sender: 'AX-SBIUPI-S',
      receivedAt: DateTime(2026, 10, 26),
      body: 'Dear SBI User, your A/c X1234-debited by Rs.500 on 26Oct26 transfer to SAMPLE RECEIVER Ref No 123456789012 -SBI',
    );
    await AccountRepository(db).save(
      name: 'Primary',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
      lastDigits: '1234',
      institution: engine.parse(message).candidate!.bankName,
    );
    await AccountRepository(db)
        .save(name: 'Savings', currency: 'INR', digits: 2, openingBalance: 0);
    await SmsImportRepository(db).enable(true);
    live = (await RealtimeSmsRepository(db).receive(message, engine))!;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsNotificationChannel, null);
    await db.close();
  });
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'notification body opens the SMS preview; View transaction opens the sheet and Back returns',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAdaptiveSheet<void>(
                  context,
                  builder: (_) =>
                      SmsNotificationPreview(database: db, id: live.sms.id),
                ),
                child: const Text('Open notification'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open notification'));
      await settle(tester);
      await settle(tester);
      expect(find.byType(TransactionSheet), findsNothing);
      expect(find.text('SMS preview'), findsOneWidget);
      expect(find.text('Record as'), findsOneWidget);
      expect(find.text('Original message'), findsOneWidget);
      expect(find.text('Category'), findsOneWidget);
      await tester.tap(find.text('View transaction'));
      await settle(tester);
      await settle(tester);
      expect(find.byType(TransactionSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(TransactionSheet), findsNothing);
      expect(find.text('SMS preview'), findsOneWidget);
    },
  );

  testWidgets('Transfer switches in place and saves like the review modal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdaptiveSheet<void>(
                context,
                builder: (_) =>
                    SmsNotificationPreview(database: db, id: live.sms.id),
              ),
              child: const Text('Open notification'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open notification'));
    await settle(tester);
    await settle(tester);
    expect(find.text('View transaction'), findsOneWidget);
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    expect(find.byType(SmsNotificationPicker), findsNothing);
    expect(find.text('Category'), findsNothing);
    expect(find.text('Transferred to'), findsOneWidget);
    // Nothing to save until the other account is chosen.
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Transferred to'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Savings').last);
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.byType(SmsNotificationPreview), findsNothing);
    expect(notifications.last['category'], 'Transfer → Savings');
  });

  testWidgets('SMS preview fits a phone-sized sheet without scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2376);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdaptiveSheet<void>(
                context,
                entrance: SheetEntrance.fadeRise,
                dismissible: false,
                topClearance: 62,
                builder: (_) =>
                    SmsNotificationPreview(database: db, id: live.sms.id),
              ),
              child: const Text('Open notification'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open notification'));
    await settle(tester);
    await settle(tester);
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SmsNotificationPreview),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.maxScrollExtent, 0);
    expect(find.text('Original message'), findsOneWidget);
    // Shown in full without expanding, recovered from the saved note.
    expect(find.textContaining('debited by Rs.500'), findsOneWidget);
    expect(find.text('View transaction'), findsOneWidget);
  });

  testWidgets('a saved SMS can become a loan payment, recorded once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late int balance;
    await tester.runAsync(() async {
      await LoanRepository(db).add(
        LoanTerms(
          lender: 'Bajaj Finance',
          kind: LoanKind.other,
          icon: 'bank',
          principal: 500000,
          openingBalance: 500000,
          startDate: DateTime(2026, 5, 12),
          snapshotDate: DateTime(2026, 5, 12),
          rate: 0,
          months: 12,
          emi: 50000,
          paidBefore: 0,
          firstDue: DateTime(2026, 6, 2),
          day: 2,
          currency: 'INR',
          digits: 2,
        ),
        (await AccountRepository(db).load()).first.id,
      );
      balance = (await AccountRepository(db).load()).first.balanceMinor;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdaptiveSheet<void>(
                context,
                builder: (_) =>
                    SmsNotificationPreview(database: db, id: live.sms.id),
              ),
              child: const Text('Open notification'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open notification'));
    await settle(tester);
    await settle(tester);
    await tester.tap(find.text('Category'));
    await settle(tester);
    await tester.tap(find.text('Loan repayment'));
    await settle(tester);
    await tester.tap(find.text('Bajaj Finance'));
    await settle(tester);
    expect(find.text('Bajaj Finance'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await settle(tester);
    await settle(tester);
    await tester.runAsync(() async {
      final loan = (await LoanRepository(db).load()).single;
      expect(loan.paid, 1);
      expect(loan.outstanding, 450000);
      expect(
        (await db.customSelect('SELECT * FROM transactions').get()).length,
        1,
      );
      expect((await AccountRepository(db).load()).first.balanceMinor, balance);
    });
  });

  Future<void> open(WidgetTester tester, String field) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdaptiveSheet<void>(
                context,
                maxHeightFactor: .85,
                builder: (_) => SmsNotificationPicker(
                  database: db,
                  id: live.sms.id,
                  field: field,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settle(tester);
    if (field != 'create_account' &&
        field != 'undo_account' &&
        !field.startsWith('undo_category:')) {
      expect(find.byType(ChoicePickerPage<int>), findsOneWidget);
      expect(find.byType(SmsNotificationPicker), findsOneWidget);
    }
  }

  testWidgets('Undo action restores category and transaction notification', (
    tester,
  ) async {
    final repo = RealtimeSmsRepository(db);
    final original = live.categoryId;
    await open(tester, 'category');
    await tester.tap(find.text('Food & Beverage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await settle(tester);
    final token = notifications.single['undoToken'];
    notifications.clear();
    await open(tester, 'undo_category:$token');
    await settle(tester);
    expect(find.byType(SmsNotificationPicker), findsNothing);
    expect((await repo.load(live.sms.id))!.categoryId, original);
    expect(notifications.single.containsKey('savedTitle'), isFalse);
    expect(notifications.single['title'], startsWith('Spent '));
    expect(notifications.single['text'], startsWith('What was this for?'));
    expect(notifications.single['suggestions'], isNotEmpty);
  });

  testWidgets(
    'new bank account is created with undo, and credit styling data',
    (tester) async {
      final engine = BankSmsParser(
        const RuleCompiler().loadRuntime(
          jsonDecode(
            File(
              'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
            ).readAsStringSync(),
          ) as Map<String, dynamic>,
        ),
      );
      live = (await RealtimeSmsRepository(db).receive(
        BankSms(
          sender: 'AX-SBIUPI-S',
          receivedAt: DateTime(2026, 10, 26, 1),
          body: 'Dear SBI User, your A/c X9999-credited by Rs.500 on 26Oct26 transfer from SAMPLE SENDER Ref No 999999999999 -SBI',
        ),
        engine,
      ))!;
      // The new bank account is created and the credit saved straight away.
      expect(live.transactionId, isNotNull);
      await showSmsNotification(db, live);
      expect(notifications.last['newAccount'], isTrue);
      expect(notifications.last['needsAccount'], isFalse);
      expect(notifications.last['credit'], isTrue);
      expect(notifications.last['amount'], startsWith('+'));
      expect(notifications.last['account'], live.sms.bankName);
      expect(notifications.last['title'], startsWith('Received '));
      expect(notifications.last['text'], endsWith('New account'));
      expect(notifications.last['text'], isNot(contains('9999')));
      // Undo removes the account; Add account then creates it without a form.
      await open(tester, 'undo_account');
      expect(notifications.last['newAccount'], isFalse);
      expect(notifications.last['needsAccount'], isTrue);
      await open(tester, 'create_account');
      expect(find.byType(EditAccountScreen), findsNothing);
      expect(notifications.last['newAccount'], isTrue);
      final account = (await AccountRepository(
        db,
      ).load()).singleWhere((a) => a.lastDigits == '9999');
      expect(account.name, live.sms.bankName);
      expect(account.institution, live.sms.bankName);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('possible match requires confirmation before combining', (
    tester,
  ) async {
    final accounts = AccountRepository(db);
    final savings = (await accounts.load()).firstWhere(
      (a) => a.name == 'Savings',
    );
    await accounts.save(
      existing: savings,
      name: savings.name,
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      lastDigits: '5678',
      institution: live.sms.bankName,
    );
    final engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
    await RealtimeSmsRepository(db).receive(
      BankSms(
        sender: 'AX-SBIUPI-S',
        receivedAt: live.sms.receivedAt,
        body: 'Dear SBI User, your A/c X5678-credited by Rs.500 on 26Oct26 transfer from SAMPLE SENDER Ref No 999999999999 -SBI',
      ),
      engine,
    );
    await open(tester, 'category');
    await tester.tap(find.text('Between my accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Savings'));
    await settle(tester);
    expect(find.text('Possible matching transaction'), findsOneWidget);
    expect(find.text('Keep separate'), findsOneWidget);
    await tester.tap(find.textContaining('· Savings'));
    await tester.pumpAndSettle();
    expect(find.text('Combine as transfer'), findsOneWidget);
    expect(
      await tester.runAsync(() => TransactionRepository(db).load()),
      hasLength(2),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(() => TransactionRepository(db).load()),
      hasLength(2),
    );
    await tester.tap(find.text('Savings'));
    await settle(tester);
    await tester.tap(find.textContaining('· Savings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Combine as transfer'));
    await settle(tester);
    expect(
      await tester.runAsync(() => TransactionRepository(db).load()),
      hasLength(1),
    );
    expect(notifications.single['category'], 'Transfer → Savings');
  });

  testWidgets(
    'account action uses searchable transaction sheet and updates the same notification',
    (tester) async {
      await open(tester, 'account');
      expect(find.text('Search accounts'), findsOneWidget);
      expect(find.text('Add account'), findsOneWidget);
      await tester.tap(find.text('Savings'));
      await settle(tester);
      expect(find.byType(SmsNotificationPicker), findsNothing);
      expect(notifications.single['id'], live.sms.id);
      expect(notifications.single['account'], 'Savings');
      expect(notifications.single['needsAccount'], isFalse);
      expect(notifications.single['credit'], isFalse);
      expect(notifications.single['amount'], startsWith('−'));
      expect(notifications.single['amount'], isNot(contains('State Bank')));
      expect(notifications.single['title'], startsWith('Spent '));
      expect(notifications.single['title'], isNot(contains('1234')));
      expect(notifications.single['text'], isNot(contains('1234')));
    },
  );

  testWidgets(
    'category action keeps category/subcategory flow and transfer choice',
    (tester) async {
      await open(tester, 'category');
      expect(find.text('Search categories'), findsOneWidget);
      expect(find.text('Between my accounts'), findsOneWidget);
      expect(find.text('Salary'), findsNothing);
      await tester.tap(find.text('Food & Beverage'));
      await tester.pumpAndSettle();
      expect(find.text('Choose subcategory'), findsOneWidget);
      expect(find.text('Use Food & Beverage only'), findsOneWidget);
      await tester.tap(find.text('Groceries'));
      await settle(tester);
      expect(find.byType(SmsNotificationPicker), findsNothing);
      expect(notifications.single['category'], 'Groceries');
      expect(notifications.single['savedTitle'], 'Saved as Groceries');
      expect(notifications.single['undoToken'], isNotEmpty);
    },
  );

  testWidgets('system Back from subcategories returns to the categories', (
    tester,
  ) async {
    await open(tester, 'category');
    await tester.tap(find.text('Food & Beverage'));
    await tester.pumpAndSettle();
    expect(find.text('Choose subcategory'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SmsNotificationPicker), findsOneWidget);
    expect(find.text('Choose subcategory'), findsNothing);
    expect(find.text('Between my accounts'), findsOneWidget);
    // From the first page the same gesture closes the sheet.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SmsNotificationPicker), findsNothing);
  });

  testWidgets('transfer opens the same account sheet and excludes the source', (
    tester,
  ) async {
    await open(tester, 'category');
    await tester.tap(find.text('Between my accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Transferred to'), findsOneWidget);
    expect(find.text('Primary'), findsNothing);
    await tester.tap(find.text('Savings'));
    await settle(tester);
    expect(notifications.single['category'], 'Transfer → Savings');
  });

  testWidgets(
    'pills never offer the catch-all, and a tap files the transaction',
    (tester) async {
      await showSmsNotification(db, live);
      final pills = (notifications.last['suggestions'] as List).cast<Map>();
      expect(pills.length, inInclusiveRange(1, 2));
      expect(pills.map((p) => p['label']), isNot(contains('Other Expense')));
      // Tapping one files the transaction under it, as the background job does.
      final repo = RealtimeSmsRepository(db);
      await repo.selectCategory(
        live.sms.id,
        pills.first['id'] as int,
        accountId: live.accountId,
      );
      expect((await repo.load(live.sms.id))!.categoryId, pills.first['id']);
      await showSmsNotification(db, (await repo.load(live.sms.id))!);
      expect(
        notifications.last['savedTitle'],
        'Saved as ${pills.first['label']}',
      );
      expect(notifications.last['suggestions'], isEmpty);
    },
  );
}
