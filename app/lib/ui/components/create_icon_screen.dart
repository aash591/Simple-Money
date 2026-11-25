import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/custom_icons.dart';
import 'action_buttons.dart';
import 'app_back_button.dart';
import 'app_icon.dart';
import 'app_toast.dart';
import 'common.dart';
import 'glass_surface.dart';
import 'secondary_header.dart';

/// The AI prompt for one new icon, in the same look as the built-in 3D set.
/// [name] is what the user typed; a placeholder shows until they type one.
String iconPromptFor(String name) {
  final what = name.trim().isEmpty ? '[icon name]' : name.trim();
  return 'Create one icon of "$what" for a money app.\n'
      '\n'
      '- Style: soft, rounded, glossy 3D render with gentle lighting and bright, '
      'friendly colors, like a set of app category icons.\n'
      '- One single object, centered, filling about 80% of the square. '
      'Nothing cropped.\n'
      '- Square image, 1:1, 1024 x 1024.\n'
      '- Transparent background (PNG with alpha). If you can\'t, use a plain '
      'pure white background: no gradient, no floor, no cast shadow.\n'
      '- No text, letters, border, frame or tile.';
}

/// Lets the user make their own 3D-style icon: type a name, copy the prompt
/// into ChatGPT (or any image AI), then upload the picture. It is saved in the
/// app's icon format under that name. Pops with the new icon key.
class CreateIconScreen extends StatefulWidget {
  const CreateIconScreen({super.key, this.pickImage});

  /// Stands in for the system file picker (tests).
  final Future<Uint8List?> Function()? pickImage;

  @override
  State<CreateIconScreen> createState() => _CreateIconScreenState();
}

class _CreateIconScreenState extends State<CreateIconScreen> {
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _hasName => CustomIcons.slug(_name.text).isNotEmpty;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: iconPromptFor(_name.text)));
    if (mounted) {
      showAppToast(context, 'Prompt copied', icon: Icons.copy_rounded);
    }
  }

  Future<Uint8List?> _pick() async {
    if (widget.pickImage != null) return widget.pickImage!();
    final files = await FilePicker.pickFiles(type: FileType.image);
    final path = files.firstOrNull?.path;
    return path == null ? null : File(path).readAsBytes();
  }

  Future<void> _upload() async {
    if (!_hasName) {
      showAppToast(
        context,
        'Type a name first',
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _pick();
      if (bytes == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final key = await CustomIcons.save(_name.text, bytes);
      if (!mounted) return;
      showAppToast(context, 'Icon saved', icon: Icons.check_rounded);
      Navigator.pop(context, key);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppToast(context, e.message, icon: Icons.info_outline_rounded);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppToast(
        context,
        'Couldn’t save that picture',
        icon: Icons.info_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return GlassPage(
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              SecondaryHeader(
                title: 'Add your own icon',
                leading: const AppBackButton(),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                      children: [
                        Text(
                          '1. Name your icon',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('icon-name'),
                          controller: _name,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: 30,
                          decoration: const InputDecoration(
                            hintText: 'e.g. Gym, Pet food, Haircut',
                            counterText: '',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '2. Copy this into ChatGPT or any image AI',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        MoneyCard(
                          child: SelectableText(
                            iconPromptFor(_name.text),
                            key: const Key('icon-prompt'),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 12),
                        PillButton(label: 'Copy prompt', onPressed: _copy),
                        const SizedBox(height: 20),
                        Text(
                          '3. Upload the picture it makes',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'We make it the right size, remove a plain '
                          'background, and save it with your name.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                        const SizedBox(height: 12),
                        PillButton(
                          label: _busy ? 'Saving…' : 'Upload icon',
                          primary: false,
                          loading: _busy,
                          onPressed: _busy ? null : _upload,
                        ),
                        if (CustomIcons.keys.value.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Text('Your icons', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final key in CustomIcons.keys.value)
                                Tooltip(
                                  message: CustomIcons.label(key),
                                  child: AppIcon(key, size: 48),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
