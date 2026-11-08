import 'package:flutter/material.dart';

import '../../../data/repositories/statement_import_repository.dart';
import '../../../data/statements/pending_statement_files.dart';
import '../../../data/statements/statement_table.dart';
import '../../../state/sync_controller.dart';
import '../../components/common.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import 'statement_file.dart';

/// The Import statement page: says which files can be read and opens the
/// file picker. A PDF, CSV or Excel file each goes to its own import, and
/// all of them end in the same review; several picked together are taken
/// one after another.
class StatementStartScreen extends StatefulWidget {
  const StatementStartScreen({super.key, required this.sync, this.onOpenAi});
  final SyncController sync;

  /// Opens the AI assistant, which can set up a layout the app can't read.
  final VoidCallback? onOpenAi;

  @override
  State<StatementStartScreen> createState() => _StatementStartScreenState();
}

class _StatementStartScreenState extends State<StatementStartScreen> {
  /// A chosen file is being read, which for a long PDF takes a moment.
  bool _reading = false;

  /// Files kept on the phone whose layout has since been set up.
  List<(PendingStatementFile, TableMapping)> _ready = const [];

  @override
  void initState() {
    super.initState();
    _loadReady();
  }

  Future<void> _loadReady() async {
    try {
      final saved = await StatementImportRepository(widget.sync.repository.db)
          .knownMappings();
      final ready = await PendingStatementFiles().ready(saved);
      if (mounted) setState(() => _ready = ready);
    } catch (_) {
      // Only a shortcut: the files can still be picked.
    }
  }

  Future<void> _choose() async {
    await importStatement(
      context,
      widget.sync,
      onOpenAi: widget.onOpenAi,
      onReading: (reading) {
        if (mounted) setState(() => _reading = reading);
      },
    );
    await _loadReady();
  }

  Future<void> _importReady(
    PendingStatementFile file,
    TableMapping mapping,
  ) async {
    await importPendingStatement(context, widget.sync, file, mapping);
    await _loadReady();
  }

  Widget _readyCard(BuildContext context) {
    final theme = Theme.of(context);
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
            child: Text('Ready to import', style: theme.textTheme.titleSmall),
          ),
          for (final (file, mapping) in _ready)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              leading: const Icon(Icons.task_alt_rounded),
              title: Text(
                file.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('Layout set up · no need to pick it again'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _importReady(file, mapping),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FeaturePage(
    title: 'Import statement',
    child: EmptyState(
      icon: Icons.receipt_long_outlined,
      title: 'Import your statements.',
      message:
          'Pick one file or several for the same months: your bank, credit '
          'card, Google Pay, PhonePe or Paytm. PDF, CSV or Excel. A payment '
          'that’s in two files, or already here, is added once.',
      actions: [
        if (_ready.isNotEmpty) ...[
          _readyCard(context),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          // A second tap while reading is ignored by the import itself.
          onPressed: _choose,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: _reading
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    strokeCap: StrokeCap.round,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                )
              : const Icon(Icons.upload_file_rounded),
          label: Text(_reading ? 'Reading file…' : 'Choose files'),
        ),
      ],
    ),
  );
}
