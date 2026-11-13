import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/statement_import_repository.dart';
import '../../../data/statements/statement_table.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../state/ad_gate.dart';
import '../../../state/sync_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../theme/app_theme.dart';
import 'statement_ai_help.dart';
import 'statement_columns_screen.dart';
import 'statement_file.dart';
import 'statement_review_screen.dart';
import 'statement_widgets.dart';

/// Several statements imported together — the bank's, a card's, Google
/// Pay's or PhonePe's for the same months. Each file is read first, so the
/// list says what the app found in it, then reviewed one after another.
/// Every review is held against what the files before it added, so a
/// payment that's in two files is recorded once and a transfer between
/// two of the user's accounts is joined up. Payment apps go first: their
/// payee names are the clearest, and the bank's rows then find them.
///
/// A layout the app hasn't seen is set up once, by the user or their AI
/// assistant ([onOpenAi]). Pops with what all the files added.
/// A picked file: its name, and a way to read it.
typedef StatementPick = ({String name, Future<Uint8List> Function() read});

class StatementBatchScreen extends StatefulWidget {
  const StatementBatchScreen({
    super.key,
    required this.sync,
    required this.files,
    this.onOpenAi,
  });
  final SyncController sync;
  final List<StatementPick> files;
  final VoidCallback? onOpenAi;

  @override
  State<StatementBatchScreen> createState() => _StatementBatchScreenState();
}

enum _Stage { reading, ready, newLayout, done, skipped, unread }

class _Item {
  _Item(this.file);
  final StatementPick file;
  StatementFile? read;
  _Stage stage = _Stage.reading;
  StatementImportResult? result;
}

const _appSources = {
  UpiStatementSource.googlePay,
  UpiStatementSource.phonePe,
  UpiStatementSource.paytm,
};

class _StatementBatchScreenState extends State<StatementBatchScreen> {
  late List<_Item> items = [for (final f in widget.files) _Item(f)];
  bool running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readAll());
  }

  Future<void> _readAll() async {
    // One at a time: a locked PDF asks for its password in turn.
    for (final item in items) {
      if (!mounted) return;
      await _read(item);
    }
    if (!mounted) return;
    setState(() {
      // Payment apps first, then the other files that read, as picked;
      // new layouts after them (the AI may set them up meanwhile), and
      // what can't be read at the end.
      int rank(_Item i) => switch (i.read) {
        ReadStatement(:final statement)
            when _appSources.contains(statement.source) =>
          0,
        ReadStatement() => 1,
        NewLayoutStatement() => 2,
        _ => 3,
      };
      items = [
        for (final r in [0, 1, 2, 3]) ...items.where((i) => rank(i) == r),
      ];
    });
  }

  Future<void> _read(_Item item) async {
    setState(() => item.stage = _Stage.reading);
    final StatementFile read;
    try {
      final bytes = await item.file.read();
      if (!mounted) return;
      read = await readStatementFile(
        context,
        widget.sync,
        item.file.name,
        bytes,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          item.read = UnreadStatement(
            item.file.name,
            'This file could not be opened.',
          );
          item.stage = _Stage.unread;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      item.read = read;
      item.stage = switch (read) {
        ReadStatement() => _Stage.ready,
        NewLayoutStatement() => _Stage.newLayout,
        UnreadStatement() => _Stage.unread,
      };
    });
  }

  bool _waiting(_Item i) =>
      i.stage == _Stage.ready ||
      i.stage == _Stage.newLayout ||
      i.stage == _Stage.skipped;

  bool get _stillReading => items.any((i) => i.stage == _Stage.reading);
  int get _left => items.where(_waiting).length;
  bool get _started =>
      items.any((i) => i.stage == _Stage.done || i.stage == _Stage.skipped);

  /// Opens each waiting file in turn; stops when the user steps back out
  /// of one, which then waits to be opened again.
  Future<void> _run() async {
    if (running) return;
    setState(() => running = true);
    try {
      for (final item in [...items]) {
        if (!mounted) return;
        if (!_waiting(item)) continue;
        final result = await _open(item);
        if (!mounted) return;
        setState(() {
          item.result = result;
          item.stage = result == null ? _Stage.skipped : _Stage.done;
        });
        if (result == null) break;
      }
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  Future<StatementImportResult?> _open(_Item item) async {
    final waiting = items.where((i) => _waiting(i) || i.stage == _Stage.done);
    final position = waiting.toList().indexOf(item) + 1;
    final step = '$position of ${waiting.length}';
    // A new layout set up meanwhile (by the AI, approved in the app) is
    // read with the columns now saved for it.
    if (item.read case NewLayoutStatement(:final rows, :final source)) {
      if (await StatementImportRepository(widget.sync.repository.db)
              .mappingFor(rows)
          case final mapping?) {
        final statement = parseStatementTable(
          rows,
          mapping,
          source: source,
        ).statement;
        if (statement.rows.isNotEmpty) {
          item.read = ReadStatement(item.file.name, statement);
        }
      }
      if (!mounted) return null;
    }
    return switch (item.read) {
      ReadStatement(:final statement) =>
        Navigator.of(context).push<StatementImportResult>(
          FeatureRoute(
            StatementReviewScreen(
              sync: widget.sync,
              statement: statement,
              step: step,
            ),
          ),
        ),
      NewLayoutStatement(:final rows, :final source, :final name) =>
        Navigator.of(context).push<StatementImportResult>(
          FeatureRoute(
            StatementColumnsScreen(
              sync: widget.sync,
              rows: rows,
              fileName: name,
              source: source,
              initial: guessMapping(rows),
              step: step,
            ),
          ),
        ),
      _ => null,
    };
  }

  Future<void> _tap(_Item item) async {
    if (running) return;
    switch (item.stage) {
      case _Stage.unread:
        // A locked PDF the user stepped past, or a file they've since
        // fixed: read it again.
        await _read(item);
      case _Stage.ready || _Stage.newLayout || _Stage.skipped:
        setState(() => running = true);
        try {
          final result = await _open(item);
          if (!mounted) return;
          setState(() {
            item.result = result;
            item.stage = result == null ? item.stage : _Stage.done;
          });
        } finally {
          if (mounted) setState(() => running = false);
        }
      case _Stage.reading || _Stage.done:
        break;
    }
  }

  StatementImportResult get _total => (
    added: items.fold(0, (n, i) => n + (i.result?.added ?? 0)),
    linked: items.fold(0, (n, i) => n + (i.result?.linked ?? 0)),
    already: items.fold(0, (n, i) => n + (i.result?.already ?? 0)),
  );

  void _finish() {
    final total = _total;
    Navigator.pop<StatementImportResult>(context, total);
    // One import, however many files: never an ad between them.
    if (total.added > 0 || total.linked > 0) {
      unawaited(AdGate.instance.after(AdMoment.statementImport));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layouts = items.where((i) => i.stage == _Stage.newLayout).length;
    final skippedLayouts = items
        .where((i) => i.stage == _Stage.skipped && i.read is NewLayoutStatement)
        .length;
    final needAi = layouts + skippedLayouts;
    final left = _left;
    return FeaturePage(
      title: 'Import statements',
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    _stillReading
                        ? 'Reading your files…'
                        : 'Each file is checked against what’s already here, '
                              'so a payment in two files is added once. '
                              'Payment apps go first: their names are '
                              'clearest.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const StatementSectionLabel('Files'),
                MoneyCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final (i, item) in items.indexed) ...[
                        if (i > 0) const StatementRowDivider(),
                        _FileRow(item: item, onTap: () => _tap(item)),
                      ],
                    ],
                  ),
                ),
                if (needAi > 0) ...[
                  const SizedBox(height: 16),
                  _AiCard(count: needAi, onOpenAi: widget.onOpenAi),
                ],
                if (_started && left == 0) ...[
                  const SizedBox(height: 16),
                  _Summary(total: _total),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: SizedBox(
                width: double.infinity,
                child: PillButton(
                  label: _stillReading
                      ? 'Reading…'
                      : left == 0
                      ? 'Done'
                      : _started
                      ? 'Continue · $left left'
                      : 'Import ${left == 1 ? '1 file' : '$left files'}',
                  loading: _stillReading,
                  onPressed: _stillReading || running
                      ? null
                      : left == 0
                      ? _finish
                      : _run,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.item, required this.onTap});
  final _Item item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final read = item.read;
    final title = switch (read) {
      ReadStatement(:final statement)
          when statement.source != UpiStatementSource.csv &&
              statement.source != UpiStatementSource.excel =>
        '${statement.source.label} · ${item.file.name}',
      _ => item.file.name,
    };
    final (Widget icon, String status, Color? color) = switch (item.stage) {
      _Stage.reading => (
        const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        'Reading…',
        null,
      ),
      _Stage.ready => (
        const Icon(Icons.description_outlined),
        _found((read as ReadStatement).statement),
        null,
      ),
      _Stage.newLayout => (
        const Icon(Icons.table_chart_outlined, color: orange),
        'New layout · set it up once',
        orange,
      ),
      _Stage.done => (
        const Icon(Icons.check_circle_rounded, color: green),
        switch (describeImport(item.result!)) {
          '' => 'Nothing new',
          final said => said,
        },
        green,
      ),
      _Stage.skipped => (
        const Icon(Icons.pause_circle_outline_rounded),
        'Not imported yet · tap to open',
        null,
      ),
      _Stage.unread => (
        const Icon(Icons.info_outline_rounded, color: coral),
        (read as UnreadStatement).message,
        null,
      ),
    };
    final tappable = item.stage != _Stage.reading && item.stage != _Stage.done;
    return StatementFileRow(
      icon: icon,
      title: title,
      status: status,
      statusColor: color,
      onTap: tappable ? onTap : null,
      theme: theme,
    );
  }

  static String _found(UpiStatement statement) {
    final dates = statement.rows.map((r) => r.date).toList()..sort();
    final format = DateFormat('d MMM yyyy');
    final n = statement.rows.length;
    return '$n transaction${n == 1 ? '' : 's'} · '
        '${format.format(dates.first)} – ${format.format(dates.last)}';
  }
}

/// A file in the list: what it is, and where its import stands.
class StatementFileRow extends StatelessWidget {
  const StatementFileRow({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.onTap,
    required this.theme,
    this.statusColor,
  });
  final Widget icon;
  final String title, status;
  final Color? statusColor;
  final VoidCallback? onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            SizedBox(width: 30, height: 30, child: Center(child: icon)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: statusColor,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    ),
  );
}

/// For layouts the app hasn't seen: the AI assistant can learn them.
class _AiCard extends StatelessWidget {
  const _AiCard({required this.count, required this.onOpenAi});
  final int count;
  final VoidCallback? onOpenAi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_outlined, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  count == 1
                      ? 'Let AI set up the new layout'
                      : 'Let AI set up the $count new layouts',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Set the columns yourself by opening the file, or ask your AI '
            'assistant to suggest them for you to approve. Then import the '
            'file again.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          StatementAiHelp(onOpenAi: onOpenAi),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.total});
  final StatementImportResult total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final said = describeImport(total);
    return MoneyCard(
      child: Row(
        children: [
          const Icon(Icons.task_alt_rounded, color: green),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              said.isEmpty
                  ? 'All done. Nothing new to add.'
                  : 'All done. $said.',
              style: theme.textTheme.titleMedium?.copyWith(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
