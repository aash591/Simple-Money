// Shared fixes: a shop's fix shows the whole message it read, the entry it
// became as the Transactions list shows it (opening read-only), and reports
// through the Report SMS sheet, tied to the fix.
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/community/community_fixes.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/components/transactions/transaction_list_row.dart';
import 'package:simple_money/ui/more/ai/shared_fixes_screen.dart';

const _body =
    'Refund for Cotton Kurti of Rs.499 is successfully processed to your '
    'Original Payment Source. It will reflect in your account within 5-7 '
    'working days. For any help reach us on the Meesho app. Meesho';
final _hash = 'e' * 64;

Map<String, Object?> _format() => {
  'classification': 'completed',
  'senderRole': 'merchant',
  'country': 'IN',
  'direction': 'credit',
  'channel': 'other',
  'tokens': [
    {'op': 'match_literal', 'value': 'Refund for '},
    {'op': 'capture_text', 'name': 'item', 'maxLength': 80},
    {'op': 'match_literal', 'value': ' of Rs.'},
    {'op': 'capture_money', 'name': 'amount', 'maxLength': 32},
    {'op': 'match_literal', 'value': ' is successfully processed'},
  ],
  'output': {
    'amount': {'capture': 'amount'},
    'counterparty': {'value': 'Meesho'},
  },
};

void main() {
  late AppDatabase db;
  final reported = <Map<String, Object?>>[];
  final sent = <List>[];
  const improve = MethodChannel('simple_money/help_improve');

  CommunitySync sync() => CommunitySync(
    db,
    client: MockClient((request) async {
      if (request.url.path == '/v1/report') {
        reported.add(jsonDecode(request.body) as Map<String, Object?>);
      }
      return http.Response('{"ok":true}', 200);
    }),
    baseUrl: 'https://community.test',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    reported.clear();
    sent.clear();
    db = AppDatabase(NativeDatabase.memory());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(improve, (call) async {
          if (call.method == 'report') {
            sent.add((call.arguments as Map)['messages'] as List);
            return 1;
          }
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(improve, null);
    await db.close();
  });

  /// The Meesho fix, and one refund it read that the user saved.
  Future<void> seed() async {
    final fix = CommunityFix(
      hash: _hash,
      kind: CommunityKind.smsRule,
      payload: {
        'bankName': 'Meesho',
        'senders': ['MESHO'],
        'format': _format(),
      },
    );
    await CommunityFixRepository(db).replace([fix]);
    final account = await AccountRepository(db).save(
      name: 'SBI',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      type: AccountType.bank,
    );
    final refunds = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.type == CategoryType.income);
    final transaction = await TransactionRepository(db).addExpenseOrIncome(
      type: TransactionType.income,
      amountMinor: 49900,
      accountId: account,
      categoryId: refunds.id,
      title: 'Meesho',
      note: 'Sender: JK-MESHO-S\n\n$_body',
      date: DateTime(2026, 11, 10, 11, 36),
    );
    // A saved message keeps only these keys; the transaction holds the rest.
    await db.customInsert(
      "INSERT INTO sms_imports (fingerprint,sender,body,received_at,candidate,rule_id,pack_version,status,transaction_id) VALUES (?,?,NULL,?,?,?,1,'imported',?)",
      variables: [
        Variable('f1'),
        Variable('JK-MESHO-S'),
        Variable(DateTime(2026, 11, 10, 11, 36).millisecondsSinceEpoch),
        Variable(jsonEncode({'notificationKey': 'k', 'isCreditCard': false})),
        Variable(CommunityFixRepository.ruleId(fix)),
        Variable(transaction),
      ],
    );
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(seed);
    await tester.pumpWidget(
      MaterialApp(home: SharedFixesScreen(community: sync())),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the whole message shows, folded until tapped', (tester) async {
    await open(tester);
    expect(find.byIcon(Icons.storefront_outlined), findsOneWidget);
    expect(find.text('Show all'), findsOneWidget);
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(find.textContaining('within 5-7 working days'), findsOneWidget);
  });

  testWidgets('the entry it became opens read-only', (tester) async {
    await open(tester);
    final row = find.byType(TransactionListRow);
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.textContaining('499')),
      findsOneWidget,
    );
    await tester.tap(row);
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
    }
    final save = find.ancestor(
      of: find.textContaining('Save'),
      matching: find.byType(GlassButton),
    );
    expect(save, findsOneWidget);
    expect(tester.widget<GlassButton>(save).onPressed, isNull);
  });

  testWidgets('a report sends the message, tied to the fix', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('Report'));
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Someone else taught the app'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bank or merchant'), findsOneWidget);
    await tester.tap(find.text('Bank or merchant wrong'));
    await tester.tap(find.text('Send'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
    }
    final message = sent.single.single as Map;
    expect(message, containsPair('fix', _hash));
    expect(message, containsPair('bank', 'Meesho'));
    expect(message, containsPair('note', 'Bank or merchant wrong'));
    expect(message['body'], _body);
    expect(reported.single, containsPair('hash', _hash));
    expect(find.textContaining('Off on this phone'), findsOneWidget);
  });
}
