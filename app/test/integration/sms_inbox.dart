// Run on Android with SMS_TEST_DENIED=true for the denied-access check, then
// run normally for inbox scanning and review. The ledger is in memory.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/sms_inbox_platform.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/sms/sms_pending_card.dart';
import 'package:simple_money/ui/sms/sms_review_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native permission denial, inbox scan, review, save and rescan', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    final platform = SmsInboxPlatform();
    final store = SmsImportStore(SmsImportRepository(db), platform: platform);
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    try {
      expect(platform.supported, isTrue);
      const denied = bool.fromEnvironment('SMS_TEST_DENIED');
      if (denied) {
        expect(await platform.hasPermission(), isFalse);
        await expectLater(
          platform.readPage(afterId: 0, since: 0),
          throwsA(isA<PlatformException>()),
        );
        return;
      }
      expect(
        await platform.requestPermission(),
        isTrue,
        reason: 'Allow the Android SMS permission prompt',
      );
      await accounts.repository.save(
        name: 'SMS test bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      await accounts.load();
      await categories.load();
      await transactions.load();
      await store.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  child: SmsPendingCard(
                    store: store,
                    onReview: (sms) => showAdaptiveSheet<void>(
                      context,
                      builder: (_) => SmsReviewFlow(
                        sms: sms,
                        store: store,
                        accounts: accounts,
                        categories: categories,
                        transactions: transactions,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await store.enable();
      await store.scan(full: true);
      expect(store.error, isNull);
      expect(store.enabled, isTrue);
      const existingInbox = bool.fromEnvironment('SMS_USE_EXISTING_INBOX');
      final inboxPage = await platform.readPage(afterId: 0, since: 0);
      // Aggregate only: never print sender, body, or transaction details.
      // ignore: avoid_print
      print(
        'Phone inbox first page rows: ${inboxPage.length}; parsed INR items: ${store.pending.where((s) => s.currency == 'INR').length}',
      );
      var seeded = store.pending
          .where(
            (s) => existingInbox
                ? s.currency == 'INR'
                : s.amountMinor == 73129 && s.accountLast4 == '9876',
          )
          .toList();
      const requireReal = bool.fromEnvironment('SMS_REQUIRE_REAL');
      if (seeded.isEmpty && !requireReal) {
        final engine = await loadBundledSmsEngine();
        final fixture = BankSms(
          sender: 'ATMSBI',
          body: 'Rs.731.29 debited from A/c X9876 on 08Oct26. Avl Bal Rs.999999999',
          receivedAt: DateTime.now(),
        );
        await store.repository.enqueue(fixture, engine.parse(fixture));
        await store.reload();
        seeded = store.pending
            .where((s) => s.amountMinor == 73129 && s.accountLast4 == '9876')
            .toList();
        // ignore: avoid_print
        print(
          'Used local SBI fixture for on-device review (no matching inbox transaction).',
        );
      }
      expect(seeded, isNotEmpty);
      final item = seeded.firstWhere(
        (s) => s.data['bankName'] == 'State Bank of India',
        orElse: () => seeded.first,
      );
      // ignore: avoid_print
      print('Reviewing parsed family: ${item.data['bankName']}');
      expect(
        store.pending.any((s) => s.body.contains('SMS-INTEGRATION-OTP')),
        isFalse,
      );
      // Open the row through the same real review sheet used by Home.
      final context = tester.element(find.byType(SmsPendingCard));
      showAdaptiveSheet<void>(
        context,
        builder: (_) => SmsReviewFlow(
          sms: item,
          store: store,
          accounts: accounts,
          categories: categories,
          transactions: transactions,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Is the payment completed?'), findsNothing);
      await tester.ensureVisible(find.text('Choose category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose category'));
      await tester.pumpAndSettle();
      final category = categories.categories.firstWhere(
        (c) => c.type.name == (item.credit ? 'income' : 'expense'),
      );
      await tester.tap(find.text(category.name).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Choose INR account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose INR account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SMS test bank').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review details'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Device SMS test');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text(item.credit ? 'Save income' : 'Save expense'));
      await tester.pumpAndSettle();
      final saved = (await transactions.repository.load()).single;
      expect(saved.title, 'Device SMS test');
      expect(saved.amountMinor == item.amountMinor, isTrue);
      expect(
        (await accounts.repository.load()).single.balanceMinor ==
            100000 + (item.credit ? item.amountMinor : -item.amountMinor),
        isTrue,
      );
      await store.scan(full: true);
      expect(store.pending.any((s) => s.id == item.id), isFalse);
      await store.disable();
      expect((await store.repository.state()).$1, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      store.dispose();
      accounts.dispose();
      categories.dispose();
      transactions.dispose();
      await db.close();
    }
  });
}
