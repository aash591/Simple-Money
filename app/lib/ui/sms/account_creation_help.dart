import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../components/common.dart';
import '../components/info_guide.dart';
import '../more/accounts/account_card.dart';

/// The SMS auto-import guide, behind the info button on Review accounts and
/// SMS review: how messages become transactions, and what needs the user.
const smsImportGuide = InfoGuide(
  title: 'About SMS auto-import',
  art: IconTile(Icons.sms_outlined, size: 56),
  headline: 'Transactions from your bank SMS',
  summary: 'Picked out of your SMS, so you don’t type them. You check the unsure ones.',
  steps: [
    GuideStep(
      'Turn it on',
      'Finds your banks and past transactions. New ones come in by themselves.',
      path: ['More', 'Settings', 'Transactions from SMS'],
    ),
    GuideStep(
      'Pick your accounts',
      'Tap a card to select it, then create. Try it:',
      path: ['Home', 'SMS auto-import', 'Review'],
      example: _ExampleAccount(),
    ),
    GuideStep(
      'Already have the account?',
      'Link it instead, so you don’t get a duplicate.',
      path: ['Account card', '⋮', 'Link existing account'],
    ),
    GuideStep(
      'Check and save',
      'Fix the account or category if needed.',
      path: ['SMS review', 'Save all transactions'],
    ),
  ],
  sections: [
    GuideSection('Good to know', [
      GuideTip(
        Icons.mark_chat_read_outlined,
        'Empty SMS review means all done',
        'Your saved transactions are in the Transactions tab.',
      ),
      GuideTip(
        Icons.error_outline_rounded,
        'Some transactions need attention',
        'They’re missing an account or category. Fix them now or later.',
        ['SMS review', '⋮', 'Needs attention'],
      ),
      GuideTip(
        Icons.wallet_outlined,
        'A Cash account is made when needed',
        'Found ATM withdrawals or deposits but no cash account? A Cash account '
            'is created for your cash in hand, so they save as transfers.',
      ),
      GuideTip(
        Icons.auto_awesome_outlined,
        'Let AI fill in accounts and categories',
        'Claude or ChatGPT can pick them for SMS waiting in review. You approve '
            'each change.',
        ['More', 'AI assistant'],
      ),
      GuideTip(
        Icons.sms_failed_outlined,
        'A bank SMS was missed or read wrong?',
        'Send it to us so we can fix it.',
        ['More', 'Help', 'Report SMS'],
      ),
    ]),
  ],
);

/// A sample card to tap; it changes nothing.
class _ExampleAccount extends StatefulWidget {
  const _ExampleAccount();
  @override
  State<_ExampleAccount> createState() => _ExampleAccountState();
}

class _ExampleAccountState extends State<_ExampleAccount> {
  bool _selected = false;

  @override
  Widget build(BuildContext context) => AccountCard(
    account: const Account(
      id: -1,
      name: 'Example bank',
      currency: 'INR',
      digits: 2,
      balanceMinor: 250000,
      lastDigits: '1234',
      icon: 'bank',
    ),
    selected: _selected,
    onTap: () => setState(() => _selected = !_selected),
    showTransactionCount: false,
    subtitle: _selected ? 'Selected' : 'Tap to select',
  );
}
