import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../domain/account.dart';
import '../../../state/account_store.dart';
import '../../../state/main_currency_controller.dart';
import '../../../state/transaction_store.dart';
import '../../components/account_total.dart';
import '../../components/app_toast.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/more_popup_button.dart';
import '../../components/reorder_lift.dart';
import '../../components/skeleton.dart';
import 'edit_account_screen.dart';
import 'account_card.dart';

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({
    super.key,
    required this.store,
    required this.transactionStore,
    this.archived = false,
  });
  final AccountStore store;
  final TransactionStore transactionStore;
  final bool archived;
  void _open(BuildContext context, [Account? account]) =>
      Navigator.of(context).push(
        FeatureRoute<void>(
          EditAccountScreen(
            store: store,
            account: account,
            transactionStore: transactionStore,
          ),
        ),
      );
  @override
  Widget build(BuildContext context) => FeaturePage(
    title: archived ? 'Archived accounts' : 'Accounts',
    actions: archived
        ? null
        : [
            MorePopupButton<String>(
              tooltip: 'Manage accounts options',
              items: const [
                MorePopupItem(
                  value: 'archived',
                  label: 'View archived accounts',
                  icon: Icons.archive_outlined,
                ),
              ],
              onSelected: (_) => Navigator.of(context).push(
                FeatureRoute<void>(
                  AccountsScreen(
                    store: store,
                    transactionStore: transactionStore,
                    archived: true,
                  ),
                ),
              ),
            ),
          ],
    child: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (store.loading) {
          return const SkeletonList();
        }
        if (store.loadError != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(store.loadError!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: store.load,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          );
        }
        final all = archived ? store.archivedAccounts : store.accounts;
        // A place that keeps no cash (gold at home, a locker) has no balance to
        // show here; it lives in Portfolio.
        final accounts = [
          for (final a in all)
            if (a.place?.holdsCash ?? true) a,
        ];
        if (archived && accounts.isEmpty) {
          return const EmptyState(
            icon: Icons.archive_outlined,
            title: 'No archived accounts',
            message: 'Accounts you archive will appear here.',
          );
        }
        if (accounts.isEmpty) {
          return EmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: 'A place for your money',
            message: 'Start with cash, a bank account, or a wallet.',
            actionLabel: 'Add your first account',
            onAction: () => _open(context),
          );
        }
        // Resolved once per list build: reading it per row re-scans every
        // account, which the drag-reorder frames would repeat for each one.
        final scope = MainCurrencyScope.maybeOf(context)?.accountScope;
        return ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
          buildDefaultDragHandles: false,
          header: archived
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    children: [
                      AccountTotal(store: store, prominent: true),
                      const SizedBox(height: 20),
                      // Both labels stay flexible: at large text scales an
                      // unconstrained hint on the right squeezes the count into a
                      // one-character-per-line column and overflows the row.
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Press and hold to reorder',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${accounts.length} ${accounts.length == 1 ? 'account' : 'accounts'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
          footer: archived
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _AddAccountCard(
                    onTap: store.saving ? null : () => _open(context),
                  ),
                ),
          onReorderStart: (_) => HapticFeedback.mediumImpact(),
          proxyDecorator: reorderLift,
          itemCount: accounts.length,
          onReorderItem: (oldIndex, newIndex) async {
            if (archived) return;
            try {
              // The list leaves some accounts out; the store counts them all.
              await store.reorder(
                store.accounts.indexOf(accounts[oldIndex]),
                store.accounts.indexOf(accounts[newIndex]),
              );
            } catch (_) {
              if (context.mounted) {
                showAppToast(
                  context,
                  'Could not save the order. Please try again.',
                );
              }
            }
          },
          itemBuilder: (context, index) {
            final account = accounts[index];
            // Press and hold a card to lift it, then drag it into place.
            return ReorderableDelayedDragStartListener(
              key: ValueKey(account.id),
              index: index,
              enabled: !archived && !store.saving,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Semantics(
                  customSemanticsActions: archived
                      ? null
                      : {
                          if (index > 0)
                            const CustomSemanticsAction(label: 'Move up'): () =>
                                store.reorder(
                                  store.accounts.indexOf(accounts[index]),
                                  store.accounts.indexOf(accounts[index - 1]),
                                ),
                          if (index < accounts.length - 1)
                            const CustomSemanticsAction(
                              label: 'Move down',
                            ): () => store.reorder(
                              store.accounts.indexOf(accounts[index]),
                              store.accounts.indexOf(accounts[index + 1]),
                            ),
                        },
                  child: AccountCard(
                    account: account,
                    scope: scope,
                    onTap: store.saving ? null : () => _open(context, account),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class _AddAccountCard extends StatelessWidget {
  const _AddAccountCard({required this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedBorder(
      Theme.of(context).colorScheme.primary.withValues(alpha: .3),
    ),
    child: Material(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .025),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 26),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Add account',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          const Radius.circular(24),
        ),
      );
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 11) {
        canvas.drawPath(metric.extractPath(offset, offset + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder oldDelegate) => oldDelegate.color != color;
}
