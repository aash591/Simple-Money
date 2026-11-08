// A real model, live, doing the job the teach tools are for: turning missed
// SMS and an unknown statement layout into suggestions. Talks to any
// OpenAI-compatible chat endpoint (llama.cpp, Ollama, ...) with tool calls,
// and prints the conversation. Skipped unless LLM_URL is set, e.g.
//   LLM_URL=https://host/v1 LLM_KEY=... LLM_MODEL=Spark-X2.6-4B-Q8_0 \
//     flutter test test/ai_small_model_live_test.dart
// LLM_TOOLS=teach offers only the four teach tools instead of all of them.
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
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/data/statements/upi_statement.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'llm_chat.dart' as chat;

/// A small bank no bundled pack knows, as its SMS really look.
const _fincare = [
  'Dear Customer, INR 1,250.00 debited from A/c no. XX4321 on 28-10-26 '
      'to VPA swiggy@icici. UPI Ref 530112345678. Not you? Call 18004251234 '
      '-Fincare SFB',
  'Dear Customer, INR 89.50 debited from A/c no. XX4321 on 29-10-26 to '
      'VPA metrorail@ybl. UPI Ref 530198765432. Not you? Call 18004251234 '
      '-Fincare SFB',
  'Dear Customer, INR 2,000.00 debited from A/c no. XX4321 on 30-10-26 '
      'to VPA rent.owner@okhdfc. UPI Ref 530155554444. Not you? Call '
      '18004251234 -Fincare SFB',
];

/// One bank, four kinds of message (UPI out, NEFT in, card, ATM), and an
/// OTP that isn't a payment at all. Amount in paise, and whether it's out.
const _nilgiri = <(String, int?, bool?)>[
  (
    'Rs.450.00 debited from a/c **5678 on 28-Oct-26 to ZOMATO LTD (UPI Ref '
        'No 530211112222). Avl Bal Rs.12,340.55 -Nilgiri Bank',
    45000,
    true,
  ),
  (
    'Rs.1,180.00 debited from a/c **5678 on 29-Oct-26 to SRI KRISHNA STORES '
        '(UPI Ref No 530233334444). Avl Bal Rs.11,160.55 -Nilgiri Bank',
    118000,
    true,
  ),
  (
    'Rs.15,000.00 credited to a/c **5678 on 29-Oct-26 by NEFT from ACME '
        'PAYROLL PVT LTD. Ref N302261234. Avl Bal Rs.26,160.55 -Nilgiri Bank',
    1500000,
    false,
  ),
  (
    'Rs.1,299.00 spent on Nilgiri Debit Card XX9012 at AMAZON PAY INDIA on '
        '30-Oct-26. Avl Bal Rs.24,861.55 -Nilgiri Bank',
    129900,
    true,
  ),
  (
    'Rs.2,000.00 withdrawn at ATM S1AW0123 from a/c **5678 on 31-Oct-26. '
        'Avl Bal Rs.22,861.55 -Nilgiri Bank',
    200000,
    true,
  ),
  (
    'Rs.799.00 spent on Nilgiri Debit Card XX9012 at NETFLIX COM on '
        '31-Oct-26. Avl Bal Rs.22,062.55 -Nilgiri Bank',
    79900,
    true,
  ),
  (
    '482913 is your OTP to log in to Nilgiri NetBanking. Do not share it '
        'with anyone. -Nilgiri Bank',
    null,
    null,
  ),
];

/// Title rows above the table, a serial number, two date columns,
/// withdrawal and deposit columns and a closing-balance footer.
const _sbiStyle = [
  ['State Bank of India', '', '', '', '', '', '', ''],
  ['Account Name', ':', 'MR ASHIQUE M', '', '', '', '', ''],
  ['Account Number', ':', '00000032145678901', '', '', '', '', ''],
  ['Statement Period', ':', '01-10-2026 to 31-10-2026', '', '', '', '', ''],
  ['', '', '', '', '', '', '', ''],
  [
    'Sl No',
    'Txn Date',
    'Value Date',
    'Description',
    'Ref No./Cheque No.',
    'Withdrawal Amt (INR)',
    'Deposit Amt (INR)',
    'Balance (INR)',
  ],
  [
    '1',
    '01 Oct 2026',
    '01 Oct 2026',
    'TO TRANSFER-UPI/DR/530112345678/SWIGGY/YESB/swiggy@ybl/Payment',
    'TRANSFER TO 4897691162091',
    '1,250.00',
    '',
    '18,750.00',
  ],
  [
    '2',
    '03 Oct 2026',
    '03 Oct 2026',
    'BY TRANSFER-NEFT*HDFC0000001*N276261234*ACME PAYROLL',
    'TRANSFER FROM 3199',
    '',
    '45,000.00',
    '63,750.00',
  ],
  [
    '3',
    '05 Oct 2026',
    '05 Oct 2026',
    'ATM WDL-ATM CASH 1234 KOLLAM',
    '',
    '2,000.00',
    '',
    '61,750.00',
  ],
  [
    '4',
    '09 Oct 2026',
    '09 Oct 2026',
    'TO TRANSFER-UPI/DR/530198765432/METRO RAIL/ICIC/metro@icici/Ticket',
    'TRANSFER TO 4897691162091',
    '89.50',
    '',
    '61,660.50',
  ],
  [
    '5',
    '12 Oct 2026',
    '12 Oct 2026',
    'BY TRANSFER-UPI/CR/530155554444/RAHUL K/SBIN/rahulk@oksbi/Lunch',
    'TRANSFER FROM 4897',
    '',
    '600.00',
    '62,260.50',
  ],
  [
    '6',
    '20 Oct 2026',
    '20 Oct 2026',
    'TO TRANSFER-UPI/DR/530177778888/AMAZON PAY/YESB/amazon@apl/Order',
    'TRANSFER TO 4897691162091',
    '1,299.00',
    '',
    '60,961.50',
  ],
  ['', '', '', 'Closing Balance', '', '', '', '60,961.50'],
];
const _sbiExpected = [
  (125000, true),
  (4500000, false),
  (200000, true),
  (8950, true),
  (60000, false),
  (129900, true),
];

/// One amount column with a Dr/Cr column beside it, dates with times, and
/// short header names ("Tran Dt", "Bal") that never say "date".
const _drCrStyle = [
  ['Kaveri Gramin Bank'],
  ['Statement of Account for 1234567890 from 01/10/2026 to 31/10/2026'],
  [''],
  ['Tran Dt', 'Narration', 'Chq / Ref No', 'Amount', 'Dr / Cr', 'Bal'],
  [
    '28-10-2026 10:21',
    'UPI-SWIGGY-swiggy@icici-530112345678',
    '530112345678',
    '1,250.00',
    'DR',
    '18,750.00',
  ],
  [
    '29-10-2026 08:05',
    'UPI-METRO RAIL-metrorail@ybl-530198765432',
    '530198765432',
    '89.50',
    'DR',
    '18,660.50',
  ],
  [
    '30-10-2026 18:40',
    'NEFT-ACME PAYROLL-SALARY OCT',
    'N30311',
    '45,000.00',
    'CR',
    '63,660.50',
  ],
  [
    '31-10-2026 12:00',
    'IMPS-RAHUL K-REFUND',
    '630412341234',
    '600.00',
    'CR',
    '64,260.50',
  ],
  [
    '31-10-2026 19:30',
    'POS-AMAZON PAY INDIA-XX9012',
    '',
    '1,299.00',
    'DR',
    '62,961.50',
  ],
];
const _drCrExpected = [
  (125000, true),
  (8950, true),
  (4500000, false),
  (60000, false),
  (129900, true),
];

/// Details above the table (one names a date), terse column names the
/// app's guess can't place (Out, In), and a totals footer.
const _terseStyle = [
  ['Customer ID', '12345', 'Branch', 'KOLLAM', 'IFSC', 'KAVR0001234'],
  ['Statement Date', ':', '31/10/2026', '', '', ''],
  ['Period', '01/10/2026', 'to', '31/10/2026', '', ''],
  ['', '', '', '', '', ''],
  ['Dt', 'Remarks', 'Ref', 'Out', 'In', 'Bal'],
  [
    '01/10/26',
    'UPI-SWIGGY-swiggy@icici',
    '530112345678',
    '250.00',
    '',
    '9,750.00',
  ],
  ['02/10/26', 'SALARY OCT ACME', 'N27512', '', '50,000.00', '59,750.00'],
  ['05/10/26', 'ATM WDL KOLLAM', '', '2,000.00', '', '57,750.00'],
  [
    '07/10/26',
    'UPI-RAHUL K-rahulk@oksbi',
    '530198765432',
    '',
    '600.00',
    '58,350.00',
  ],
  ['', 'Total', '', '2,250.00', '50,600.00', ''],
];
const _terseExpected = [
  (25000, true),
  (5000000, false),
  (200000, true),
  (60000, false),
];

const _teachTools = {
  'list_missed_sms',
  'label_sms',
  'list_statements_to_map',
  'map_statement',
};

void main() {
  final teachOnly = Platform.environment['LLM_TOOLS'] == 'teach';
  final skip = chat.llmSkip;

  late AppDatabase db;
  late AgentTools tools;
  var inbox = <(String, String)>[];

  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(
      db,
      missedSms: (window) async => [
        for (final (i, (sender, body)) in inbox.indexed)
          ReportableSms(
            '$i',
            BankSms(
              sender: sender,
              body: body,
              receivedAt: DateTime(2026, 10, 20 + i, 10),
            ),
            ReportableKind.missed,
            'unregisteredSender',
            null,
          ),
      ],
    );
  });
  tearDown(() => db.close());

  Future<int> converse(String task) async => (await chat.converse(
    tools,
    task,
    only: teachOnly ? _teachTools : null,
  )).calls.length;

  /// Approves every suggested SMS rule, then reads [bodies] as [sender].
  Future<List<PortableParseResult>> approveRulesAndRead(
    String sender,
    List<String> bodies,
  ) async {
    final rules = (await AgentSuggestionRepository(
      db,
    ).load()).where((s) => s.kind == AgentSuggestionKind.parserRule).toList();
    // ignore: avoid_print
    print('Rules suggested: ${rules.length}');
    expect(rules, isNotEmpty, reason: 'No SMS rule was suggested');
    for (final rule in rules) {
      await AgentSuggestionRepository(db).apply(rule.id);
    }
    final engine = await loadSmsEngine(db);
    return [
      for (final body in bodies)
        engine.parse(
          BankSms(sender: sender, body: body, receivedAt: DateTime(2026)),
        ),
    ];
  }

  /// Saves [rows]' layout the way the app does, lets the model map it,
  /// approves it and imports the whole file again with it.
  Future<List<UpiStatementRow>> mapAndImport(
    String fileName,
    List<List<String>> rows, {
    required int description,
  }) async {
    await StatementSampleRepository().add(fileName, rows, guessHeaderRow(rows));
    await converse(
      'I imported a bank statement SimpleMoney couldn’t read. Set up its '
      'columns.',
    );
    final suggestion = (await AgentSuggestionRepository(db).load())
        .where((s) => s.kind == AgentSuggestionKind.statementLayout)
        .firstOrNull;
    expect(suggestion, isNotNull, reason: 'No layout was suggested');
    await AgentSuggestionRepository(db).apply(suggestion!.id);
    final saved = await StatementImportRepository(db).columnMappings();
    final mapping = findSavedMapping(rows, saved);
    expect(mapping, isNotNull, reason: 'The saved layout isn’t found again');
    // ignore: avoid_print
    print('Mapped: ${mapping!.toJson()['columns']}');
    expect(mapping[TableField.description], description);
    return parseStatementTable(rows, mapping).statement.rows;
  }

  void expectRows(List<UpiStatementRow> rows, List<(int, bool)> expected) {
    expect([
      for (final r in rows)
        (r.amountMinor, r.direction != UpiStatementDirection.credit),
    ], expected);
  }

  test(
    'The model teaches the app a bank’s missed SMS',
    () async {
      inbox = [for (final body in _fincare) ('VM-FINCSF', body)];
      await converse(
        'SimpleMoney is missing some bank SMS. Teach it to read them.',
      );
      final results = await approveRulesAndRead('AD-FINCSF', _fincare);
      final read = results.where((r) => r.candidate != null).length;
      // ignore: avoid_print
      print('Approved rules read $read of ${_fincare.length} messages');
      expect(read, _fincare.length);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'The model teaches four kinds of SMS from one bank, and skips its OTP',
    () async {
      inbox = [for (final m in _nilgiri) ('JD-NILGRB', m.$1)];
      await converse(
        'SimpleMoney is missing some bank SMS. Teach it to read them.',
      );
      final results = await approveRulesAndRead('AX-NILGRB', [
        for (final m in _nilgiri) m.$1,
      ]);
      final read = [
        for (final (i, r) in results.indexed)
          if (r.candidate case final c?)
            (i, c.amountMinor, c.direction == SmsDirection.debit),
      ];
      // ignore: avoid_print
      print('Read: $read');
      expect(read, [
        for (final (i, m) in _nilgiri.indexed)
          if (m.$2 != null) (i, m.$2, m.$3),
      ]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'The model maps a statement layout the app doesn’t know',
    () async {
      final rows = [
        ['Fincare Small Finance Bank · Statement of account'],
        [
          'Value Dt',
          'Particulars',
          'Chq/Ref',
          'Dr Amount',
          'Cr Amount',
          'Running Bal',
        ],
        [
          '28/10/2026',
          'UPI/swiggy@icici/530112345678',
          '530112345678',
          '1,250.00',
          '',
          '18,750.00',
        ],
        [
          '29/10/2026',
          'UPI/metrorail@ybl/530198765432',
          '530198765432',
          '89.50',
          '',
          '18,660.50',
        ],
        [
          '30/10/2026',
          'NEFT CR SALARY OCT',
          'N30311',
          '',
          '45,000.00',
          '63,660.50',
        ],
      ];
      expectRows(await mapAndImport('fincare_oct.xlsx', rows, description: 1), [
        (125000, true),
        (8950, true),
        (4500000, false),
      ]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'The model maps a statement with title rows and two date columns',
    () async {
      expectRows(
        await mapAndImport('sbi_oct.xls', _sbiStyle, description: 3),
        _sbiExpected,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'The model maps a statement with one amount and a Dr/Cr column',
    () async {
      expectRows(
        await mapAndImport('kaveri_oct.csv', _drCrStyle, description: 1),
        _drCrExpected,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'The model maps terse column names under details rows',
    () async {
      expectRows(
        await mapAndImport('kavr_oct.xlsx', _terseStyle, description: 1),
        _terseExpected,
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
