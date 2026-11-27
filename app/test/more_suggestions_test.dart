import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/liquid_glass_nav_bar.dart';
import 'package:simple_money/ui/more/more_screen.dart';

void main() {
  testWidgets('Suggestions is its own row in More, next to AI assistant', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    addTearDown(() async {
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
          ),
        ),
      ),
    );
    expect(find.text('AI suggestions'), findsOneWidget);
    expect(find.text('Claude / ChatGPT (MCP)'), findsOneWidget);
    // Pro is offered in one slim row under the profile card.
    expect(find.text('SimpleMoney Pro'), findsOneWidget);
    // Shared fixes now lives in Settings, not here.
    expect(find.text('Community rules'), findsNothing);
  });

  testWidgets('a tab shows a dot only while something is waiting', (
    tester,
  ) async {
    Widget bar({required bool dot}) => MaterialApp(
      home: Scaffold(
        bottomNavigationBar: LiquidGlassNavBar(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          destinations: [
            const LiquidGlassDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: 'Home',
            ),
            LiquidGlassDestination(
              icon: Icons.more_horiz_rounded,
              selectedIcon: Icons.more_horiz_rounded,
              label: 'More',
              dot: dot,
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(bar(dot: false));
    expect(find.byKey(const Key('nav-dot')), findsNothing);
    await tester.pumpWidget(bar(dot: true));
    // The bar draws each tab on two layers, so the dot is on both.
    expect(find.byKey(const Key('nav-dot')), findsWidgets);
  });
}
