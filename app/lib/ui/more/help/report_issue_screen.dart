import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../data/issue_report.dart';
import '../../components/action_buttons.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/feature_page.dart';
import '../settings/sync/backup_widgets.dart' show ErrorBanner;

/// Help › Send feedback: what went wrong or could be better, an optional file
/// (a screenshot, say) up to 30 MB, and how to reach the user.
class ReportIssueScreen extends StatefulWidget {
  const ReportIssueScreen({super.key, this.reporter, this.pickFiles});

  /// For tests.
  final IssueReporter? reporter;
  final Future<List<PlatformFile>> Function()? pickFiles;

  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  late final IssueReporter _reporter = widget.reporter ?? IssueReporter();
  final _text = TextEditingController();
  final _contact = TextEditingController();
  final _files = <PlatformFile>[];
  final _sizes = <int>[];
  bool _sending = false;

  /// How much of the attachment has gone, 0 to 1; null before it starts.
  double? _progress;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _contact.dispose();
    super.dispose();
  }

  bool get _canSend => _text.text.trim().isNotEmpty && !_sending;

  /// Anything typed or attached would be lost by leaving.
  bool get _hasDraft =>
      _text.text.trim().isNotEmpty ||
      _contact.text.trim().isNotEmpty ||
      _files.isNotEmpty;

  Future<void> _confirmLeave() async {
    final sending = _sending;
    final leave = await showConfirmationAlert(
      context,
      title: sending ? 'Stop sending?' : 'Discard feedback?',
      message: sending
          ? 'Your feedback is still being sent. If you leave now, it won’t arrive.'
          : 'Your feedback will be discarded if you leave this page.',
      confirmLabel: 'Leave',
    );
    if (!leave || !mounted) return;
    // It may have finished while the question was open.
    if (_sending) _reporter.cancel();
    Navigator.of(context).pop();
  }

  int get _totalSize => _sizes.fold(0, (sum, size) => sum + size);

  Future<void> _attach() async {
    try {
      final picked = await (widget.pickFiles ?? FilePicker.pickFiles)();
      if (picked.isEmpty) return;
      final sizes = [for (final file in picked) await file.length()];
      if (!mounted) return;
      if (_files.length + picked.length > maxReportFiles) {
        setState(() => _error = 'You can attach up to 10 files.');
        return;
      }
      if (_totalSize + sizes.fold(0, (sum, size) => sum + size) >
          maxReportFileBytes) {
        setState(
          () => _error = 'Attachments can add up to 30 MB. Pick smaller ones.',
        );
        return;
      }
      setState(() {
        _files.addAll(picked);
        _sizes.addAll(sizes);
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t open that file.');
    }
  }

  void _remove(int index) => setState(() {
    _files.removeAt(index);
    _sizes.removeAt(index);
  });

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _progress = null;
      _error = null;
    });
    try {
      await _reporter.send(
        _text.text,
        contact: _contact.text,
        files: List.of(_files),
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      setState(() => _sending = false);
      await showNoticeAlert(
        context,
        title: 'Thank you!',
        message: 'Your feedback was sent. It helps us make Simple Money better.',
      );
      if (mounted) Navigator.of(context).pop();
    } on IssueReportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final hint = theme.textTheme.bodyMedium?.copyWith(color: muted);
    return PopScope(
      canPop: !_hasDraft && !_sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: FeaturePage(
      title: 'Send feedback',
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                  child: Text(
                    'Tell us what went wrong or what you’d like improved. A screenshot or recording helps.',
                    style: hint?.copyWith(height: 1.4),
                  ),
                ),
                MoneyCard(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _text,
                        enabled: !_sending,
                        minLines: 6,
                        maxLines: 12,
                        maxLength: 4000,
                        textCapitalization: TextCapitalization.sentences,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'Describe your issue',
                          border: InputBorder.none,
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final (i, file) in _files.indexed)
                        _fileRow(theme, i, file),
                      if (_files.length < maxReportFiles)
                        _attachRow(theme, muted),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                MoneyCard(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Contact info', style: theme.textTheme.titleMedium),
                      TextField(
                        controller: _contact,
                        enabled: !_sending,
                        onChanged: (_) => setState(() {}),
                        keyboardType: TextInputType.emailAddress,
                        maxLength: 120,
                        decoration: const InputDecoration(
                          hintText: 'Phone number or email (optional)',
                          border: InputBorder.none,
                          counterText: '',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_sending) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      // A file has a known length; text alone is too quick to track.
                      value: _files.isEmpty ? null : _progress,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _files.isEmpty
                        ? 'Sending…'
                        : _progress == null
                        ? 'Starting…'
                        : _progress! >= 1
                        ? 'Almost done…'
                        : 'Sending… ${(_progress! * 100).floor()}%',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  ErrorBanner(_error!),
                ],
                const SizedBox(height: 12),
                PillButton(
                  label: 'Submit',
                  loading: _sending,
                  onPressed: _canSend ? _send : null,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }

  /// The picture button at the foot of the box, with what it takes.
  Widget _attachRow(ThemeData theme, Color muted) => InkWell(
    onTap: _sending ? null : _attach,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.add_photo_alternate_outlined, color: muted, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _files.isEmpty ? 'Add attachment' : 'Add another',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ),
          Text(
            _files.isEmpty
                ? 'Up to 30 MB'
                : '${_size(_totalSize)} of 30 MB',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    ),
  );

  Widget _fileRow(ThemeData theme, int index, PlatformFile file) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(Icons.insert_drive_file_rounded, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 15),
              ),
              Text(_size(_sizes[index]), style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Remove ${file.name}',
          onPressed: _sending ? null : () => _remove(index),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
}
