import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/more/more_screen.dart';

void main() {
  testWidgets('Profile distinguishes loading, signed out and paused sync', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    final repository = SyncRepository(db);
    final sync = SyncController(repository);
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    addTearDown(() async {
      sync.dispose();
      transactions.dispose();
      categories.dispose();
      accounts.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoreScreen(
            store: accounts,
            categoryStore: categories,
            transactionStore: transactions,
            syncController: sync,
          ),
        ),
      ),
    );
    expect(find.text('Loading account…'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsNothing);

    await tester.runAsync(sync.refresh);
    await tester.pump();
    expect(find.text('Sign in with Google'), findsOneWidget);

    await tester.runAsync(() async {
      await repository.connect('test@example.com', 'test-subject');
      await sync.refresh();
    });
    await tester.pump();
    expect(find.text('Google Drive connected'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsNothing);

    await tester.runAsync(() async {
      await repository.disconnect();
      await sync.refresh();
    });
    await tester.pump();
    expect(find.text('test@example.com'), findsOneWidget);
    expect(find.text('Sync is off'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsNothing);
  });
}
