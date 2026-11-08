import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../../data/reportable_sms.dart';
import '../../../domain/account.dart';
import '../../../domain/realtime_sms_category.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_toast.dart';
import '../../components/card_action.dart';
import '../../components/common.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/segmented_pill.dart';
import '../../components/search_field.dart';
import '../../components/text_entry_popup.dart';
import '../../theme/app_theme.dart';
import '../../theme/sheet_colors.dart';

/// Bank and business SMS for the user to report: ones the parser missed, ones
/// it read (perhaps wrongly) and the rest. Nothing is sent until they tap
/// Report on a message (or Report all).
class ReportSmsScreen extends StatefulWidget {
  const ReportSmsScreen({super.key});

  @override
  State<ReportSmsScreen> createState() => _ReportSmsScreenState();
}

enum _Tab { missed, detected, other, reported }

class _ReportSmsScreenState extends State<ReportSmsScreen> {
  final _repository = ReportableSmsRepository();
  final _search = TextEditingController();
  final _messages = <ReportableSms>[];
  StreamSubscription<List<ReportableSms>>? _scan;
  // True from the start, so the first frame says "Reading" rather than
  // "Nothing missed".
  bool _scanning = true;
  Set<String> _reported = {};
  final _sending = <String>{};
  _Tab _tab = _Tab.missed;
  bool _needsPermission = false;
  String? _error;

  bool get _busy => _sending.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_repository.inbox.supported) _load();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Starts a fresh scan. Messages appear page by page; the returned future
  /// completes when the whole inbox has been read.
  Future<void> _load({bool ask = false}) async {
    await _scan?.cancel();
    setState(() {
      _error = null;
      _needsPermission = false;
    });
    try {
      final allowed =
          await _repository.inbox.hasPermission() ||
          (ask && await _repository.inbox.requestPermission());
      if (!allowed) {
        if (mounted) setState(() => _needsPermission = true);
        return;
      }
      final reported = await _repository.reportedIds();
      if (!mounted) return;
      setState(() {
        _reported = reported;
        _messages.clear();
        _scanning = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Couldn’t read your messages.';
          _scanning = false;
        });
      }
      return;
    }
    final done = Completer<void>();
    void finish([String? error]) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _error = error ?? _error;
        });
      }
      if (!done.isCompleted) done.complete();
    }

    _scan = _repository.scan().listen(
      (page) {
        if (!mounted) return;
        setState(() {
          _messages
            ..addAll(page)
            ..sort((a, b) => b.sms.receivedAt.compareTo(a.sms.receivedAt));
        });
      },
      onError: (_) => finish('Couldn’t read all your messages.'),
      onDone: finish,
      cancelOnError: true,
    );
    return done.future;
  }

  List<ReportableSms> _visible(_Tab tab) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final m in _messages)
        if ((tab == _Tab.reported
                ? _reported.contains(m.id)
                : !_reported.contains(m.id) && m.kind.name == tab.name) &&
            (query.isEmpty ||
                m.sms.sender.toLowerCase().contains(query) ||
                m.sms.body.toLowerCase().contains(query)))
          m,
    ];
  }

  Future<void> _report(List<ReportableSms> messages) async {
    if (_busy || messages.isEmpty) return;
    final details = await showAdaptiveSheet<_ReportDetails>(
      context,
      builder: (_) => _ReportSheet(
        count: messages.length,
        kind: messages.first.kind,
        contact: _repository.savedContact(),
      ),
    );
    if (details == null || !mounted) return;
    setState(() => _sending.addAll(messages.map((m) => m.id)));
    try {
      await _repository.report(
        messages,
        note: details.note,
        contact: details.contact,
      );
      if (!mounted) return;
      setState(() => _reported.addAll(messages.map((m) => m.id)));
      showAppToast(
        context,
        'Thanks for reporting',
        icon: Icons.check_circle_rounded,
      );
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'Couldn’t send. Try again later.',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t send. Try again later.');
    } finally {
      if (mounted) {
        setState(() => _sending.removeAll(messages.map((m) => m.id)));
      }
    }
  }

  Future<void> _openSettings() async {
    try {
      await _repository.openSettings();
    } on PlatformException catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Open Settings > Apps > Simple Money > Permissions > SMS.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: FeaturePage(
      title: 'Report SMS',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: _body(context),
        ),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    if (!_repository.inbox.supported) {
      return const EmptyState(
        icon: Icons.sms_outlined,
        title: 'Android only',
        message: 'Reporting SMS is available on Android.',
      );
    }
    if (_needsPermission) {
      return _PermissionCard(
        onAllow: () => _load(ask: true),
        onOpenSettings: _openSettings,
      );
    }
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final shown = _visible(_tab);
    final header = [
      SegmentedPill<_Tab>(
        segments: const [
          PillSegment(_Tab.missed, 'Missed'),
          PillSegment(_Tab.detected, 'Read'),
          PillSegment(_Tab.other, 'Other'),
          PillSegment(_Tab.reported, 'Sent'),
        ],
        value: _tab,
        onChanged: (tab) => setState(() => _tab = tab),
      ),
      const SizedBox(height: 12),
      SearchField(
        controller: _search,
        hintText: 'Search',
        onChanged: (_) => setState(() {}),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 0, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${shown.length} · ${_caption(_tab)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_tab == _Tab.missed && shown.length > 1)
              TextButton(
                onPressed: _busy ? null : () => _report(shown),
                child: const Text('Report all'),
              ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ),
      const SizedBox(height: 8),
    ];
    final footer = [
      if (_scanning)
        const _Scanning()
      else if (shown.isEmpty)
        _NothingHere(tab: _tab),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(
          'Last ${ReportableSmsRepository.window.inDays} days. Personal '
          'messages and OTPs are hidden.',
          textAlign: TextAlign.center,
          style: muted,
        ),
      ),
    ];
    // Other can run to thousands of messages, so cards are built lazily.
    return SegmentSwipe<_Tab>(
      values: _Tab.values,
      value: _tab,
      onChanged: (tab) => setState(() => _tab = tab),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          itemCount: header.length + shown.length + footer.length,
          itemBuilder: (context, index) {
            if (index < header.length) return header[index];
            index -= header.length;
            if (index >= shown.length) return footer[index - shown.length];
            final message = shown[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: appCardGap),
              child: _MessageCard(
                key: ValueKey(message.id),
                message: message,
                reported: _reported.contains(message.id),
                sending: _sending.contains(message.id),
                onReport: _busy ? null : () => _report([message]),
              ),
            );
          },
        ),
      ),
    );
  }

  static String _caption(_Tab tab) => switch (tab) {
    _Tab.missed => 'Payments the app didn’t catch',
    _Tab.detected => 'Check these were read right',
    _Tab.other => 'Other bank and business SMS',
    _Tab.reported => 'Sent to the developer',
  };
}

class _Scanning extends StatelessWidget {
  const _Scanning();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Text(
          'Reading messages…',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

class _ReportDetails {
  const _ReportDetails(this.note, this.contact);
  final String note, contact;
}

/// Asks what's wrong and how to reply, both optional, before sending.
class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.count,
    required this.kind,
    required this.contact,
  });
  final int count;
  final ReportableKind kind;
  final Future<String> contact;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _note = TextEditingController();
  final _contact = TextEditingController();
  final _picked = <String>{};

  List<String> get _reasons => switch (widget.kind) {
    ReportableKind.detected => const [
      'Wrong amount',
      'Wrong debit/credit',
      'Wrong account',
      'Wrong name',
      'Wrong category',
      'Not a transaction',
    ],
    ReportableKind.missed || ReportableKind.other => const [
      'Is a transaction',
      'Balance update',
      'Bill or due date',
    ],
  };

  @override
  void initState() {
    super.initState();
    widget.contact.then((saved) {
      if (mounted && _contact.text.isEmpty) _contact.text = saved;
    });
  }

  @override
  void dispose() {
    _note.dispose();
    _contact.dispose();
    super.dispose();
  }

  void _send() => Navigator.pop(
    context,
    _ReportDetails(
      [
        ..._picked,
        if (_note.text.trim().isNotEmpty) _note.text.trim(),
      ].join('; '),
      _contact.text.trim(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return SheetPage(
      header: SheetHeader(
        widget.count == 1 ? 'Report message' : 'Report ${widget.count}',
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'What’s wrong?',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final reason in _reasons)
                FilterChip(
                  label: Text(reason),
                  selected: _picked.contains(reason),
                  onSelected: (on) => setState(
                    () => on ? _picked.add(reason) : _picked.remove(reason),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          SheetTextField(
            controller: _note,
            label: 'Details',
            hintText: 'Optional',
            maxLength: 300,
            multiline: true,
            autofocus: false,
          ),
          const SizedBox(height: 8),
          SheetTextField(
            controller: _contact,
            label: 'Contact',
            hintText: 'Optional, if you want a reply',
            maxLength: 100,
            autofocus: false,
          ),
          Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: colors.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Encrypted. Only the developer can read it.',
                  style: TextStyle(fontSize: 13, color: colors.muted),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: () => Navigator.pop(context),
        primaryLabel: 'Send',
        onPrimary: _send,
        primaryColor: colors.primary,
      ),
    );
  }
}

class _MessageCard extends StatefulWidget {
  const _MessageCard({
    super.key,
    required this.message,
    required this.reported,
    required this.sending,
    required this.onReport,
  });
  final ReportableSms message;
  final bool reported, sending;
  final VoidCallback? onReport;

  @override
  State<_MessageCard> createState() => _MessageCardState();
}

class _MessageCardState extends State<_MessageCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sms = widget.message.sms;
    final parsed = widget.message.parsed;
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sms.sender,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  if (widget.reported) ...[
                    _Badge(label: 'Sent', color: scheme.primary),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    DateFormat('d MMM, HH:mm').format(sms.receivedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AnimatedSize(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: Text(
                  sms.body,
                  maxLines: _expanded ? null : 3,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ),
              if (parsed != null) ...[
                const SizedBox(height: 12),
                _ReadAs(parsed),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!widget.reported) ...[
                    widget.sending
                        ? const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : CardAction(
                            label: 'Report',
                            icon: Icons.outbox_outlined,
                            color: scheme.primary,
                            onTap: widget.onReport,
                          ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the app read, one labelled field per row, so a wrong amount,
/// direction, name, account or category is easy to spot.
class _ReadAs extends StatelessWidget {
  const _ReadAs(this.parsed);
  final SmsTransactionCandidate parsed;

  /// The category the app files it under by default, matching live SMS: the
  /// parser's catch-all "Personal" becomes Other Income or Other Expense.
  String get _category {
    final name = parsed.category?.name;
    return name == null || name.toLowerCase() == 'personal'
        ? realtimeFallbackCategoryName(_credit)
        : name;
  }

  bool get _credit => parsed.direction == SmsDirection.credit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final amount = formatAccountMoney(
      parsed.amountMinor,
      digits: 2,
      currency: parsed.currencyCode,
    );
    final account = [
      ?parsed.bankName,
      if (parsed.accountLast4 case final last4?) '••$last4',
    ].join(' ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _Field(
            'Amount',
            '${_credit ? '+' : '−'}$amount',
            color: _credit ? green : coral,
            bold: true,
          ),
          _Field(_credit ? 'From' : 'To', parsed.counterparty),
          _Field('Account', account.isEmpty ? null : account),
          _Field('Category', _category),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.color, this.bold = false});
  final String label;
  final String? value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
          Expanded(
            child: Text(
              value ?? 'Not found',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: value == null ? muted : color,
                fontWeight: bold ? FontWeight.w700 : null,
                fontStyle: value == null ? FontStyle.italic : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: color.withValues(alpha: .12),
      shape: const StadiumBorder(),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ),
  );
}

class _NothingHere extends StatelessWidget {
  const _NothingHere({required this.tab});
  final _Tab tab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title) = switch (tab) {
      _Tab.missed => (Icons.task_alt_rounded, 'Nothing missed'),
      _Tab.detected => (Icons.receipt_long_outlined, 'Nothing read yet'),
      _Tab.other => (Icons.sms_outlined, 'No other messages'),
      _Tab.reported => (Icons.outbox_outlined, 'Nothing sent yet'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.onAllow, required this.onOpenSettings});
  final VoidCallback onAllow, onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
      children: [
        MoneyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(Icons.sms_outlined, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Allow SMS access',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Needed to show your bank SMS. Nothing is sent unless you report one.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onAllow,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Allow SMS access'),
              ),
              const SizedBox(height: 4),
              Text(
                'Blocked? App settings › ⋮ › Allow restricted settings, then allow SMS.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton(
                onPressed: onOpenSettings,
                child: const Text('Open app settings'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
