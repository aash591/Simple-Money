import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../data/backup/data_transfer.dart';
import '../../../../state/sync_controller.dart';
import '../../../components/app_toast.dart';
import '../../../components/confirmation_alert.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import '../../../theme/app_theme.dart';

/// Export, import and delete — everything that moves or removes the ledger.
class DataScreen extends StatefulWidget {
  const DataScreen({super.key, required this.controller});
  final SyncController? controller;
  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  /// What is running, shown above the lists; null when idle.
  String? _working;

  String get _today => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _run(String label, Future<String?> Function() task) async {
    if (_working != null) return;
    setState(() => _working = label);
    showAppToast(context, label);
    try {
      final done = await task();
      if (done != null && mounted) {
        showAppToast(context, done, icon: Icons.check_rounded);
      }
    } catch (error) {
      if (mounted) {
        showAppToast(
          context,
          error is FormatException
              ? error.message
              : widget.controller!.describeError(
                  error,
                  'Something went wrong. Please try again.',
                ),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<String?> _save(String name, String mime, Uint8List bytes) async {
    final saved = await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      mimeType: mime,
    );
    return saved == null ? null : 'Saved $name';
  }

  void _exportAll(SyncController sync) => _run(
    'Preparing your export…',
    () async => _save(
      'simplemoney-$_today.json',
      'application/json',
      await exportLedger(sync.repository.db),
    ),
  );

  void _exportCsv(SyncController sync) => _run(
    'Preparing your spreadsheet…',
    () async => _save(
      'simplemoney-transactions-$_today.csv',
      'text/csv',
      await exportTransactionsCsv(sync.repository.db),
    ),
  );

  void _import(SyncController sync) => _run('Importing…', () async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    final data = parseLedgerExport(await file.readAsBytes());
    String count(String table, String noun) {
      final n = data.count(table);
      return '$n $noun${n == 1 ? '' : 's'}';
    }

    if (!mounted ||
        !await showConfirmationAlert(
          context,
          title: 'Import this file?',
          message:
              'It has ${count('accounts', 'account')} and '
              '${count('transactions', 'transaction')} from '
              '${DateFormat.yMMMd().format(data.updatedAt)}. They replace '
              'everything on this phone.',
          confirmLabel: 'Import',
        )) {
      return null;
    }
    await sync.importData(data);
    return 'Data imported';
  });

  Future<void> _eraseDevice(SyncController sync) async {
    if (!await showDeleteConfirmation(
      context,
      title: 'Delete data on this phone?',
      message: 'Deletes all accounts, transactions and budgets on this phone. Categories reset. Your Google Drive copy stays.',
    )) {
      return;
    }
    await _run('Deleting…', () async {
      await sync.eraseDevice();
      return 'Deleted from this phone';
    });
  }

  Future<void> _eraseDrive(SyncController sync) async {
    if (!await showDeleteConfirmation(
      context,
      title: 'Delete your Google Drive data?',
      message: 'Deletes your SimpleMoney data in Google Drive and turns off sync. Data on this phone stays.',
    )) {
      return;
    }
    await _run('Deleting from Google Drive…', () async {
      await sync.eraseDrive();
      return 'Deleted from Google Drive';
    });
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.controller;
    if (sync == null) {
      return const FeaturePage(
        title: 'Your data',
        child: Center(child: Text('Not available here.')),
      );
    }
    return FeaturePage(
      title: 'Your data',
      child: ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final idle = _working == null;
          final driveReady = sync.supported && sync.status?.email != null;
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
            children: [
              MenuGroup(
                label: 'Export & import',
                children: [
                  MenuRow(
                    icon: Icons.file_download_rounded,
                    title: 'Export all data',
                    subtitle: 'A file you can import later',
                    onTap: idle ? () => _exportAll(sync) : null,
                  ),
                  MenuRow(
                    icon: Icons.table_chart_rounded,
                    title: 'Export transactions',
                    subtitle: 'CSV for Excel or Google Sheets',
                    onTap: idle ? () => _exportCsv(sync) : null,
                  ),
                  MenuRow(
                    icon: Icons.file_upload_rounded,
                    title: 'Import from file',
                    subtitle: 'Replaces this phone’s data',
                    onTap: idle ? () => _import(sync) : null,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              MenuGroup(
                label: 'Delete',
                children: [
                  MenuRow(
                    icon: Icons.phone_android_rounded,
                    title: 'Delete data on this phone',
                    subtitle: 'Your Google Drive copy stays',
                    tint: coral,
                    onTap: idle ? () => _eraseDevice(sync) : null,
                  ),
                  MenuRow(
                    icon: Icons.cloud_off_rounded,
                    title: 'Delete data from Google Drive',
                    subtitle: driveReady
                        ? 'Also turns sync off'
                        : 'Sign in to sync to use this',
                    tint: coral,
                    onTap: idle && driveReady ? () => _eraseDrive(sync) : null,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
