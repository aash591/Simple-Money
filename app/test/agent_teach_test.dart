// The tools a small model can use to teach the app: label_sms (copy values
// out of a missed SMS) and map_statement (name a statement's columns).
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/agent/statement_samples.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/data/repositories/statement_import_repository.dart';
import 'package:simple_money/data/statements/pending_statement_files.dart';
import 'package:simple_money/data/statements/upi_statement.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

const _paid =
    'Paid Rs.1,250.00 to Blue Tokai Coffee from Zeta card XX4321. '
    'Ref 99887766. -Zeta';
const _paidAgain =
    'Paid Rs.89.00 to Metro Rail from Zeta card XX4321. Ref A1B2C3. -Zeta';
const _debited =
    'Rs 500.00 debited from A/c XX1234 on 31-10-26 to SWIGGY. Avl Bal Rs '
    '12,000.50 -Zeta';
const _debitedAgain =
    'Rs 75.25 debited from A/c XX1234 on 02-11-26 to ZOMATO. Avl Bal Rs '
    '11,925.25 -Zeta';

void main() {
  late AppDatabase db;
  late AgentTools tools;
  var inbox = <String>[];

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  /// The id list_missed_sms gives [body].
  Future<String> idOf(String body) async {
    final listed = await call('list_missed_sms');
    return ((listed['messages'] as List).cast<Map>().firstWhere(
          (m) => m['text'] == body,
        ))['id']
        as String;
  }

  Future<PortableParseResult> parse(String body) async =>
      (await loadSmsEngine(db)).parse(
        BankSms(sender: 'AD-ZETAPY', body: body, receivedAt: DateTime(2026)),
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(
      db,
      missedSms: (window) async => [
        for (final (i, body) in inbox.indexed)
          ReportableSms(
            '$i',
            BankSms(
              sender: 'VM-ZETAPY',
              body: body,
              receivedAt: DateTime(2026, 10, 20 + i),
            ),
            ReportableKind.missed,
            'unregisteredSender',
            null,
          ),
      ],
    );
  });

  tearDown(() => db.close());

  test(
    'Suggestions made before statement layouts survive the upgrade',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp('agent_upgrade_');
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      final file = File('${directory.path}/ledger.sqlite');
      db = AppDatabase(NativeDatabase(file));
      // A complete ledger keeps the fixture valid for unrelated migrations.
      await db.customSelect('SELECT 1').get();
      await db.customStatement('DROP TABLE agent_suggestions');
      await db.customStatement('''CREATE TABLE agent_suggestions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('new_category', 'sms_correction',
              'transaction_edit', 'parser_rule')),
            target TEXT NOT NULL, payload TEXT NOT NULL, before TEXT,
            summary TEXT NOT NULL, detail TEXT NOT NULL, reason TEXT,
            status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending',
              'applied', 'rejected', 'undone')),
            error TEXT, created_at INTEGER NOT NULL, decided_at INTEGER)''');
      await db.customStatement(
        """INSERT INTO agent_suggestions
            (batch_id, kind, target, payload, summary, detail, created_at)
            VALUES ('b', 'new_category', 'Food', '{}', 'New category', '', 1)""",
      );
      await db.customStatement('PRAGMA user_version = 34');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final kinds = await db
          .customSelect('SELECT kind FROM agent_suggestions')
          .map((r) => r.read<String>('kind'))
          .get();
      expect(kinds, ['new_category']);
      await db.customStatement("""INSERT INTO agent_suggestions (batch_id, kind, target, payload, summary, detail, created_at)
      VALUES ('b', 'statement_layout', 'x', '{}', 'Layout', '', 2)""");
    },
  );

  test(
    'Copied values become a rule that reads the other messages too',
    () async {
      inbox = [_paid, _paidAgain];
      final taught = await call('label_sms', {
        'sms_id': await idOf(_paid),
        'amount': '1,250.00',
        'payee': 'Blue Tokai Coffee',
        'account': 'XX4321',
        'reference': '99887766',
        'direction': 'debit',
        'channel': 'card',
        'sender_type': 'bank',
        'country': 'IN',
        'currency': 'INR',
        'bank_name': 'Zeta',
      });
      expect(taught['suggested'], isTrue, reason: '$taught');
      expect(taught['read_by_this_rule'], 2);
      expect(taught['still_missed'], isEmpty);
      expect(taught['next'], startsWith('Done'));
      expect(taught['read_from_this_sms'], containsPair('amount', '1250.00'));

      final repo = AgentSuggestionRepository(db);
      final pending = await repo.load();
      expect(pending.single.kind, AgentSuggestionKind.parserRule);
      expect(await repo.apply(pending.single.id), isNull);
      final read = await parse(_paidAgain);
      expect(read.candidate?.amountMinor, 8900);
      expect(read.candidate?.counterparty, 'Metro Rail');
    },
  );

  test('Dates and balances in between are read as any text', () async {
    inbox = [_debited, _debitedAgain];
    final taught = await call('label_sms', {
      'sms_id': await idOf(_debited),
      'amount': '500.00',
      'account': 'XX1234',
      'payee': 'SWIGGY',
      'direction': 'debit',
      'channel': 'bankTransfer',
      'sender_type': 'bank',
      'country': 'IN',
      'currency': 'INR',
      'bank_name': 'Zeta',
    });
    expect(taught['read_by_this_rule'], 2, reason: '$taught');
  });

  test('A new bank is named from how its SMS signs off', () async {
    inbox = [_paid, _paidAgain];
    final taught = await call('label_sms', {
      'sms_id': await idOf(_paid),
      'amount': '1,250.00',
      'payee': 'Blue Tokai Coffee',
      'direction': 'debit',
      'channel': 'card',
      'sender_type': 'bank',
      'country': 'IN',
      'currency': 'INR',
    });
    expect(taught['suggested'], isTrue, reason: '$taught');
    final rule = (await AgentSuggestionRepository(db).load()).single;
    expect(rule.summary, 'New SMS rule · Zeta');
  });

  test('A value not copied exactly says how to fix it', () async {
    inbox = [_paid];
    final wrong = await call('label_sms', {
      'sms_id': await idOf(_paid),
      'amount': '1250',
      'direction': 'debit',
      'channel': 'card',
      'sender_type': 'bank',
      'country': 'IN',
      'currency': 'INR',
      'bank_name': 'Zeta',
    });
    expect(wrong['error'], contains('isn’t in the message'));
    expect(await AgentSuggestionRepository(db).load(), isEmpty);
  });

  test(
    'A statement layout is mapped by column names, approved and undone',
    () async {
      await StatementSampleRepository().add('hdfc.xls', [
        ['HDFC BANK Ltd.'],
        [
          'Txn Date',
          'Narration',
          'Withdrawal Amt.',
          'Deposit Amt.',
          'Closing Balance',
        ],
        ['01/10/26', 'UPI-SWIGGY-swiggy@icici', '250.00', '', '9,750.00'],
        ['02/10/26', 'SALARY OCT', '', '50,000.00', '59,750.00'],
        ['03/10/26', 'ATM WDL', '2,000.00', '', '57,750.00'],
      ], 1);
      final listed = await call('list_statements_to_map');
      final sample = (listed['statements'] as List).single as Map;
      expect(sample['column_names'], contains('Withdrawal Amt.'));
      expect((sample['example_rows'] as List).length, 3);

      expect(
        sample['app_guess'],
        containsPair('debit', 'Withdrawal Amt.'),
        reason: '$sample',
      );

      final bad = await call('map_statement', {
        'statement_id': sample['id'],
        'date': 'Posted on',
        'amount': 'Withdrawal Amt.',
      });
      expect(bad['error'], contains('Txn Date'));

      // Near enough is enough: a typo, a part of the name, and amount
      // alongside debit and credit (not needed, so set aside).
      final loose = await call('map_statement', {
        'statement_id': sample['id'],
        'date': 'Date',
        'description': 'Narations',
        'amount': 'Withdrawal',
        'debit': 'Withdrawal',
        'credit': 'Deposit Amt',
        'reference': 'none',
      });
      expect(loose['reads'], '3 of 3 sample rows', reason: '$loose');
      expect(
        loose['ignored'],
        containsPair('amount', 'Not needed with debit and credit.'),
      );
      expect(loose['next'], startsWith('Done'));

      // Each call adds to the last; "none" clears a field, and what's
      // left out is filled in from the app's own guess.
      final cleared = await call('map_statement', {
        'statement_id': sample['id'],
        'description': 'none',
        'credit': 'none',
      });
      expect(cleared['reads'], '3 of 3 sample rows', reason: '$cleared');
      expect(
        cleared['filled_in'],
        allOf(
          containsPair('description', 'Narration'),
          containsPair('credit', 'Deposit Amt.'),
        ),
      );

      final mapped = await call('map_statement', {
        'statement_id': sample['id'],
        'date': 'Txn Date',
        'description': 'narration',
        'debit': 'Withdrawal Amt.',
        'credit': 'Deposit Amt.',
        'balance': 'Closing Balance',
        'date_order': 'day_first',
      });
      expect(mapped['reads'], '3 of 3 sample rows', reason: '$mapped');
      expect((mapped['preview'] as List).first, contains('2026-10-01'));

      final repo = AgentSuggestionRepository(db);
      final suggestion = (await repo.load()).single;
      expect(suggestion.kind, AgentSuggestionKind.statementLayout);
      expect(await repo.apply(suggestion.id), isNull);
      final layouts = StatementImportRepository(db);
      expect(
        (await layouts.columnMappings()).keys,
        contains(startsWith('txn date|')),
      );
      // Mapped: it's no longer waiting for the AI.
      expect(await StatementSampleRepository().load(), isEmpty);

      expect(await repo.undo(suggestion.id), isNull);
      expect(await layouts.columnMappings(), isEmpty);
    },
  );

  test('A PDF column split in two is joined back by the AI', () async {
    // As the app rebuilt an SBI PDF: the narration wraps into a second
    // column, and one credit sits out of line in a column of its own.
    await StatementSampleRepository().add('sbi.pdf', [
      ['Txn Date', 'Column 2', 'Description', 'Debit', 'Amount', 'Credit',
        'Balance'],
      ['01-04-2026', 'WDL TFR UPI/DR/6091/ADWAITH', '0097 AT', '1,000.00',
        '', '', '4,914.41'],
      ['03-04-2026', 'DEP TFR UPI/CR/6091/ASHIQUE', '0099 AT', '', '',
        '2,500.00', '7,414.41'],
      ['03-04-2026', 'DEP TFR UPI/CR/6092/SHAFEER', '0098 AT', '', '90.00',
        '', '7,504.41'],
    ], 0);
    final id =
        (((await call('list_statements_to_map'))['statements'] as List).single
            as Map)['id'];
    final pages = await call('view_statement_pages', {'statement_id': id});
    expect(pages['pages'], 0);
    expect(pages['next'], contains('allow pictures'));

    final bad = await call('map_statement', {
      'statement_id': id,
      'date': 'Txn Date',
      'join': {'Nothing': 'Description'},
    });
    expect(bad['error'], contains('Can’t join'));

    final mapped = await call('map_statement', {
      'statement_id': id,
      'date': 'Txn Date',
      'description': 'Description',
      'debit': 'Debit',
      'credit': 'Credit',
      'balance': 'Balance',
      'join': {'Column 2': 'Description', 'Amount': 'Credit'},
    });
    expect(mapped['reads'], '3 of 3 sample rows', reason: '$mapped');
    // Both halves of the narration, and the stray 90.00 as money in.
    expect(mapped['preview'], [
      startsWith('2026-04-01 · 1000.00 debit · ADWAITH 0097'),
      startsWith('2026-04-03 · 2500.00 credit · ASHIQUE 0099'),
      startsWith('2026-04-03 · 90.00 credit · SHAFEER 0098'),
    ]);
  });

  test('Map statement checks the whole file, not just the examples', () async {
    final folder = await Directory.systemTemp.createTemp('pending_');
    PendingStatementFiles.defaultDirectory = () async => folder;
    addTearDown(() => folder.delete(recursive: true));
    // A PDF table where a short balance ("940.00") lands in a column of its
    // own, empty in the first rows.
    final rows = [
      ['Txn Date', 'Description', 'Debit', 'Credit', 'Column 5', 'Balance'],
      for (var day = 1; day <= 6; day++)
        ['0$day-04-2026', 'UPI/DR/$day/SHOP', '10.00', '', '',
          '${2000 - day * 10}.00'],
      ['07-04-2026', 'UPI/DR/7/SHOP', '1,000.00', '', '940.00', ''],
      ['08-04-2026', 'UPI/CR/8/SALARY', '', '5,000.00', '', '5,940.00'],
    ];
    await PendingStatementFiles().save('sbi.pdf', rows, UpiStatementSource.bank);
    await StatementSampleRepository().add('sbi.pdf', rows, 0);
    final listed =
        ((await call('list_statements_to_map'))['statements'] as List).single
            as Map;
    expect(listed['rows_with_value_per_column'], containsPair('Column 5', 1));

    final args = {
      'statement_id': listed['id'],
      'date': 'Txn Date',
      'description': 'Description',
      'debit': 'Debit',
      'credit': 'Credit',
      'balance': 'Balance',
    };
    final first = await call('map_statement', args);
    final whole = first['whole_file'] as Map;
    expect(whole['rows_missing_amount_or_balance'], 1, reason: '$first');
    expect(whole['their_amounts'], [
      {'Debit': '1,000.00', 'Column 5': '940.00'},
    ]);
    expect(first['next'], contains('join'));

    final joined = await call('map_statement', {
      ...args,
      'join': {'Column 5': 'Balance'},
    });
    expect(joined['whole_file'], {'rows': 8, 'balance_breaks': 0});
    expect(joined['next'], startsWith('Done'));
  });

  test('A short-code description is pointed at the narration', () async {
    await StatementSampleRepository().add('fincare.xlsx', [
      ['Value Dt', 'Particulars', 'Chq/Ref', 'Dr Amount', 'Cr Amount'],
      ['28/10/2026', 'UPI/swiggy@icici/530112345678', '5301', '1,250.00', ''],
      ['30/10/2026', 'NEFT CR SALARY OCT', 'N303', '', '45,000.00'],
      ['', 'Closing balance', '', '', ''],
    ], 0);
    final id =
        (((await call('list_statements_to_map'))['statements'] as List).single
            as Map)['id'];
    final mapped = await call('map_statement', {
      'statement_id': id,
      'date': 'Value Dt',
      'description': 'Chq/Ref',
      'debit': 'Dr Amount',
      'credit': 'Cr Amount',
    });
    // The footer has no date, so it isn't a row that failed to read.
    expect(mapped['reads'], '2 of 2 sample rows', reason: '$mapped');
    expect(mapped['skipped'], startsWith('1 without a date'));
    expect(mapped['next'], contains('description “Particulars”'));
  });

  test('Each kind of SMS is labelled once, then the reply says done', () async {
    const upi =
        'Rs.450.00 debited from a/c **5678 on 28-Oct-26 to ZOMATO LTD (UPI '
        'Ref No 530211112222). Avl Bal Rs.12,340.55 -Zeta';
    const upiAgain =
        'Rs.1,180.00 debited from a/c **5678 on 29-Oct-26 to SRI KRISHNA '
        'STORES (UPI Ref No 530233334444). Avl Bal Rs.11,160.55 -Zeta';
    const card =
        'Card XX9012 used for INR 799.00 at NETFLIX COM. Not you? SMS BLOCK '
        'to 5676 -Zeta';
    const otp =
        '482913 is your OTP to log in to Zeta NetBanking. Do not share it '
        'with anyone. -Zeta';
    inbox = [upi, upiAgain, card, otp];
    final upiId = await idOf(upiAgain);
    final first = await call('label_sms', {
      'sms_id': await idOf(upi),
      'amount': '450.00',
      'account': '5678',
      'payee': 'ZOMATO LTD',
      'reference': '530211112222',
      'direction': 'debit',
      'channel': 'upi',
      'sender_type': 'bank',
      'country': 'IN',
      'currency': 'INR',
    });
    expect(first['read_by_this_rule'], 2, reason: '$first');
    expect(first['not_payments'], 1, reason: '$first');
    final missed = (first['still_missed'] as List).cast<Map>();
    expect([for (final m in missed) m['text']], [card]);
    expect(first['next'], contains(missed.single['sms_id'] as String));

    // The other UPI message needs nothing more: no second rule for it.
    final cardId = _idIn(missed.single);
    final listedBefore = await call('list_missed_sms');
    expect(listedBefore['total'], 1, reason: '$listedBefore');
    final repeat = await call('label_sms', {
      'sms_id': upiId,
      'amount': '1,180.00',
      'direction': 'debit',
      'channel': 'upi',
      'sender_type': 'bank',
      'country': 'IN',
      'currency': 'INR',
    });
    expect(repeat['suggested'], isFalse, reason: '$repeat');

    final again = await call('label_sms', {
      'sms_id': cardId,
      'amount': '799.00',
      'account': 'XX9012',
      'payee': 'NETFLIX COM',
      'direction': 'debit',
      'channel': 'card',
      'sender_type': 'bank',
      'country': 'IN',
      'currency': 'INR',
    });
    expect(again['next'], startsWith('Done'), reason: '$again');
    final listed = await call('list_missed_sms');
    expect(listed['total'], 0, reason: '$listed');
    expect(listed['already_handled'], 4);
  });

  test('A layout given a piece at a time, as row values, adds up', () async {
    await StatementSampleRepository().add('kavr.xlsx', [
      ['Dt', 'Remarks', 'Ref', 'Out', 'In', 'Bal'],
      ['01/10/26', 'UPI-SWIGGY', '5301', '250.00', '', '9,750.00'],
      ['02/10/26', 'SALARY OCT', 'N275', '', '50,000.00', '59,750.00'],
      ['05/10/26', 'ATM WDL', '', '2,000.00', '', '57,750.00'],
    ], 0);
    final id =
        (((await call('list_statements_to_map'))['statements'] as List).single
            as Map)['id'];
    // "amount" from a row whose money-in cell is blank: really money out.
    final first = await call('map_statement', {
      'statement_id': id,
      'date': '01/10/26',
      'description': 'UPI-SWIGGY',
      'amount': '250.00',
      'credit': '',
    });
    expect(first['reads'], '3 of 3 sample rows', reason: '$first');
    expect(
      first['ignored'],
      containsPair('amount', contains('only money out')),
    );

    // Only date and debit, as values; credit added by the next call.
    await StatementSampleRepository().add('fin.xlsx', [
      ['Value Dt', 'Particulars', 'Chq/Ref', 'Dr Amount', 'Cr Amount'],
      ['28/10/2026', 'UPI/swiggy@icici', '5301', '1,250.00', ''],
      ['30/10/2026', 'NEFT CR SALARY OCT', 'N303', '', '45,000.00'],
    ], 0);
    final fin =
        (((await call('list_statements_to_map'))['statements'] as List).first
            as Map)['id'];
    final noDate = await call('map_statement', {
      'statement_id': fin,
      'date': 'none',
      'debit': '1,250.00',
    });
    expect(noDate['error'], contains('Still needed: date'));
    final done = await call('map_statement', {
      'statement_id': fin,
      'date': '28/10/2026',
    });
    expect(done['reads'], '2 of 2 sample rows', reason: '$done');
    expect(done['next'], startsWith('Done'));
  });

  test(
    'A date value in two columns, or with a time, finds its column',
    () async {
      await StatementSampleRepository().add('sbi.xls', [
        ['Txn Date', 'Value Date', 'Description', 'Withdrawal', 'Deposit'],
        ['01 Oct 2026', '01 Oct 2026', 'UPI/SWIGGY', '1,250.00', ''],
        ['03 Oct 2026', '03 Oct 2026', 'NEFT SALARY', '', '45,000.00'],
      ], 0);
      await StatementSampleRepository().add('kaveri.csv', [
        ['Tran Dt', 'Narration', 'Amount', 'Dr / Cr'],
        ['28-10-2026 10:21', 'UPI-SWIGGY', '1,250.00', 'DR'],
        ['30-10-2026 18:40', 'NEFT-ACME', '45,000.00', 'CR'],
      ], 0);
      final ids = {
        for (final s
            in (await call('list_statements_to_map'))['statements'] as List)
          (s as Map)['file']: s['id'],
      };
      final sbi = await call('map_statement', {
        'statement_id': ids['sbi.xls'],
        'date': '01 Oct 2026',
        'debit': 'Withdrawal',
        'credit': 'Deposit',
      });
      expect(sbi['reads'], '2 of 2 sample rows', reason: '$sbi');
      final kaveri = await call('map_statement', {
        'statement_id': ids['kaveri.csv'],
        'date': '28-10-2026',
        'amount': 'Amount',
        'direction': 'Dr / Cr',
      });
      expect(kaveri['reads'], '2 of 2 sample rows', reason: '$kaveri');
    },
  );
}

String _idIn(Map message) => message['sms_id'] as String;
