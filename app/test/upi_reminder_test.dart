import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/upi_reminder.dart';
import 'package:simple_money/domain/upi_payment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  final shown = <Map<Object?, Object?>>[];

  PendingUpiPayment payment({String? place, int? accountId}) =>
      PendingUpiPayment(
        id: 'p1',
        recipient: UpiRecipient.parse('upi://pay?pa=shop@bank&pn=Mina%20Medicals'),
        amountText: '250',
        categoryId: null,
        accountId: accountId,
        date: DateTime(2026, 11, 4),
        place: place,
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    shown.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('simple_money/upi_notifications'),
          (call) async {
            if (call.method == 'show') {
              shown.add(call.arguments as Map<Object?, Object?>);
            }
            return null;
          },
        );
  });
  tearDown(() => db.close());

  Future<int> addAccount({String currency = 'INR'}) async {
    await AccountRepository(db).save(
      name: 'Bank $currency',
      currency: currency,
      digits: 2,
      openingBalance: 0,
    );
    return (await AccountRepository(db).load()).last.id;
  }

  test('the only INR account is used when none was chosen', () async {
    await addAccount(currency: 'USD');
    final inr = await addAccount();
    final accounts = await AccountRepository(db).load();
    expect(upiPaymentAccount(payment(), accounts), inr);
    expect(upiPaymentAccount(payment(accountId: inr), accounts), inr);
  });

  test('two INR accounts need a choice', () async {
    await addAccount();
    await addAccount();
    final accounts = await AccountRepository(db).load();
    expect(upiPaymentAccount(payment(), accounts), isNull);
    expect(upiPaymentAccount(payment(accountId: accounts.last.id), accounts),
        accounts.last.id);
  });

  test('the notification names the amount, the shop and the place', () async {
    await addAccount();
    await CategoryRepository(db).load();
    await showUpiReminder(db, payment(place: 'Edappally, Kochi'));
    final data = shown.single;
    expect(data['id'], 'p1');
    expect(data['title'], 'Did you pay ₹250 to Mina Medicals?');
    expect(data['text'], contains('Near Edappally, Kochi'));
    expect(data['text'], contains('Tap a category'));
    final pills = data['suggestions'] as List;
    expect(pills.length, lessThanOrEqualTo(2));
    expect(pills, isNotEmpty);
  });

  test('with no single account to save into, there are no pills', () async {
    await addAccount();
    await addAccount();
    await showUpiReminder(db, payment());
    expect(shown.single['suggestions'], isEmpty);
    expect(shown.single['text'], contains('Tap to mark it paid'));
  });
}
