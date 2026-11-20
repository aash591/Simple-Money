import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/loan.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_icon.dart';
import '../../theme/sheet_colors.dart';

extension LoanKindIcon on LoanKind {
  IconData get icon => const [
    Icons.home_outlined,
    Icons.directions_car_outlined,
    Icons.two_wheeler_outlined,
    Icons.person_outline,
    Icons.school_outlined,
    Icons.diamond_outlined,
    Icons.credit_card,
    Icons.account_balance_outlined,
  ][index];
}

String loanMoney(LoanTerms terms, int value) =>
    formatAccountMoney(value, digits: terms.digits, currency: terms.currency);
String loanDate(DateTime date) => DateFormat('d MMM yyyy').format(date);
String loanError(Object error) => error is ArgumentError
    ? '${error.message}'
    : error is StateError
    ? error.message
    : 'Could not save this loan. Please try again.';

class LoanValue extends StatelessWidget {
  const LoanValue(this.label, this.value, {super.key});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final labelWidget = Text(label, style: theme.textTheme.bodySmall);
        final valueStyle = theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        );
        if (constraints.maxWidth < 260 ||
            MediaQuery.textScalerOf(context).scale(14) > 19) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              labelWidget,
              const SizedBox(height: 5),
              Text(value, textAlign: TextAlign.end, style: valueStyle),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: labelWidget),
            const SizedBox(width: 16),
            Expanded(
              child: Text(value, textAlign: TextAlign.end, style: valueStyle),
            ),
          ],
        );
      },
    ),
  );
}

/// A field for typing into a loan form: an outlined, card-filled box with
/// its [label] always above it, as [SheetTextField] draws one, so it reads
/// as somewhere to type rather than another line of text.
///
/// [placeholder] shows inside the empty box (what leaving it blank means),
/// [prefix] before what is typed (the currency), and [hint] a short note
/// under the box.
class LoanField extends StatelessWidget {
  const LoanField(
    this.controller,
    this.label, {
    super.key,
    this.numeric = true,
    this.hint,
    this.placeholder,
    this.prefix,
    this.onChanged,
  });
  final TextEditingController controller;
  final String label;
  final bool numeric;
  final String? hint;
  final String? placeholder;
  final String? prefix;
  final VoidCallback? onChanged;
  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: controller,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        textCapitalization: numeric
            ? TextCapitalization.none
            : TextCapitalization.words,
        textInputAction: TextInputAction.done,
        maxLength: numeric ? 16 : 40,
        onChanged: (_) => onChanged?.call(),
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colors.text,
        ),
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          hintText: placeholder,
          hintStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: colors.muted,
          ),
          prefixText: prefix == null ? null : '$prefix ',
          prefixStyle: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.muted,
          ),
          helperText: hint,
          helperMaxLines: 3,
          helperStyle: TextStyle(fontSize: 12.5, color: colors.muted),
          counterText: '',
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
          filled: true,
          fillColor: colors.card,
          border: border(colors.outline),
          enabledBorder: border(colors.outline),
          focusedBorder: border(colors.primary, 1.5),
        ),
      ),
    );
  }
}

class LoanFormActions extends StatelessWidget {
  const LoanFormActions({
    super.key,
    required this.saving,
    required this.label,
    required this.onSave,
    required this.onBack,
    this.error,
  });
  final bool saving;
  final String label;
  final VoidCallback? onSave;
  final VoidCallback onBack;
  final String? error;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: LoanNote(error!, error: true),
        ),
      ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: saving ? null : onBack,
        primaryLabel: saving ? 'Saving...' : label,
        onPrimary: saving ? null : onSave,
      ),
    ],
  );
}

/// A consistent group for loan details and forms inside the shared sheets.
class LoanSection extends StatelessWidget {
  const LoanSection({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: SheetCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Text(title!, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
            ],
            ...children,
          ],
        ),
      ),
    ),
  );
}

class LoanNote extends StatelessWidget {
  const LoanNote(this.text, {super.key, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final color = error ? colors.expense : colors.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Semantics(
        liveRegion: error,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: color, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LoanIdentity extends StatelessWidget {
  const LoanIdentity(this.loan, {super.key});
  final Loan loan;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20, top: 4),
    child: Row(
      children: [
        BadgedAppIcon(
          loan.icon,
          badgeKey: loan.icon == loan.terms.icon ? null : loan.terms.icon,
          size: 48,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loan.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                loan.terms.mode.label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
