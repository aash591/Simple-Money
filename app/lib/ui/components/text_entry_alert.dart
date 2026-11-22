import 'package:flutter/material.dart';

import 'confirmation_alert.dart';

/// The frosted [ConfirmationAlert] with one text field in it, for asking for
/// a short piece of text such as a name or a password. It sits above the
/// keyboard, with a character count and a clear button in the field. Save
/// stays grey until something is typed, unless [allowEmpty]. Returns the
/// trimmed text (empty if cleared), or null if canceled or dismissed.
///
/// [subject] is what the question is about, such as a file name, shown under
/// the message. [checkLabel] adds a tick box under the field, holding
/// [checked].
Future<String?> showTextEntryAlert(
  BuildContext context, {
  required String title,
  String? message,
  String? subject,
  String? hintText,
  String initialValue = '',
  String confirmLabel = 'Save',
  int maxLength = 32,
  bool sensitive = false,
  bool multiline = false,
  bool allowEmpty = false,
  TextInputType? keyboardType,
  String? checkLabel,
  ValueNotifier<bool>? checked,
}) async {
  var text = initialValue;
  // Not disposed here: the alert is still on screen while it fades out.
  final filled = ValueNotifier(allowEmpty || initialValue.trim().isNotEmpty);
  final saved = await showConfirmationAlert(
    context,
    title: title,
    content: _AlertTextField(
      initialValue: initialValue,
      message: message,
      subject: subject,
      hintText: hintText,
      maxLength: maxLength,
      sensitive: sensitive,
      multiline: multiline,
      allowEmpty: allowEmpty,
      keyboardType: keyboardType,
      checkLabel: checkLabel,
      checked: checked,
      onChanged: (value) {
        text = value;
        filled.value = allowEmpty || value.trim().isNotEmpty;
      },
    ),
    confirmLabel: confirmLabel,
    destructive: false,
    confirmEnabled: filled,
    autofocusCancel: false,
  );
  return saved ? text.trim() : null;
}

class _AlertTextField extends StatefulWidget {
  const _AlertTextField({
    required this.initialValue,
    required this.onChanged,
    required this.message,
    required this.subject,
    required this.hintText,
    required this.maxLength,
    required this.sensitive,
    required this.multiline,
    required this.allowEmpty,
    required this.keyboardType,
    this.checkLabel,
    this.checked,
  });
  final String initialValue;
  final ValueChanged<String> onChanged;
  final String? message, subject, hintText;
  final int maxLength;
  final bool sensitive, multiline, allowEmpty;
  final TextInputType? keyboardType;
  final String? checkLabel;
  final ValueNotifier<bool>? checked;

  @override
  State<_AlertTextField> createState() => _AlertTextFieldState();
}

class _AlertTextFieldState extends State<_AlertTextField> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initialValue,
  )..addListener(() => widget.onChanged(controller.text));

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  String? get message => widget.message;
  String? get subject => widget.subject;
  String? get hintText => widget.hintText;
  int get maxLength => widget.maxLength;
  bool get sensitive => widget.sensitive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final muted = textColor.withValues(alpha: .6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message != null)
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              letterSpacing: -0.1,
              height: 1.35,
              color: textColor.withValues(alpha: .85),
            ),
          ),
        if (subject != null) ...[
          const SizedBox(height: 10),
          Text(
            subject!,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
              color: textColor,
            ),
          ),
        ],
        const SizedBox(height: 18),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TextField(
            controller: controller,
            autofocus: true,
            maxLength: maxLength,
            // A password is typed as shown, so a slip is seen; the keyboard
            // just isn't asked to suggest or correct it.
            autocorrect: !sensitive,
            enableSuggestions: !sensitive,
            minLines: 1,
            maxLines: widget.multiline ? 5 : 1,
            keyboardType:
                widget.keyboardType ??
                (widget.multiline
                    ? TextInputType.multiline
                    : TextInputType.text),
            // Sentence case suits a name or note, not a password or address.
            textCapitalization: sensitive || widget.keyboardType != null
                ? TextCapitalization.none
                : TextCapitalization.sentences,
            textInputAction: widget.multiline
                ? TextInputAction.newline
                : TextInputAction.done,
            onSubmitted: widget.multiline
                ? null
                : (value) {
                    if (widget.allowEmpty || value.trim().isNotEmpty) {
                      Navigator.pop(context, true);
                    }
                  },
            cursorColor: theme.colorScheme.primary,
            style: TextStyle(fontSize: 18, color: textColor),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: TextStyle(fontSize: 18, color: muted),
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: textColor.withValues(alpha: .25)),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 1.5,
                ),
              ),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${controller.text.length}/$maxLength',
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                        IconButton(
                          tooltip: 'Clear',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.cancel, size: 22, color: muted),
                          onPressed: controller.clear,
                        ),
                      ],
                    ),
            ),
          ),
        ),
        if ((widget.checkLabel, widget.checked) case (
          final label?,
          final checked?,
        ))
          ValueListenableBuilder<bool>(
            valueListenable: checked,
            builder: (context, value, _) => InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => checked.value = !value,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    // Flush with the field's left edge.
                    SizedBox.square(
                      dimension: 20,
                      child: Checkbox(
                        value: value,
                        onChanged: (v) => checked.value = v ?? false,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          color: textColor.withValues(alpha: .85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
