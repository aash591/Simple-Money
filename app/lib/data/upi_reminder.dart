import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../domain/account.dart';
import '../domain/category.dart';
import '../domain/upi_payment.dart';
import '../state/sms_import_store.dart';
import 'db/app_database.dart';
import 'realtime_sms.dart' show smsDisplayName;
import 'repositories/account_repository.dart';
import 'repositories/category_repository.dart';
import 'repositories/realtime_sms_repository.dart';
import 'repositories/upi_repository.dart';

const _channel = MethodChannel('simple_money/upi_notifications');

/// The account a pending payment will land in: the one chosen, else the only
/// INR account there is. Null when the user has to pick.
int? upiPaymentAccount(PendingUpiPayment payment, List<Account> accounts) {
  final inr = accounts.where((a) => a.currency == 'INR' && a.digits == 2);
  if (payment.accountId != null && inr.any((a) => a.id == payment.accountId)) {
    return payment.accountId;
  }
  return inr.length == 1 ? inr.single.id : null;
}

/// The up to two categories most likely for [payment]: the one used last time
/// for this address, what its name suggests, then what is used most.
Future<List<Category>> upiCategorySuggestions(
  AppDatabase db,
  PendingUpiPayment payment,
  List<Category> categories,
) async {
  final expense = [
    for (final c in categories)
      if (c.type == CategoryType.expense) c,
  ];
  final picks = <Category>[];
  void add(Category? c) {
    if (c != null && picks.every((p) => p.id != c.id)) picks.add(c);
  }

  final recipient = payment.recipient;
  add(expense.where((c) => c.id == payment.categoryId).firstOrNull);
  final remembered = await UpiRepository(db).remembered(recipient);
  add(expense.where((c) => c.id == remembered.categoryId).firstOrNull);
  try {
    final categorizer = await loadBundledCategorizer();
    add(
      categorizer.category(
        recipient.hasMeaningfulName ? recipient.name : '',
        expense,
        credit: false,
        detail: recipient.isLegacyPhone ? null : recipient.address,
      ),
    );
  } catch (_) {}
  final frequent = await RealtimeSmsRepository(db)
      .frequentCategories(credit: false);
  for (final id in frequent) {
    add(expense.where((c) => c.id == id).firstOrNull);
  }
  return picks.take(2).toList();
}

String _amountText(PendingUpiPayment payment) => payment.amountText.isEmpty
    ? ''
    : '₹${formatAccountAmount(upiAmountMinor(payment.amountText)!, digits: 2, currency: 'INR')}';

/// Asks, with a notification, whether [payment] went through: its amount and
/// place, and a pill for each likely category that saves it in one tap.
Future<void> showUpiReminder(AppDatabase db, PendingUpiPayment payment) async {
  final accounts = await AccountRepository(db).load();
  final categories = await CategoryRepository(db).load();
  final canSave = upiPaymentAccount(payment, accounts) != null;
  final suggestions = canSave
      ? await upiCategorySuggestions(db, payment, categories)
      : const <Category>[];
  final recipient = payment.recipient;
  final name = recipient.hasMeaningfulName
      ? smsDisplayName(recipient.name)
      : smsDisplayName(recipient.isLegacyPhone ? null : recipient.address);
  final amount = _amountText(payment);
  await _channel.invokeMethod<void>('show', {
    'id': payment.id,
    'title': amount.isEmpty
        ? 'Did your payment go through?'
        : 'Did you pay $amount${name.isEmpty ? '' : ' to $name'}?',
    'text': [
      if (payment.place != null) 'Near ${payment.place}',
      suggestions.isEmpty
          ? 'Tap to mark it paid'
          : 'Tap a category to mark it paid',
    ].join(' · '),
    'suggestions': [
      for (final c in suggestions) {'id': c.id, 'label': c.name},
    ],
  });
}

/// Background entry for the reminder and its buttons. [payload]: `id`, then
/// either `remind`, `discard`, or a `category` to save the payment under.
Future<void> processBackgroundUpiPayment() async {
  WidgetsFlutterBinding.ensureInitialized();
  const worker = MethodChannel('simple_money/sms_worker');
  AppDatabase? db;
  try {
    final data = jsonDecode((await worker.invokeMethod<String>('message'))!);
    final id = data['id'] as String;
    db = AppDatabase();
    final repository = UpiRepository(db);
    final payment = (await repository.load())
        .where((p) => p.id == id)
        .firstOrNull;
    // Already saved or deleted in the app: nothing left to ask.
    if (payment == null) {
      await _channel.invokeMethod<void>('cancel', id);
    } else if (data['remind'] == true) {
      await showUpiReminder(db, payment);
    } else if (data['discard'] == true) {
      await repository.delete(id);
      await _channel.invokeMethod<void>('cancel', id);
    } else {
      final accounts = await AccountRepository(db).load();
      final categories = await CategoryRepository(db).load();
      final category = categories
          .where((c) => c.id == data['category'])
          .firstOrNull;
      final account = upiPaymentAccount(payment, accounts);
      if (category != null && account != null) {
        await repository.confirm(
          id,
          details: payment.copyWith(
            categoryId: category.id,
            accountId: account,
          ),
        );
        final amount = _amountText(payment);
        await _channel.invokeMethod<void>('show', {
          'id': id,
          'done': true,
          'title': 'Saved as ${category.name}',
          'text': [
            if (amount.isNotEmpty) amount,
            payment.recipient.hasMeaningfulName
                ? smsDisplayName(payment.recipient.name)
                : null,
          ].whereType<String>().join(' · '),
        });
      }
    }
  } on StateError {
    // The payment changed since the pill was shown; the app will ask again.
  } finally {
    await db?.close();
    await worker.invokeMethod<void>('complete', true);
  }
}
