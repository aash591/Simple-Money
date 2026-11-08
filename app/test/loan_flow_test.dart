import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/loan_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/more/loans/loan_flow_screen.dart';
import 'package:simple_money/ui/more/loans/loan_review_card.dart';
import 'package:simple_money/ui/more/loans/loan_detail_screen.dart';
import 'package:simple_money/ui/more/loans/loan_action_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  for (final flexible in [false, true]) {
    testWidgets(
      flexible
          ? 'Existing flexible loan keeps unknown interest, edits previous answers, and records allocation'
          : 'Interest-free device EMI skips interest method in full screen',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory(), false);
        final repo = LoanRepository(db);
        await AccountRepository(db).save(
          name: 'HDFC Bank',
          currency: 'INR',
          digits: 2,
          openingBalance: 20000000,
        );
        final accounts = AccountStore(AccountRepository(db));
        final categories = CategoryStore(CategoryRepository(db));
        final transactions = TransactionStore(
          TransactionRepository(db),
          accounts,
        );
        final loans = LoanStore(
          repo,
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        );
        await accounts.load();
        await categories.load();
        await transactions.load();
        await loans.load();
        addTearDown(() async {
          loans.dispose();
          transactions.dispose();
          categories.dispose();
          accounts.dispose();
          await db.close();
        });
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        const screenshots = bool.fromEnvironment('CAPTURE_LOAN_FLOW');
        if (screenshots) {
          await tester.runAsync(() async {
            final font = File(
              "${Platform.environment['FLUTTER_ROOT'] ?? 'C:/tools/flutter'}/bin/cache/artifacts/material_fonts/roboto-regular.ttf",
            );
            if (await font.exists()) {
              await (FontLoader('Roboto')..addFont(
                    Future.value(
                      ByteData.sublistView(await font.readAsBytes()),
                    ),
                  ))
                  .load();
            }
            final icons = File(
              'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
            );
            if (await icons.exists()) {
              await (FontLoader('MaterialIcons')..addFont(
                    Future.value(
                      ByteData.sublistView(await icons.readAsBytes()),
                    ),
                  ))
                  .load();
            }
          });
        }
        Future<void> shot(String name) async {
          if (!screenshots) return;
          await tester.pumpAndSettle();
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('build/loan-flow-review').create(recursive: true);
            await File('build/loan-flow-review/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(flexible ? Brightness.dark : Brightness.light),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showAddLoanFlow(context, loans),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> tap(String label) async {
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(label).last);
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> next() async {
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> field(String label, String value) async {
          final keyed = find.byKey(ValueKey(label));
          final input = keyed.evaluate().isNotEmpty
              ? find.descendant(of: keyed, matching: find.byType(TextField))
              : find.widgetWithText(TextField, label);
          await tester.ensureVisible(input);
          await tester.enterText(input, value);
          await tester.pumpAndSettle();
        }

        await tap('Open');
        expect(find.text('What kind of loan?'), findsNothing);
        expect(
          tester.getSize(find.byType(Scaffold).last),
          const Size(390, 844),
        );
        await field('Type a name', flexible ? 'Gold loan' : 'iPhone purchase');
        await shot(flexible ? 'name-dark' : 'name-light');
        await next();
        for (final d in (flexible ? '100000' : '60000').split('')) {
          await tester.tap(
            find.descendant(
              of: find.byType(NumberKeypad),
              matching: find.text(d),
            ),
          );
          await tester.pump();
        }
        await shot('amount-${flexible ? 'dark' : 'light'}');
        await next();
        expect(find.text('Does it charge interest?'), findsOneWidget);
        if (flexible) {
          await tap('Yes');
          await field('Interest rate (%)', '12');
          await tap('The amount still unpaid');
          await shot('interest-method');
          await next();
          await tap('No fixed end date');
          await next();
          await tap('Yes, I have');
          await field('Outstanding principal', '70000');
          await shot('position-unknown');
          // Prior answers are real edit targets and dependent pages recompute.
          await tester.ensureVisible(find.byTooltip('Edit details'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Edit details'));
          await tester.pumpAndSettle();
          await tap('Interest');
          await field('Interest rate (%)', '10');
          await next();
          await next();
          expect(find.widgetWithText(TextField, '70000'), findsOneWidget);
          await next();
          await tap('Flexible payments');
          expect(find.text('Monthly instalment'), findsNothing);
          await next();
        } else {
          await tap('No');
          expect(find.text('What is the interest charged on?'), findsNothing);
          await next();
          await field('Duration', '12');
          await next();
          await tap('No payments yet');
          await next();
          await tap('Fixed monthly EMI');
          await shot('emi-estimate');
          expect(find.text('Estimated monthly EMI'), findsOneWidget);
          await next();
        }
        expect(find.text('Accounts and reminders'), findsOneWidget);
        if (!flexible) {
          await tap('Fees and charges');
          await field('Fees paid at disbursement', '500');
          await tap('Deducted from money received');
          await tap('Record money received');
          await tap('HDFC Bank · INR');
        }
        await next();
        expect(find.text('Review your loan'), findsOneWidget);
        expect(find.text('View more details'), findsNothing);
        expect(find.byTooltip('Change repay from'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is LinearProgressIndicator &&
                widget.value == (flexible ? 0.3 : 0.0),
          ),
          findsOneWidget,
        );
        expect(find.text('EMIs paid'), findsNothing);
        await shot(flexible ? 'review-flexible' : 'review-emi');
        Finder fact(String label) => find.byWidgetPredicate(
          (widget) => widget is LoanReviewFact && widget.label == label,
        );
        expect(
          find.descendant(
            of: fact('Unpaid interest (est.)'),
            matching: find.text(flexible ? 'Unknown' : '₹0'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('You borrowed'), findsNothing);
        expect(find.text('Advanced interest settings'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        if (flexible) {
          expect(
            find.descendant(
              of: fact('Total balance'),
              matching: find.text('Unknown'),
            ),
            findsOneWidget,
          );
        } else {
          expect(
            find.descendant(
              of: fact('Money received in'),
              matching: find.text('₹59,500 added'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: fact('Total to repay (est.)'),
              matching: find.text('₹60,000'),
            ),
            findsOneWidget,
          );
        }
        // Editing one answer returns straight to the preview, after validation.
        await tester.ensureVisible(find.byTooltip('Edit loan name'));
        await tester.tap(find.byTooltip('Edit loan name'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester.getTopLeft(find.text('Name your loan')).dx,
          greaterThan(18),
        );
        await tester.pumpAndSettle();
        expect(find.text('Continue'), findsNothing);
        expect(find.byTooltip('Edit details'), findsNothing);
        await field('Type a name', '');
        await tap('Save');
        expect(find.text('Give this loan a name.'), findsOneWidget);
        await field('Type a name', flexible ? 'Gold loan' : 'iPhone purchase');
        await tester.tap(find.widgetWithText(GlassButton, 'Save'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester.getTopLeft(find.text('Review your loan')).dx,
          lessThan(18),
        );
        await tester.pumpAndSettle();
        expect(find.text('Review your loan'), findsOneWidget);
        for (final cancel in [true, false]) {
          await tester.tap(find.byTooltip('Edit loan name'));
          await tester.pumpAndSettle();
          await field('Type a name', 'Discard this name');
          if (cancel) {
            await tap('Cancel');
          } else {
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
          }
          expect(find.text('Review your loan'), findsOneWidget);
          expect(find.text('Discard this name'), findsNothing);
          expect(
            find.text(flexible ? 'Gold loan' : 'iPhone purchase'),
            findsOneWidget,
          );
          expect(await repo.load(), isEmpty);
        }
        // Both full names and money values wrap at larger accessibility sizes.
        tester.view.physicalSize = const Size(320, 740);
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await shot(
          flexible ? 'review-flexible-large-text' : 'review-emi-large-text',
        );
        await tester.ensureVisible(find.byTooltip('Change repay from'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await shot(
          flexible ? 'review-flexible-accounts' : 'review-emi-accounts',
        );
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        await tap('Add loan');
        final saved = (await repo.load()).single;
        expect(saved.terms.rate, flexible ? 10 : 0);
        expect(
          saved.terms.mode,
          flexible ? LoanRepaymentMode.flexible : LoanRepaymentMode.emi,
        );
        expect(saved.outstanding, flexible ? 7000000 : 6000000);
        expect(saved.terms.openingInterest, flexible ? isNull : 0);
        expect(saved.terms.months, flexible ? 0 : 12);
        expect(saved.terms.emi, flexible ? 0 : 500000);
        final recorded = await TransactionRepository(db).load();
        if (flexible) {
          expect(recorded, isEmpty);
        } else {
          expect(saved.terms.chargesMinor, 50000);
          expect(saved.terms.chargesDeducted, isTrue);
          expect(recorded.single.amountMinor, 5950000);
        }
        if (flexible) {
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(Brightness.dark),
                home: LoanDetailScreen(store: loans, id: saved.id),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await shot('flexible-detail');
          await tester.scrollUntilVisible(
            find.text('Record payment'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tap('Record payment');
          expect(find.byType(LoanActionSheet), findsOneWidget);
          await tester.enterText(find.byType(TextField).first, '5000');
          await tester.pumpAndSettle();
          await field('Interest paid', '1250');
          await field('Unpaid interest after payment', '0');
          await shot('payment-allocation');
          await tap('Save payment');
          final updated = (await repo.load()).single;
          expect(updated.outstanding, 6625000);
          expect(updated.unpaidInterestAt(DateTime.now()), 0);
          expect(updated.events.single.interest, 125000);
        }
      },
    );
  }
  testWidgets(
    'Full-screen input keeps actions reachable at 320px with large text and keyboard',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory(), false);
      final accounts = AccountStore(AccountRepository(db)),
          categories = CategoryStore(CategoryRepository(db));
      final transactions = TransactionStore(
        TransactionRepository(db),
        accounts,
      );
      final loans = LoanStore(
        LoanRepository(db),
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      );
      addTearDown(() async {
        loans.dispose();
        transactions.dispose();
        categories.dispose();
        accounts.dispose();
        await db.close();
      });
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
              viewInsets: const EdgeInsets.only(bottom: 260),
            ),
            child: child!,
          ),
          home: LoanFlowScreen(store: loans),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Type a name'),
        'My loan',
      );
      await tester.pumpAndSettle();
      expect(find.text('Continue').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
