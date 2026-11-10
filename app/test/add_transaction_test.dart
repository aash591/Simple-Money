import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/security_controller.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';
import 'package:simple_money/ui/transactions/transaction_widgets.dart';
import 'package:simple_money/ui/transactions/transfer_sheet.dart';

void main() {
  late AppDatabase database;
  late AccountStore accountStore;
  late CategoryStore categoryStore;
  late TransactionStore transactionStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'upi.intro_seen': true,
      SecurityController.hideAmountsPreferenceKey: false,
    });
    database = AppDatabase(NativeDatabase.memory());
    accountStore = AccountStore(AccountRepository(database));
    categoryStore = CategoryStore(CategoryRepository(database));
    transactionStore = TransactionStore(
      TransactionRepository(database),
      accountStore,
    );
    await accountStore.load();
    await categoryStore.load();
    await transactionStore.load();
  });

  // These sheets are tall (question + amount card + a 4-row keypad, or a
  // details card with several rows) — the default 800x600 test surface
  // clips/overflows them, which silently drops taps rather than failing
  // loudly. A phone-sized-or-larger canvas avoids that class of flakiness.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  tearDown(() async {
    accountStore.dispose();
    categoryStore.dispose();
    transactionStore.dispose();
    await database.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accountStore,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final action in ['income', 'expense', 'upi']) {
    testWidgets('Launcher $action opens only its sheet', (tester) async {
      useTallSurface(tester);
      tester.platformDispatcher.defaultRouteNameTestValue = '/quick/$action';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      await pumpApp(tester);
      expect(find.byTooltip('View month transactions'), findsNothing);
      expect(find.text('Add a transaction'), findsNothing);
      if (action == 'upi') {
        expect(find.text('Scan a UPI QR code'), findsOneWidget);
      } else {
        expect(find.byType(NumberKeypad), findsOneWidget);
        expect(
          find.text(
            action == 'income'
                ? 'Amount received'
                : 'Amount',
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  Future<void> tapDigits(WidgetTester tester, String digits) async {
    for (final digit in digits.split('')) {
      await tester.tap(
        find.descendant(
          of: find.byType(NumberKeypad),
          matching: find.text(digit),
        ),
      );
    }
    await tester.pump();
  }

  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(TransactionSheet), matching: finder);

  Finder rowValue(String label, String value) => find.descendant(
    of: find.widgetWithText(InkWell, label),
    matching: find.text(value),
  );

  Future<void> saveCash() => accountStore.save(
    name: 'Cash',
    currency: 'INR',
    digits: 2,
    openingBalance: 100000,
  );

  Finder continueButton() => find.widgetWithText(GlassButton, 'Continue');

  Future<void> tapChoice(WidgetTester tester, String label) async {
    final row = find.widgetWithText(ListTile, label).hitTestable();
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// The text field inside Confirm's typable [label] row.
  Finder textRowField(String label) => find.descendant(
    of: find.widgetWithText(TransactionTextRow, label),
    matching: find.byType(TextField),
  );

  /// From Home, through Amount, Category (Cafe) and Pay from (Cash) to the
  /// Date step of a new ₹50 expense.
  Future<void> walkToDateStep(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add expense'));
    await tester.pumpAndSettle();
    await tapDigits(tester, '50');
    await tester.tap(continueButton());
    await tester.pumpAndSettle();
    await tapChoice(tester, 'Food & Beverage');
    await tapChoice(tester, 'Cafe');
    await tapChoice(tester, 'Cash');
  }

  testWidgets(
    'Add subcategory keeps the chosen parent and advances to accounts',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      await pumpApp(tester);
      await tester.tap(find.byTooltip('Add transaction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      await tapDigits(tester, '50');
      await tester.tap(continueButton());
      await tester.pumpAndSettle();
      await tapChoice(tester, 'Food & Beverage');
      await tester.ensureVisible(find.text('Add subcategory'));
      await tester.tap(find.text('Add subcategory'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Category name'),
        'Lunch break',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(GlassButton, 'Add category'));
      await tester.pumpAndSettle();
      final created = categoryStore.categories.firstWhere(
        (c) => c.name == 'Lunch break',
      );
      final parent = categoryStore.categories.firstWhere(
        (c) => c.name == 'Food & Beverage',
      );
      expect(created.parentId, parent.id);
      expect(find.text('Pay from'), findsOneWidget);
      expect(inSheet(find.text('Lunch break')), findsOneWidget);
      await tapChoice(tester, 'Cash');
      expect(inSheet(find.text('Cash')), findsOneWidget);
      expect(inSheet(find.text('Lunch break')), findsOneWidget);
      await tester.tap(continueButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Save expense'));
      await tester.pumpAndSettle();
      expect(transactionStore.transactions.single.categoryId, created.id);
    },
  );

  testWidgets(
    'Date step shows the shared calendar inline; picking a day moves on',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      await pumpApp(tester);
      await walkToDateStep(tester);

      expect(find.text('When did you spend it?'), findsOneWidget);
      final popup = find.byType(TransactionSheet);
      final now = DateTime.now();
      await tester.tap(
        find.descendant(of: popup, matching: find.text('${now.year}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('year-grid-pager')), findsOneWidget);
      await tester.tap(
        find.descendant(of: popup, matching: find.text('${now.year}')).last,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('month-grid')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: popup,
          matching: find.text(
            const [
              'Jan',
              'Feb',
              'Mar',
              'Apr',
              'May',
              'Jun',
              'Jul',
              'Aug',
              'Sep',
              'Oct',
              'Nov',
              'Dec',
            ][now.month - 1],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day-grid-pager')), findsOneWidget);

      final targetDay = now.day == 1 ? 2 : 1;
      await tester.tap(
        find.descendant(of: popup, matching: find.text('$targetDay')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Confirm expense'), findsOneWidget);
      expect(
        rowValue(
          'Date',
          '${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][now.month - 1]} $targetDay, ${now.year}',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Add expense: amount -> category -> pay from -> date -> confirm (typed title and note) -> saves and debits the account',
    (tester) async {
      useTallSurface(tester);
      await saveCash();

      await pumpApp(tester);
      final brandingBottom = tester
          .getBottomLeft(find.byTooltip('View month transactions'))
          .dy;
      await tester.tap(find.byTooltip('Add transaction'));
      await tester.pumpAndSettle();
      expect(find.text('Add a transaction'), findsOneWidget);
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();

      expect(find.text('Amount'), findsOneWidget);
      expect(find.text('0.00'), findsOneWidget);
      expect(tester.widget<GlassButton>(continueButton()).onPressed, isNull);
      await tapDigits(tester, '50');
      expect(find.text('50'), findsOneWidget);
      await tester.tap(continueButton());
      await tester.pumpAndSettle();

      // Category fills the sheet up to just below Home's header, with
      // the search bar at the bottom — not focused until it's tapped.
      expect(find.text('Choose category'), findsOneWidget);
      final categoryTop = tester.getTopLeft(find.byType(TransactionSheet)).dy;
      expect(categoryTop, greaterThan(brandingBottom));
      expect(categoryTop, lessThan(brandingBottom + 60));
      final search = find.widgetWithText(TextField, 'Search categories');
      expect(
        tester.getTopLeft(search).dy,
        greaterThan(
          tester
              .getBottomLeft(
                find.widgetWithText(ListTile, 'Food & Beverage').first,
              )
              .dy,
        ),
      );
      final editable = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isFalse);

      final allRows = find.byType(ListTile).evaluate().length;
      await tester.enterText(search, 'food');
      await tester.pump();
      expect(find.byType(ListTile).evaluate().length, lessThan(allRows));
      expect(inSheet(find.text('₹50')), findsOneWidget);
      // Searching a parent also includes its child categories.
      expect(find.text('Cafe'), findsOneWidget);
      await tapChoice(tester, 'Food & Beverage');
      expect(find.text('Choose subcategory'), findsOneWidget);
      expect(inSheet(find.text('₹50')), findsOneWidget);
      expect(inSheet(find.text('Food & Beverage')), findsOneWidget);
      expect(find.text('Add subcategory'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Choose category'), findsOneWidget);
      await tapChoice(tester, 'Food & Beverage');
      await tapChoice(tester, 'Cafe');
      expect(inSheet(find.text('Food & Beverage')), findsOneWidget);
      expect(inSheet(find.text('Cafe')), findsOneWidget);
      expect(inSheet(find.byIcon(Icons.radio_button_unchecked)), findsNothing);
      expect(inSheet(find.byIcon(Icons.check_circle_rounded)), findsNothing);

      // Pay from: as tall as its content (one account), so shorter.
      expect(find.text('Pay from'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(TransactionSheet)).dy,
        greaterThan(categoryTop),
      );
      expect(find.widgetWithText(TextField, 'Search accounts'), findsOneWidget);
      await tapChoice(tester, 'Cash');

      expect(find.text('When did you spend it?'), findsOneWidget);
      await tester.tap(continueButton());
      await tester.pumpAndSettle();

      // Confirm: title and note are typed right here, and neither field
      // opens the keyboard until it's tapped.
      expect(find.text('Confirm expense'), findsOneWidget);
      expect(rowValue('Category', 'Cafe'), findsOneWidget);
      expect(rowValue('Paid from', 'Cash'), findsOneWidget);
      for (final label in ['Title', 'Note']) {
        final editable = tester.widget<EditableText>(
          find.descendant(
            of: textRowField(label),
            matching: find.byType(EditableText),
          ),
        );
        expect(editable.focusNode.hasFocus, isFalse);
      }
      await tester.enterText(textRowField('Title'), 'Coffee');
      await tester.enterText(textRowField('Note'), 'With a friend');

      // Tapping a row edits just that step, then returns to Confirm with
      // what was typed still there.
      await tester.tap(find.widgetWithText(InkWell, 'Paid from'));
      await tester.pumpAndSettle();
      await tapChoice(tester, 'Cash');
      expect(find.text('Confirm expense'), findsOneWidget);
      expect(
        tester.widget<TextField>(textRowField('Title')).controller!.text,
        'Coffee',
      );

      await tester.tap(find.widgetWithText(GlassButton, 'Save expense'));
      await tester.pumpAndSettle();

      expect(find.text('Expense saved'), findsOneWidget);
      expect(find.byType(TransactionSheet), findsNothing);
      expect(accountStore.accounts.single.balanceMinor, 95000);
      final saved = transactionStore.transactions.single;
      expect(saved.type, TransactionType.expense);
      expect(saved.amountMinor, 5000);
      expect(saved.title, 'Coffee');
      expect(saved.note, 'With a friend');
      expect(saved.accountId, accountStore.accounts.single.id);
      expect(
        saved.categoryId,
        categoryStore.categories.firstWhere((c) => c.name == 'Cafe').id,
      );
    },
  );

  testWidgets(
    'Add flow: a scrim tap is ignored, back steps back, Cancel and drag-down close it',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      await pumpApp(tester);

      await tester.tap(find.byTooltip('Add transaction'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('Add a transaction'), findsOneWidget);

      await tester.tap(find.text('Add income'));
      await tester.pumpAndSettle();
      expect(find.text('Amount received'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Add a transaction'), findsOneWidget);

      await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionSheet), findsNothing);

      await tester.tap(find.byTooltip('Add transaction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('0.00'), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionSheet), findsOneWidget);
      await tester.drag(
        find.byIcon(Icons.backspace_outlined),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TransactionSheet), findsOneWidget);
      await tester.drag(find.text('Add expense'), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionSheet), findsNothing);
      expect(transactionStore.transactions, isEmpty);
    },
  );

  testWidgets(
    'Tapping a transaction opens it; Edit opens the review sheet and updates it in place',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      final cash = accountStore.accounts.single;
      final category = categoryStore.categories.firstWhere(
        (c) => c.type == CategoryType.expense,
      );
      await transactionStore.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 45000,
        accountId: cash.id,
        categoryId: category.id,
        title: 'Groceries',
        date: DateTime.now(),
      );

      await pumpApp(tester);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groceries'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('Transaction')), findsOneWidget);
      expect(inSheet(find.text('- ₹450')), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Edit'));
      await tester.pumpAndSettle();

      // Edit opens the review sheet SMS and statements use.
      expect(find.text('Edit transaction'), findsOneWidget);
      expect(find.text('Record as'), findsOneWidget);

      // Cancel drops the edit and returns to View.
      await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Transaction')), findsOneWidget);

      await tester.tap(find.widgetWithText(GlassButton, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(RegExp('^Edit amount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '600');
      await tester.tap(find.widgetWithText(GlassButton, 'Save').last);
      await tester.pumpAndSettle();
      expect(find.text('₹600'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Transaction updated'), findsOneWidget);
      expect(find.byType(TransactionSheet), findsNothing);
      final saved = transactionStore.transactions.single;
      expect(saved.amountMinor, 60000);
      expect(saved.title, 'Groceries');
      expect(accountStore.accounts.single.balanceMinor, 40000);
      expect(accountStore.accounts.single.transactionCount, 1);
    },
  );

  testWidgets(
    'Edit can turn a saved expense into a transfer between accounts',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      await accountStore.save(
        name: 'Wallet',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      final cash = accountStore.accounts.firstWhere((a) => a.name == 'Cash');
      final category = categoryStore.categories.firstWhere(
        (c) => c.type == CategoryType.expense,
      );
      await transactionStore.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 20000,
        accountId: cash.id,
        categoryId: category.id,
        title: 'ATM',
        date: DateTime.now(),
      );

      await pumpApp(tester);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ATM'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Transfer').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose INR account'));
      await tester.pumpAndSettle();
      await tapChoice(tester, 'Wallet');
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();

      final saved = transactionStore.transactions.single;
      expect(saved.type, TransactionType.transfer);
      expect(saved.toAccountId, isNotNull);
      final balances = {
        for (final a in accountStore.accounts) a.name: a.balanceMinor,
      };
      expect(balances, {'Cash': 80000, 'Wallet': 20000});
    },
  );

  testWidgets(
    'View: Delete asks for confirmation, then removes the transaction and reverses the balance',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      final cash = accountStore.accounts.single;
      final category = categoryStore.categories.firstWhere(
        (c) => c.type == CategoryType.expense,
      );
      await transactionStore.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 45000,
        accountId: cash.id,
        categoryId: category.id,
        title: 'Groceries',
        date: DateTime.now(),
      );

      await pumpApp(tester);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groceries'));
      await tester.pumpAndSettle();

      // Backing out of the confirmation leaves the transaction untouched.
      await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this transaction?'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionSheet), findsOneWidget);
      expect(transactionStore.transactions, hasLength(1));

      await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
      await tester.pumpAndSettle();
      // The alert's Delete sits above the page's own Delete button.
      await tester.tap(find.widgetWithText(GlassButton, 'Delete').last);
      await tester.pumpAndSettle();
      // A second alert asks again before anything is deleted.
      expect(find.text('Are you sure?'), findsOneWidget);
      expect(transactionStore.transactions, hasLength(1));
      await tester.tap(find.widgetWithText(GlassButton, 'Yes, delete'));
      await tester.pumpAndSettle();

      expect(find.text('Transaction deleted'), findsOneWidget);
      expect(find.byType(TransactionSheet), findsNothing);
      expect(transactionStore.transactions, isEmpty);
      expect(accountStore.accounts.single.balanceMinor, 100000);
      expect(accountStore.accounts.single.transactionCount, 0);
    },
  );

  testWidgets(
    'Transfer: one account per step, and the source is not offered as the destination',
    (tester) async {
      useTallSurface(tester);
      await saveCash();
      await accountStore.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 500000,
      );

      await pumpApp(tester);
      await tester.tap(find.byTooltip('Add transaction'));
      await tester.pumpAndSettle();
      expect(find.text('Move money between your accounts'), findsNothing);
      await tester.tap(find.text('Transfer between accounts'));
      await tester.pumpAndSettle();

      // The source comes first, so the keypad already knows the currency.
      expect(find.text('Transfer from'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Cash').hitTestable());
      await tester.pumpAndSettle();

      // The Add-type sheet stays mounted underneath, so scope past its own
      // Cancel button to the transfer flow's.
      expect(
        find.descendant(
          of: find.byType(TransferSheet),
          matching: find.widgetWithText(GlassButton, 'Cancel'),
        ),
        findsOneWidget,
      );
      await tapDigits(tester, '20');
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await tester.pumpAndSettle();

      // Cash is the source, so it is not among the destinations at all.
      expect(find.text('Transfer to'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Cash').hitTestable(), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'Bank').hitTestable());
      await tester.pumpAndSettle();

      // Both accounts hold rupees, so nothing asks what arrived.
      expect(find.text('How much arrived?'), findsNothing);
      expect(find.text('When did you transfer it?'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(rowValue('From', 'Cash'), findsOneWidget);
      expect(rowValue('To', 'Bank'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Save transfer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Transfer saved'), findsOneWidget);
      final cash = accountStore.accounts.firstWhere((a) => a.name == 'Cash');
      final bank = accountStore.accounts.firstWhere((a) => a.name == 'Bank');
      expect(cash.balanceMinor, 98000); // From: debited
      expect(bank.balanceMinor, 502000); // To: credited
      final saved = transactionStore.transactions.single;
      expect(saved.type, TransactionType.transfer);
      // Same currency, unedited: nothing implied about what arrived.
      expect(saved.toAmountMinor, isNull);
    },
  );

  testWidgets(
    'Adjust balance (Transactions ⋮ menu): adding an amount updates the account without logging a transaction',
    (tester) async {
      useTallSurface(tester);
      await saveCash();

      await pumpApp(tester);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Adjust balance'));
      await tester.tap(find.text('Adjust balance'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add'));
      await tester.tap(find.widgetWithText(InkWell, 'Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Cash').hitTestable());
      await tester.pumpAndSettle();

      // One screen: nothing to save until an amount changes the balance.
      final save = find.widgetWithText(GlassButton, 'Save');
      expect(tester.widget<GlassButton>(save).onPressed, isNull);
      expect(find.text('Amount to add'), findsOneWidget);
      await tapDigits(tester, '50');
      await tester.pump();

      expect(find.text('Current balance'), findsOneWidget);
      expect(find.text('New balance'), findsOneWidget);
      expect(find.textContaining('1,050'), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.textContaining('Balance updated'), findsOneWidget);
      expect(accountStore.accounts.single.balanceMinor, 105000);
      expect(transactionStore.transactions, isEmpty);
    },
  );
}
