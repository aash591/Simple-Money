import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/convert_minor.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late TransactionStore transactions;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.load();
    await transactions.load();
    for (final code in ['SAR', 'INR']) {
      await accounts.save(
        name: '$code account',
        currency: code,
        digits: 2,
        openingBalance: 100000,
      );
    }
  });

  tearDown(() async {
    transactions.dispose();
    accounts.dispose();
    await db.close();
  });

  int idOf(String code) =>
      accounts.accounts.firstWhere((a) => a.currency == code).id;
  int balanceOf(String code) =>
      accounts.accounts.firstWhere((a) => a.currency == code).balanceMinor;

  test('Each account moves by its own figure, not the sender\'s', () async {
    await transactions.addTransfer(
      amountMinor: 50000, // SAR 500 leaves
      fromAccountId: idOf('SAR'),
      toAccountId: idOf('INR'),
      toAmountMinor: 1108000, // ₹11,080 arrives
      date: DateTime(2026, 9, 12),
    );
    expect(balanceOf('SAR'), 100000 - 50000);
    expect(balanceOf('INR'), 100000 + 1108000);
    expect(transactions.transactions.single.receivedMinor, 1108000);
  });

  test('Deleting restores both balances exactly', () async {
    await transactions.addTransfer(
      amountMinor: 50000,
      fromAccountId: idOf('SAR'),
      toAccountId: idOf('INR'),
      toAmountMinor: 1108000,
      date: DateTime(2026, 9, 12),
    );
    await transactions.deleteTransaction(transactions.transactions.single.id);
    expect(balanceOf('SAR'), 100000);
    expect(balanceOf('INR'), 100000);
    expect(transactions.transactions, isEmpty);
  });

  test('A mismatched pair with no received amount is still refused', () async {
    await expectLater(
      transactions.addTransfer(
        amountMinor: 50000,
        fromAccountId: idOf('SAR'),
        toAccountId: idOf('INR'),
        date: DateTime(2026, 9, 12),
      ),
      throwsArgumentError,
    );
    expect(balanceOf('SAR'), 100000);
    expect(balanceOf('INR'), 100000);
    expect(transactions.transactions, isEmpty);
  });

  test('A same-currency transfer still needs no received amount', () async {
    await accounts.save(
      name: 'Second INR',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
    );
    final second = accounts.accounts.firstWhere((a) => a.name == 'Second INR');
    await transactions.addTransfer(
      amountMinor: 20000,
      fromAccountId: idOf('INR'),
      toAccountId: second.id,
      date: DateTime(2026, 9, 12),
    );
    expect(balanceOf('INR'), 80000);
    expect(
      accounts.accounts.firstWhere((a) => a.id == second.id).balanceMinor,
      20000,
    );
    expect(transactions.transactions.single.toAmountMinor, isNull);
    expect(transactions.transactions.single.receivedMinor, 20000);
  });

  test(
    'A charge on a same-currency transfer is the gap between the two',
    () async {
      await accounts.save(
        name: 'Second INR',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      final second = accounts.accounts.firstWhere(
        (a) => a.name == 'Second INR',
      );
      await transactions.addTransfer(
        amountMinor: 100000, // ₹1,000 sent
        fromAccountId: idOf('INR'),
        toAccountId: second.id,
        toAmountMinor: 99500, // ₹995 arrived: a ₹5 charge
        date: DateTime(2026, 9, 12),
      );
      expect(balanceOf('INR'), 0);
      expect(
        accounts.accounts.firstWhere((a) => a.id == second.id).balanceMinor,
        99500,
      );
    },
  );

  test('A zero or negative received amount is rejected', () async {
    await expectLater(
      transactions.addTransfer(
        amountMinor: 50000,
        fromAccountId: idOf('SAR'),
        toAccountId: idOf('INR'),
        toAmountMinor: 0,
        date: DateTime(2026, 9, 12),
      ),
      throwsArgumentError,
    );
  });

  group('crossConvertMinor', () {
    test('Converts through a shared base in one rounding', () {
      // Table base INR: 1 INR = 0.0449 SAR, 1 INR = 1 INR.
      expect(
        crossConvertMinor(
          50000,
          fromDigits: 2,
          toDigits: 2,
          perMainFrom: 0.0449,
          perMainTo: 1,
        ),
        1113586, // SAR 500 -> ₹11,135.86
      );
    });

    test('Is null when either rate is missing or unusable', () {
      for (final pair in [
        (null, 1.0),
        (1.0, null),
        (0.0, 1.0),
        (1.0, -1.0),
        (double.nan, 1.0),
      ]) {
        expect(
          crossConvertMinor(
            50000,
            fromDigits: 2,
            toDigits: 2,
            perMainFrom: pair.$1,
            perMainTo: pair.$2,
          ),
          isNull,
        );
      }
    });

    test('Respects each currency\'s precision', () {
      // SAR 500 -> JPY at 1 INR = 0.0449 SAR, 1 INR = 1.78 JPY, 0 decimals.
      expect(
        crossConvertMinor(
          50000,
          fromDigits: 2,
          toDigits: 0,
          perMainFrom: 0.0449,
          perMainTo: 1.78,
        ),
        19822,
      );
    });
  });
}
