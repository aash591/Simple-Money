import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/components/common.dart';
import 'package:simple_money/ui/components/detail_page.dart';
import 'package:simple_money/ui/components/secondary_header.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/components/transactions/transaction_list_row.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [320.0, 390.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('Financial rows at $width, $scale text, $brightness', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var opened = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SecondaryHeader(
                        title: 'Transactions',
                        leading: BackButton(),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: MoneyCard(
                          child: TransactionListRow(
                            transaction: MoneyTransaction(
                              id: 1,
                              type: TransactionType.transfer,
                              amountMinor: 123456789,
                              accountId: 1,
                              date: DateTime(2026, 10, 24),
                              title: 'Monthly savings and household expenses',
                            ),
                            account: null,
                            toAccount: null,
                            category: null,
                            parentCategory: null,
                            formattedAmount: 'INR 12,34,567.89',
                            onTap: () => opened = true,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.all(18),
                        child: DetailHero(
                          leading: Icon(Icons.account_balance),
                          title: 'Household savings',
                          amount: 'INR 12,34,567.89',
                          caption: 'Available balance',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(TransactionListRow));
          expect(opened, isTrue);
        });
      }
    }
  }
}
