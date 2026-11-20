import 'package:flutter/material.dart';

import '../../theme/sheet_colors.dart';
import '../adaptive_sheet.dart';
import '../../transactions/transaction_widgets.dart' show SuggestionChips;
import '../segmented_pill.dart';

/// One way a review sheet can record a transaction, for its "Record as"
/// switch.
class ReviewKind<T extends Object> {
  const ReviewKind(this.value, this.label, this.icon);
  final T value;
  final String label;
  final IconData icon;
}

/// The body of a review sheet: what kind of movement this is, its amount,
/// title and date, a "Record as" switch, the tappable choices, and the text
/// it came from. Shared by SMS review, statement rows and editing a saved
/// transaction, so all three read the same.
///
/// Amount, title and date become tappable when given a callback.
class TransactionReviewContent<T extends Object> extends StatelessWidget {
  const TransactionReviewContent({
    super.key,
    required this.badge,
    required this.color,
    required this.badgeIcon,
    required this.amount,
    required this.title,
    required this.date,
    required this.kinds,
    required this.kind,
    required this.onKindChanged,
    required this.rows,
    this.onEditAmount,
    this.onEditTitle,
    this.onEditDate,
    this.titleText,
    this.onTitleChanged,
    this.titleSuggestions,
    this.helper,
    this.notice,
    this.sourceHeading = 'Original message',
    this.sourceIcon = Icons.sms_outlined,
    this.sourceDetail,
    this.sourceText,
    this.error,
  });

  /// "Money paid", "Money received", "Credit card repayment"…
  final String badge;
  final Color color;
  final IconData badgeIcon;
  final String amount, title, date;
  final VoidCallback? onEditAmount, onEditTitle, onEditDate;

  /// Edit the title in place, with a cursor, instead of through [onEditTitle].
  /// See [TransactionReviewHeader.titleText].
  final String? titleText;
  final ValueChanged<String>? onTitleChanged;
  final List<String> Function(String text)? titleSuggestions;

  /// The "Record as" choices; one choice hides the switch.
  final List<ReviewKind<T>> kinds;
  final T kind;

  /// Null disables the switch.
  final ValueChanged<T>? onKindChanged;

  /// A note under the switch, only when the choice needs explaining.
  final String? helper;

  /// Shown above the choices, such as which loan owns this transaction.
  final Widget? notice;

  /// The tappable choice rows, already separated by dividers.
  final List<Widget> rows;

  /// The text the transaction was read from; hidden when empty.
  final String sourceHeading;
  final IconData sourceIcon;
  final String? sourceDetail, sourceText;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final text = sourceText?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TransactionReviewHeader(
          badge: badge,
          color: color,
          badgeIcon: badgeIcon,
          amount: amount,
          title: title,
          date: date,
          onEditAmount: onEditAmount,
          onEditTitle: onEditTitle,
          onEditDate: onEditDate,
          titleText: titleText,
          onTitleChanged: onTitleChanged,
          titleSuggestions: titleSuggestions,
        ),
        if (notice != null) ...[const SizedBox(height: 12), notice!],
        if (kinds.length > 1) ...[
          const SizedBox(height: 14),
          Text(
            'Record as',
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SegmentedPill<T>(
            segments: [
              for (final kind in kinds)
                PillSegment(kind.value, kind.label, icon: kind.icon),
            ],
            value: kind,
            onChanged: onKindChanged,
          ),
        ],
        if (helper != null) ...[
          const SizedBox(height: 8),
          Text(helper!, style: TextStyle(color: colors.muted, fontSize: 13)),
        ],
        const SizedBox(height: 10),
        SheetCard(child: Column(children: rows)),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(sourceIcon, size: 16, color: colors.muted),
              const SizedBox(width: 6),
              Text(
                sourceHeading,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sourceDetail ?? '',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.control,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              text,
              style: TextStyle(color: colors.muted, fontSize: 13, height: 1.4),
            ),
          ),
        ],
        if (error != null)
          Text(error!, style: TextStyle(color: colors.expense)),
      ],
    );
  }
}

/// One choice row of a review card. A [locked] row shows a lock where the
/// chevron would be and can't be tapped.
class ReviewChoiceRow extends StatelessWidget {
  const ReviewChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.detail,
    this.locked = false,
    this.topAligned = false,
  });

  final String label;
  final String value;
  final String? detail;
  final Widget icon;
  final VoidCallback? onTap;
  final bool locked;

  /// Keeps the icon and chevron at the top, for values that run over
  /// several lines (a note).
  final bool topAligned;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return ListTile(
      isThreeLine: topAligned,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      minVerticalPadding: 6,
      leading: SizedBox(width: 36, height: 40, child: Center(child: icon)),
      title: Text(label, style: TextStyle(color: colors.muted, fontSize: 12)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              color: colors.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail != null)
            Text(detail!, style: TextStyle(color: colors.muted, fontSize: 12)),
        ],
      ),
      trailing: Icon(
        locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
        color: colors.muted,
        size: locked ? 16 : 20,
      ),
      onTap: locked ? null : onTap,
    );
  }
}

/// The top of a transaction sheet: what kind of movement this is, then its
/// amount, title and date. Shared by the review sheets and the saved
/// transaction's view, so they read the same. Amount, title and date show a
/// pen and become tappable when given a callback.
class TransactionReviewHeader extends StatelessWidget {
  const TransactionReviewHeader({
    super.key,
    required this.badge,
    required this.color,
    required this.badgeIcon,
    required this.amount,
    required this.title,
    required this.date,
    this.onEditAmount,
    this.onEditTitle,
    this.onEditDate,
    this.titleText,
    this.onTitleChanged,
    this.titleSuggestions,
  });
  final String badge;
  final Color color;
  final IconData badgeIcon;
  final String amount, title, date;
  final VoidCallback? onEditAmount, onEditTitle, onEditDate;

  /// With [onTitleChanged], tapping the title puts a cursor in it right there
  /// ([titleText] is what is typed so far, [title] what shows when it is
  /// empty), and [titleSuggestions] offers past titles as it is typed.
  final String? titleText;
  final ValueChanged<String>? onTitleChanged;
  final List<String> Function(String text)? titleSuggestions;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    Widget editable(Widget child, VoidCallback? onTap, String label) =>
        onTap == null
        ? child
        : Semantics(
            button: true,
            label: 'Edit $label',
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: child,
              ),
            ),
          );
    // A small pen after a tappable line, as tall as its text, says it can be
    // edited.
    Widget pen(Widget text, double size, Color color, VoidCallback? onTap) =>
        onTap == null
        ? text
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: text),
              const SizedBox(width: 5),
              Icon(Icons.edit_outlined, size: size, color: color),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(badgeIcon, size: 14, color: color),
                const SizedBox(width: 5),
                Text(
                  badge,
                  textAlign: TextAlign.center,
                  textHeightBehavior: const TextHeightBehavior(
                    applyHeightToFirstAscent: false,
                    applyHeightToLastDescent: false,
                  ),
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: editable(
            _centeredAmount(
              context,
              amount,
              Theme.of(context).textTheme.headlineLarge?.copyWith(
                color: colors.text,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
            onEditAmount,
            'amount',
          ),
        ),
        Center(
          child: onTitleChanged != null && titleText != null
              ? _InlineTitle(
                  title: title,
                  text: titleText!,
                  onChanged: onTitleChanged!,
                  suggestions: titleSuggestions,
                )
              : editable(
                  pen(
                    Text(
                      title,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    15,
                    colors.muted,
                    onEditTitle,
                  ),
                  onEditTitle,
                  'title',
                ),
        ),
        const SizedBox(height: 4),
        Center(
          child: editable(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_rounded, size: 16, color: colors.text),
                const SizedBox(width: 6),
                Flexible(
                  child: pen(
                    Text(
                      date,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    14,
                    colors.text,
                    onEditDate,
                  ),
                ),
              ],
            ),
            onEditDate,
            'date',
          ),
        ),
      ],
    );
  }
}

/// The title under the amount, edited where it stands: tapping it turns it
/// into a field with a cursor, and past titles that fit what is typed are
/// offered below it.
class _InlineTitle extends StatefulWidget {
  const _InlineTitle({
    required this.title,
    required this.text,
    required this.onChanged,
    this.suggestions,
  });
  final String title, text;
  final ValueChanged<String> onChanged;
  final List<String> Function(String text)? suggestions;

  @override
  State<_InlineTitle> createState() => _InlineTitleState();
}

class _InlineTitleState extends State<_InlineTitle> {
  late final _controller = TextEditingController(text: widget.text);
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing && mounted) {
        setState(() => _editing = false);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  void _typed(String value) {
    widget.onChanged(value);
    setState(() {});
  }

  void _pick(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _typed(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final style = TextStyle(
      color: colors.text,
      fontSize: 15,
      fontWeight: FontWeight.w500,
    );
    if (!_editing) {
      return Semantics(
        button: true,
        label: 'Edit title',
        child: InkWell(
          onTap: _start,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    style: style,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 5),
                Icon(Icons.edit_outlined, size: 15, color: colors.muted),
              ],
            ),
          ),
        ),
      );
    }
    final suggestions = widget.suggestions?.call(_controller.text) ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          style: style,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          maxLength: 50,
          maxLines: 1,
          cursorColor: colors.primary,
          buildCounter: (
            _, {
            required currentLength,
            required isFocused,
            maxLength,
          }) => null,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            hintText: widget.title,
            hintStyle: style.copyWith(color: colors.muted),
            contentPadding: const EdgeInsets.symmetric(vertical: 2),
          ),
          onChanged: _typed,
          onSubmitted: (_) => _focus.unfocus(),
        ),
        if (suggestions.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SuggestionChips(values: suggestions, onPick: _pick),
          ),
      ],
    );
  }
}

/// [amount] shifted so its figures sit at the centre and the currency symbol
/// hangs off to their left, instead of the symbol pushing the number
/// off-centre. Anything that is not a symbol followed by a plain figure (a
/// transfer's "a → b", a very long amount) is centred whole.
Widget _centeredAmount(BuildContext context, String amount, TextStyle? style) {
  // Centred as a whole (symbol included), so it lines up with the badge,
  // title and date above and below it.
  return Text(amount, style: style, textAlign: TextAlign.center);
}
