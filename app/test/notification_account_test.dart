// An app's notification names no account. Teaching can say which of the user's
// accounts it belongs to: then every later notification of that app goes
// there by itself. Left out, each payment waits in review for the user to pick
// one. Either way the app can be taught: it needn't carry an account number.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/manual_sms_teacher.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/realtime_sms_repository.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

const _first =
    '₹10.00 sent to ASHIQUE M\nLow balance! Add funds for seamless pay';
const _later = '₹25.00 sent to RAVI K\nLow balance! Add funds for seamless pay';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  final key = notificationSenderKey('com.example.pay');
  const labels = SmsLabels(
    amount: '10.00',
    payee: 'ASHIQUE M',
    moneyOut: true,
    currency: 'INR',
  );
  BankSms sms(String message) => BankSms(
    sender: key,
    body: message,
    receivedAt: DateTime(2026, 11, 23, 9),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  /// What a notification becomes when it arrives, as the background reader
  /// does: with the rules taught so far, and the notification's leading word.
  Future<LiveSms?> arrive(String message) async {
    final engine = await loadBundledSmsEngineFor(
      key,
      userPack: await userSmsPack(db),
      // As the background reader loads them: an app that gives no account
      // holds no money of the user's, so no account is made for it.
      roles: await smsSenderRoles(db),
    );
    return RealtimeSmsRepository(db).receive(
      BankSms(
        sender: key,
        body: notificationRuleText(message),
        receivedAt: DateTime(2026, 11, 23, 9, 5),
      ),
      engine!,
      fromNotification: true,
    );
  }

  test(
    'with no account chosen it can still be taught, and waits for review',
    () async {
      // Neither an account number nor a category to go on: an SMS rule would
      // be refused, but a person teaching an app may leave both to the review.
      final read = await ManualSmsTeacher(db)
          .teach(sms(_first), labels, appName: 'Example Pay');
      expect(read, 1);
      final rules = await UserSmsRuleRepository(db).load();
      expect(rules.single.bankName, 'Example Pay');
      expect(rules.single.senders, [key]);

      final live = await arrive(_later);
      expect(live, isNotNull);
      // Read, but no account yet: the user picks it in the home screen review.
      expect(live!.accountId, isNull);
    },
  );

  test('a chosen account takes every later notification of the app', () async {
    final kotak = await AccountRepository(
      db,
    ).save(name: 'Kotak Bank', currency: 'INR', digits: 2, openingBalance: 0);
    await ManualSmsTeacher(db)
        .teach(sms(_first), labels, appName: 'Example Pay', accountId: kotak);

    final link = await db
        .customSelect('SELECT account_id FROM sms_account_links')
        .getSingle();
    expect(link.read<int>('account_id'), kotak);

    // A different payment later: it goes straight to the chosen account.
    final live = await arrive(_later);
    expect(live, isNotNull);
    expect(live!.accountId, kotak);
  });

  test(
    'an account in another currency is refused, not silently linked',
    () async {
      final dollars = await AccountRepository(db).save(
        name: 'Dollar account',
        currency: 'USD',
        digits: 2,
        openingBalance: 0,
      );
      await expectLater(
        ManualSmsTeacher(db).teach(
          sms(_first),
          labels,
          appName: 'Example Pay',
          accountId: dollars,
        ),
        throwsA(anything),
      );
    },
  );
}
