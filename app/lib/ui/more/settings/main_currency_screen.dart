import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/currency.dart';
import '../../../state/main_currency_controller.dart';
import '../../components/app_toast.dart';
import '../../components/common.dart';
import '../../components/currency_flag.dart';
import '../../components/currency_notice.dart';
import '../../components/feature_page.dart';
import '../accounts/currency_screen.dart';

class MainCurrencyScreen extends StatelessWidget {
  const MainCurrencyScreen({super.key, required this.controller});
  final MainCurrencyController controller;

  Future<void> _pick(BuildContext context) async {
    final picked = await Navigator.of(context).push<Currency>(
      FeatureRoute<Currency>(
        CurrencyScreen(
          selectedCode: controller.code,
          selectedTerritory: controller.territory,
        ),
      ),
    );
    if (picked == null) return;
    try {
      await controller.setCurrency(picked);
    } catch (_) {
      if (context.mounted) {
        showAppToast(context, 'Could not save the currency. Try again.');
      }
    }
  }

  Future<void> _refresh(BuildContext context) async {
    final updated = await controller.refresh(force: true);
    if (!context.mounted) return;
    showAppToast(
      context,
      updated
          ? 'Exchange rates updated.'
          : 'Could not reach the rate service. '
                '${controller.table == null ? 'No rates yet.' : 'Showing the rates you already have.'}',
      icon: updated ? Icons.check_rounded : Icons.cloud_off_rounded,
    );
  }

  @override
  Widget build(BuildContext context) => FeaturePage(
    title: 'Main currency',
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final date = controller.table?.date;
        final stale = CurrencyNotice.isStale(date);
        final combining = controller.multipleCurrencies;
        final theme = Theme.of(context);
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MoneyCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: controller.territory == null
                              ? const Icon(Icons.currency_exchange_rounded)
                              : CurrencyFlag(controller.territory!),
                          title: Text(
                            controller.code,
                            style: theme.textTheme.titleMedium,
                          ),
                          subtitle: _CurrencyName(
                            code: controller.code,
                            territory: controller.territory,
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _pick(context),
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
                      child: _Footnote('For combined balances and summaries.'),
                    ),
                    const SizedBox(height: appCardGap),
                    MoneyCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Exchange rates',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Icon(
                                combining && (stale || date == null)
                                    ? Icons.warning_amber_rounded
                                    : Icons.currency_exchange_rounded,
                                size: 18,
                                color: combining && (stale || date == null)
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  !combining
                                      ? 'Available with multiple account currencies'
                                      : date == null
                                      ? 'No rates downloaded'
                                      : '${DateFormat.yMMMd().format(date)}${stale ? ' · Update needed' : ''}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: controller.refreshing || !combining
                                ? null
                                : () => _refresh(context),
                            icon: controller.refreshing
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded),
                            label: Text(
                              controller.refreshing
                                  ? 'Refreshing…'
                                  : 'Refresh rates',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Text(
                        'Rates provided by Fawaz Ahmed Currency API',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// The picked currency's own name ("Indian Rupee"), looked up from the
/// bundled list so this row reads the same way the picker's rows do.
class _CurrencyName extends StatelessWidget {
  const _CurrencyName({required this.code, required this.territory});
  final String code;
  final String? territory;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Currency>>(
    future: Currency.load(),
    builder: (context, snapshot) {
      final match = snapshot.data?.where(
        (c) => territory == null ? c.code == code : c.territory == territory,
      );
      final currency = match == null || match.isEmpty ? null : match.first;
      return Text(
        currency == null
            ? 'Combined balances and summaries'
            : '${currency.name} · ${currency.country}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    },
  );
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}
