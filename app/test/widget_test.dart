import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/ui/more/settings/customization_screen.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:drift/native.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/components/more_popup_button.dart';
import 'package:simple_money/ui/more/categories/categories_screen.dart';

void main() {
  late AppDatabase database;
  late AccountStore store;
  late CategoryStore categoryStore;
  late TransactionStore transactionStore;
  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    store = AccountStore(AccountRepository(database));
    categoryStore = CategoryStore(CategoryRepository(database));
    transactionStore = TransactionStore(TransactionRepository(database), store);
    await store.load();
    await categoryStore.load();
    await transactionStore.load();
  });
  tearDown(() async {
    store.dispose();
    categoryStore.dispose();
    transactionStore.dispose();
    await database.close();
  });
  testWidgets('Customization updates the app and persists choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: store,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customization'));
    await tester.pumpAndSettle();
    expect(find.byType(CustomizationScreen), findsOneWidget);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(CustomizationScreen));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).scaffoldBackgroundColor, Colors.black);
    await tester.ensureVisible(find.byTooltip('Purple'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Purple'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(context).colorScheme.primary,
      CustomizationScreen.colors['Purple'],
    );
    final restored = AppearanceController();
    await restored.restore();
    expect(restored.value, ThemeMode.dark);
    expect(restored.accentColor, CustomizationScreen.colors['Purple']);
    restored.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home screen renders totals and bottom nav', (tester) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: store,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('View month transactions'), findsOneWidget);
    expect(find.text('Net savings'), findsOneWidget);
    expect(find.text('Money out'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
  });

  testWidgets('Reusable more popup opens, dismisses, and selects actions', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              MorePopupButton<int>(
                items: const [
                  MorePopupItem(value: 1, label: 'Edit'),
                  MorePopupItem(
                    value: 2,
                    label: 'Settings',
                    dividerBefore: true,
                  ),
                ],
                onSelected: (value) => selected = value,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.text('Edit'), findsNothing);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('Transactions tab opens the real transaction history screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: store,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    expect(find.text('All your income and expenses'), findsNothing);
    expect(find.text('Total balance'), findsOneWidget);
    expect(find.text('No transactions in this period'), findsOneWidget);
    expect(find.byTooltip('Add transaction'), findsOneWidget);
  });

  testWidgets('Transactions tab shows saved entries and live search results', (
    tester,
  ) async {
    await store.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
    final cafe = categoryStore.categories.firstWhere((c) => c.name == 'Cafe');
    await transactionStore.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 5000,
      accountId: store.accounts.single.id,
      categoryId: cafe.id,
      title: 'Coffee',
      date: DateTime.now(),
    );

    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: store,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Cafe'), findsOneWidget);
    expect(find.text('- ₹50'), findsWidgets);
    expect(find.text('₹950'), findsWidgets);

    await tester.tap(find.byTooltip('Search transactions'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('transaction-search')),
      'salary',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching transactions'), findsOneWidget);
  });

  testWidgets(
    'More opens, hides the add transaction button, and keeps Home intact',
    (tester) async {
      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: store,
          categoryStore: categoryStore,
          transactionStore: transactionStore,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Your profile'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.tap(find.text('Manage Accounts'));
      await tester.pumpAndSettle();
      expect(find.text('Add your first account'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Net savings'), findsOneWidget);
    },
  );

  testWidgets('More opens Security with app lock off by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: store,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Security'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    expect(find.text('App lock'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'App lock'),
          )
          .value,
      isFalse,
    );
  });

  testWidgets(
    'Categories: defaults are seeded per tab, new ones can be added via the '
    'floating + button, and both defaults and their subcategories can be deleted',
    (tester) async {
      // Tall enough that the whole (long) default category list is built by
      // ListView.builder, not just what a phone-sized viewport would show —
      // this test taps items throughout the list, not just the first screenful.
      tester.view.physicalSize = const Size(1080, 5000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: store,
          categoryStore: categoryStore,
          transactionStore: transactionStore,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Categories'));
      await tester.pumpAndSettle();
      expect(find.text('Expense'), findsOneWidget);
      expect(find.text('Food & Beverage'), findsOneWidget);
      expect(find.text('Cafe'), findsOneWidget);

      await tester.tap(find.text('Income'));
      await tester.pumpAndSettle();
      expect(find.text('Salary'), findsOneWidget);

      // Debts and Loans manage their own categories; there's no tab for them.
      expect(find.text('DEBT/LOAN'), findsNothing);
      expect(find.text('Repayment'), findsNothing);

      await tester.tap(find.text('Expense'));
      await tester.pumpAndSettle();

      // Add a new top-level category via the reusable floating + button.
      await tester.tap(find.byTooltip('Add category'));
      await tester.pumpAndSettle();
      expect(find.text('Expense'), findsOneWidget);
      final addButton = find.widgetWithText(GlassButton, 'Add category');
      expect(tester.widget<GlassButton>(addButton).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('category-name')),
        'Pet Supplies',
      );
      await tester.pump();
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      expect(find.text('Pet Supplies'), findsOneWidget);

      // Add a subcategory under an existing default category.
      await tester.tap(find.byTooltip('Add category'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('category-name')),
        'Vet Visits',
      );
      await tester.tap(find.text('Select category'));
      await tester.pumpAndSettle();
      expect(find.text("Type a category's name"), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Food & Beverage');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Food & Beverage'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Add category'));
      await tester.pumpAndSettle();
      expect(find.text('Vet Visits'), findsOneWidget);
      expect(
        categoryStore.categories
            .firstWhere((c) => c.name == 'Vet Visits')
            .parentId,
        categoryStore.categories
            .firstWhere((c) => c.name == 'Food & Beverage')
            .id,
      );

      // Delete a leaf default category.
      await tester.ensureVisible(find.text('Cafe'));
      await tester.tap(find.text('Cafe'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete category'));
      await tester.pumpAndSettle();
      expect(find.text('Delete category?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('This can’t be undone.'), findsOneWidget);
      await tester.tap(find.text('Yes, delete'));
      await tester.pumpAndSettle();
      expect(find.text('Cafe'), findsNothing);
      expect(categoryStore.categories.where((c) => c.name == 'Cafe'), isEmpty);

      // Deleting a default parent cascades to its subcategories.
      await tester.ensureVisible(find.text('Housing'));
      await tester.tap(find.text('Housing'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete category'));
      await tester.pumpAndSettle();
      expect(
        find.text('This will also delete its 5 subcategories.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes, delete'));
      await tester.pumpAndSettle();
      expect(find.text('Housing'), findsNothing);
      expect(find.text('Furniture'), findsNothing);
      expect(
        categoryStore.categories.where((c) => c.name == 'Housing'),
        isEmpty,
      );
      expect(
        categoryStore.categories.where((c) => c.name == 'Furniture'),
        isEmpty,
      );
    },
  );

  testWidgets('Categories: search opens and Cancel restores the header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: CategoriesScreen(store: categoryStore)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Search categories'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(find.text('Cancel'), findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);

    await tester.enterText(field, 'Cafe');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Categories'), findsOneWidget);
    expect(find.byTooltip('Search categories'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Create, edit, currency search, validation and unsaved-change protection',
    (tester) async {
      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: store,
          categoryStore: categoryStore,
          transactionStore: transactionStore,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage Accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add your first account'));
      await tester.pumpAndSettle();
      // This flow creates a cash wallet; bank accounts require an account suffix.
      await tester.tap(find.byKey(const Key('account-type-cash')));
      await tester.pumpAndSettle();
      final addButton = find.widgetWithText(GlassButton, 'Add account');
      expect(tester.widget<GlassButton>(addButton).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('account-name')),
        'Travel wallet',
      );
      await tester.enterText(
        find.byKey(const Key('opening-balance')),
        '123.456',
      );
      await tester.pump();
      expect(tester.widget<GlassButton>(addButton).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('opening-balance')),
        '123.45',
      );
      await tester.ensureVisible(find.text('Currency'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Currency'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'united states');
      await tester.pumpAndSettle();
      expect(find.text('US Dollar'), findsOneWidget);
      await tester.tap(find.text('US Dollar'));
      await tester.pumpAndSettle();
      expect(find.text('USD'), findsWidgets);
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      expect(tester.widget<GlassButton>(addButton).onPressed, isNotNull);
      await tester.tap(addButton);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(store.accounts.single.balanceMinor, 12345);
      expect(store.accounts.single.currency, 'USD');
      await tester.tap(find.text('Travel wallet'));
      await tester.pumpAndSettle();
      // An existing account opens read-only; editing is behind the menu.
      expect(find.text('Account info'), findsOneWidget);
      expect(find.widgetWithText(GlassButton, 'Save changes'), findsNothing);
      await tester.tap(find.byTooltip('Account options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GlassButton>(
              find.widgetWithText(GlassButton, 'Save changes'),
            )
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('opening-balance')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('account-name')),
        'Holiday fund',
      );
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Save changes'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(store.accounts.single.name, 'Holiday fund');
      expect(store.accounts.single.balanceMinor, 12345);
    },
  );
}
