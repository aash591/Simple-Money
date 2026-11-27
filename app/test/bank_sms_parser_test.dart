import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  late BankSmsParser parser;
  BankSms message(String body, {String sender = 'SBICRD'}) =>
      BankSms(sender: sender, body: body, receivedAt: DateTime(2026, 10, 11));
  setUpAll(() {
    const compiler = RuleCompiler();
    parser = BankSmsParser(
      compiler.mergeRuntimePacks([
        for (final bank in [
          'sbi',
          'hdfc',
          'icici',
          'axis',
          'onecard',
          'federal',
          'boi',
          'canara',
        ])
          compiler.loadRuntime(
            jsonDecode(
              File(
                'packages/universal_bank_sms_parser/distribution/packs/india/$bank.json',
              ).readAsStringSync(),
            ) as Map<String, dynamic>,
          ),
      ]),
    );
  });

  test('manually inspected deposit templates have explicit portable rules', () {
    for (final entry in [
      (
        'sbi',
        'AX-CBSSBI-S',
        'Your A/C XXXXX1234 Credited INR 1,250.50 on 11/10/26 -Deposit of Cash at S1NL000001 CDM. Avl Bal INR 9,876.54-SBI',
        'in.sbi.cdm.cash_deposit',
        SmsDirection.credit,
        SmsPaymentChannel.atm,
        125050,
      ),
      (
        'sbi',
        'AD-CBSSBI-S',
        'Your A/C XXXXX1234 Credited INR 500.00 on 11/10/26 -Deposit of Cash at S1NN000002 CDM. Avl Bal INR 9,876.54-SBI',
        'in.sbi.cdm.cash_deposit',
        SmsDirection.credit,
        SmsPaymentChannel.atm,
        50000,
      ),
      (
        'sbi',
        'AD-CBSSBI-S',
        'Your AC XXXXX1234 Debited INR 25.00 on 11/10/26 -CDM CHARGE DR. Avl Bal INR 9,876.54.-SBI',
        'in.sbi.cdm.charge',
        SmsDirection.debit,
        SmsPaymentChannel.atm,
        2500,
      ),
      (
        'federal',
        'AX-FEDBNK-S',
        'Hi,Rs.1250.50credited in your A/c XX1234 on 11OCT2026 10:30:00 using cash deposit machine at FBL-TEST BRANCH. Current Bal: Rs.9876.54 - Federal Bank',
        'in.federal.template021',
        SmsDirection.credit,
        SmsPaymentChannel.atm,
        125050,
      ),
      (
        'canara',
        'AD-CANBNK-S',
        'INR 1,250.50 has been CREDITED to your A/c XXX1234 on 11/10/26 by CASH.Total bal is INR 9,876.54.  Please Install Canara ai1 app for Mobile Banking services - Canara Bank',
        'in.canara.device013.cash_credit',
        SmsDirection.credit,
        SmsPaymentChannel.bankTransfer,
        125050,
      ),
    ]) {
      final pack = const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/${entry.$1}.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      );
      final sms = message(entry.$3, sender: entry.$2);
      for (final engine in [PortableSmsEngine(pack), parser]) {
        final result = engine.parse(sms);
        expect(result.ruleId, entry.$4);
        expect(result.candidate?.amountMinor, entry.$7);
        expect(result.candidate?.accountLast4, '1234');
        expect(result.candidate?.direction, entry.$5);
        expect(result.candidate?.channel, entry.$6);
      }
      expect(parser.balanceSnapshot(sms)?['balanceMinor'], 987654);
    }
  });

  test('deposit-like failures, OTPs and offers do not produce deposits', () {
    for (final entry in [
      (
        'CBSSBI',
        'OTP 123456. Your A/C XXXXX1234 Credited INR 500.00 on 11/10/26 -Deposit of Cash at S1NL000001 CDM. Avl Bal INR 9,876.54-SBI',
      ),
      ('CBSSBI', 'Cash deposit failed for A/C XXXXX1234 at CDM. INR 500.00.'),
      (
        'FEDBNK',
        'Offer: Deposit cash using cash deposit machine and earn Rs.500 cashback.',
      ),
      (
        'CBSSBI',
        'Your A/C XXXXX1234 cash deposit of INR 500.00 is pending at CDM.',
      ),
    ]) {
      expect(
        parser.parse(message(entry.$2, sender: entry.$1)).candidate,
        isNull,
        reason: entry.$2,
      );
    }
  });

  test('SBIUPI sender is recognized as State Bank of India', () {
    final result = parser.parse(
      message(
        'Rs 500.00 debited via UPI from A/c X1234. Avl Bal Rs 1,000.00.',
        sender: 'AX-SBIUPI-S',
      ),
    );
    expect(result.candidate, isNotNull);
    expect(result.candidate!.bankName, 'State Bank of India');
    expect(result.candidate!.amountMinor, 50000);
    expect(result.candidate!.accountLast4, '1234');
    expect(result.candidate!.channel, SmsPaymentChannel.upi);
    expect(result.candidate!.direction, SmsDirection.debit);
  });

  test('SBI incoming transfer captures the sender and category', () {
    final result = parser.parse(
      message(
        'Dear SBI User, your A/c X1234-credited by Rs.550 on 10Oct26 transfer from SAMPLE SENDER Ref No 123456789012 -SBI',
        sender: 'AX-SBIUPI-S',
      ),
    );
    expect(result.ruleId, 'in.sbi.device017.transfer_credit');
    expect(result.candidate?.counterparty, 'SAMPLE SENDER');
    expect(result.candidate?.reference, '123456789012');
    expect(result.candidate?.category?.name, 'Other Income');
    expect(result.candidate?.category?.isFallback, isFalse);
  });

  test('SBI UPI transfer debit captures the recipient and reference', () {
    final result = parser.parse(
      message(
        'Dear UPI user A/C X1234 debited by 350.90 on date 13Oct26 trf to SAMPLE SERVICES Refno 123456789012 If not u? call-1800111109 for other services-18001234-SBI',
        sender: 'AX-SBIUPI-S',
      ),
    );
    expect(result.ruleId, 'in.sbi.device018.upi_transfer_debit');
    expect(result.candidate?.amountMinor, 35090);
    expect(result.candidate?.accountLast4, '1234');
    expect(result.candidate?.direction, SmsDirection.debit);
    expect(result.candidate?.channel, SmsPaymentChannel.upi);
    expect(result.candidate?.counterparty, 'SAMPLE SERVICES');
    expect(result.candidate?.reference, '123456789012');
  });

  test('Canara cash deposits preserve a three-digit suffix without inventing digits', () {
    final pack = const RuleCompiler().loadRuntime(
      jsonDecode(
        File(
          'packages/universal_bank_sms_parser/distribution/packs/india/canara.json',
        ).readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final sms = message(
      'INR 1,250.50 has been CREDITED to your A/c XXX123 on 11/10/2026 by CASH.Total bal is INR 9,876.54.  Please Install Canara ai1 app for Mobile Banking services - Canara Bank',
      sender: 'CANBNK',
    );
    for (final engine in [PortableSmsEngine(pack), parser]) {
      final result = engine.parse(sms);
      expect(result.ruleId, 'in.canara.device013.cash_credit');
      expect(result.candidate?.amountMinor, 125050);
      expect(result.candidate?.accountLast4, '123');
      expect(result.candidate?.direction, SmsDirection.credit);
      expect(result.candidate?.channel, SmsPaymentChannel.bankTransfer);
    }
    expect(smsMetadata(sms.body)['balanceMinor'], 987654);
  });

  test(
    'realme formats identify cards, repayments, and bank account variants',
    () {
      for (final entry in [
        (
          'ONECRD',
          "Happy learning! You've made a payment for Rs. 1,250.50 at SCHOOL, CITY on card ending XX1234. Here are your reward points: 1crd.in/OneCrd/txns -Team OneCard",
          true,
          SmsDirection.debit,
        ),
        (
          'ONECRD',
          'Your payment of Rs. 1,250.50 has been processed for OneCard ending XX1234.',
          true,
          SmsDirection.credit,
        ),
        (
          'AXISBK',
          'Spent INR 1250.50\nAxis Bank Card no. XX1234\n07-10-26 20:30:06 IST\nSHOP\nAvl Limit: INR 101236.56\nNot you? SMS BLOCK 1234 to 919951860002',
          true,
          SmsDirection.debit,
        ),
        (
          'AXISBK',
          'Congratulations! Cashback of INR 1250.50 has been credited to your AXIS BANK SUPERMONEY RuPay Credit Card XX1234 towards your last month spends - Axis Bank',
          true,
          SmsDirection.credit,
        ),
        (
          'FEDBNK',
          'Rs 1250.50 credited to your A/c XX1234 via IMPS on 15AUG2026 10:30:00 IMPS Ref no 987654 BAL-Rs 5000.00 -Federal Bank',
          false,
          SmsDirection.credit,
        ),
        (
          'ICICIB',
          'ICICI Bank Account XX1234 is credited with Rs 1250.50 on 07-Oct-26 by Account linked to mobile number XXXXX9999. IMPS Ref. no. 987654.',
          false,
          SmsDirection.credit,
        ),
        (
          'BOIIND',
          'BOI - Rs 1250.50 Debited(TRF) DORMANT ACCOUNT TRANSFER DEBIT in your Ac XX1234 on 07-10-2026. .Avl BalRs 5000.',
          false,
          SmsDirection.debit,
        ),
      ]) {
        final result = parser.parse(message(entry.$2, sender: entry.$1));
        expect(
          result.candidate,
          isNotNull,
          reason: '${entry.$1}: ${result.reason}',
        );
        expect(result.candidate!.amountMinor, 125050);
        expect(result.candidate!.accountLast4, '1234', reason: entry.$1);
        final metadata = smsMetadata(entry.$2, sender: entry.$1);
        expect(metadata['isCreditCard'], entry.$3);
        expect(
          metadata['direction'] ?? result.candidate!.direction.name,
          entry.$4.name,
        );
      }
    },
  );

  test('compact balances and available limits remain distinct', () {
    for (final balance in [
      'BAL-Rs.5,000.25',
      'BAL:Rs5000.25',
      'Avl BalRs 5000.25',
    ]) {
      final snapshot = parser.balanceSnapshot(
        message('Your Ac XX1234 $balance', sender: 'FEDBNK'),
      );
      expect(snapshot?['balanceMinor'], 500025, reason: balance);
      expect(snapshot?['availableCreditLimitMinor'], isNull);
    }
    for (final limit in [
      'Avl Limit: INR 10,123.56',
      'Your available limit is Rs.10123.56',
      'Available credit limit: Rs.10123.56',
    ]) {
      final snapshot = parser.balanceSnapshot(
        message('SBI Credit Card XX1234. $limit'),
      );
      expect(snapshot?['availableCreditLimitMinor'], 1012356, reason: limit);
      expect(snapshot?['balanceMinor'], isNull);
      expect(
        parser.parse(message('SBI Credit Card XX1234. $limit')).candidate,
        isNull,
      );
    }
    expect(
      smsMetadata(
        'Credit limit increased from Rs.5000 to Rs.10000 for SBI Card XX1234',
      )['availableCreditLimitMinor'],
      isNull,
    );
    expect(
      parser.balanceSnapshot(
        message('Offer: SBI Card XX1234 available limit Rs.10000'),
      ),
      isNull,
    );
    expect(
      smsMetadata(
        'Your Debit Card XX1234 spent Rs.500. Avl Bal Rs.1000',
      )['isCreditCard'],
      isFalse,
    );
    expect(
      smsMetadata(
        'Rs.3,000.00 withdrawn on UCO Bank Card XX1234 on 30-11-2025 at ATM. Avl Bal Rs.5000.00',
      )['isCreditCard'],
      isFalse,
    );
  });

  test('restored-device SuperCard spending, repayments, and limits', () {
    for (final sender in ['AD-SPRCRD-S', 'AD-RBLCRD-S']) {
      final sms = message(
        "You've spent INR 1250.50 at SHOP on Bajaj Finserv RBL Bank SuperCard (1234) on 07-10-2026. Avl limit-INR10123.56. Not You? onelink.to/example",
        sender: sender,
      );
      final result = parser.parse(sms);
      expect(result.candidate?.amountMinor, 125050);
      expect(result.candidate?.accountLast4, '1234');
      expect(result.candidate?.direction, SmsDirection.debit);
      expect(smsMetadata(sms.body, sender: sender)['isCreditCard'], isTrue);
      expect(
        parser.balanceSnapshot(sms)?['availableCreditLimitMinor'],
        1012356,
      );
    }
    for (final entry in [
      (
        'RBLCRD',
        'Hi, we have received a payment of INR 1250.50 towards your Bajaj Finserv RBL Bank SuperCard (XXXX1234) on Mar 7, 2026.',
      ),
      (
        'RBLBNK',
        'Payment of Rs.1250.50 received on RBL Bank Credit Card XX1234 on 07-10-2026, subject to realisation. Avl Limit Rs.10123.56. View on MyCard app',
      ),
    ]) {
      final result = parser.parse(message(entry.$2, sender: entry.$1));
      expect(result.candidate?.amountMinor, 125050);
      expect(result.candidate?.accountLast4, '1234');
      expect(result.candidate?.direction, SmsDirection.credit);
      expect(result.candidate?.bankName, 'RBL Bank');
    }
    for (final body in [
      'Alert! Total Amount Due on RBL Bank Credit Card(xx1234) is Rs.5000 & Min Amount Due is Rs.500. Pay by 07/10/2026.',
      'OTP 987654 for INR 500 spent on Bajaj Finserv RBL Bank SuperCard (1234).',
      'INR 500 transaction declined on Bajaj Finserv RBL Bank SuperCard (1234).',
      'Hi! Increase Credit Limit from Rs.5000 to Rs.10000 on your Bajaj Finserv RBL Bank SuperCard (xx1234) at no extra cost.',
    ]) {
      expect(parser.parse(message(body, sender: 'SPRCRD')).candidate, isNull);
    }
    expect(
      parser
          .parse(
            message('Spent INR 500 on SuperCard (1234).', sender: 'UNKNOWN'),
          )
          .candidate,
      isNull,
    );
  });

  test('vivo HDFC and Federal credit card formats retain suffix and limit', () {
    for (final entry in [
      (
        'HDFCBK',
        'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 1250.50 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 1234 ON 07-10-2026.YOUR AVAILABLE LIMIT IS RS. 10123.56',
        SmsDirection.credit,
      ),
      (
        'FEDBNK',
        'Payment of Rs 1250.50 is received towards your credit card number ending with 1234 on 07/10/2026 -Federal Bank',
        SmsDirection.credit,
      ),
      (
        'FEDBNK',
        'INR 1250.50 spent on your credit card ending with 1234 at SHOP on 07-10-2026. Available limit Rs.10123.56. Not you, call 1800 -Federal Bank',
        SmsDirection.debit,
      ),
    ]) {
      final sms = message(entry.$2, sender: entry.$1);
      final result = parser.parse(sms);
      expect(result.candidate?.amountMinor, 125050);
      expect(result.candidate?.accountLast4, '1234');
      expect(result.candidate?.direction, entry.$3);
      expect(smsMetadata(sms.body, sender: sms.sender)['isCreditCard'], isTrue);
      if (sms.body.contains('LIMIT') || sms.body.contains('limit')) {
        expect(
          parser.balanceSnapshot(sms)?['availableCreditLimitMinor'],
          1012356,
        );
      }
    }
  });

  test(
    'merchant payments and debit-funded card repayments keep their direction',
    () {
      final merchant = message(
        'Your payment of Rs. 1250.50 at SCHOOL, CITY has been processed. Check reward points earned on this purchase at onecardapp.page.link/rp -Team OneCard',
        sender: 'ONECRD',
      );
      expect(parser.parse(merchant).candidate?.direction, SmsDirection.debit);
      expect(
        smsMetadata(merchant.body, sender: merchant.sender)['direction'],
        'debit',
      );
      final repayment = message(
        'We have received payment of Rs.1250.50 via RuPay Debit Card & the same has been credited to your SBI Credit Card. Your available limit is Rs.10123.56.',
      );
      expect(
        smsMetadata(repayment.body, sender: repayment.sender)['isCreditCard'],
        isTrue,
      );
      expect(parser.parse(repayment).candidate?.direction, SmsDirection.credit);
      expect(smsMetadata(repayment.body)['availableCreditLimitMinor'], 1012356);
      final fi = message(
        "You've spent INR 1250.50 at OneCard on October 7, 2026. Balance: INR 5000. If it wasn't done by you, ping us on the Fi app. -Federal",
        sender: 'FEDFIB',
      );
      expect(smsMetadata(fi.body, sender: fi.sender)['isCreditCard'], isFalse);
      expect(smsMetadata(fi.body, sender: fi.sender)['balanceMinor'], 500000);
      expect(parser.parse(fi).candidate?.direction, SmsDirection.debit);
    },
  );

  test('recognizes new credit card spending formats and ignores limits', () {
    for (final entry in [
      (
        'SBICRD',
        'SBI Credit Card XX1234 used for INR 1,234.50 at SHOP on 11/10/26. Available limit INR 80,000.00.',
      ),
      (
        'HDFCBK',
        'INR 999.00 charged to your HDFC Bank Credit Card ending 1234 at SHOP on 11/10/26.',
      ),
      (
        'ICICIB',
        'Your ICICI Bank credit card XX1234 used for Rs.456.78 at SHOP on 11/10/26.',
      ),
    ]) {
      final result = parser.parse(message(entry.$2, sender: entry.$1));
      expect(
        result.candidate,
        isNotNull,
        reason: '${entry.$1}: ${result.reason}',
      );
      expect(result.candidate!.accountLast4, '1234', reason: entry.$1);
      expect(result.candidate!.direction, SmsDirection.debit);
    }
    expect(
      parser
          .parse(
            message(
              'SBI Credit Card XX1234 used for INR 1,234.50 at SHOP on 11/10/26. Available limit INR 80,000.00.',
            ),
          )
          .candidate!
          .amountMinor,
      123450,
    );
  });

  test('card repayments and refunds are credits in host metadata', () {
    expect(
      smsMetadata(
        'Your payment of Rs.1,644.55 has been credited to your SBI Credit Card ending with 5667. Your available limit is Rs.48,355.45.',
      )['direction'],
      'credit',
    );
    final result = parser.parse(
      message(
        'Refund of INR 123.45 credited to SBI Credit Card XX1234 on 11/10/26.',
      ),
    );
    expect(result.candidate?.amountMinor, 12345);
    expect(
      smsMetadata(
        'Refund of INR 123.45 credited to SBI Credit Card XX1234 on 11/10/26.',
      )['direction'],
      'credit',
    );
  });

  test('does not infer completed spending from unsafe or unknown messages', () {
    for (final body in [
      'OTP 987654 for INR 123.45 spent on SBI Credit Card XX1234.',
      'INR 123.45 transaction declined on SBI Credit Card XX1234.',
      'Payment of INR 123.45 initiated to SBI Credit Card XX1234.',
      'INR 123.45 due on SBI Credit Card XX1234.',
      'Reward points credited to SBI Credit Card XX1234. Available limit INR 123.45.',
    ]) {
      expect(parser.parse(message(body)).candidate, isNull, reason: body);
    }
    expect(
      parser
          .parse(
            message(
              'INR 123.45 spent on credit card XX1234.',
              sender: 'UNKNOWN',
            ),
          )
          .candidate,
      isNull,
    );
  });

  test('balance-only messages identify account and do not use card limits', () {
    final result = parser.balanceSnapshot(
      message(
        'Your A/c XX1234 current balance: INR 3,328.37.',
        sender: 'ATMSBI',
      ),
    );
    expect(result?['balanceMinor'], 332837);
    expect(result?['accountLast4'], '1234');
    expect(
      smsMetadata(
        'Rs.500 debited from A/c X1234. Avl Bal Rs.0.00',
      )['balanceMinor'],
      0,
    );
    expect(
      smsMetadata(
        'SBI Credit Card XX1234 available limit Rs.48,355.45',
      )['balanceMinor'],
      isNull,
    );
  });
}
