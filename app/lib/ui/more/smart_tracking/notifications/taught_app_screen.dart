import 'package:flutter/material.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../../../data/bank_sms_parser.dart';
import '../../../../data/db/app_database.dart';
import '../../../../data/notification_access_platform.dart';
import '../../../../data/repositories/account_repository.dart';
import '../../../../data/repositories/category_repository.dart';
import '../../../../data/repositories/sms_import_repository.dart';
import '../../../../data/repositories/transaction_repository.dart';
import '../../../../data/user_sms_rules.dart';
import '../../../../domain/account.dart';
import '../../../../domain/category.dart';
import '../../../../domain/currency_digits.dart';
import '../../../../domain/transaction.dart';
import '../../../../state/account_store.dart';
import '../../../../state/category_store.dart';
import '../../../../state/transaction_store.dart';
import '../../../components/app_toast.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import '../../../components/transactions/transaction_list_row.dart';
import '../../../theme/app_theme.dart';
import '../../../transactions/amount_typing.dart';
import '../../../transactions/transaction_sheet.dart';
import '../sms/teach_sms_sheet.dart';
import 'notification_preview.dart';

/// Smart tracking › App notifications › one taught app: switch it off or on,
/// see the notifications it was taught from, and tap one to teach it again
/// (the old rule is replaced). One app can send several kinds of
/// notification, and each kind was taught from its own, so each is listed.
class TaughtAppScreen extends StatefulWidget {
  const TaughtAppScreen({
    super.key,
    required this.database,
    required this.app,
    this.platform,
    this.onRulesChanged,
  });

  final AppDatabase database;
  final TaughtApp app;

  /// Replaced in tests.
  final NotificationAccessPlatform? platform;

  /// Reads again with the new rule, after a notification was taught again.
  final VoidCallback? onRulesChanged;

  @override
  State<TaughtAppScreen> createState() => _TaughtAppScreenState();
}

/// One kind of notification the app was taught: its rule, and the
/// notification the rule was taught from, as it looked.
class _Kind {
  const _Kind(this.rule, this.notification, [this.entry]);
  final UserSmsRule rule;
  final CapturedNotification notification;

  /// The transaction its rule reads from that notification, as the
  /// Transactions list shows it. Null when the rule can't read it any more.
  final _Entry? entry;
}

class _Entry {
  const _Entry(this.transaction, this.account, this.currency, this.digits);
  final MoneyTransaction transaction;
  final Account? account;
  final String currency;
  final int digits;
}

class _TaughtAppScreenState extends State<TaughtAppScreen> {
  late final NotificationAccessPlatform _platform =
      widget.platform ?? NotificationAccessPlatform();
  late TaughtApp _app = widget.app;
  List<_Kind> _kinds = const [];
  bool _loaded = false;

  /// To show what a notification becomes as the app shows a transaction, and
  /// to open it for looking at.
  late final _accounts = AccountStore(AccountRepository(widget.database));
  late final _categories = CategoryStore(CategoryRepository(widget.database));
  late final _transactions = TransactionStore(
    TransactionRepository(widget.database),
    _accounts,
  );

  @override
  void dispose() {
    _transactions.dispose();
    _categories.dispose();
    _accounts.dispose();
    super.dispose();
  }

  /// What [rule] reads from the notification it was taught from, with the
  /// account everything from this app goes to (if one was chosen).
  Future<_Entry?> _entryOf(
    UserSmsRule rule,
    CapturedNotification n,
    Map<String, int> links,
  ) async {
    try {
      final sample = rule.samples.isEmpty ? n.message : rule.samples.first;
      final result = BankSmsParser(await compileUserSmsRules([rule])).parse(
        BankSms(
          sender: _app.senderKey,
          body: sample,
          receivedAt: rule.createdAt,
        ),
      );
      final c = result.candidate;
      if (c == null) return null;
      final credit = c.direction == SmsDirection.credit;
      final key = smsBankKey({
        'countryCode': c.countryCode,
        'bankName': c.bankName,
        'currencyCode': c.currencyCode,
        'accountLast4': c.accountLast4,
      });
      final account = _accounts.accounts
          .where((a) => a.id == links[key] && !a.isArchived)
          .firstOrNull;
      final name = c.category?.name.toLowerCase();
      final category = name == null
          ? null
          : _categories.categories
                .where(
                  (k) =>
                      k.name.toLowerCase() == name &&
                      k.type ==
                          (credit ? CategoryType.income : CategoryType.expense),
                )
                .firstOrNull;
      return _Entry(
        MoneyTransaction(
          id: -1,
          type: credit ? TransactionType.income : TransactionType.expense,
          amountMinor: c.amountMinor,
          accountId: account?.id ?? 0,
          categoryId: category?.id,
          title: c.counterparty,
          note: 'Notification from ${_app.label}\n\n$sample',
          date: rule.createdAt,
        ),
        account,
        c.currencyCode,
        currencyDigits(c.currencyCode),
      );
    } catch (_) {
      return null;
    }
  }

  Category? _category(int? id) =>
      _categories.categories.where((c) => c.id == id).firstOrNull;

  /// The entry as a row of the Transactions list. Tap to look at it on the
  /// transaction page, with nothing to save.
  Widget _entryRow(_Entry e) {
    final t = e.transaction;
    final credit = t.type == TransactionType.income;
    final category = _category(t.categoryId);
    final amount = formatAccountMoney(
      t.amountMinor,
      digits: e.digits,
      currency: e.currency,
    );
    final todo = [
      if (e.account == null) 'account',
      if (category == null) 'category',
    ];
    return TransactionListRow(
      transaction: t,
      account: e.account,
      toAccount: null,
      category: category,
      parentCategory: _category(category?.parentId),
      formattedAmount: '${credit ? '+ ' : '- '}$amount',
      subtitle: todo.isEmpty ? null : 'Select ${todo.join(' and ')} on review',
      subtitleColor: todo.isEmpty ? null : coral,
      showDate: true,
      onTap: () => showPreviewTransactionSheet(
        context,
        draft: TransactionDraft(
          type: t.type,
          amountText: AmountTyping.fromMinor(t.amountMinor, e.digits),
          title: t.title,
          categoryId: t.categoryId,
          accountId: e.account?.id,
          date: t.date,
          note: t.note,
        ),
        accountStore: _accounts,
        categoryStore: _categories,
        transactionStore: _transactions,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The notification a rule was taught from, as the sample it kept: without
  /// the leading word every notification is read with, and split back into
  /// its heading (the first line) and its text.
  CapturedNotification _from(UserSmsRule rule) {
    var message = rule.samples.isEmpty ? '' : rule.samples.first;
    if (message.startsWith(notificationRuleAnchor)) {
      message = message.substring(notificationRuleAnchor.length);
    }
    final lines = message.split('\n');
    return CapturedNotification(
      package: _app.package,
      label: _app.label,
      title: lines.first,
      text: lines.skip(1).join('\n'),
      message: message,
      // When it was taught.
      receivedAt: rule.createdAt,
      icon: _app.icon,
    );
  }

  Future<void> _load() async {
    try {
      final (_, taught) = await _platform.state();
      final now = taught.where((a) => a.package == widget.app.package);
      final rules = [
        for (final r in await UserSmsRuleRepository(widget.database).load())
          if (r.senders.contains(_app.senderKey)) r,
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await Future.wait([_accounts.load(), _categories.load()]);
      final links = await SmsImportRepository(widget.database).accountLinks();
      final kinds = <_Kind>[];
      for (final r in rules) {
        final n = _from(r);
        kinds.add(_Kind(r, n, await _entryOf(r, n, links)));
      }
      if (!mounted) return;
      setState(() {
        if (now.isNotEmpty) _app = now.first;
        _kinds = kinds;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _setEnabled(bool on) async {
    final (_, taught) = await _platform.state();
    setState(() => _app = _app.copyWith(enabled: on));
    await _platform.setTaught([
      for (final a in taught)
        if (a.package == _app.package) a.copyWith(enabled: on) else a,
    ]);
  }

  /// Teach [kind] again: the same notification, marked afresh. The rule it
  /// was taught as is replaced.
  Future<void> _reteach(_Kind kind) async {
    final n = kind.notification;
    final read = await showTeachSmsSheet(
      context,
      database: widget.database,
      message: BankSms(
        sender: _app.senderKey,
        body: n.message,
        receivedAt: n.receivedAt,
      ),
      appName: _app.label,
      preview: NotificationPreview(n),
      replacingRuleId: kind.rule.id,
    );
    if (read == null || !mounted) return;
    widget.onRulesChanged?.call();
    await _load();
    if (!mounted) return;
    showAppToast(
      context,
      'Taught again · ${_app.label}',
      icon: Icons.check_circle_rounded,
    );
  }

  Widget _icon() {
    final scheme = Theme.of(context).colorScheme;
    final icon = _app.icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 40,
        child: icon != null
            ? Image.memory(icon, fit: BoxFit.cover, gaplessPlayback: true)
            : ColoredBox(
                color: scheme.primary.withValues(alpha: .18),
                child: Center(
                  child: Text(
                    _app.label.isEmpty ? '?' : _app.label[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FeaturePage(
      title: _app.label,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
            children: [
              MenuGroup(
                children: [
                  MenuRow(
                    key: const Key('taught-app-switch'),
                    icon: Icons.apps_rounded,
                    leading: _icon(),
                    title: _app.label,
                    subtitle: _app.enabled
                        ? 'Reading its notifications'
                        : 'Paused · not reading',
                    onTap: () => _setEnabled(!_app.enabled),
                    trailing: Switch.adaptive(
                      value: _app.enabled,
                      onChanged: _setEnabled,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 16, 10, 12),
                child: Text(
                  _kinds.isEmpty && _loaded
                      ? 'Nothing is saved for this app. Teach it from a '
                            'notification on the previous screen.'
                      : 'The notifications it was taught from. Tap one to '
                            'teach it again.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ),
              for (final kind in _kinds)
                Padding(
                  // Close within a pair, wider between pairs: the notification
                  // and what it reads as belong together.
                  padding: const EdgeInsets.only(bottom: 26),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NotificationPreview(
                        kind.notification,
                        key: Key('kind-${kind.rule.id}'),
                        onPage: true,
                        maxLines: 4,
                        onTap: () => _reteach(kind),
                      ),
                      if (kind.entry case final entry?) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 10, 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.subdirectory_arrow_right_rounded,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text('Reads as', style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Container(
                          key: Key('entry-${kind.rule.id}'),
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: _entryRow(entry),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
