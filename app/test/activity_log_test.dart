import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/sync_activity.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/history/change_history.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/more/activity/activity_log_screen.dart';

import 'multi_device_merge_test.dart' show Phone, SharedDrive;

void main() {
  group('change history', () {
    late Phone phone;
    late ChangeHistoryRepository history;
    late int cash;
    setUp(() async {
      phone = Phone(SharedDrive());
      history = ChangeHistoryRepository(phone.db);
      cash = await phone.accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
    });
    tearDown(() => phone.db.close());

    Future<void> edit(int id, int amount, String title) =>
        phone.transactions.updateExpenseOrIncome(
          id: id,
          type: TransactionType.expense,
          amountMinor: amount,
          accountId: cash,
          categoryId: 1,
          title: title,
          date: DateTime(2026, 11, 18),
        );

    test('keeps every add, edit and delete made here, newest first', () async {
      final id = await phone.spend(cash, 2500, title: 'Lunch');
      await edit(id, 3000, 'Lunch out');
      await phone.transactions.delete(id);
      final log = await history.load();
      expect(log.map((c) => c.action), [
        ChangeAction.deleted,
        ChangeAction.edited,
        ChangeAction.added,
      ]);
      expect(log.every((c) => c.device == null), isTrue);
      expect(log[1].changedColumns, containsAll(['amount_minor', 'title']));
      expect(log[1].before?['title'], 'Lunch');
      expect(log[1].after?['title'], 'Lunch out');
      expect(log.first.record['title'], 'Lunch out');
    });

    test('undoing an add deletes it and puts the balance back', () async {
      await phone.spend(cash, 2500);
      await history.undo((await history.load()).single.id);
      expect(await phone.ledger(), isEmpty);
      expect((await phone.account(cash)).balanceMinor, 100000);
      expect((await phone.account(cash)).transactionCount, 0);
      final log = await history.load();
      expect(log.first.action, ChangeAction.deleted);
      expect(log.last.undone, isTrue);
    });

    test('undoing a delete brings it back with its balance', () async {
      final id = await phone.spend(cash, 2500, title: 'Lunch');
      await phone.transactions.delete(id);
      expect((await phone.account(cash)).balanceMinor, 100000);
      await history.undo((await history.load()).first.id);
      expect((await phone.ledger()).single.title, 'Lunch');
      expect((await phone.account(cash)).balanceMinor, 100000 - 2500);
    });

    test('undoing an edit restores the earlier amount and balance', () async {
      final id = await phone.spend(cash, 2500, title: 'Lunch');
      await edit(id, 4000, 'Dinner');
      await history.undo((await history.load()).first.id);
      final only = (await phone.ledger()).single;
      expect(only.title, 'Lunch');
      expect(only.amountMinor, 2500);
      expect((await phone.account(cash)).balanceMinor, 100000 - 2500);
    });

    test('a change edited again since must wait for the newer one', () async {
      final id = await phone.spend(cash, 2500, title: 'Lunch');
      await edit(id, 3000, 'Second');
      final added = (await history.load()).last;
      expect(() => history.undo(added.id), throwsStateError);
      await history.undo((await history.load()).first.id); // the edit
      await history.undo(added.id); // now the add
      expect(await phone.ledger(), isEmpty);
      expect(() => history.undo(added.id), throwsStateError); // already
    });
  });

  group('across phones', () {
    late SharedDrive drive;
    late Phone a, b;
    late int cash;
    setUp(() async {
      drive = SharedDrive();
      a = Phone(drive);
      b = Phone(drive);
      await a.repository.setDeviceName('Pixel 8');
      await a.repository.connect('me@example.com', 'me');
      cash = await a.accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      await a.upload();
      await b.repository.connect('me@example.com', 'me');
      await b.engine.restore((await b.engine.findBackup())!);
      await b.upload();
    });
    tearDown(() async {
      await a.db.close();
      await b.db.close();
    });

    test('a restore doesn\'t fill the log', () async {
      expect(await ChangeHistoryRepository(b.db).load(), isEmpty);
    });

    test('changes from another phone are logged with its name', () async {
      await a.spend(cash, 2500, title: 'Lunch');
      await a.upload();
      await b.pull();
      final change = (await ChangeHistoryRepository(b.db).load()).single;
      expect(change.action, ChangeAction.added);
      expect(change.device, 'Pixel 8');
      expect(change.record['title'], 'Lunch');
    });

    test('an undo here reaches the other phone', () async {
      await a.spend(cash, 2500, title: 'Lunch');
      await a.upload();
      await b.pull();
      final history = ChangeHistoryRepository(b.db);
      await history.undo((await history.load()).single.id);
      await b.upload();
      await a.pull();
      for (final phone in [a, b]) {
        expect(await phone.ledger(), isEmpty);
        expect((await phone.account(cash)).balanceMinor, 100000);
      }
      final there = (await ChangeHistoryRepository(a.db).load()).first;
      expect(there.action, ChangeAction.deleted);
      expect(there.device, isNotNull);
    });
  });

  testWidgets('the screen shows each change as its transaction', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    final repository = SyncRepository(db);
    final sync = SyncController(
      repository,
      engine: SyncEngine(repository, openTransport: (_) async => SharedDrive()),
    );
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    addTearDown(() async {
      sync.dispose();
      await db.close();
    });
    await tester.runAsync(() async {
      final cash = await AccountRepository(db).save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      final transactions = TransactionRepository(db);
      final id = await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 25000,
        accountId: cash,
        categoryId: 1,
        title: 'Lunch',
        date: DateTime(2026, 11, 18),
      );
      await transactions.delete(id);
      await repository.logActivity(SyncActivityKind.connected, message: 'me@x');
      await accounts.load();
      await categories.load();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ActivityLogScreen(
          database: db,
          accounts: accounts,
          categories: categories,
          sync: sync,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Lunch'), findsNWidgets(2));
    expect(find.textContaining('Added ·'), findsOneWidget);
    expect(find.textContaining('Deleted ·'), findsOneWidget);
    expect(find.text('Sync turned on'), findsOneWidget);

    // Sorted by amount: no day groups, and no sync events.
    expect(find.text('Today'), findsWidgets);
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amount'));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsNothing);
    expect(find.text('Sync turned on'), findsNothing);
    expect(find.text('Lunch'), findsNWidgets(2));

    // The tabs swipe: from All, one swipe left is Added.
    await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.textContaining('Added ·'), findsOneWidget);
    expect(find.textContaining('Deleted ·'), findsNothing);
    await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Nothing edited yet.'), findsOneWidget);

    await tester.tap(find.text('Deleted'));
    await tester.pumpAndSettle();
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.textContaining('Added ·'), findsNothing);

    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted transaction'), findsOneWidget);
    expect(find.text('Undo · bring it back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
