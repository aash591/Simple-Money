import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/components/charts/charts.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/recurring_payment_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/recurring_payment.dart';
import 'package:simple_money/domain/recurring_suggestions.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/recurring_payment_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/detail_page.dart';
import 'package:simple_money/ui/more/loans/loan_review_card.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/more/more_screen.dart';
import 'package:simple_money/ui/more/recurring/recurring_payment_detail_screen.dart';
import 'package:simple_money/ui/more/recurring/recurring_payments_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

RecurringPaymentDraft draft({
  String name = 'Netflix',
  String? icon,
  int amount = 64900,
  BillingCycle cycle = BillingCycle.monthly,
  DateTime? nextDue,
  int accountId = 1,
  int? categoryId,
  bool incoming = false,
}) => RecurringPaymentDraft(
  name: name,
  icon: icon,
  amountMinor: amount,
  cycle: cycle,
  nextDue: nextDue ?? DateTime(2026, 1, 31),
  accountId: accountId,
  categoryId: categoryId,
  remind: false,
  incoming: incoming,
);

void main() {
  test('Names suggest an icon and category, by direction', () {
    expect(suggestRecurring('Rent', incoming: false)?.category, 'Rent');
    expect(suggestRecurring('Rent', incoming: true)?.category, 'Rental Income');
    expect(
      suggestRecurring('Car insurance', incoming: false)?.category,
      'Vehicle Insurance',
    );
    expect(suggestRecurring('Gym', incoming: false)?.icon, 'gym');
    expect(suggestRecurring('Salary', incoming: true)?.category, 'Salary');
    expect(suggestRecurring('Zzz', incoming: false), isNull);
  });

  group('Billing cycles', () {
    test('Month-based renewals keep to the original day', () {
      var due = DateTime(2026, 1, 31);
      final dates = <DateTime>[];
      for (var i = 0; i < 3; i++) {
        due = BillingCycle.monthly.after(due, 31);
        dates.add(due);
      }
      expect(dates, [
        DateTime(2026, 2, 28),
        DateTime(2026, 3, 31),
        DateTime(2026, 4, 30),
      ]);
      expect(
        BillingCycle.yearly.after(DateTime(2028, 2, 29), 29),
        DateTime(2029, 2, 28),
      );
      expect(
        BillingCycle.quarterly.after(DateTime(2026, 11, 30), 30),
        DateTime(2027, 2, 28),
      );
      expect(
        BillingCycle.weekly.after(DateTime(2026, 12, 29), 29),
        DateTime(2027, 1, 5),
      );
    });

    test('Monthly cost spreads other cycles over a month', () {
      expect(BillingCycle.yearly.monthly(120000), 10000);
      expect(BillingCycle.quarterly.monthly(30000), 10000);
      expect(BillingCycle.weekly.monthly(1200), 5200);
      expect(BillingCycle.weekly.yearly(1200), 62400);
      expect(BillingCycle.quarterly.yearly(30000), 120000);
    });

    test('Upcoming renewals land in the months they are charged', () {
      RecurringPayment sub(BillingCycle cycle, DateTime due, int amount) =>
          RecurringPayment(
            id: 1,
            name: 'x',
            icon: null,
            amountMinor: amount,
            currency: 'INR',
            digits: 2,
            cycle: cycle,
            nextDue: due,
            day: due.day,
            accountId: 1,
            categoryId: null,
            remind: false,
            paused: false,
          );
      final totals = upcomingRenewals(
        [
          sub(BillingCycle.monthly, DateTime(2026, 9, 20), 100),
          sub(BillingCycle.yearly, DateTime(2026, 11, 2), 5000),
          // Overdue by months: owed once now, then back on schedule.
          sub(BillingCycle.quarterly, DateTime(2026, 3, 10), 300),
        ],
        6,
        now: DateTime(2026, 9, 16),
      );
      expect(totals, [400, 100, 5100, 400, 100, 100]);
      expect(
        upcomingRenewals(
          [
            sub(BillingCycle.monthly, DateTime(2026, 9, 20), 100),
            sub(BillingCycle.yearly, DateTime(2026, 11, 2), 5000),
            sub(BillingCycle.quarterly, DateTime(2026, 3, 10), 300),
          ],
          6,
          now: DateTime(2026, 9, 16),
          includeOverdue: false,
        ),
        [100, 100, 5100, 400, 100, 100],
        reason: 'Annual fees stay in their renewal month; overdue bills are separate.',
      );
      // Money coming in is totalled on its own, never mixed with what goes out.
      final rent = RecurringPayment(
        id: 9,
        name: 'Rent',
        icon: null,
        amountMinor: 2500,
        currency: 'INR',
        digits: 2,
        cycle: BillingCycle.monthly,
        nextDue: DateTime(2026, 9, 20),
        day: 20,
        accountId: 1,
        categoryId: null,
        remind: false,
        paused: false,
        incoming: true,
      );
      final both = [
        sub(BillingCycle.monthly, DateTime(2026, 9, 20), 100),
        rent,
      ];
      expect(upcomingRenewals(both, 3, now: DateTime(2026, 9, 16)), [
        100,
        100,
        100,
      ]);
      expect(
        upcomingRenewals(both, 3, now: DateTime(2026, 9, 16), incoming: true),
        [2500, 2500, 2500],
      );
    });
  });

  group('Repository', () {
    late AppDatabase db;
    late RecurringPaymentRepository repository;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory(), false);
      repository = RecurringPaymentRepository(db);
      await AccountRepository(
        db,
      ).save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 1000000);
    });
    tearDown(() => db.close());
    Future<RecurringPayment> current() async =>
        (await repository.load()).single;

    test('Adding takes the account currency and renewal day', () async {
      await repository.add(draft());
      final s = await current();
      expect(s.name, 'Netflix');
      expect(s.currency, 'INR');
      expect(s.digits, 2);
      expect(s.day, 31);
      expect(s.nextDue, DateTime(2026, 1, 31));
      expect(
        () => repository.add(draft(name: '  ')),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.add(draft(accountId: 99)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'Money coming in is logged as income and credits the account',
      () async {
        await repository.add(
          draft(name: 'Rent', amount: 2500000, incoming: true),
        );
        final s = await current();
        expect(s.incoming, isTrue);
        await repository.markPaid(s, date: DateTime(2026, 1, 31, 10));
        final paid = (await TransactionRepository(db).load()).single;
        expect(paid.type, TransactionType.income);
        expect(paid.title, 'Rent');
        final categories = await CategoryRepository(db).load();
        expect(
          categories.firstWhere((c) => c.id == paid.categoryId).name,
          'Rental Income',
        );
        expect(
          (await AccountRepository(db).load()).single.balanceMinor,
          1000000 + 2500000,
        );
        expect((await current()).nextDue, DateTime(2026, 2, 28));
      },
    );

    test('Mark paid logs one expense and moves to the next renewal', () async {
      await repository.add(draft());
      final s = await current();
      await repository.markPaid(s, date: DateTime(2026, 1, 31, 10));
      final transactions = await TransactionRepository(db).load();
      expect(transactions.single.amountMinor, 64900);
      expect(transactions.single.title, 'Netflix');
      final categories = await CategoryRepository(db).load();
      expect(
        categories
            .firstWhere((c) => c.id == transactions.single.categoryId)
            .name,
        'Subscriptions',
      );
      expect(
        (await AccountRepository(db).load()).single.balanceMinor,
        1000000 - 64900,
      );
      expect((await current()).nextDue, DateTime(2026, 2, 28));
      // The same renewal can't be paid twice from a stale copy.
      expect(
        () => repository.markPaid(s, date: DateTime(2026, 1, 31)),
        throwsA(isA<StateError>()),
      );
      expect(await TransactionRepository(db).load(), hasLength(1));
    });

    test('Payment history lists what was charged, newest first', () async {
      await repository.add(draft());
      expect(await repository.payments((await current()).id), isEmpty);
      await repository.markPaid(await current(), date: DateTime(2026, 1, 31));
      await repository.markPaid(await current(), date: DateTime(2026, 2, 28));
      final id = (await current()).id;
      final history = await repository.payments(id);
      expect(history.map((p) => p.date), [
        DateTime(2026, 2, 28),
        DateTime(2026, 1, 31),
      ]);
      expect(history.every((p) => p.amountMinor == 64900), isTrue);
      expect(history.first.account, 'Cash');
      // A skipped renewal records nothing, so it never shows up here.
      await repository.skip(await current());
      expect(await repository.payments(id), hasLength(2));
      // Deleting the expense drops the payment with it.
      await TransactionRepository(db).delete(history.first.transactionId);
      expect(await repository.payments(id), hasLength(1));
    });

    test('A payment wears its subscription logo, badged', () async {
      await repository.add(draft(icon: 'brand:netflix'));
      await repository.markPaid(await current(), date: DateTime(2026, 1, 31));
      final transactions = TransactionRepository(db);
      final paid = (await transactions.load()).single;
      expect(paid.icon, 'brand:netflix');
      expect(paid.badgeIcon, 'subscriptions');

      // Without a logo of its own it just shows the recurring payment mark.
      await repository.add(draft(name: 'Gym'));
      final gym = (await repository.load()).firstWhere((s) => s.name == 'Gym');
      await repository.markPaid(gym, date: DateTime(2026, 1, 31));
      final gymPaid = (await transactions.load()).firstWhere(
        (t) => t.title == 'Gym',
      );
      expect(gymPaid.icon, 'subscriptions');
      expect(gymPaid.badgeIcon, isNull);

      // Deleting either side drops the link, never the payment.
      await transactions.delete(gymPaid.id);
      await repository.delete(
        (await repository.load()).firstWhere((s) => s.name == 'Netflix').id,
      );
      final left = (await transactions.load()).single;
      expect(left.icon, isNull);
      expect(left.badgeIcon, isNull);
      expect(
        await db.customSelect('SELECT * FROM recurring_payment_history').get(),
        isEmpty,
      );
    });

    test('Upgrading a v15 ledger links payments already marked paid', () async {
      final directory = await Directory.systemTemp.createTemp('subs_');
      final file = File('${directory.path}/ledger.sqlite');
      final old = AppDatabase(NativeDatabase(file), false);
      await AccountRepository(
        old,
      ).save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 500000);
      final oldRepository = RecurringPaymentRepository(old);
      await oldRepository.add(draft(icon: 'brand:netflix'));
      await oldRepository.markPaid(
        (await oldRepository.load()).single,
        date: DateTime(2026, 1, 31),
      );
      await old.customStatement('DROP TABLE recurring_payment_history');
      // Back to how a v15 install had it: the old name, no direction column,
      // and triggers under the old name.
      for (final operation in ['insert', 'update', 'delete']) {
        await old.customStatement(
          'DROP TRIGGER IF EXISTS sync_recurring_payments_$operation',
        );
      }
      await old.customStatement(
        'ALTER TABLE recurring_payments DROP COLUMN incoming',
      );
      await old.customStatement(
        'ALTER TABLE recurring_payments RENAME TO subscriptions',
      );
      await old.customStatement('PRAGMA user_version = 15');
      await old.close();
      final upgraded = AppDatabase(NativeDatabase(file), false);
      try {
        final paid = (await TransactionRepository(upgraded).load()).single;
        expect(paid.icon, 'brand:netflix');
        expect(paid.badgeIcon, 'subscriptions');
        final queued = await upgraded
            .customSelect(
              "SELECT * FROM sync_outbox WHERE table_name = 'recurring_payment_history'",
            )
            .get();
        expect(queued, hasLength(1));
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    });

    test('Skip moves on without logging a payment', () async {
      await repository.add(draft());
      await repository.skip(await current());
      expect((await current()).nextDue, DateTime(2026, 2, 28));
      expect(await TransactionRepository(db).load(), isEmpty);
    });

    test('Resuming picks up at the next renewal from today', () async {
      final today = dateOnly(DateTime.now());
      await repository.add(
        draft(nextDue: DateTime(today.year, today.month - 3, 1)),
      );
      await repository.setPaused(await current(), true);
      expect((await current()).paused, isTrue);
      await repository.setPaused(await current(), false);
      final resumed = await current();
      expect(resumed.paused, isFalse);
      expect(resumed.nextDue.isBefore(today), isFalse);
      expect(
        resumed.nextDue.isBefore(DateTime(today.year, today.month + 1, 2)),
        isTrue,
      );
    });

    test('Deleting its account or category detaches them', () async {
      final categories = await CategoryRepository(db).load();
      final food = categories.firstWhere((c) => c.parentId == null);
      await repository.add(draft(categoryId: food.id));
      await CategoryRepository(db).delete(food.id);
      expect((await current()).categoryId, isNull);
      await AccountRepository(db).delete(1);
      final s = await current();
      expect(s.accountId, isNull);
      expect(
        () => repository.markPaid(s, date: DateTime.now()),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Mark paid can come from another account in its currency', () async {
      final accounts = AccountRepository(db);
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      await accounts.save(
        name: 'Travel',
        currency: 'USD',
        digits: 2,
        openingBalance: 0,
      );
      final bank = (await accounts.load()).firstWhere((a) => a.name == 'Bank');
      final travel = (await accounts.load()).firstWhere(
        (a) => a.name == 'Travel',
      );
      await repository.add(draft());
      final s = await current();
      await expectLater(
        repository.markPaid(
          s,
          date: DateTime(2026, 1, 20),
          accountId: travel.id,
        ),
        throwsA(isA<ArgumentError>()),
      );
      await repository.markPaid(
        s,
        date: DateTime(2026, 1, 20),
        accountId: bank.id,
      );
      final paid = (await TransactionRepository(db).load()).single;
      expect(paid.accountId, bank.id);
      expect(paid.date, DateTime(2026, 1, 20));
      // Its own account stays the default for next time.
      expect((await current()).accountId, 1);
    });

    test('Changes are queued for sync', () async {
      await repository.add(draft());
      final queued = await db
          .customSelect(
            "SELECT * FROM sync_outbox WHERE table_name = 'recurring_payments'",
          )
          .get();
      expect(queued, hasLength(1));
    });

    test('Upgrading a v40 ledger renames the tables and keeps its data', () async {
      final directory = await Directory.systemTemp.createTemp('subs_');
      final file = File('${directory.path}/ledger.sqlite');
      final old = AppDatabase(NativeDatabase(file), false);
      await AccountRepository(
        old,
      ).save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 500000);
      final repository = RecurringPaymentRepository(old);
      await repository.add(draft(icon: 'brand:netflix'));
      await repository.markPaid(
        (await repository.load()).single,
        date: DateTime(2026, 1, 31),
      );
      // Back to the v40 shape: old names, no direction column.
      for (final table in ['recurring_payments', 'recurring_payment_history']) {
        for (final operation in ['insert', 'update', 'delete']) {
          await old.customStatement(
            'DROP TRIGGER IF EXISTS sync_${table}_$operation',
          );
        }
      }
      await old.customStatement(
        'ALTER TABLE recurring_payments DROP COLUMN incoming',
      );
      await old.customStatement(
        'ALTER TABLE recurring_payments RENAME TO subscriptions',
      );
      await old.customStatement(
        'ALTER TABLE recurring_payment_history RENAME TO subscription_payments',
      );
      await old.customStatement(
        'ALTER TABLE subscription_payments RENAME COLUMN recurring_payment_id TO subscription_id',
      );
      await old.customStatement('PRAGMA user_version = 40');
      await old.close();
      final upgraded = AppDatabase(NativeDatabase(file), false);
      try {
        final loaded = await RecurringPaymentRepository(upgraded).load();
        expect(loaded.single.name, 'Netflix');
        expect(loaded.single.incoming, isFalse);
        final paid = (await TransactionRepository(upgraded).load()).single;
        expect(paid.badgeIcon, 'subscriptions');
        final link = await TransactionRepository(upgraded).link(paid.id);
        expect(link?.name, 'Netflix');
        // Changes keep reaching the sync queue under the new name.
        await RecurringPaymentRepository(upgraded).add(draft(name: 'Gym'));
        final queued = await upgraded
            .customSelect(
              "SELECT * FROM sync_outbox WHERE table_name = 'recurring_payments'",
            )
            .get();
        expect(queued, isNotEmpty);
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    });

    test('Upgrading a v14 ledger adds subscriptions with sync', () async {
      final directory = await Directory.systemTemp.createTemp('subs_');
      final file = File('${directory.path}/ledger.sqlite');
      final old = AppDatabase(NativeDatabase(file), false);
      await AccountRepository(
        old,
      ).save(name: 'Existing', currency: 'INR', digits: 2, openingBalance: 500);
      // Dropping the table drops its sync triggers too, as on a v14 install.
      await old.customStatement('DROP TABLE recurring_payments');
      await old.customStatement('PRAGMA user_version = 14');
      await old.close();
      final upgraded = AppDatabase(NativeDatabase(file), false);
      try {
        expect(
          (await AccountRepository(upgraded).load()).single.balanceMinor,
          500,
        );
        await RecurringPaymentRepository(upgraded).add(draft());
        final queued = await upgraded
            .customSelect(
              "SELECT * FROM sync_outbox WHERE table_name = 'recurring_payments'",
            )
            .get();
        expect(queued, hasLength(1));
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    });
  });

  group('Screens', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory(), false);
      await AccountRepository(
        db,
      ).save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 1000000);
    });
    tearDown(() => db.close());

    Future<RecurringPaymentStore> store() async {
      final accounts = AccountStore(AccountRepository(db));
      final categories = CategoryStore(CategoryRepository(db));
      final transactions = TransactionStore(
        TransactionRepository(db),
        accounts,
      );
      final recurringPayments = RecurringPaymentStore(
        RecurringPaymentRepository(db),
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      );
      await Future.wait([
        accounts.load(),
        categories.load(),
        transactions.load(),
      ]);
      await recurringPayments.load();
      addTearDown(() {
        recurringPayments.dispose();
        transactions.dispose();
        categories.dispose();
        accounts.dispose();
      });
      return recurringPayments;
    }

    testWidgets('More lists Recurring payments, with Settings second to last', (
      tester,
    ) async {
      final recurringPayments = await tester.runAsync(store);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: MoreScreen(
              store: recurringPayments!.accountStore,
              categoryStore: recurringPayments.categoryStore,
              transactionStore: recurringPayments.transactionStore,
              recurringPaymentStore: recurringPayments,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final titles = [
        'Manage Accounts',
        'Categories',
        'Recurring payments',
        'Settings',
        'About SimpleMoney',
      ];
      final tops = [
        for (final title in titles) tester.getTopLeft(find.text(title)).dy,
      ];
      expect(tops, [...tops]..sort());
      await tester.ensureVisible(find.text('Recurring payments'));
      await tester.tap(find.text('Recurring payments'));
      await tester.pumpAndSettle();
      expect(find.byType(RecurringPaymentsScreen), findsOneWidget);
      expect(find.text('No recurring payments yet.'), findsOneWidget);
    });

    testWidgets('Typing a name suggests its category, until one is picked', (
      tester,
    ) async {
      final payments = await tester.runAsync(store);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: RecurringPaymentsScreen(store: payments!),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add recurring payment'));
      await tester.pumpAndSettle();
      for (final digit in '9000'.split('')) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'House rent');
      await tester.pumpAndSettle();
      expect(find.text('Rent'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Electricity bill');
      await tester.pumpAndSettle();
      expect(find.text('Electricity'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('A recurring payment can be money coming in', (tester) async {
      final recurringPayments = await tester.runAsync(store);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: RecurringPaymentsScreen(store: recurringPayments!),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add recurring payment'));
      await tester.pumpAndSettle();
      for (final digit in '2500'.split('')) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Rent');
      await tester.tap(find.text('Money coming in'));
      await tester.pumpAndSettle();
      expect(find.text('Paid into'), findsOneWidget);
      expect(find.text('Rental Income'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final saved = (await tester.runAsync(recurringPayments.repository.load))!
          .single;
      expect(saved.incoming, isTrue);
      expect(find.text('Mark received'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Adding one from the list saves it and shows its card', (
      tester,
    ) async {
      final recurringPayments = await tester.runAsync(store);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: RecurringPaymentsScreen(store: recurringPayments!),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add recurring payment'));
      await tester.pumpAndSettle();
      expect(find.text('How much does it cost?'), findsOneWidget);
      for (final digit in '649'.split('')) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Spotify');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final saved = (await tester.runAsync(recurringPayments.repository.load))!
          .single;
      expect(saved.name, 'Spotify');
      expect(saved.amountMinor, 64900);
      expect(saved.icon, 'brand:spotify');
      expect(
        find.descendant(
          of: find.byType(RecurringPaymentCard),
          matching: find.text('Spotify'),
        ),
        findsOneWidget,
      );
      expect(find.text('Mark paid'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tapping one opens its page, not the edit form', (
      tester,
    ) async {
      final recurringPayments = await tester.runAsync(() async {
        final s = await store();
        final today = dateOnly(DateTime.now());
        await s.repository.add(
          draft(name: 'Netflix', amount: 64900, nextDue: today),
        );
        // One renewal already paid, so the page has history to show.
        await s.repository.markPaid(
          (await s.repository.load()).single,
          date: today,
        );
        await s.repository.add(
          draft(
            name: 'iCloud',
            amount: 219000,
            cycle: BillingCycle.yearly,
            nextDue: DateTime(today.year + 1, 3, 9),
          ),
        );
        await s.load();
        return s;
      });
      tester.view.physicalSize = const Size(430, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: RecurringPaymentsScreen(store: recurringPayments!),
        ),
      );
      await tester.pumpAndSettle();
      // The chart legend names them too, so aim at the card itself.
      Finder card(String name) => find.descendant(
        of: find.byType(RecurringPaymentCard),
        matching: find.text(name),
      );
      await tester.ensureVisible(card('Netflix'));
      await tester.pumpAndSettle();
      await tester.tap(card('Netflix'));
      await tester.pumpAndSettle();

      expect(find.byType(RecurringPaymentDetailScreen), findsOneWidget);
      // Built from the shell the Loan and Debt pages share.
      expect(find.byType(DetailHero), findsOneWidget);
      expect(find.byType(DetailFacts), findsOneWidget);
      expect(find.byType(LoanFactTile), findsNothing);
      expect(find.byType(DetailHistoryCard), findsOneWidget);
      // The page, not the form: no Save/Cancel pair waiting on the user.
      expect(find.text('Save'), findsNothing);
      expect(find.text('Next due'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Payments'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      // The renewal date is spelled out the way it would be said aloud.
      expect(find.textContaining('of each month'), findsOneWidget);
      expect(find.text('Cash'), findsWidgets);
      // The paid renewal is listed rather than the empty-state line.
      expect(find.textContaining('No payments recorded yet'), findsNothing);
      expect(find.text('₹649'), findsWidgets);
      // Both next-renewal actions are offered up front.
      expect(find.text('Record advance payment'), findsOneWidget);
      expect(find.text('Skip this one'), findsOneWidget);

      await tester.tap(find.text('Record advance payment'));
      await tester.pumpAndSettle();
      expect(find.text('Future payment'), findsOneWidget);
      final advanceButton = find
          .widgetWithText(GlassButton, 'Record advance payment')
          .last;
      expect(tester.widget<GlassButton>(advanceButton).onPressed, isNull);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(tester.widget<GlassButton>(advanceButton).onPressed, isNotNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // Opening the next payment again must require a fresh acknowledgment.
      await tester.tap(find.text('Record advance payment'));
      await tester.pumpAndSettle();
      expect(tester.widget<GlassButton>(advanceButton).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // A yearly plan names its month — "9th of each month" would be useless
      // — and shows what it works out to against everything else.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(card('iCloud'));
      await tester.pumpAndSettle();
      await tester.tap(card('iCloud'));
      await tester.pumpAndSettle();
      expect(find.text('9th March, every year'), findsOneWidget);
      expect(find.text('₹182.50 a month'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Forecast shows future bill months and excludes paused plans', (
      tester,
    ) async {
      final recurringPayments = await tester.runAsync(() async {
        final s = await store();
        final today = dateOnly(DateTime.now());
        await s.repository.add(draft(name: 'Netflix', nextDue: today));
        await s.repository.add(
          draft(
            name: 'iCloud',
            amount: 7500,
            nextDue: DateTime(today.year, today.month, today.day + 3),
          ),
        );
        await s.repository.add(draft(name: 'Gym', nextDue: today));
        await s.repository.setPaused(
          (await s.repository.load()).firstWhere((x) => x.name == 'Gym'),
          true,
        );
        await s.load();
        return s;
      });
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: RecurringPaymentsScreen(store: recurringPayments!),
        ),
      );
      await tester.pumpAndSettle();
      // The list uses the same card Home does. A paused recurring payment isn't
      // owed, so a muted "Paused" chip takes the pay button's place;
      // resuming happens in the edit sheet, behind a tap on the card.
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Resume'), findsNothing);
      expect(find.text('Mark paid'), findsNWidgets(2));

      // Mark paid opens a sheet to pick the account and day first.
      await tester.tap(find.text('Mark paid').first);
      await tester.pumpAndSettle();
      expect(find.text('Mark as paid'), findsOneWidget);
      expect(find.text('Paid from'), findsOneWidget);
      expect(find.text('Cash'), findsWidgets);
      expect(find.textContaining('Today · '), findsOneWidget);
      expect(find.text('Next due'), findsOneWidget);
      expect(find.text('Expense recorded'), findsOneWidget);
      expect(find.text('From Cash'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as paid'), findsNothing);
      expect(find.text('Payments by month'), findsOneWidget);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Months'), findsNothing);
      expect(find.byType(BarChart), findsOneWidget);
      final chartWidget = tester.widget<BarChart>(find.byType(BarChart));
      final active = recurringPayments.recurringPayments
          .where((s) => !s.paused)
          .toList();
      expect(
        chartWidget.series.single.values,
        upcomingRenewals(active, 6, now: DateTime.now(), includeOverdue: false),
      );
      chartWidget.onSelect!(1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Paused sorts after everything that's still renewing.
      expect(
        tester.getTopLeft(find.text('Paused')).dy,
        greaterThan(tester.getTopLeft(find.text('Netflix').first).dy),
      );
      expect(
        tester.getTopLeft(find.text('Paused')).dy,
        greaterThan(tester.getTopLeft(find.text('Mark paid').last).dy),
      );
      expect(tester.takeException(), isNull);
      // Exercise the replacement chart independently of the existing overview.
      final chart = tester.widget(
        find.ancestor(
          of: find.text('Payments by month'),
          matching: find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ChartCard',
          ),
        ),
      );
      tester.view.physicalSize = const Size(320, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(body: SingleChildScrollView(child: chart)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
