// A bank can send one payment as an SMS and as an app notification. Exactly one
// of the two must become a transaction, whichever arrives first. Two payments
// that merely look alike (other amount, far apart, both SMS) stay separate.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

PortableParseResult _parsed({int amount = 24760, bool credit = false}) =>
    PortableParseResult(
      classification: RuleClassification.completed,
      decision: SmsDecision.review,
      reason: 'completedNeedsReview',
      packVersion: 1,
      ruleId: 'user.test.r1',
      candidate: SmsTransactionCandidate(
        amountMinor: amount,
        currencyCode: 'INR',
        direction: credit ? SmsDirection.credit : SmsDirection.debit,
        channel: SmsPaymentChannel.upi,
        occurredAt: DateTime(2026, 11, 23),
        bankName: 'Zyx Bank',
        countryCode: 'IN',
        accountLast4: '1234',
      ),
    );

void main() {
  late AppDatabase db;
  late SmsImportRepository imports;
  final appKey = notificationSenderKey('com.example.bank');
  final noon = DateTime(2026, 11, 23, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    imports = SmsImportRepository(db);
  });
  tearDown(() => db.close());

  Future<void> add(
    String sender,
    String body,
    DateTime at, {
    int amount = 24760,
    bool credit = false,
  }) => imports.enqueue(
    BankSms(sender: sender, body: body, receivedAt: at),
    _parsed(amount: amount, credit: credit),
  );

  Future<Map<String, String>> statuses() async => {
    for (final r
        in await db
            .customSelect('SELECT sender,status FROM sms_imports')
            .get())
      r.read<String>('sender'): r.read<String>('status'),
  };

  test('the notification after the SMS is dropped', () async {
    await add('HDFCBK', 'Rs 247.60 debited A/c 1234', noon);
    await add(
      appKey,
      'Debit alert Rs 247.60 from A/c 1234',
      noon.add(const Duration(seconds: 40)),
    );
    expect(await statuses(), {'HDFCBK': 'pending', appKey: 'dismissed'});
  });

  test('the SMS after the notification is dropped', () async {
    await add(appKey, 'Debit alert Rs 247.60 from A/c 1234', noon);
    await add(
      'HDFCBK',
      'Rs 247.60 debited A/c 1234',
      noon.add(const Duration(minutes: 1)),
    );
    expect(await statuses(), {appKey: 'pending', 'HDFCBK': 'dismissed'});
  });

  test('another amount, direction or time is another payment', () async {
    await add('HDFCBK', 'Rs 247.60 debited', noon);
    await add(appKey, 'Rs 100 debited', noon, amount: 10000);
    expect((await statuses())[appKey], 'pending');

    await add(
      appKey,
      'Rs 247.60 credited',
      noon.add(const Duration(seconds: 10)),
      credit: true,
    );
    expect((await statuses())[appKey], 'pending');

    // Three minutes apart: too far to be one payment.
    await imports.enqueue(
      BankSms(
        sender: notificationSenderKey('net.other.app'),
        body: 'Rs 247.60 debited later',
        receivedAt: noon.add(const Duration(minutes: 3)),
      ),
      _parsed(),
    );
    final pending = await db
        .customSelect("SELECT count(*) c FROM sms_imports WHERE status='pending'")
        .getSingle();
    expect(pending.read<int>('c'), 4);
  });

  test('two SMS with the same amount are not touched', () async {
    await add('HDFCBK', 'Rs 247.60 debited A/c 1234', noon);
    await add(
      'ICICIB',
      'Rs 247.60 debited A/c 5678',
      noon.add(const Duration(seconds: 20)),
    );
    expect(await statuses(), {'HDFCBK': 'pending', 'ICICIB': 'pending'});
  });
}
