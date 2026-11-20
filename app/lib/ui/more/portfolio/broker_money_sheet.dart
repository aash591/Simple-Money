import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../state/account_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transaction_widgets.dart';
import '../../transactions/transfer_sheet.dart';

/// The add button on a broker's Transfers tab: choose deposit or withdraw,
/// styled like Add a transaction, then the flow itself on the next page of the
/// same sheet. Backing out of the flow's first step slides back to the choice.
Future<void> showBrokerMoneySheet(
  BuildContext context, {
  required AccountStore accounts,
  required TransactionStore transactions,
  required Account broker,
}) => showAdaptiveSheet<void>(
  context,
  builder: (_) => _BrokerMoneySheet(
    accounts: accounts,
    transactions: transactions,
    broker: broker,
  ),
);

enum _Page { choose, deposit, withdraw }

class _BrokerMoneySheet extends StatefulWidget {
  const _BrokerMoneySheet({
    required this.accounts,
    required this.transactions,
    required this.broker,
  });
  final AccountStore accounts;
  final TransactionStore transactions;
  final Account broker;

  @override
  State<_BrokerMoneySheet> createState() => _BrokerMoneySheetState();
}

class _BrokerMoneySheetState extends State<_BrokerMoneySheet> {
  _Page _page = _Page.choose;
  bool _forward = true;

  void _go(_Page page) => setState(() {
    _forward = page.index > _page.index;
    _page = page;
  });

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return StepSlider(
      stepKey: _page,
      forward: _forward,
      child: switch (_page) {
        _Page.choose => SheetPage(
          header: const SheetHeader('Add', centered: true),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TypeChoiceCard(
                icon: Icons.south_west_rounded,
                color: colors.income,
                title: 'Deposit',
                subtitle: 'Money you put into ${widget.broker.name}',
                onTap: () => _go(_Page.deposit),
              ),
              const SizedBox(height: 12),
              TypeChoiceCard(
                icon: Icons.north_east_rounded,
                color: colors.expense,
                title: 'Withdraw',
                subtitle: 'Money you took out of ${widget.broker.name}',
                onTap: () => _go(_Page.withdraw),
              ),
            ],
          ),
          actions: ActionButtonBar(
            secondaryLabel: 'Cancel',
            onSecondary: _close,
          ),
        ),
        _Page.deposit => TransferSheet(
          accountStore: widget.accounts,
          transactionStore: widget.transactions,
          depositToAccountId: widget.broker.id,
          onLeave: () => _go(_Page.choose),
          onClose: _close,
        ),
        _Page.withdraw => TransferSheet(
          accountStore: widget.accounts,
          transactionStore: widget.transactions,
          initialFromAccountId: widget.broker.id,
          withdrawal: true,
          onLeave: () => _go(_Page.choose),
          onClose: _close,
        ),
      },
    );
  }
}
