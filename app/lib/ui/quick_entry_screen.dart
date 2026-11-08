import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/transaction.dart';
import '../state/account_store.dart';
import '../state/category_store.dart';
import '../state/transaction_store.dart';
import '../state/security_controller.dart';
import 'components/adaptive_sheet.dart';
import 'components/native_modal_blur.dart';
import 'transactions/transaction_sheet.dart';
import 'upi/upi_payment_flow.dart';

/// Transparent host for a launcher widget. The dashboard is never built.
class QuickEntryScreen extends StatefulWidget {
  const QuickEntryScreen({
    super.key,
    required this.action,
    required this.accounts,
    required this.categories,
    required this.transactions,
  });
  final String action;
  final AccountStore accounts;
  final CategoryStore categories;
  final TransactionStore transactions;

  @override
  State<QuickEntryScreen> createState() => _QuickEntryScreenState();
}

class _QuickEntryScreenState extends State<QuickEntryScreen> {
  @override
  void initState() {
    super.initState();
    NativeModalBlur.enabled = true;
  }

  @override
  void dispose() {
    NativeModalBlur.enabled = false;
    super.dispose();
  }

  bool _opened = false;

  Future<void> _open() async {
    if (!mounted) return;
    final security = SecurityScope.of(context);
    if (security.covered || !security.ready) {
      _opened = false;
      return;
    }
    if (widget.action == 'upi') {
      await showAdaptiveSheet<void>(
        context,
        dismissible: false,
        builder: (sheetContext) => UpiPaymentFlow(
          accountStore: widget.accounts,
          categoryStore: widget.categories,
          transactionStore: widget.transactions,
          onBack: () => Navigator.pop(sheetContext),
          onClose: () => Navigator.pop(sheetContext),
        ),
      );
    } else {
      await showAddTransactionSheet(
        context,
        accountStore: widget.accounts,
        categoryStore: widget.categories,
        transactionStore: widget.transactions,
        initialType: widget.action == 'income'
            ? TransactionType.income
            : TransactionType.expense,
      );
    }
    if (mounted) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final security = SecurityScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.accounts,
        widget.categories,
        widget.transactions,
      ]),
      builder: (context, _) {
        final error =
            widget.accounts.loadError ??
            widget.categories.loadError ??
            widget.transactions.loadError;
        final ready =
            !widget.accounts.loading &&
            !widget.categories.loading &&
            !widget.transactions.loading;
        if (!_opened &&
            ready &&
            error == null &&
            security.ready &&
            !security.covered) {
          _opened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _open());
        }
        if (error != null) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error),
                      TextButton(
                        onPressed: () {
                          widget.accounts.load();
                          widget.categories.load();
                          widget.transactions.load();
                        },
                        child: const Text('Try again'),
                      ),
                      TextButton(
                        onPressed: SystemNavigator.pop,
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return const SizedBox.expand();
      },
    );
  }
}
