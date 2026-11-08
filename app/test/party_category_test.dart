import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/statements/statement_reconciliation.dart';
import 'package:simple_money/data/statements/upi_statement.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/party_category.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  late PartyCategorizer categorizer;
  late List<Category> categories;

  setUpAll(() async {
    const compiler = RuleCompiler();
    categorizer = PartyCategorizer(
      PortableCategorizer(
        compiler.loadRuntime(
          jsonDecode(
            File(
              'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
            ).readAsStringSync(),
          ) as Map<String, dynamic>,
        ),
      ),
    );
    final db = AppDatabase(NativeDatabase.memory(), false);
    categories = await CategoryRepository(db).load();
    await db.close();
  });

  String? category(String party, {bool credit = false, String? detail}) =>
      categorizer
          .category(party, categories, credit: credit, detail: detail)
          ?.name;

  test('payees resolve to the default categories', () {
    expect(category('MINA MEDICALS'), 'Pharmacy');
    expect(category('NK SILKS'), 'Clothing');
    expect(category('Avilo Tea New'), 'Cafe');
    expect(category('Kerala State Road Transport Corporation'), 'Bus');
    expect(category('BSNL Landline - Individual'), 'Mobile');
    expect(category('Vi'), 'Mobile');
    expect(category('Meesho'), 'Shopping');
    // No "Bakery" category by default: its alias "Cafe" stands in.
    expect(category('MARISTON CAKES AND BAKES'), 'Cafe');
    // No "Vehicle Maintenance" either: Transportation does.
    expect(category('STAR AUTO PARTS'), 'Transportation');
    expect(
      category(
        'Google I',
        detail: 'UPI/DR/500114917725/Google I/ICIC/gpayrechar/UPI',
      ),
      'Mobile Recharge',
    );
    expect(category('Int.Pd:9150444825:01-07-2026', credit: true), 'Interest');
    // A person is left to the payee's history or Other.
    expect(category('Shefeek M'), isNull);
  });

  test('ATM cash is no category but a transfer with cash in hand', () {
    final withdrawal = categorizer.suggest(
      'ATM WDL ATM CASH 4410 KARIKODE ONSITE KOLLAM',
      credit: false,
    )!;
    expect(isCashMovement(withdrawal), isTrue);
    expect(category('ATM WDL ATM CASH 4410'), isNull);

    const sbi = StatementAccount(bank: 'State Bank of India', digits: '2199');
    UpiStatementRow row(String party, UpiStatementDirection direction) =>
        UpiStatementRow(
          date: DateTime(2026, 3, 1, 12),
          direction: direction,
          amountMinor: 50000,
          counterparty: party,
          account: sbi,
        );
    final rows = markCashMovements(
      [
        row('ATM WDL ATM CASH 4410', UpiStatementDirection.debit),
        row('CSH DEP (CDM) CDM4040106KOLLAM', UpiStatementDirection.credit),
        row('MINA MEDICALS', UpiStatementDirection.debit),
      ],
      (r) => switch (categorizer.suggest(
        r.counterparty,
        credit: r.direction == UpiStatementDirection.credit,
      )) {
        final s? => isCashMovement(s),
        null => false,
      },
    );
    expect(rows.map((r) => (r.direction, r.account, r.toAccount)), [
      (UpiStatementDirection.selfTransfer, sbi, StatementAccount.cash),
      (UpiStatementDirection.selfTransfer, StatementAccount.cash, sbi),
      (UpiStatementDirection.debit, sbi, null),
    ]);
  });
}
