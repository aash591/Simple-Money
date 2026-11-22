import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/agent/agent_suggestion_repository.dart';
import '../../../data/statements/pending_statement_files.dart';
import '../../components/action_buttons.dart';
import '../../components/app_toast.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../theme/app_theme.dart';

/// What to paste to Claude or ChatGPT to set up a new statement layout.
/// Most people don't know what to ask, and the words matter little to the
/// AI as long as it's pointed at the layouts waiting for columns.
const statementLayoutPrompt =
    'Set up the new statement layout in my SimpleMoney app. Look at the '
    'statements waiting for columns, work out which column is which, and '
    'send it as a suggestion for me to approve.';

/// The same request, naming the file.
String statementLayoutPromptFor(String fileName) =>
    'Set up the layout of “$fileName” in my SimpleMoney app. Look at the '
    'statements waiting for columns, work out which column is which, and '
    'send it as a suggestion for me to approve.';

/// One card for a layout the app can't read: ask the AI, see when its
/// suggestion arrives, and approve it right here. Nothing else to open.
class StatementAiCard extends StatefulWidget {
  const StatementAiCard({
    super.key,
    required this.repository,
    required this.signature,
    required this.fileName,
    required this.onApproved,
    this.pagePictures,
    this.onlyWhenReady = false,
    this.saved = false,
    this.onAsk,
  });
  final AgentSuggestionRepository repository;

  /// Draws the PDF's first pages, for a PDF: the user can let their AI see
  /// them, which shows it the real columns.
  final Future<List<Uint8List>> Function()? pagePictures;

  /// The layout's [tableSignature]: the suggestion for it is named by this.
  final String signature;
  final String fileName;

  /// The layout was approved and saved: read the file with it.
  final VoidCallback onApproved;

  /// Shown only while the AI's suggestion waits for approval, with the
  /// file's name: for a list of files, as on the Import statement page.
  final bool onlyWhenReady;

  /// The layout is already saved: the card offers to fix it.
  final bool saved;

  /// Called before the request is copied: makes sure the AI can see this
  /// file, which a saved layout's file no longer is.
  final Future<void> Function()? onAsk;

  @override
  State<StatementAiCard> createState() => _StatementAiCardState();
}

class _StatementAiCardState extends State<StatementAiCard> {
  Timer? _timer;
  AgentSuggestion? _ready;
  bool _asked = false, _busy = false, _done = false;

  /// Pictures of the pages were shared with the AI.
  bool _pictures = false;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_done || _busy) return;
    try {
      final all = await widget.repository.load(
        statuses: {AgentSuggestionStatus.pending},
        limit: 50,
      );
      final found = all
          .where(
            (s) =>
                s.kind == AgentSuggestionKind.statementLayout &&
                s.target == widget.signature,
          )
          .firstOrNull;
      if (mounted && found?.id != _ready?.id) setState(() => _ready = found);
    } catch (_) {
      // Checked again in a moment.
    }
  }

  /// Asks once whether the AI may see the pages, and keeps their pictures
  /// on the phone for it if so.
  Future<void> _offerPictures() async {
    final draw = widget.pagePictures;
    if (draw == null || _asked) return;
    final allow = await showConfirmationAlert(
      context,
      title: 'Show your AI the pages?',
      message:
          'It then sees the first 2 pages as pictures, so it gets the '
          'columns right. They show everything on them: your name, address, '
          'account number and payments.',
      confirmLabel: 'Show pages',
      cancelLabel: 'Text only',
      destructive: false,
    );
    if (!allow || !mounted) return;
    try {
      final pictures = await draw();
      await PendingStatementFiles().savePictures(widget.signature, pictures);
      if (mounted) setState(() => _pictures = pictures.isNotEmpty);
    } catch (_) {
      if (mounted) {
        showAppToast(
          context,
          'Couldn’t make the pictures. Your AI gets the text.',
          icon: Icons.info_outline_rounded,
        );
      }
    }
  }

  Future<void> _ask() async {
    try {
      await widget.onAsk?.call();
    } catch (_) {
      // The request still goes; the AI says if it can't see the file.
    }
    if (!mounted) return;
    await _offerPictures();
    if (!mounted) return;
    await Clipboard.setData(
      ClipboardData(text: statementLayoutPromptFor(widget.fileName)),
    );
    if (!mounted) return;
    setState(() => _asked = true);
    showAppToast(context, 'Copied. Paste it in your AI app.');
  }

  Future<void> _approve(AgentSuggestion suggestion) async {
    setState(() => _busy = true);
    final error = await widget.repository.apply(suggestion.id);
    if (!mounted) return;
    if (error != null) {
      setState(() => _busy = false);
      showAppToast(context, error, icon: Icons.error_outline_rounded);
      return;
    }
    setState(() {
      _busy = false;
      _done = true;
      _ready = null;
    });
    _timer?.cancel();
    widget.onApproved();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _ready;
    if (widget.onlyWhenReady && ready == null) return const SizedBox.shrink();
    final title = widget.onlyWhenReady
        ? 'Your AI set up ${widget.fileName}'
        : _done
        ? 'Layout saved'
        : ready != null
        ? 'Your AI set this up'
        : widget.saved
        ? 'Reading this wrong? Your AI can fix it'
        : 'Let your AI set this up';
    final card = MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_done)
            Text(
              'The columns below use it. Check them, then continue.',
              style: theme.textTheme.bodySmall,
            )
          else if (ready != null) ...[
            for (final line in ready.detail)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(line, style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 12),
            PillButton(
              label: _busy
                  ? 'Saving…'
                  : widget.onlyWhenReady
                  ? 'Approve and import'
                  : 'Approve layout',
              onPressed: _busy ? null : () => _approve(ready),
            ),
          ] else ...[
            Text(
              _asked
                  ? 'Waiting for your AI… Paste the request in Claude or '
                        'ChatGPT. Its answer shows up here.'
                        '${_pictures ? ' It can see the first 2 pages.' : ''}'
                  : widget.pagePictures != null
                  ? 'Your AI can see the first 2 pages, if you allow it. '
                        'Nothing changes until you approve.'
                  : 'Your AI sees only the column names and 5 example rows. '
                        'Nothing changes until you approve.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            PillButton(
              label: _asked ? 'Copy again' : 'Ask my AI',
              primary: !_asked,
              onPressed: _ask,
            ),
            const SizedBox(height: 8),
            Text(
              'Needs a session: More › AI assistant',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
    return widget.onlyWhenReady
        ? Padding(padding: const EdgeInsets.only(bottom: 12), child: card)
        : card;
  }
}

/// Help for a statement layout the app can't read yet: a prompt to copy,
/// what the AI does and doesn't get to see, and the way to the AI assistant.
/// [onOpenAi] opens it; without it the path is written out.
class StatementAiHelp extends StatelessWidget {
  const StatementAiHelp({super.key, this.onOpenAi});
  final VoidCallback? onOpenAi;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: statementLayoutPrompt));
    if (context.mounted) {
      showAppToast(context, 'Prompt copied', icon: Icons.copy_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Start an AI session here, then paste this in Claude or ChatGPT. '
          'Not sure what to ask? This works:',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Material(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: .6,
          ),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _copy(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Text(
                      statementLayoutPrompt,
                      style: TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                    semanticLabel: 'Copy prompt',
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        _Reassurance(
          Icons.table_chart_outlined,
          'It sees only the column names and up to 5 example rows. Never '
          'the whole file.',
          muted,
        ),
        _Reassurance(
          Icons.timer_outlined,
          'Only while a session is on, and only the AI app you connected.',
          muted,
        ),
        _Reassurance(
          Icons.verified_user_outlined,
          'It can only suggest. Nothing changes until you approve. The '
          'examples are removed from your phone once the layout is saved.',
          muted,
        ),
        _Reassurance(
          Icons.bolt_rounded,
          'Your file waits on this phone. Once you approve, it imports in '
          'one tap: no need to pick it again.',
          muted,
        ),
        if (onOpenAi != null) ...[
          const SizedBox(height: 12),
          PillButton(
            label: 'Go to AI session',
            primary: false,
            onPressed: onOpenAi,
          ),
        ] else ...[
          const SizedBox(height: 6),
          Text(
            'Start a session: More › AI assistant',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _Reassurance extends StatelessWidget {
  const _Reassurance(this.icon, this.text, this.color);
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: color, height: 1.35),
          ),
        ),
      ],
    ),
  );
}
