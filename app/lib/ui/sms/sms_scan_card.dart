import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/sms_import_store.dart';
import '../components/action_buttons.dart';
import '../theme/app_theme.dart';

/// Home's SMS auto-import card. Every state — the invitation, a scan in
/// progress, and what is left afterwards — fills the same slots: a header
/// with a status line, three figures and one action, so the card keeps
/// its height as a scan moves along.
class SmsScanCard extends StatelessWidget {
  const SmsScanCard({
    super.key,
    required this.store,
    required this.onScan,
    this.onReview,
    this.unlinked = 0,
  });
  final SmsImportStore store;

  /// Starts the first scan, or a fresh one from the header.
  final VoidCallback onScan;

  /// Opens what was found; null before the first scan.
  final VoidCallback? onReview;

  /// Banks whose messages carry no account number to match.
  final int unlinked;

  static const title = 'SMS auto-import';

  @override
  Widget build(BuildContext context) {
    final number = NumberFormat.decimalPattern();
    String count(int n, String one, String many) =>
        '${number.format(n)} ${n == 1 ? one : many}';
    final scanning = store.scanning;
    final intro = !scanning && onReview == null;
    final toCheck = store.pendingCount;
    final attention = !scanning && !intro && (toCheck > 0 || unlinked > 0);

    final state = scanning
        ? _CardState.scanning
        : intro
        ? _CardState.intro
        : attention
        ? _CardState.attention
        : _CardState.done;

    final status = store.error != null && !scanning
        ? store.error!
        : switch (state) {
            _CardState.intro => 'Add bank transactions without typing them.',
            _CardState.scanning when store.importing =>
              'Saving your transactions…',
            _CardState.scanning =>
              '${count(store.scannedMessages, 'message', 'messages')} checked',
            _CardState.attention when toCheck > 0 => count(
              toCheck,
              'transaction to check',
              'transactions to check',
            ),
            _CardState.attention => count(
              unlinked,
              'bank needs an account',
              'banks need an account',
            ),
            _CardState.done => 'All caught up · new SMS save on arrival',
          };

    final scan = store.lastScan;
    final figures = switch (state) {
      _CardState.intro => const [
        _Figure.icon(Icons.account_balance_outlined, 'Finds banks'),
        _Figure.icon(Icons.task_alt_rounded, 'Saves the sure'),
        _Figure.icon(Icons.help_outline_rounded, 'Asks the rest'),
      ],
      _CardState.scanning => [
        _Figure(number.format(store.foundTransactions), 'Found'),
        _Figure(number.format(store.foundAccounts.length), 'Banks'),
        const _Figure('–', 'To check'),
      ],
      _ => [
        _Figure(scan == null ? '–' : number.format(scan.saved), 'Saved'),
        _Figure(number.format(toCheck), 'To check', attention: toCheck > 0),
        _Figure(
          number.format(unlinked),
          'Need account',
          attention: unlinked > 0,
        ),
      ],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          state: state,
          status: status,
          error: store.error != null && !scanning,
          onScanAgain: store.busy ? null : onScan,
          showScanAgain:
              store.supported &&
              (state == _CardState.attention || state == _CardState.done),
        ),
        const SizedBox(height: 14),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, figure) in figures.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _FigureTile(figure)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        switch (state) {
          _CardState.scanning => _ScanProgress(
            label: store.importing
                ? 'Adding accounts and transactions…'
                : 'Checking your SMS…',
          ),
          _CardState.intro => PillButton(
            onPressed: store.busy ? null : onScan,
            label: store.busy ? 'Waiting for permission…' : 'Scan messages',
          ),
          _CardState.attention => PillButton(
            onPressed: store.busy ? null : onReview,
            label: 'Review',
          ),
          _CardState.done => PillButton(
            primary: false,
            onPressed: store.busy ? null : onReview,
            label: 'Open SMS review',
          ),
        },
        const SizedBox(height: 10),
        const _PrivacyLine(),
      ],
    );
  }
}

enum _CardState { intro, scanning, attention, done }

class _Header extends StatelessWidget {
  const _Header({
    required this.state,
    required this.status,
    required this.error,
    required this.onScanAgain,
    required this.showScanAgain,
  });
  final _CardState state;
  final String status;
  final bool error;
  final VoidCallback? onScanAgain;
  final bool showScanAgain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = switch (state) {
      _CardState.attention => orange,
      _CardState.done => green,
      _ => colors.primary,
    };
    final icon = switch (state) {
      _CardState.intro => Icons.sms_outlined,
      _CardState.scanning => Icons.manage_search_rounded,
      _CardState.attention => Icons.mark_chat_unread_outlined,
      _CardState.done => Icons.mark_chat_read_outlined,
    };
    final statusStyle = theme.textTheme.bodySmall?.copyWith(
      color: error ? colors.error : colors.onSurfaceVariant,
      height: 1.3,
    );
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Icon(icon, key: ValueKey(icon), size: 22, color: tint),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                SmsScanCard.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              // Always two lines tall, so a longer status never moves the
              // card below it.
              Stack(
                children: [
                  ExcludeSemantics(
                    child: Opacity(
                      opacity: 0,
                      child: Text(' \n ', style: statusStyle),
                    ),
                  ),
                  Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: statusStyle,
                  ),
                ],
              ),
            ],
          ),
        ),
        // Kept even when hidden, so the title wraps the same in every state.
        SizedBox(
          width: 40,
          height: 40,
          child: showScanAgain
              ? IconButton(
                  tooltip: 'Scan again',
                  padding: EdgeInsets.zero,
                  onPressed: onScanAgain,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                )
              : null,
        ),
      ],
    );
  }
}

class _Figure {
  const _Figure(this.value, this.label, {this.attention = false}) : icon = null;
  const _Figure.icon(this.icon, this.label) : value = null, attention = false;
  final String? value;
  final IconData? icon;
  final String label;
  final bool attention;
}

class _FigureTile extends StatelessWidget {
  const _FigureTile(this.figure);
  final _Figure figure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = figure.attention ? orange : colors.primary;
    final scaler = MediaQuery.textScalerOf(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: figure.attention ? .12 : .07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // One height for a figure or an icon, so states swap in place.
          SizedBox(
            height: scaler.scale(28),
            child: Center(
              child: figure.icon != null
                  ? Icon(figure.icon, size: 22, color: tint)
                  : Text(
                      figure.value!,
                      maxLines: 1,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: figure.attention ? orange : null,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            figure.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stands in for the action while a scan runs: the same pill, with a bar
/// moving along its foot.
class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 48,
        color: colors.primary.withValues(alpha: .08),
        child: Stack(
          children: [
            Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                minHeight: 3,
                color: colors.primary,
                backgroundColor: Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyLine extends StatelessWidget {
  const _PrivacyLine();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 13,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            'Your messages never leave this phone',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
