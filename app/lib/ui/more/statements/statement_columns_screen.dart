import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/agent/agent_suggestion_repository.dart';
import '../../../data/agent/statement_samples.dart';

import '../../../data/repositories/statement_import_repository.dart';
import '../../../data/statements/pending_statement_files.dart';
import '../../../data/statements/statement_table.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../domain/account.dart';
import '../../../state/sync_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../theme/app_theme.dart';
import 'statement_ai_help.dart';
import 'statement_review_screen.dart';
import 'statement_widgets.dart';

/// Shows how a CSV or Excel statement's columns were read — with the rows as
/// they'll import, directions included — lets the user fix any column, and
/// continues to the shared review. Pops with what the import did.
class StatementColumnsScreen extends StatefulWidget {
  const StatementColumnsScreen({
    super.key,
    required this.sync,
    required this.rows,
    required this.fileName,
    required this.initial,
    this.source = UpiStatementSource.csv,
    this.remembered = false,
    this.step,
    this.pagePictures,
  });
  final SyncController sync;
  final List<List<String>> rows;
  final String fileName;

  /// [UpiStatementSource.csv] or [UpiStatementSource.excel].
  final UpiStatementSource source;

  /// The saved mapping for this layout, or the guessed one.
  final TableMapping initial;
  final bool remembered;

  /// Where this file is among several imported together ("2 of 4").
  final String? step;

  /// A PDF's first pages as pictures, for the user's AI if they allow it.
  final Future<List<Uint8List>> Function()? pagePictures;

  @override
  State<StatementColumnsScreen> createState() => _StatementColumnsScreenState();
}

class _StatementColumnsScreenState extends State<StatementColumnsScreen> {
  List<List<String>> get rows => widget.rows;
  late TableMapping mapping = widget.initial;
  late TableParseResult result = _parse(mapping);

  TableParseResult _parse(TableMapping mapping) =>
      parseStatementTable(rows, mapping, source: widget.source);
  late final int columnCount = rows
      .take(200)
      .fold(0, (widest, row) => math.max(widest, row.length));

  void _update(TableMapping next) => setState(() {
    mapping = next;
    result = _parse(next);
  });

  List<String> get _header =>
      rows.elementAtOrNull(mapping.headerRow) ?? const [];

  static String _letter(int index) {
    var name = '';
    for (var i = index + 1; i > 0; i = (i - 1) ~/ 26) {
      name = String.fromCharCode(65 + (i - 1) % 26) + name;
    }
    return name;
  }

  String _columnName(int index) {
    final name = _header.elementAtOrNull(index)?.trim() ?? '';
    return name.isEmpty ? 'Column ${_letter(index)}' : name;
  }

  String _sample(int index) =>
      rows
          .skip(mapping.headerRow + 1)
          .map((r) => r.elementAtOrNull(index)?.trim() ?? '')
          .where((v) => v.isNotEmpty)
          .firstOrNull ??
      'Empty';

  String _fieldValue(TableField field) {
    final column = mapping[field];
    return column == null
        ? 'None'
        : '${_letter(column)} · ${_columnName(column)}';
  }

  Future<void> _pickColumn(TableField field) async {
    final picked = await showChoiceListSheet<int>(
      context,
      title: field.label,
      selected: mapping[field] ?? -1,
      items: [
        const ChoiceItem(
          value: -1,
          icon: Icon(Icons.block_rounded, size: 20),
          label: 'None',
        ),
        for (var i = 0; i < columnCount; i++)
          ChoiceItem(
            value: i,
            icon: Text(
              _letter(i),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            label: _columnName(i),
            subtitle: _sample(i),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    _update(mapping.withColumn(field, picked < 0 ? null : picked));
  }

  Future<void> _pickAmountStyle() async {
    final separate = await showChoiceListSheet<bool>(
      context,
      title: 'Amounts',
      selected: mapping.usesDebitCredit,
      items: const [
        ChoiceItem(
          value: false,
          icon: Icon(Icons.looks_one_outlined, size: 20),
          label: 'One amount column',
          subtitle: 'With a sign, Dr/Cr, or a direction column',
        ),
        ChoiceItem(
          value: true,
          icon: Icon(Icons.swap_vert_rounded, size: 20),
          label: 'Separate money out and money in',
          subtitle: 'Withdrawal and deposit columns',
        ),
      ],
    );
    if (separate == null || separate == mapping.usesDebitCredit || !mounted) {
      return;
    }
    _update(
      separate
          ? mapping.withColumn(TableField.amount, null)
          : mapping
                .withColumn(TableField.debit, null)
                .withColumn(TableField.credit, null),
    );
  }

  Future<void> _pickDateOrder() async {
    final picked = await showChoiceListSheet<DateOrder>(
      context,
      title: 'Date format',
      selected: mapping.dateOrder,
      items: [
        for (final order in DateOrder.values)
          ChoiceItem(
            value: order,
            icon: const Icon(Icons.calendar_today_outlined, size: 20),
            label: order == DateOrder.auto
                ? 'Auto-detect · ${result.dateOrder.label.split(' · ').first}'
                : order.label,
          ),
      ],
    );
    if (picked != null && mounted) _update(mapping.copyWith(dateOrder: picked));
  }

  Future<void> _pickFallback() async {
    final picked = await showChoiceListSheet<UpiStatementDirection>(
      context,
      title: 'Rows with no direction',
      selected: mapping.fallback,
      items: const [
        ChoiceItem(
          value: UpiStatementDirection.debit,
          icon: Icon(Icons.north_east_rounded, color: coral, size: 20),
          label: 'Payments',
        ),
        ChoiceItem(
          value: UpiStatementDirection.credit,
          icon: Icon(Icons.south_west_rounded, color: green, size: 20),
          label: 'Money received',
        ),
      ],
    );
    if (picked != null && mounted) _update(mapping.copyWith(fallback: picked));
  }

  void _moveHeader(int delta) {
    final row = (mapping.headerRow + delta).clamp(0, rows.length - 1);
    if (row == mapping.headerRow) return;
    _update(
      guessMapping(
        rows,
        row,
      ).copyWith(dateOrder: mapping.dateOrder, fallback: mapping.fallback),
    );
  }

  /// The AI's layout was approved: read this file with it.
  Future<void> _useSavedLayout() async {
    try {
      final saved = await StatementImportRepository(widget.sync.repository.db)
          .knownMappings();
      final found = findSavedMapping(rows, saved);
      if (found != null && mounted) _update(found);
    } catch (_) {
      // The columns stay as they were; the user can still set them.
    }
  }

  Future<void> _continue() async {
    final statement = result.statement;
    try {
      await StatementImportRepository(widget.sync.repository.db)
          .saveColumnMapping(tableSignature(_header), mapping.toJson());
      await StatementSampleRepository().remove(tableSignature(_header));
      // Set up by hand here, so it isn't waiting for a one-tap import.
      unawaited(
        PendingStatementFiles()
            .remove(tableSignature(_header))
            .catchError((_) {}),
      );
    } catch (_) {
      // Only a convenience for the next file.
    }
    if (!mounted) return;
    final done = await Navigator.of(context).push<StatementImportResult>(
      FeatureRoute(
        StatementReviewScreen(
          sync: widget.sync,
          statement: statement,
          step: widget.step,
        ),
      ),
    );
    if (done != null && mounted) Navigator.pop(context, done);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = mapping.isComplete && result.statement.rows.isNotEmpty;
    final fields = [TableField.date, TableField.time, TableField.description];
    final amountFields = mapping.usesDebitCredit
        ? [TableField.debit, TableField.credit]
        : [TableField.amount, TableField.direction];
    return FeaturePage(
      title: widget.step == null
          ? '${widget.source.label} columns'
          : '${widget.source.label} columns · ${widget.step}',
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    widget.remembered
                        ? 'Using the columns you chose last time for '
                              '${widget.fileName}’s layout.'
                        : 'Check the columns of ${widget.fileName}. Fixes are '
                              'remembered for next time.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 12),
                // Shown for a saved layout too: one saved wrong is fixed
                // the same way.
                StatementAiCard(
                  repository: AgentSuggestionRepository(
                    widget.sync.repository.db,
                  ),
                  signature: tableSignature(_header),
                  fileName: widget.fileName,
                  onApproved: _useSavedLayout,
                  pagePictures: widget.pagePictures,
                  saved: widget.remembered,
                  // A saved layout's file was taken off the AI's list.
                  onAsk: () =>
                      rememberNewLayout(widget.fileName, rows, widget.source),
                ),
                const SizedBox(height: 12),
                if (widget.source == UpiStatementSource.bank) ...[
                  _statementCard(),
                  const SizedBox(height: 12),
                ],
                _tablePreview(context),
                const StatementSectionLabel('Columns'),
                MoneyCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final field in fields) ...[
                        if (field != fields.first) const StatementRowDivider(),
                        _fieldRow(field),
                      ],
                      const StatementRowDivider(),
                      StatementPickerRow(
                        icon: const Icon(Icons.calendar_month_outlined),
                        title: 'Date format',
                        value: mapping.dateOrder == DateOrder.auto
                            ? 'Auto · ${result.dateOrder.label}'
                            : mapping.dateOrder.label,
                        missing: false,
                        onTap: _pickDateOrder,
                      ),
                    ],
                  ),
                ),
                const StatementSectionLabel('Amounts'),
                MoneyCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      StatementPickerRow(
                        icon: const Icon(Icons.payments_outlined),
                        title: 'Layout',
                        value: mapping.usesDebitCredit
                            ? 'Separate money out and money in'
                            : 'One amount column',
                        missing: false,
                        onTap: _pickAmountStyle,
                      ),
                      for (final field in amountFields) ...[
                        const StatementRowDivider(),
                        _fieldRow(field),
                      ],
                      if (result.undirected > 0) ...[
                        const StatementRowDivider(),
                        StatementPickerRow(
                          icon: const Icon(
                            Icons.help_outline_rounded,
                            color: orange,
                          ),
                          title:
                              '${result.undirected} '
                              'row${result.undirected == 1 ? ' has' : 's have'} '
                              'no direction · treat as',
                          value:
                              mapping.fallback == UpiStatementDirection.credit
                              ? 'Money received'
                              : 'Payments',
                          missing: false,
                          onTap: _pickFallback,
                        ),
                      ],
                    ],
                  ),
                ),
                const StatementSectionLabel('Optional'),
                MoneyCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      _fieldRow(TableField.reference),
                      const StatementRowDivider(),
                      _fieldRow(TableField.account),
                      const StatementRowDivider(),
                      _fieldRow(TableField.balance),
                    ],
                  ),
                ),
                const StatementSectionLabel('How the rows read'),
                _results(context),
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
                  label: 'Continue',
                  onPressed: ready ? _continue : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the PDF says it is, read from above its table.
  Widget _statementCard() {
    final account = result.account;
    final holder = result.statement.owner.names
        .map(
          (n) => n
              .split(' ')
              .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
              .join(' '),
        )
        .join(', ');
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          StatementPickerRow(
            icon: const Icon(Icons.account_balance_outlined),
            title: 'Account',
            value: account?.label ?? 'Not found · you’ll choose it next',
            missing: false,
            onTap: null,
          ),
          if (holder.isNotEmpty) ...[
            const StatementRowDivider(),
            StatementPickerRow(
              icon: const Icon(Icons.person_outline_rounded),
              title: 'Account holder',
              value: holder,
              missing: false,
              onTap: null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _fieldRow(TableField field) {
    final required =
        field == TableField.date ||
        field == TableField.amount ||
        (mapping.usesDebitCredit &&
            !mapping.columns.containsKey(TableField.debit) &&
            !mapping.columns.containsKey(TableField.credit) &&
            (field == TableField.debit || field == TableField.credit));
    return StatementPickerRow(
      icon: Text(
        mapping[field] == null ? '–' : _letter(mapping[field]!),
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
      title: field.label,
      value: _fieldValue(field),
      missing: required && mapping[field] == null,
      onTap: () => _pickColumn(field),
    );
  }

  Widget _tablePreview(BuildContext context) {
    final theme = Theme.of(context);
    final shown = [
      _header,
      ...rows
          .skip(mapping.headerRow + 1)
          .where((r) => r.any((c) => c.trim().isNotEmpty))
          .take(4),
    ];
    Widget cell(String text, {bool bold = false}) => SizedBox(
      width: 112,
      child: Padding(
        padding: const EdgeInsets.only(right: 10, bottom: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: bold ? FontWeight.w700 : null,
            color: bold ? theme.colorScheme.onSurface : null,
          ),
        ),
      ),
    );
    return MoneyCard(
      padding: const EdgeInsets.fromLTRB(18, 10, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Header row ${mapping.headerRow + 1}',
                  style: theme.textTheme.titleMedium?.copyWith(fontSize: 15),
                ),
              ),
              IconButton(
                tooltip: 'Header row up',
                onPressed: mapping.headerRow > 0 ? () => _moveHeader(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton(
                tooltip: 'Header row down',
                onPressed: mapping.headerRow < rows.length - 1
                    ? () => _moveHeader(1)
                    : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < columnCount; i++)
                      cell(_letter(i), bold: true),
                  ],
                ),
                for (final (n, row) in shown.indexed)
                  Row(
                    children: [
                      for (var i = 0; i < columnCount; i++)
                        cell(row.elementAtOrNull(i) ?? '', bold: n == 0),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    final theme = Theme.of(context);
    final parsed = result.statement.rows;
    final summary = !mapping.isComplete
        ? 'Choose the Date and Amount columns.'
        : '${parsed.length} transaction${parsed.length == 1 ? '' : 's'} '
              'found${result.skipped == 0 ? '' : ' · ${result.skipped} '
                        'row${result.skipped == 1 ? '' : 's'} skipped '
                        '(totals, balances or notes)'}';
    String money(int minor) =>
        formatAccountMoney(minor, digits: 2, currency: 'INR');
    final breaks = mapping.isComplete ? result.balanceBreaks : null;
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(summary, style: theme.textTheme.bodySmall),
          if (breaks != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  breaks == 0
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: breaks == 0 ? green : orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    breaks == 0
                        ? 'Every row adds up to the balance beside it.'
                        : '${breaks == 1 ? '1 row doesn’t' : '$breaks rows don’t'} '
                              'add up to the balance beside '
                              '${breaks == 1 ? 'it' : 'them'}. Check the '
                              'amount columns, or that money out and in '
                              'aren’t swapped.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          for (final row in parsed.take(5)) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.counterparty,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        DateFormat(
                          row.date.hour == 12 && row.date.minute == 0
                              ? 'd MMM y'
                              : 'd MMM y, h:mm a',
                        ).format(row.date),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  switch (row.direction) {
                    UpiStatementDirection.credit =>
                      '+${money(row.amountMinor)}',
                    UpiStatementDirection.debit => '−${money(row.amountMinor)}',
                    UpiStatementDirection.selfTransfer =>
                      '⇄ ${money(row.amountMinor)}',
                  },
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 15,
                    color: row.direction == UpiStatementDirection.credit
                        ? green
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens a CSV or Excel file's column screen, with the mapping saved for its
/// layout when there is one.
Future<StatementImportResult?> openStatementColumns(
  BuildContext context,
  SyncController sync,
  List<List<String>> rows,
  String fileName,
  UpiStatementSource source, {
  Future<List<Uint8List>> Function()? pagePictures,
}) async {
  if (rows.every((r) => r.every((c) => c.trim().isEmpty))) {
    showAppToast(
      context,
      'This file is empty.',
      icon: Icons.info_outline_rounded,
    );
    return null;
  }
  final saved = await StatementImportRepository(sync.repository.db)
      .knownMappings();
  final remembered = findSavedMapping(rows, saved);
  if (remembered == null) await rememberNewLayout(fileName, rows, source);
  if (!context.mounted) return null;
  return Navigator.of(context).push<StatementImportResult>(
    FeatureRoute(
      StatementColumnsScreen(
        sync: sync,
        rows: rows,
        fileName: fileName,
        source: source,
        initial: remembered ?? guessMapping(rows),
        remembered: remembered != null,
        pagePictures: pagePictures,
      ),
    ),
  );
}
