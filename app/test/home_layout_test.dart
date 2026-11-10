import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/insights_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/home_layout.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/more/home_layout_screen.dart';
import 'package:simple_money/ui/components/reminder_card.dart';
import 'package:simple_money/ui/home/home_cards.dart';
import 'package:simple_money/ui/more/home_preview_data.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  testWidgets('Every real card draws on example data at narrow width with '
      'large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final example = HomePreviewData.create();
    addTearDown(example.dispose);
    for (final id in HomeCardId.values) {
      final card = buildHomeCard(id, example.context);
      expect(card, isNotNull, reason: '${id.name} has example data');
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(18), child: card),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: id.name);
      // These hide themselves when nothing is due: the example must be due.
      if (const [
        HomeCardId.upcomingEmis,
        HomeCardId.upcomingPayments,
        HomeCardId.upcomingDebts,
      ].contains(id)) {
        expect(find.byType(ReminderCard), findsOneWidget, reason: id.name);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('the committed card shows what you pay and what you get', (
    tester,
  ) async {
    final example = HomePreviewData.create();
    addTearDown(example.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: buildHomeCard(HomeCardId.committed, example.context),
          ),
        ),
      ),
    );
    expect(find.text('To pay'), findsOneWidget);
    expect(find.text('To get'), findsOneWidget);
    expect(
      find.textContaining('Next: HDFC Bank EMI is due tomorrow'),
      findsOneWidget,
    );
    // EMI 16,017 + Netflix 649 out; Alex's 1,500 in.
    expect(find.textContaining('16,666'), findsOneWidget);
    expect(find.textContaining('1,500'), findsWidgets);

    // Tapping a day with a payment lists it underneath; tapping again clears.
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    await tester.tap(find.text('${tomorrow.day}').first);
    await tester.pumpAndSettle();
    expect(find.text('HDFC Bank EMI'), findsOneWidget);
    expect(find.textContaining('Next:'), findsNothing);
    await tester.tap(find.text('${tomorrow.day}').first);
    await tester.pumpAndSettle();
    expect(find.text('HDFC Bank EMI'), findsNothing);
    expect(find.textContaining('Next:'), findsOneWidget);
  });

  testWidgets('the reminder card keeps its action at the right edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final example = HomePreviewData.create();
    addTearDown(example.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: buildHomeCard(HomeCardId.upcomingEmis, example.context),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(ReminderCard));
    final action = tester.getRect(find.text('Mark paid'));
    final chip = tester.getRect(find.text('Due tomorrow'));
    // The action sits against the right edge (card padding and its own
    // arrow), the due date against the left, and the gap between is free.
    expect(card.right - action.right, lessThan(60));
    expect(chip.left - card.left, lessThan(60));
    expect(action.left - chip.right, greaterThan(20));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  group('HomeLayout', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('starts with every card shown in the default order', () async {
      final layout = HomeLayout();
      await layout.restore();
      expect(layout.order, HomeCardId.values);
      expect(layout.visible, HomeCardId.values);
      expect(layout.isDefault, isTrue);
      layout.dispose();
    });

    test('saves order and hidden cards, and restores them', () async {
      final layout = HomeLayout();
      await layout.restore();
      layout.move(HomeCardId.recentTransactions.index, 0);
      layout.setVisible(HomeCardId.netWorth, false);
      expect(layout.order.first, HomeCardId.recentTransactions);
      expect(layout.visible, isNot(contains(HomeCardId.netWorth)));
      expect(layout.isDefault, isFalse);
      await Future<void>.delayed(Duration.zero);
      layout.dispose();

      final restored = HomeLayout();
      await restored.restore();
      expect(restored.order.first, HomeCardId.recentTransactions);
      expect(restored.isVisible(HomeCardId.netWorth), isFalse);
      restored.reset();
      expect(restored.isDefault, isTrue);
      restored.dispose();
    });

    test('drops unknown saved cards and slots new ones in after their '
        'default neighbour', () async {
      SharedPreferences.setMockInitialValues({
        HomeLayout.orderKey: ['recentTransactions', 'gone', 'overview'],
      });
      final layout = HomeLayout();
      await layout.restore();
      expect(layout.order.toSet(), HomeCardId.values.toSet());
      expect(layout.order.length, HomeCardId.values.length);
      // Kept in the saved relative order.
      expect(
        layout.order.indexOf(HomeCardId.recentTransactions),
        lessThan(layout.order.indexOf(HomeCardId.overview)),
      );
      // SMS history follows the card before it by default, including for
      // existing saved layouts.
      expect(
        layout.order.indexOf(HomeCardId.smsHistory),
        layout.order.indexOf(HomeCardId.upcomingDebts) + 1,
      );
      layout.dispose();
    });

    testWidgets('the arrangement screen hides a card', (tester) async {
      final layout = HomeLayout();
      await tester.pumpWidget(
        MaterialApp(home: HomeLayoutScreen(layout: layout)),
      );
      // The name above the real card, and the card's own title.
      expect(find.text('Upcoming EMIs'), findsWidgets);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(layout.isVisible(HomeCardId.values.first), isFalse);
      expect(
        find.text(
          '${HomeCardId.values.length - 1} of ${HomeCardId.values.length} shown',
        ),
        findsOneWidget,
      );
      // Reset lives behind the header's overflow menu, which only becomes
      // tappable once the layout differs from the default.
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();
      expect(layout.isDefault, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      layout.dispose();
    });

    testWidgets('the arrangement screen shows every upcoming card with an '
        'example payment', (tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final layout = HomeLayout();
      await tester.pumpWidget(
        MaterialApp(home: HomeLayoutScreen(layout: layout)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Car · HDFC Bank'), findsOneWidget);
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      layout.dispose();
    });

    testWidgets('press and hold lifts a card so it can be dragged into '
        'place; a plain swipe only scrolls', (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final layout = HomeLayout();
      await tester.pumpWidget(
        MaterialApp(home: HomeLayoutScreen(layout: layout)),
      );
      await tester.pumpAndSettle();
      final second = find.text('Upcoming payments').first;

      // A quick drag does not pick the card up.
      await tester.drag(second, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(layout.order.first, HomeCardId.overview);

      // Held down first, it lifts and can be moved above the one before.
      await tester.pumpAndSettle();
      final start = tester.getCenter(find.text('Upcoming payments').first);
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      final target = tester.getCenter(find.text('Upcoming EMIs').first);
      for (var i = 1; i <= 12; i++) {
        await gesture.moveTo(Offset.lerp(start, target, i / 12)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layout.order[1], HomeCardId.upcomingPayments);
      expect(layout.order[2], HomeCardId.upcomingEmis);
      await tester.pumpWidget(const SizedBox.shrink());
      layout.dispose();
    });
  });

  group('InsightsRepository', () {
    late AppDatabase db;
    late AccountStore accounts;
    late CategoryStore categories;
    late TransactionStore transactions;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      accounts = AccountStore(AccountRepository(db));
      categories = CategoryStore(CategoryRepository(db));
      transactions = TransactionStore(TransactionRepository(db), accounts);
      await accounts.load();
      await categories.load();
      await transactions.load();
      await accounts.save(
        name: 'Wallet',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
    });
    tearDown(() async {
      accounts.dispose();
      categories.dispose();
      transactions.dispose();
      await db.close();
    });

    Future<void> add(
      TransactionType type,
      int amount,
      DateTime date,
      String category,
    ) => transactions.addExpenseOrIncome(
      type: type,
      amountMinor: amount,
      accountId: accounts.accounts.first.id,
      categoryId: categories.categories
          .firstWhere((c) => c.name == category)
          .id,
      date: date,
    );

    test('adds up months and month-end balances', () async {
      await add(TransactionType.expense, 1000, DateTime(2026, 1, 5), 'Cafe');
      await add(TransactionType.expense, 3000, DateTime(2026, 2, 5), 'Cafe');
      await add(TransactionType.expense, 400, DateTime(2026, 2, 25), 'Cafe');
      await add(TransactionType.income, 9000, DateTime(2026, 3, 1), 'Salary');
      await add(TransactionType.expense, 5000, DateTime(2026, 3, 10), 'Cafe');
      await transactions.addTransfer(
        amountMinor: 600,
        fromAccountId: accounts.accounts.first.id,
        toAccountId: accounts.accounts[1].id,
        date: DateTime(2026, 3, 2),
      );

      final result = await InsightsRepository(db)
          .load(DateTime(2026, 3), 'INR', 2);
      expect(result.previousDailyExpenses.length, 28);
      expect(result.previousDailyExpenses[4], 3000);
      expect(result.flows.length, InsightsRepository.months);
      expect(result.flows.last, (
        month: DateTime(2026, 3),
        income: 9000,
        spent: 5000,
      ));
      expect(result.flows[4].spent, 3400);

      // Transfers between the two INR accounts leave the total alone.
      expect(result.balances.last, 100000 - 1000 - 3400 + 9000 - 5000);
      expect(result.balances[4], 100000 - 1000 - 3400);
      expect(result.balances[3], 100000 - 1000);
      expect(result.balances[2], 100000);
    });
  });
}
