import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart'
    show BankSms;

import '../../../data/community/community_fixes.dart';
import '../../../data/reportable_sms.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/category_repository.dart';
import '../../../data/repositories/transaction_repository.dart';
import '../../../data/sms_sender_role.dart';
import '../../../domain/account.dart';
import '../../../domain/bank_institution_icon.dart';
import '../../../domain/category.dart';
import '../../../domain/currency_digits.dart';
import '../../../domain/transaction.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/card_action.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../theme/app_theme.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/transaction_sheet.dart';
import 'sms/teach_missed_sms_screen.dart';

/// Fixes other people shared that read something on this phone: for an SMS
/// format, a message it read and the entry it made. One can be switched off
/// here, or reported, which also tells the server.
class SharedFixesScreen extends StatefulWidget {
  const SharedFixesScreen({
    super.key,
    required this.community,
    this.onRulesChanged,
  });
  final CommunitySync community;

  /// Reads the inbox again after a shared SMS format was turned off or on.
  final VoidCallback? onRulesChanged;

  @override
  State<SharedFixesScreen> createState() => _SharedFixesScreenState();
}

class _SharedFixesScreenState extends State<SharedFixesScreen> {
  /// The fixes that read something on this phone, or that the user turned
  /// off, each with how it was used and a message it read.
  List<_Shown>? _fixes;

  /// Downloaded but not used here: for banks and statements this phone
  /// doesn't have.
  int _unused = 0;
  final _busy = <String>{};

  /// For showing what a message became as the row the app shows, and
  /// opening it.
  late final _accounts = AccountStore(
    AccountRepository(widget.community.database),
  );
  late final _categories = CategoryStore(
    CategoryRepository(widget.community.database),
  );
  late final _transactions = TransactionStore(
    TransactionRepository(widget.community.database),
    _accounts,
  );
  bool _stores = false;
  late final _reports = ReportableSmsRepository();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _transactions.dispose();
    _categories.dispose();
    _accounts.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var fixes = <_Shown>[];
    var unused = 0;
    try {
      final repository = widget.community.repository;
      final all = await repository.load(includeOff: true);
      final uses = await repository.uses(all);
      for (final fix in all) {
        final use = uses[fix.hash];
        if (use == null && !fix.off) {
          unused++;
          continue;
        }
        fixes.add(
          _Shown(
            fix,
            use?.count ?? 0,
            use == null ? null : await repository.sample(use),
          ),
        );
      }
      // The busiest first.
      fixes.sort((a, b) => b.uses.compareTo(a.uses));
      if (!_stores && fixes.any((f) => f.sample != null)) {
        try {
          await Future.wait([
            _accounts.load(),
            _categories.load(),
            _transactions.load(),
          ]);
          _stores = true;
        } catch (_) {
          /* The entry then shows from the message alone. */
        }
      }
    } catch (_) {
      fixes = const [];
    }
    if (mounted) {
      setState(() {
        _fixes = fixes;
        _unused = unused;
      });
    }
  }

  /// The switch: on or off on this phone only; nothing is sent.
  Future<void> _set(CommunityFix fix, bool on) => _change(fix, () async {
    if (on) {
      await widget.community.turnOn(fix.hash);
    } else {
      await widget.community.turnOff(fix.hash, report: false);
    }
  });

  /// Reports a fix that reads messages wrong. With a message it read, this is
  /// the Report SMS sheet, sending that message (with what the user says) to
  /// the developer, tied to the fix. Either way the fix is turned off here
  /// and checked again on the server.
  Future<void> _report(_Shown shown) async {
    final fix = shown.fix;
    final sample = shown.sample;
    final body = sample?.body;
    if (sample == null || body == null) {
      final sure = await showConfirmationAlert(
        context,
        title: 'Report this fix?',
        message:
            'It’s turned off on this phone and checked again. Nothing from '
            'your messages is sent.',
        confirmLabel: 'Report',
      );
      if (!sure || !mounted) return;
      await _change(fix, () => widget.community.turnOff(fix.hash));
      if (mounted) {
        showAppToast(context, 'Reported. Thanks!', icon: Icons.flag_rounded);
      }
      return;
    }
    final details = await showReportSmsSheet(
      context,
      count: 1,
      kind: ReportableKind.detected,
      contact: _reports.savedContact(),
      bank: fix.title,
      intro:
          'Someone else taught the app to read ${fix.title} SMS like this. '
          'Reporting turns it off on this phone and sends this message to '
          'the developer, so the fix can be corrected for everyone.',
    );
    if (details == null || !mounted) return;
    var sent = true;
    await _change(fix, () async {
      try {
        await _reports.report(
          [
            ReportableSms(
              sample.id,
              BankSms(
                sender: sample.sender,
                body: body,
                receivedAt: sample.receivedAt,
              ),
              ReportableKind.detected,
              'sharedFix',
              null,
              bank: fix.title,
            ),
          ],
          note: details.note,
          contact: details.contact,
          bank: details.bank,
          fix: fix.hash,
        );
      } on PlatformException {
        // The fix is still reported and turned off; only the message
        // didn't go.
        sent = false;
      }
      await widget.community.turnOff(fix.hash);
    });
    if (!mounted) return;
    showAppToast(
      context,
      sent
          ? 'Reported. Thanks!'
          : 'Fix reported. The message couldn’t be sent.',
      icon: Icons.flag_rounded,
    );
  }

  Future<void> _change(CommunityFix fix, Future<void> Function() run) async {
    setState(() => _busy.add(fix.hash));
    await run();
    if (fix.kind == CommunityKind.smsRule) widget.onRulesChanged?.call();
    await _load();
    if (mounted) setState(() => _busy.remove(fix.hash));
  }

  @override
  Widget build(BuildContext context) =>
      FeaturePage(title: 'Shared fixes', child: _body(context));

  Widget _body(BuildContext context) {
    final fixes = _fixes;
    if (fixes == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    final footnote = _unused == 0
        ? null
        : '$_unused more ${_unused == 1 ? 'fix is' : 'fixes are'} ready for '
              'banks and statements you don’t use yet.';
    if (fixes.isEmpty) {
      return ListView(
        children: [
          const EmptyState(
            icon: Icons.groups_outlined,
            title: 'None in use yet',
            message:
                'When a fix others taught the app reads your bank SMS or a '
                'statement, it shows up here. Report one if it reads yours '
                'wrong.',
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: Text(footnote, textAlign: TextAlign.center, style: muted),
            ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'Fixes others taught the app that read your SMS or statements. '
            'Report one that reads yours wrong.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final shown in fixes)
          Padding(
            padding: const EdgeInsets.only(bottom: appCardGap),
            child: _FixCard(
              shown: shown,
              busy: _busy.contains(shown.fix.hash),
              onChanged: (on) => _set(shown.fix, on),
              onReport: () => _report(shown),
              entry: shown.sample == null
                  ? null
                  : _entry(context, shown.fix, shown.sample!),
            ),
          ),
        if (footnote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
            child: Text(footnote, style: muted),
          ),
      ],
    );
  }

  Account? _account(int? id) =>
      _accounts.accounts.where((a) => a.id == id).firstOrNull;
  Category? _category(int? id) =>
      _categories.categories.where((c) => c.id == id).firstOrNull;

  /// The entry the message became, as the Transactions list shows it: the
  /// saved transaction, or for one still waiting in review, what it will
  /// be. Tapping opens it on the edit page, to look at only.
  Widget _entry(BuildContext context, CommunityFix fix, FixSample sample) {
    final saved = _transactions.transactions
        .where((t) => t.id == sample.transactionId)
        .firstOrNull;
    final MoneyTransaction t;
    final Account? account;
    final int digits;
    final String currency;
    if (saved != null) {
      t = saved;
      account = _account(t.accountId);
      currency = account?.currency ?? 'INR';
      digits = account?.digits ?? currencyDigits(currency);
    } else {
      final c = sample.candidate;
      final credit = (c['correctedDirection'] ?? c['direction']) == 'credit';
      final type = credit ? TransactionType.income : TransactionType.expense;
      currency = c['currencyCode'] as String? ?? 'INR';
      digits = currencyDigits(currency);
      account = _account(c['assignedAccountId'] as int?);
      final name = (c['category'] as Map?)?['name'] as String?;
      final category = _categories.categories
          .where(
            (k) =>
                k.name.toLowerCase() == name?.toLowerCase() &&
                k.type == (credit ? CategoryType.income : CategoryType.expense),
          )
          .firstOrNull;
      t = MoneyTransaction(
        id: -1,
        type: type,
        amountMinor: (c['amountMinor'] as num?)?.toInt() ?? 0,
        accountId: account?.id ?? 0,
        categoryId: category?.id,
        title: c['counterparty'] as String? ?? fix.title,
        note: sample.body == null
            ? null
            : 'Sender: ${sample.sender}\n\n${sample.body}',
        date: sample.receivedAt,
      );
    }
    final credit = t.type == TransactionType.income;
    final category = _category(t.categoryId);
    final todo = [
      if (account == null) 'account',
      if (category == null && t.type != TransactionType.transfer) 'category',
    ];
    final amount = formatAccountMoney(
      t.amountMinor,
      digits: digits,
      currency: currency,
    );
    return TransactionListRow(
      transaction: t,
      account: account,
      toAccount: _account(t.toAccountId),
      category: category,
      parentCategory: _category(category?.parentId),
      formattedAmount: t.type == TransactionType.transfer
          ? amount
          : '${credit ? '+ ' : '- '}$amount',
      subtitle: saved != null || todo.isEmpty
          ? null
          : 'Select ${todo.join(' and ')} on review',
      subtitleColor: saved != null || todo.isEmpty ? null : coral,
      showDate: true,
      onTap: !_stores || t.type == TransactionType.transfer
          ? () {}
          : () => showPreviewTransactionSheet(
              context,
              draft: TransactionDraft(
                type: t.type,
                amountText: AmountTyping.fromMinor(t.amountMinor, digits),
                title: t.title,
                categoryId: t.categoryId,
                accountId: account?.id,
                date: t.date,
                note: t.note,
              ),
              accountStore: _accounts,
              categoryStore: _categories,
              transactionStore: _transactions,
            ),
    );
  }
}

class _Shown {
  const _Shown(this.fix, this.uses, this.sample);
  final CommunityFix fix;
  final int uses;
  final FixSample? sample;
}

/// One shared fix: what it is and whether it's on; for an SMS format, a
/// message it read and the entry it made of it; and a way to report it.
class _FixCard extends StatelessWidget {
  const _FixCard({
    required this.shown,
    required this.busy,
    required this.onChanged,
    required this.onReport,
    required this.entry,
  });
  final _Shown shown;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onReport;

  /// The entry its message became, when it read one here.
  final Widget? entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fix = shown.fix;
    final sms = fix.kind == CommunityKind.smsRule;
    final sample = shown.sample;
    final count = NumberFormat.decimalPattern().format(shown.uses);
    // A shop's or biller's SMS: shown as the shop it is, not a bank.
    final shop =
        sms &&
        fix.payload['format'] is Map &&
        !ruleSenderRole(Map<String, dynamic>.from(fix.payload['format'] as Map))
            .holdsMoney;
    final what = sms
        ? shown.uses == 0
              ? (shop ? 'Shop SMS' : 'Bank SMS')
              : 'Read $count ${shown.uses == 1 ? 'message' : 'messages'}'
        : 'Statement layout';
    final label = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final wash = scheme.onSurface.withValues(alpha: .05);
    final senders = (fix.payload['senders'] as List? ?? const []).join(', ');
    return MoneyCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 40,
                child: !sms
                    ? const IconTile(Icons.table_chart_outlined, size: 40)
                    : shop
                    ? const IconTile(Icons.storefront_outlined, size: 40)
                    : AppIcon(bankInstitutionIcon(fix.title), size: 40),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fix.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      fix.off ? '$what · Off on this phone' : what,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: fix.off ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(value: !fix.off, onChanged: busy ? null : onChanged),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                if (sms) ...[
                  Text('Message', style: label),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: wash,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [
                            sample?.sender ?? senders,
                            if (sample != null)
                              DateFormat('d MMM, HH:mm')
                                  .format(sample.receivedAt),
                          ].join(' · '),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _ExpandableText(
                          sample?.body ?? _wording(fix.payload['format']),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.4,
                          ),
                        ),
                        // The message itself is gone: its wording stands in,
                        // with what changes left out.
                        if (sample?.body == null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '“…” changes from message to message.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (entry case final entry?) ...[
                    const SizedBox(height: 12),
                    Text('Reads as', style: label),
                    const SizedBox(height: 6),
                    Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: wash,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: entry,
                    ),
                  ],
                ] else ...[
                  Text('Columns', style: label),
                  const SizedBox(height: 4),
                  Text(
                    (fix.payload['signature'] as String? ?? '')
                        .split('|')
                        .where((c) => c.isNotEmpty)
                        .join(' · '),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, right: 4),
              child: CardAction(
                label: 'Report',
                icon: Icons.flag_outlined,
                color: scheme.onSurfaceVariant,
                onTap: busy || fix.off ? null : onReport,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A message, four lines at first; tapping shows all of it, and again folds
/// it. Short ones show whole, with nothing to tap.
class _ExpandableText extends StatefulWidget {
  const _ExpandableText(this.text, {this.style});
  final String text;
  final TextStyle? style;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const _lines = 4;
  bool _open = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: _lines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth);
      final long = painter.didExceedMaxLines;
      painter.dispose();
      final text = Text(
        widget.text,
        style: widget.style,
        maxLines: _open || !long ? null : _lines,
        overflow: _open || !long ? null : TextOverflow.ellipsis,
      );
      if (!long) return text;
      final scheme = Theme.of(context).colorScheme;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _open ? 'Show less' : 'Show all',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A format's wording, with what changes between messages as "…".
String _wording(Object? format) {
  if (format is! Map) return '';
  final out = StringBuffer();
  for (final token in (format['tokens'] as List?) ?? const []) {
    if (token is! Map) continue;
    final op = token['op'];
    if (op == 'match_literal') {
      out.write(token['value'] ?? '');
    } else if (op is String && op.startsWith('capture_')) {
      out.write('…');
    }
  }
  return out.toString().trim();
}
