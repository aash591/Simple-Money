import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../domain/account.dart';
import '../domain/category.dart';
import '../domain/realtime_sms_category.dart';
import '../state/sms_import_store.dart';
import 'db/app_database.dart';
import 'repositories/account_repository.dart';
import 'repositories/category_repository.dart';
import 'repositories/realtime_sms_repository.dart';
import 'repositories/sms_import_repository.dart';

const smsNotificationChannel = MethodChannel('simple_money/sms_notifications');

Future<void> showSmsNotification(AppDatabase db, LiveSms live) async {
  await _showSingleNotification(db, live);
  final active =
      await smsNotificationChannel.invokeListMethod<String>('activeIds') ?? [];
  for (final id in active.where((id) => id != live.sms.id)) {
    final related = await RealtimeSmsRepository(db).load(id);
    if (related != null) await _showSingleNotification(db, related);
  }
}

Future<void> _showSingleNotification(AppDatabase db, LiveSms live) async {
  final accounts = await AccountRepository(db).load();
  final categories = await CategoryRepository(db).load();
  final account = accounts.where((a) => a.id == live.accountId).firstOrNull;
  final other = accounts.where((a) => a.id == live.otherAccountId).firstOrNull;
  final category = categories.where((c) => c.id == live.categoryId).firstOrNull;
  final party = (live.sms.data['counterparty'] as String?)?.trim();
  final repository = RealtimeSmsRepository(db);
  final confirmation = await repository.categoryConfirmation(live.sms.id);
  final newAccount =
      account != null &&
      await repository.createdAccount(live.sms.id) == account.id;
  final ambiguous =
      account == null &&
      resolveSmsAccount(
        live.sms,
        await SmsImportRepository(db).detectedAccounts(),
      ).ambiguousAccount;
  final categoryName = other != null
      ? 'Transferred'
      : category?.name ?? 'Uncategorised';
  final name = smsDisplayName(party);
  final credit = live.sms.credit;
  final amount =
      '${currencyPrefix(live.sms.currency)}'
      '${formatAccountAmount(live.sms.amountMinor, digits: 2, currency: live.sms.currency)}';
  final signed = '${credit ? '+' : '−'}$amount';
  final label = name.isEmpty ? (credit ? 'Money received' : 'Payment') : name;
  // Minimal on purpose: no account digits, and only the bank beside the
  // question, so there is little to read over a shoulder.
  final title = other != null
      ? (credit
            ? 'Received $amount from ${other.name}'
            : 'Sent $amount to ${other.name}')
      : credit
      ? 'Received $amount${name.isEmpty ? '' : ' from $name'}'
      : 'Spent $amount${name.isEmpty ? '' : ' at $name'}';
  final question = other != null
      ? 'Transfer'
      : credit
      ? 'Where is this from?'
      : 'What was this for?';
  final suggestions = other != null || confirmation != null
      ? const <Category>[]
      : smsCategorySuggestions(
          live.sms,
          categories,
          current: category,
          frequent: await repository.frequentCategories(credit: credit),
        );
  await smsNotificationChannel.invokeMethod<void>('show', {
    'id': live.sms.id,
    'amount': signed,
    'bank': live.sms.bankName,
    'title': title,
    'text': [
      question,
      live.sms.bankName,
      if (newAccount) 'New account',
    ].join(' · '),
    'credit': credit,
    'suggestions': [
      for (final c in suggestions) {'id': c.id, 'label': c.name},
    ],
    if (confirmation != null) ...{
      'savedTitle': 'Saved as $categoryName',
      'savedMessage':
          '$signed · $label. ${confirmation['merchant'] != null ? 'Future payments here will be sorted automatically.' : 'Category updated for this transaction.'}',
      'undoToken': confirmation['token'],
    },
    'account': account?.name ?? live.sms.bankName,
    'category': other != null
        ? 'Transfer → ${other.name}'
        : category?.name ?? 'Uncategorised',
    'needsAccount': account == null && !ambiguous,
    'chooseAccount': ambiguous,
    'newAccount': newAccount,
    'receivedAt': live.sms.receivedAt.millisecondsSinceEpoch,
  });
}

/// A counterparty cleaned for a notification: no UPI plumbing, no shouting,
/// no company suffix. Empty when nothing readable is left.
String smsDisplayName(String? raw) {
  var name = (raw ?? '').trim();
  name = name.replaceFirst(
    RegExp(r'^(vpa|upi)[\s/:-]*', caseSensitive: false),
    '',
  );
  if (!name.contains(' ') && name.contains('@')) {
    name = name.substring(0, name.indexOf('@'));
  }
  name = name
      .replaceFirst(RegExp(r'[\s/-]*\d{6,}$'), '')
      .replaceFirst(
        RegExp(
          r'\s+(pvt\.?\s*ltd\.?|private\s+limited|ltd\.?|limited)$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // A bare UPI handle such as sri.lakshmi.stores reads (and wraps) as words.
  final handle = !name.contains(' ') && RegExp(r'[._-]').hasMatch(name);
  if (handle) name = name.replaceAll(RegExp(r'[._-]+'), ' ').trim();
  final mixed =
      !handle && name != name.toUpperCase() && name != name.toLowerCase();
  final acronym = name.length <= 4 && !name.contains(' ');
  if (name.isEmpty || mixed || acronym && name == name.toUpperCase()) {
    return name;
  }
  return name
      .split(' ')
      .map(
        (w) =>
            w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase(),
      )
      .join(' ');
}

Future<void> processBackgroundSms() async {
  WidgetsFlutterBinding.ensureInitialized();
  const worker = MethodChannel('simple_money/sms_worker');
  AppDatabase? db;
  var success = false;
  try {
    final raw = await worker.invokeMethod<String>('message');
    final data = jsonDecode(raw!) as Map;
    final message = BankSms(
      sender: data['sender'] as String,
      body: data['body'] as String,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        data['receivedAt'] as int,
      ),
    );
    // Only the sender's own packs are compiled; other senders stop here.
    // Personal numbers never reach the database.
    if (normalizeRuleSender(message.sender) == null) {
      success = true;
      return;
    }
    db = AppDatabase();
    final engine = await loadBundledSmsEngineFor(
      message.sender,
      userPack: await userSmsPack(db),
      communityPack: await communitySmsPack(db),
    );
    if (engine != null) {
      final result = await RealtimeSmsRepository(db).receive(message, engine);
      if (result != null) await showSmsNotification(db, result);
    }
    success = true;
  } finally {
    await db?.close();
    await worker.invokeMethod<void>('complete', success);
  }
}

/// One tap on a category pill of the notification: saves that category for
/// the message without opening the app, then refreshes the notification.
Future<void> processBackgroundCategoryPick() async {
  WidgetsFlutterBinding.ensureInitialized();
  const worker = MethodChannel('simple_money/sms_worker');
  AppDatabase? db;
  try {
    final raw = await worker.invokeMethod<String>('message');
    final data = jsonDecode(raw!) as Map;
    db = AppDatabase();
    final repository = RealtimeSmsRepository(db);
    final live = await repository.load(data['id'] as String);
    // A transfer has no category, and a deleted transaction nothing to save.
    if (live != null && live.otherAccountId == null) {
      await repository.selectCategory(
        live.sms.id,
        data['category'] as int,
        accountId: live.accountId,
      );
      final saved = await repository.load(live.sms.id);
      if (saved != null) await showSmsNotification(db, saved);
    }
  } on StateError {
    // The transaction or category changed since the pill was shown; the
    // notification as it stands is still right.
  } finally {
    await db?.close();
    await worker.invokeMethod<void>('complete', true);
  }
}
