import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/backup/data_transfer.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/ui/more/accounts/account_card.dart';
import 'package:simple_money/ui/more/accounts/edit_account_screen.dart';
import 'package:simple_money/ui/sms/sms_results_page.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/backup/sync_schema.dart';
import 'package:flutter/rendering.dart';

import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  test(
    'startup creates one default cash account only for an empty ledger',
    () async {
      final database = AppDatabase(NativeDatabase.memory(), false);
      final store = AccountStore(AccountRepository(database));
      try {
        await store.load(initializeDefault: true);
        expect(store.accounts, hasLength(1));
        final cash = store.accounts.single;
        expect(cash.name, 'Cash in hand');
        expect(cash.type, AccountType.cash);
        expect(cash.balanceMinor, 0);
        expect(cash.currency, 'INR');
        await store.load(initializeDefault: true);
        expect(store.accounts, hasLength(1));
        await store.archive(cash.id);
        await store.load(initializeDefault: true);
        expect(store.allAccounts, hasLength(1));
        expect(store.accounts, isEmpty);
      } finally {
        store.dispose();
        await database.close();
      }
    },
  );

  late AppDatabase db;
  late AccountRepository accounts;
  late SmsImportRepository sms;
  late BankSmsParser parser;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory(), false);
    accounts = AccountRepository(db);
    sms = SmsImportRepository(db);
    const compiler = RuleCompiler();
    parser = BankSmsParser(
      compiler.loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
  });
  tearDown(() => db.close());
  test(
    'v24 migration preserves balances and adds synced account metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'account_type_migration_',
      );
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file), false);
      try {
        await AccountRepository(
          disk,
        ).save(name: 'Bank', currency: 'INR', digits: 2, openingBalance: 12345);
        for (final operation in ['insert', 'update', 'delete']) {
          await disk.customStatement('DROP TRIGGER sync_accounts_$operation');
        }
        for (final column in [
          'type',
          'last_digits',
          'institution',
          'credit_limit_minor',
          'available_limit_minor',
          'balance_reported_at',
          'credit_limit_reported_at',
          'available_limit_reported_at',
        ]) {
          await disk.customStatement(
            'ALTER TABLE accounts DROP COLUMN $column',
          );
        }
        await createSyncTriggers(disk, 'accounts');
        await disk.customStatement('PRAGMA user_version=24');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file), false);
        final original = (await AccountRepository(disk).load()).single;
        expect(original.balanceMinor, 12345);
        expect(original.type, AccountType.bank);
        await AccountRepository(disk).save(
          existing: original,
          name: 'Bank',
          currency: 'INR',
          digits: 2,
          openingBalance: 0,
          type: AccountType.creditCard,
          lastDigits: '1234',
          creditLimitMinor: 1000000,
          availableCreditLimitMinor: 900000,
        );
        final row = await disk
            .customSelect(
              "SELECT row_json FROM sync_outbox WHERE table_name='accounts'",
            )
            .getSingle();
        expect(jsonDecode(row.read<String>('row_json'))['type'], 'creditCard');
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('types, identifiers and credit limits persist and export', () async {
    await accounts.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 1000,
      type: AccountType.cash,
    );
    final id = await accounts.save(
      name: 'Card',
      currency: 'INR',
      digits: 2,
      openingBalance: -200000,
      type: AccountType.creditCard,
      lastDigits: '1234',
      creditLimitMinor: 1000000,
      availableCreditLimitMinor: 800000,
    );
    final card = (await accounts.load()).firstWhere((a) => a.id == id);
    expect(card.type, AccountType.creditCard);
    expect(card.lastDigits, '1234');
    expect(card.creditUtilization, .2);
    await accounts.save(
      existing: card,
      name: 'Renamed',
      currency: 'INR',
      digits: 3,
      openingBalance: 0,
    );
    final edited = (await accounts.load()).last;
    expect(edited.creditLimitMinor, 10000000);
    expect(edited.availableCreditLimitMinor, 8000000);
    final exported = jsonDecode(utf8.decode(await exportLedger(db))) as Map;
    expect((exported['tables']['accounts'] as List).last['type'], 'creditCard');
    expect(
      (exported['tables']['accounts'] as List).last['last_digits'],
      '1234',
    );
  });
  test('bulk creation uses snapshots, reuses identifiers and does not double count SMS history', () async {
    final date = DateTime(2026, 10, 7);
    final bank = BankSms(
      sender: 'ATMSBI',
      body: 'Rs.500 debited from A/c X1234 on 07Oct26. Avl Bal Rs.1500',
      receivedAt: date,
    );
    final card = BankSms(
      sender: 'SBICRD',
      body: 'SBI Credit Card XX5678 used for INR 500 at SHOP. Available limit INR 9500.',
      receivedAt: date,
    );
    await sms.enqueue(bank, parser.parse(bank));
    await sms.enqueue(card, parser.parse(card));
    final rows = await sms.pending();
    final credit = rows.firstWhere((r) => r.creditCard);
    await sms.recordBalance({
      ...credit.data,
      'creditLimitMinor': 1000000,
    }, date);
    final groups = await sms.detectedAccounts();
    await sms.createDetectedAccounts(groups);
    await sms.createDetectedAccounts(groups);
    var saved = await accounts.load();
    expect(saved, hasLength(2));
    expect(
      saved.firstWhere((a) => a.type == AccountType.bank).balanceMinor,
      150000,
    );
    expect(
      saved
          .firstWhere((a) => a.type == AccountType.creditCard)
          .creditUtilization,
      .05,
    );
    final links = await sms.accountLinks();
    final categories = await CategoryRepository(db).load();
    final category = categories.firstWhere((c) => c.type.name == 'expense');
    for (final row in rows) {
      await sms.save(
        row,
        type: TransactionType.expense,
        amountMinor: row.amountMinor,
        accountId: links[row.bankKey]!,
        categoryId: category.id,
        date: row.receivedAt,
      );
    }
    saved = await accounts.load();
    expect(
      saved.firstWhere((a) => a.type == AccountType.bank).balanceMinor,
      150000,
    );
    expect(
      saved.firstWhere((a) => a.type == AccountType.creditCard).balanceMinor,
      -50000,
    );
    expect(await sms.pending(), isEmpty);
    await sms.recordBalance({
      ...credit.data,
      'availableCreditLimitMinor': 900000,
    }, date.add(const Duration(days: 1)));
    await sms.recordBalance({
      ...credit.data,
      'availableCreditLimitMinor': 990000,
    }, date.subtract(const Duration(days: 1)));
    expect(
      (await accounts.load())
          .firstWhere((a) => a.type == AccountType.creditCard)
          .availableCreditLimitMinor,
      900000,
    );
  });
  test('manual SMS account balance is saved and preserved on retry', () async {
    final message = BankSms(
      sender: 'ATMSBI',
      body: 'Rs.500 debited from A/c X1234 on 07Oct26.',
      receivedAt: DateTime(2026, 10, 7),
    );
    await sms.enqueue(message, parser.parse(message));
    final groups = await sms.detectedAccounts();
    expect(groups, hasLength(1));
    await sms.createDetectedAccounts(
      groups,
      openingBalances: {groups.single.bankKey: 123456},
    );
    await sms.createDetectedAccounts(groups);
    final saved = (await accounts.load()).single;
    expect(saved.balanceMinor, 123456);
    expect(saved.balanceReportedAt, isNotNull);
  });
  test(
    'manual SMS card limits persist and establish the card balance',
    () async {
      final group = PendingSmsImport(
        id: 'card',
        sender: 'SBICRD',
        body: '',
        receivedAt: DateTime(2026, 10, 7),
        data: {
          'countryCode': 'IN',
          'currencyCode': 'INR',
          'bankName': 'SBI',
          'accountLast4': '5678',
          'isCreditCard': true,
        },
      );
      await sms.createDetectedAccounts(
        [group],
        availableLimits: {group.bankKey: 750000},
        creditLimits: {group.bankKey: 1000000},
      );
      await sms.createDetectedAccounts([group]);
      final saved = (await accounts.load()).single;
      expect(saved.availableCreditLimitMinor, 750000);
      expect(saved.creditLimitMinor, 1000000);
      expect(saved.balanceMinor, -250000);
      expect(saved.balanceReportedAt, isNotNull);
    },
  );
  test('balance-only detections create accounts and match manually entered last digits', () async {
    final data = {
      'countryCode': 'IN',
      'currencyCode': 'INR',
      'bankName': 'SBI',
      'accountLast4': '1234',
      'isCreditCard': false,
      'balanceMinor': 150000,
    };
    await sms.recordBalance(data, DateTime(2026, 10, 7));
    final id = await accounts.save(
      name: 'Salary',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      type: AccountType.bank,
      lastDigits: '34',
    );
    final found = await sms.detectedAccounts();
    expect(found, hasLength(1));
    await sms.createDetectedAccounts(found);
    expect(await accounts.load(), hasLength(1));
    expect((await sms.accountLinks())[found.single.bankKey], id);
  });
  testWidgets(
    'shared credit card displays limits and percentage at narrow widths',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AccountCard(
              account: Account(
                id: 1,
                name: 'Credit card',
                currency: 'INR',
                digits: 2,
                balanceMinor: -200000,
                type: AccountType.creditCard,
                lastDigits: '1234',
                creditLimitMinor: 1000000,
                availableCreditLimitMinor: 800000,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Credit limit'), findsOneWidget);
      expect(find.text('Available limit'), findsOneWidget);
      expect(find.text('20.0% used'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('manual credit card creation stores identification and limits', (
    tester,
  ) async {
    final store = AccountStore(accounts);
    await store.load();
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(home: EditAccountScreen(store: store)));
    await tester.tap(find.byKey(const Key('account-type-creditCard')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('account-last-digits')),
      '1234',
    );
    await tester.enterText(
      find.byKey(const Key('account-credit-limit')),
      '10000',
    );
    await tester.enterText(
      find.byKey(const Key('account-available-limit')),
      '8000',
    );
    await tester.ensureVisible(find.byKey(const Key('account-name')));
    await tester.enterText(find.byKey(const Key('account-name')), 'Card');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(GlassButton, 'Add account'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final card = (await accounts.load()).single;
    expect(card.type, AccountType.creditCard);
    expect(card.lastDigits, '1234');
    expect(card.creditLimitMinor, 1000000);
    expect(card.availableCreditLimitMinor, 800000);
    expect(card.creditUtilization, .2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'manual creation asks for type and identification, and cash skips digits',
    (tester) async {
      final store = AccountStore(accounts);
      await store.load();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(home: EditAccountScreen(store: store)),
      );
      await tester.enterText(find.byKey(const Key('account-name')), 'Cash');
      await tester.tap(find.byKey(const Key('account-type-cash')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-last-digits')), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(GlassButton, 'Add account'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect((await accounts.load()).single.type, AccountType.cash);
    },
  );
  testWidgets('SMS reviews shared cards and creates only selected accounts', (
    tester,
  ) async {
    final date = DateTime(2026, 10, 7);
    for (final message in [
      BankSms(
        sender: 'ATMSBI',
        body: 'Rs.500 debited from A/c X1234 on 07Oct26. Avl Bal Rs.1500',
        receivedAt: date,
      ),
      BankSms(
        sender: 'SBICRD',
        body: 'SBI Credit Card XX5678 used for INR 500 at SHOP. Available limit INR 9500. Total credit limit INR 10000.',
        receivedAt: date,
      ),
    ]) {
      await sms.enqueue(message, parser.parse(message));
    }
    final store = SmsImportStore(sms);
    final accountStore = AccountStore(accounts);
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(
      TransactionRepository(db),
      accountStore,
    );
    addTearDown(store.dispose);
    addTearDown(accountStore.dispose);
    addTearDown(categories.dispose);
    addTearDown(transactions.dispose);
    await tester.runAsync(() async {
      await store.reload();
      await accountStore.load();
      await categories.load();
    });
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fontPath = Platform.environment['QA_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        for (final family in ['Roboto', 'Ahem']) {
          final font = FontLoader(family)
            ..addFont(
              File(fontPath).readAsBytes().then((b) => ByteData.sublistView(b)),
            );
          await font.load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          home: SmsResultsPage(
            store: store,
            accounts: accountStore,
            categories: categories,
            transactions: transactions,
            onReview: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Review accounts'), findsOneWidget);
    expect(find.byType(AccountCard), findsNWidgets(2));
    expect(find.text('1 SMS'), findsNWidgets(2));
    expect(find.text('5.0% used'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      tester
          .widgetList<AccountCard>(find.byType(AccountCard))
          .every((card) => !card.selected),
      isTrue,
    );
    final bankSelection = find.byWidgetPredicate(
      (widget) =>
          widget is AccountCard && widget.account.type == AccountType.bank,
    );
    await tester.tap(
      find.descendant(of: bankSelection, matching: find.text('Bank account')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AccountCard>(bankSelection).selected, isTrue);
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('build/sms_review_accounts.png')
          .writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
    await tester.runAsync(() async {
      await tester.tap(find.text('Create 1 account'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('SMS review'), findsOneWidget);
    expect(accountStore.accounts, hasLength(1));
    expect(accountStore.accounts.single.type, AccountType.bank);
    expect(find.byType(EditAccountScreen), findsNothing);
    expect(tester.takeException(), isNull);
    if (fontPath != null) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(Brightness.light),
            home: EditAccountScreen(store: accountStore),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-type-creditCard')));
      await tester.pumpAndSettle();
      final form =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await form.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('build/add_credit_account.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
