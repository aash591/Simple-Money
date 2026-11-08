import 'package:flutter/material.dart';

import '../theme/sheet_colors.dart';

/// The outlined, card-filled text field for typing inside a sheet, with an
/// always-floating label and a character counter. Autofocused by default,
/// since a sheet showing one usually exists just to type into it.
class SheetTextField extends StatelessWidget {
  const SheetTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.maxLength,
    this.hintText,
    this.multiline = false,
    this.autofocus = true,
    this.textInputAction,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final int maxLength;
  final String? hintText;
  final bool multiline;
  final bool autofocus;

  /// Defaults to a new line when [multiline], otherwise Done.
  final TextInputAction? textInputAction;

  /// Defaults to multiline or plain text.
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      autofocus: autofocus,
      maxLength: maxLength,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 5 : 1,
      keyboardType:
          keyboardType ??
          (multiline ? TextInputType.multiline : TextInputType.text),
      textInputAction:
          textInputAction ??
          (multiline ? TextInputAction.newline : TextInputAction.done),
      textCapitalization: TextCapitalization.sentences,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: TextStyle(fontSize: 16, color: colors.text),
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        filled: true,
        fillColor: colors.card,
        border: border(colors.outline),
        enabledBorder: border(colors.outline),
        focusedBorder: border(colors.primary, 1.5),
      ),
    );
  }
}
