import '../../data/community/community_fixes.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/backup/sync_repository.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/debt_store.dart';
import '../../state/loan_store.dart';
import 'loans/loans_screen.dart';
import '../../state/sms_import_store.dart';
import '../../state/subscription_store.dart';
import 'subscriptions/subscriptions_screen.dart';
import '../../state/transaction_store.dart';
import '../../state/sync_controller.dart';
import '../../state/home_layout.dart';
import '../../state/pro_controller.dart';
import '../../state/upi_settings.dart';
import '../components/common.dart';
import '../components/menu_list.dart';
import '../components/feature_page.dart';
import '../components/status_bar_blur_scope.dart';
import 'debts/debts_screen.dart';
import 'about/about_screen.dart';
import '../../data/agent/ai_session.dart';
import 'ai/ai_assistant_screen.dart';
import 'ai/ai_suggestions_screen.dart';
import 'help/help_screen.dart';
import 'pro/pro_screen.dart';
import 'settings/settings_screen.dart';
import 'accounts/accounts_screen.dart';
import 'categories/categories_screen.dart';
import 'settings/sync/sync_screen.dart';
import 'statements/statement_file.dart';
import 'statements/statement_start_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({
    super.key,
    required this.store,
    required this.categoryStore,
    required this.transactionStore,
    this.syncController,
    this.debtStore,
    this.loanStore,
    this.subscriptionStore,
    this.onLedgerChanged,
    this.onRulesChanged,
    this.smsStore,
    this.aiSession,
    this.community,
  });
  final AccountStore store;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final SyncController? syncController;
  final DebtStore? debtStore;
  final LoanStore? loanStore;
  final SubscriptionStore? subscriptionStore;

  /// Reloads the ledger screens after something here changed it.
  final VoidCallback? onLedgerChanged;

  /// Reads the inbox again after the user's SMS rules changed.
  final VoidCallback? onRulesChanged;

  /// The bank SMS reader, for the on/off switch in Settings.
  final SmsImportStore? smsStore;

  /// Connecting AI apps; without it, the row opens just the suggestions.
  final AiSessionController? aiSession;

  /// Offers to share approved fixes with other users.
  final CommunitySync? community;

  /// More › AI assistant, from here or from a statement import it can help.
  /// After an AI's statement layout is approved: its file, kept on the
  /// phone, imports in one tap.
  Future<void> _offerImport(BuildContext context, String signature) async {
    if (syncController case final sync?) {
      await offerPendingImport(context, sync, signature);
    }
  }

  void _openAi(BuildContext context) => Navigator.of(context).push(
    FeatureRoute<void>(
      aiSession != null
          ? AiAssistantScreen(
              controller: aiSession!,
              onLedgerChanged: onLedgerChanged,
              onRulesChanged: onRulesChanged,
              onLayoutApproved: _offerImport,
              community: community,
            )
          : AiSuggestionsScreen(
              database: transactionStore.repository.database,
              onLedgerChanged: onLedgerChanged,
              onRulesChanged: onRulesChanged,
              onLayoutApproved: _offerImport,
              community: community,
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final upi = UpiSettingsScope.maybeOf(context);
    final homeLayout = HomeLayoutScope.maybeOf(context);
    return StatusBarBlurScope(
      builder: (context, scrollController, topInset) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          // A dozen rows, so no lazy list: every group is built, as the one
          // long card was before.
          child: SingleChildScrollView(
            key: const PageStorageKey('more'),
            controller: scrollController,
            padding: EdgeInsets.fromLTRB(
              18,
              topInset + 12,
              18,
              96 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MoneyCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 30,
                  ),
                  child: _ProfileCard(sync: syncController, text: text),
                ),
                const SizedBox(height: appCardGap),
                MenuGroup(
                  label: 'Money',
                  children: [
                    MenuRow(
                      icon: Icons.account_balance_wallet_rounded,
                      title: 'Manage Accounts',
                      subtitle: 'Cash, banks, and everything in between',
                      onTap: () => Navigator.of(context).push(
                        FeatureRoute<void>(
                          AccountsScreen(
                            store: store,
                            transactionStore: transactionStore,
                          ),
                        ),
                      ),
                    ),
                    MenuRow(
                      icon: Icons.category_rounded,
                      title: 'Categories',
                      subtitle: 'Give every transaction a place',
                      onTap: () => Navigator.of(context).push(
                        FeatureRoute<void>(
                          CategoriesScreen(store: categoryStore),
                        ),
                      ),
                    ),
                    if (debtStore != null)
                      MenuRow(
                        icon: Icons.handshake_rounded,
                        title: 'Debts',
                        subtitle: 'Who owes you, and who you owe',
                        onTap: () => Navigator.of(context).push(
                          FeatureRoute<void>(DebtsScreen(store: debtStore!)),
                        ),
                      ),
                    if (loanStore != null)
                      MenuRow(
                        icon: Icons.account_balance_rounded,
                        title: 'Loans',
                        subtitle: 'EMIs, interest, and what is left to pay',
                        onTap: () => Navigator.of(context).push(
                          FeatureRoute<void>(LoansScreen(store: loanStore!)),
                        ),
                      ),
                    if (subscriptionStore != null)
                      MenuRow(
                        icon: Icons.autorenew_rounded,
                        title: 'Subscriptions',
                        subtitle: 'Netflix, gym, and everything that renews',
                        onTap: () => Navigator.of(context).push(
                          FeatureRoute<void>(
                            SubscriptionsScreen(store: subscriptionStore!),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                MenuGroup(
                  label: 'Tools',
                  children: [
                    if (syncController != null)
                      MenuRow(
                        icon: Icons.upload_file_rounded,
                        title: 'Import statement',
                        subtitle: 'UPI app PDF, or any CSV or Excel export',
                        onTap: () => Navigator.of(context).push(
                          FeatureRoute<void>(
                            StatementStartScreen(
                              sync: syncController!,
                              onOpenAi: () => _openAi(context),
                            ),
                          ),
                        ),
                      ),
                    MenuRow(
                      icon: Icons.auto_awesome_rounded,
                      title: 'AI assistant',
                      subtitle: 'Claude and ChatGPT, with your approval',
                      onTap: () => _openAi(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                MenuGroup(
                  label: 'App',
                  children: [
                    MenuRow(
                      icon: Icons.settings_rounded,
                      title: 'Settings',
                      subtitle: 'Sync, customization, security and your data',
                      onTap: () => Navigator.of(context).push(
                        FeatureRoute<void>(
                          SettingsScreen(
                            syncController: syncController,
                            upiSettings: upi,
                            homeLayout: homeLayout,
                            smsStore: smsStore,
                          ),
                        ),
                      ),
                    ),
                    MenuRow(
                      icon: Icons.help_rounded,
                      title: 'Help',
                      subtitle: 'FAQ, reports and community',
                      onTap: () =>
                          Navigator.of(context)
                              .push(FeatureRoute<void>(const HelpScreen())),
                    ),
                    MenuRow(
                      icon: Icons.info_rounded,
                      title: 'About SimpleMoney',
                      subtitle: 'Simple by design. Yours by default.',
                      onTap: () =>
                          Navigator.of(context)
                              .push(FeatureRoute<void>(const AboutScreen())),
                    ),
                    ListenableBuilder(
                      listenable: ProController.instance,
                      builder: (context, _) => MenuRow(
                        icon: Icons.workspace_premium_rounded,
                        highlight: true,
                        title: 'SimpleMoney Pro',
                        subtitle: ProController.instance.isPro
                            ? 'Thank you for supporting SimpleMoney'
                            : 'AI assistant, unlimited budgets and more',
                        onTap: () =>
                            Navigator.of(context)
                                .push(FeatureRoute<void>(const ProScreen())),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  'Made with ❤️ by AasH591',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.sync, required this.text});
  final SyncController? sync;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    if (sync == null) return _content(context, null);
    return ListenableBuilder(
      listenable: sync!,
      builder: (context, _) => _content(context, sync!.status),
    );
  }

  Widget _content(BuildContext context, SyncStatus? status) {
    final name = status?.displayName;
    final email = status?.email;
    final picture = status?.pictureUrl;
    final loading = sync != null && status == null;
    final connected = status?.enabled == true && email != null;
    final label = loading
        ? 'Loading account…'
        : connected
        ? 'Google Drive connected'
        : email != null
        ? 'Sync is off'
        : 'Sign in with Google';
    return Column(
      children: [
        _Avatar(pictureUrl: picture),
        const SizedBox(height: 18),
        Text(name ?? 'Your profile', style: text.titleLarge),
        const SizedBox(height: 7),
        Text(
          email ??
              (loading
                  ? 'Your money stays on this device'
                  : 'Sign in to keep a live backup of your data '
                        'in Google Drive'),
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 16),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: connected || loading
                ? null
                : () => Navigator.of(context)
                      .push(FeatureRoute<void>(SyncScreen(controller: sync))),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .07),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    connected
                        ? Icons.cloud_done_outlined
                        : loading
                        ? Icons.hourglass_empty_rounded
                        : email != null
                        ? Icons.cloud_off_outlined
                        : Icons.login_rounded,
                    size: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.pictureUrl});
  final String? pictureUrl;

  @override
  Widget build(BuildContext context) => Container(
    width: 72,
    height: 72,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Theme.of(context).colorScheme.primary,
      boxShadow: [
        BoxShadow(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .18),
          blurRadius: 20,
          offset: const Offset(0, 6),
        ),
      ],
    ),
    child: pictureUrl == null
        ? const Icon(
            Icons.person_outline_rounded,
            color: Colors.white,
            size: 34,
          )
        : CachedNetworkImage(
            imageUrl: pictureUrl!,
            fit: BoxFit.cover,
            fadeInDuration: Duration.zero,
            errorWidget: (_, _, _) => const Icon(
              Icons.person_outline_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
  );
}
