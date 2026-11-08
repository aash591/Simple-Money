import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../tool/project_data.dart';

void main() {
  final pack = readRuntimePacks('../../distribution/packs');
  final categorizer = PortableCategorizer(pack);
  test(
    'generic NACH debit requires confirmation and is not an EMI assumption',
    () {
      final result = PortableSmsEngine(pack).parse(
        BankSms(
          sender: 'JD-CBSSBI-S',
          body: 'Dear Customer, Your A/C XXXXX123456 has a debit by NACH of Rs 5,848.00 on 05/10/26. Avl Bal Rs 1,55,331.66. Download YONO - SBI',
          receivedAt: DateTime(2026, 10, 5),
        ),
      );
      expect(result.candidate?.category?.id, 'nach_debit');
      expect(result.candidate?.category?.needsCategoryConfirmation, isTrue);
      expect(
        result.candidate?.accountingTreatment,
        SmsAccountingTreatment.expense,
      );
    },
  );
  test(
    'OneCard conversational receipt and purchase formats classify correctly',
    () {
      final engine = PortableSmsEngine(pack);
      final repayment = engine.parse(
        BankSms(
          sender: 'AD-OneCrd-S',
          body: 'Hola! that was sweet. We have received payment against your OneCard for Rs.14723.02 on 08 Jan 2026',
          receivedAt: DateTime(2026, 1, 8),
        ),
      );
      expect(
        repayment.candidate?.accountingTreatment,
        SmsAccountingTreatment.transfer,
      );
      final purchase = engine.parse(
        BankSms(
          sender: 'CP-OneCrd-S',
          body: "Fresh picks! You've spent Rs. 5,677.00 at SAMPLE STORE, Kollam with your SIB One Credit Card ending in XX1234. Reward points are now in your basket. To dispute this payment, click: m.1crd.in/OneCrd/shcut",
          receivedAt: DateTime(2026, 1, 25),
        ),
      );
      expect(purchase.candidate?.counterparty, 'SAMPLE STORE, Kollam');
      expect(
        purchase.candidate?.accountingTreatment,
        SmsAccountingTreatment.expense,
      );
    },
  );
  test('payment reminders do not become expenses or receive a category', () {
    final engine = PortableSmsEngine(pack);
    for (final body in [
      'Hi Person, Your bill has been generated. Pay your bill of Rs.500 here at the earliest and celebrate the OneCard rewards. Please ignore if already paid. - SIB OneCard',
      'Make the most of your payment options by converting your outstanding dues of Rs.500 to EMI. Call 1800 to know more. Please ignore if already paid. - SIB OneCard',
    ]) {
      final result = engine.parse(
        BankSms(
          sender: 'ONECRD',
          body: body,
          receivedAt: DateTime(2026, 10, 12),
        ),
      );
      expect(result.classification, RuleClassification.notice);
      expect(result.candidate, isNull);
    }
  });
  final cases = jsonDecode(
    File('../../tests/categorization/india.json').readAsStringSync(),
  ) as List;
  for (final fixture in cases) {
    test('shared category contract: ${fixture['id']}', () {
      final input = fixture['input'];
      final original = SmsTransactionCandidate.fromJson(
        Map<String, dynamic>.from(input['candidate'] as Map),
      );
      final result = categorizer.enrich(input['body'] as String, original);
      expect(result.counterparty, fixture['expected']['counterparty']);
      expect(result.category?.toJson(), fixture['expected']['category']);
      expect(result.amountMinor, original.amountMinor);
      expect(result.direction, original.direction);
      expect(result.accountLast4, original.accountLast4);
    });
  }
  test('category JSON round-trip and output aliases do not mutate rules', () {
    final fixture = cases.first;
    final input = fixture['input'];
    final candidate = SmsTransactionCandidate.fromJson(
      Map<String, dynamic>.from(input['candidate'] as Map),
    );
    final enriched = categorizer.enrich(input['body'], candidate);
    expect(
      () => enriched.category!.aliases.add('Changed'),
      throwsUnsupportedError,
    );
    final json =
        PortableParseResult(
              classification: RuleClassification.completed,
              decision: SmsDecision.review,
              reason: 'completedNeedsReview',
              packVersion: pack.packVersion,
              candidate: enriched,
            ).toJson()['candidate']
            as Map;
    expect(
      SmsTransactionCandidate.fromJson(Map<String, dynamic>.from(json))
          .category!
          .toJson(),
      enriched.category!.toJson(),
    );
  });
  test('conflicting category IDs in packs are rejected before activation', () {
    RuntimeRulePack bankPack(String bank) => const RuleCompiler().loadRuntime(
      jsonDecode(
        File('../../distribution/packs/india/$bank.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final first = bankPack('sbi');
    final changed = bankPack('federal').toJson();
    changed['categoryRules'][0]['name'] = 'Changed';
    final other = const RuleCompiler().loadRuntime(changed);
    expect(
      () => const RuleCompiler().mergeRuntimePacks([first, other]),
      throwsA(
        isA<RuleValidationException>().having(
          (e) => e.message,
          'reason',
          contains('Conflicting enrichment rule'),
        ),
      ),
    );
  });
  test(
    'counterparty rules enforce bounds and do not emit numeric terminal IDs',
    () {
      final candidate = SmsTransactionCandidate(
        amountMinor: 50000,
        direction: SmsDirection.debit,
        occurredAt: DateTime(2026, 10, 12),
        currencyCode: 'INR',
        countryCode: 'IN',
      );
      final result = categorizer.enrich(
        'Rs 500 done at 123456 on 12/10/26.',
        candidate,
      );
      expect(result.counterparty, isNull);
      expect(result.category?.id, 'personal');
      expect(
        categorizer
            .enrich(
              'Debited via UPI to ${List.filled(300, 'A').join()}.Ref:987',
              candidate,
            )
            .counterparty,
        isNull,
      );
    },
  );
  test('package parser labels SBI card repayment as a credit and exports the category', () {
    final result = PortableSmsEngine(pack).parse(
      BankSms(
        sender: 'SBICRD',
        body: 'Your payment of Rs.1,644.55 has been credited to your SBI Credit Card ending with 5667. Your available limit is Rs.48,355.45.',
        receivedAt: DateTime(2026, 10, 12),
      ),
    );
    expect(result.candidate?.direction, SmsDirection.credit);
    expect(result.candidate?.category?.id, 'credit_card_repayment');
    expect(result.candidate?.category?.type, 'income');
    expect(
      result.candidate?.accountingTreatment,
      SmsAccountingTreatment.transfer,
    );
    expect(result.candidate?.toJson()['accountingTreatment'], 'transfer');
    expect(
      SmsTransactionCandidate.fromJson(result.candidate!.toJson())
          .accountingTreatment,
      SmsAccountingTreatment.transfer,
    );
  });

  test('Axis repayment is a transfer, while card refunds remain credits', () {
    SmsTransactionCandidate classify(String body) => categorizer.enrich(
      body,
      SmsTransactionCandidate(
        amountMinor: 2149525,
        direction: SmsDirection.credit,
        occurredAt: DateTime(2026, 10, 4),
        currencyCode: 'INR',
        countryCode: 'IN',
        bankName: 'Axis Bank',
        channel: SmsPaymentChannel.card,
        accountLast4: '1437',
      ),
    );
    final repayment = classify(
      'Payment of INR 21495.25 has been received towards your Axis Bank Credit Card XX1437 on 04-10-26 - Axis Bank',
    );
    expect(repayment.accountingTreatment, SmsAccountingTreatment.transfer);
    expect(repayment.direction, SmsDirection.credit);
    final refund = classify(
      'Refund of INR 21495.25 has been credited to your Axis Bank Credit Card XX1437',
    );
    expect(refund.isCreditCardRepayment, isFalse);
    expect(refund.accountingTreatment, SmsAccountingTreatment.income);
  });

  test(
    'a payee or narration from anywhere is categorized by the same rules',
    () {
      String? name(String text, {bool credit = false, String? detail}) =>
          categorizer
              .categorize(
                text,
                direction: credit ? SmsDirection.credit : SmsDirection.debit,
                detail: detail,
              )
              ?.name;
      // Payees as statements and UPI apps print them, names cut short.
      expect(name('MINA MED'), 'Pharmacy');
      expect(name('NEW SIMLA MEDICALS'), 'Pharmacy');
      expect(name('MS SHIFA TEXTILES'), 'Clothing');
      expect(name('KALYAN SILKS TRICHUR PRIVATE LIMITED'), 'Clothing');
      expect(name('TEA SPOT'), 'Cafe');
      expect(name('STAR AUTO PARTS'), 'Vehicle Maintenance');
      expect(name('Expo Motorcycle spares'), 'Vehicle Maintenance');
      expect(name('BSNL Landline - Individual'), 'Mobile');
      expect(name('Vi'), 'Mobile');
      expect(name('Vi Prepaid'), 'Mobile');
      expect(name('MEESHO L'), 'Shopping');
      expect(name('Kerala State Road Transport Corporation'), 'Bus');
      expect(name('MARISTON CAKES AND BAKES'), 'Bakery');
      expect(name('LEKSHMI BAKERS'), 'Bakery');
      expect(name('Kerala Vision Broadband'), 'Internet');
      expect(name('SBI FASTAG NETC'), 'Tolls');
      expect(name('ARCHICA TOOLS AND FASTENERS'), 'Repairs');
      // The narration beside a cut-short payee names what it was.
      expect(
        name(
          'Google I',
          detail: 'UPI/DR/500114917725/Google I/ICIC/gpayrechar/UPI',
        ),
        'Mobile Recharge',
      );
      // Bank wording: cash moving between an account and the user's pocket.
      expect(
        name('ATM WDL ATM CASH 4410 KARIKODE ONSITE KOLLAM'),
        'ATM Withdrawal',
      );
      expect(
        name('CSH DEP (CDM) CDM4040106KOLLAM MAIN BRANCH', credit: true),
        'ATM Deposit',
      );
      expect(name('T CASH WDL Commission'), 'Bank Charges');
      expect(
        name('Int.Pd:9150444825:01-07-2026 to 30-09-2026', credit: true),
        'Interest',
      );
      // A person's name is no category, nor one that merely contains "VI".
      expect(name('NISMA VI'), isNull);
      expect(name('Shefeek M'), isNull);
      expect(name('MUHAMMED'), isNull);
    },
  );
}
