import 'package:flutter/material.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../../../data/bank_sms_parser.dart';
import '../../../../data/db/app_database.dart';
import '../../../../data/manual_sms_teacher.dart';
import '../../../../data/repositories/account_repository.dart';
import '../../../../domain/account.dart';
import '../../../../domain/bank_institution_icon.dart';
import '../../../../domain/currency_digits.dart';
import '../../../../state/account_store.dart';
import '../../../../state/main_currency_controller.dart';
import '../../../components/action_buttons.dart';
import '../../../components/adaptive_sheet.dart';
import '../../../components/app_icon.dart';
import '../../../components/card_action.dart';
import '../../../components/segmented_pill.dart';
import '../../../sms/sms_preview_content.dart';
import '../../../theme/sheet_colors.dart';
import '../../../transactions/quick_add_helpers.dart';

/// Teach the app [message] by hand: tap its amount, who was paid and the
/// account, say whether money went out or came in, and a rule is saved for
/// messages like it. Pops with how many messages the rule reads, or null.
/// [others] are more messages, so the rule is tried on those from the same
/// sender too.
Future<int?> showTeachSmsSheet(
  BuildContext context, {
  required AppDatabase database,
  required BankSms message,
  List<BankSms> others = const [],
  String? appName,
  Widget? preview,
  int? replacingRuleId,
}) => showAdaptiveSheet<int>(
  context,
  builder: (_) => TeachSmsSheet(
    database: database,
    message: message,
    others: others,
    appName: appName,
    preview: preview,
    replacingRuleId: replacingRuleId,
  ),
);

enum _Mark {
  amount('Amount', 'Tap the amount.'),
  payee('Paid to', 'Tap who was paid. Tap the next word to add it.'),
  account('Account', 'Tap the account or card digits. Optional.');

  const _Mark(this._label, this._hint);
  final String _label, _hint;

  /// The words for this mark, given which way the money went: the other
  /// party is who was paid when it went out, who paid when it came in.
  String label(bool? moneyOut) => this == payee
      ? switch (moneyOut) {
          true => 'Paid to',
          false => 'Received from',
          null => 'Name /\nmerchant',
        }
      : _label;

  String hint(bool? moneyOut) => this == payee
      ? switch (moneyOut) {
          true => 'Tap who was paid. Tap the next word to add it.',
          false => 'Tap who paid you. Tap the next word to add it.',
          null => 'Tap the name or merchant. Tap the next word to add it.',
        }
      : _hint;
}

/// One word of the message and where it sits in it.
class _Word {
  const _Word(this.text, this.start);
  final String text;
  final int start;
  int get end => start + text.length;
}

/// The message's words. A name a bank glued to a prefix with a dot, like
/// "Fv.ASHIQ,", splits after the dot so the name alone can be marked;
/// numbers such as "Rs.10.00" stay whole.
List<_Word> _splitWords(String body) {
  bool letter(String c) => c.toLowerCase() != c.toUpperCase();
  final words = <_Word>[];
  for (final m in RegExp(r'\S+').allMatches(body)) {
    final text = m.group(0)!;
    var from = 0;
    for (var i = 1; i < text.length - 1; i++) {
      if (text[i] == '.' && letter(text[i - 1]) && letter(text[i + 1])) {
        words.add(_Word(text.substring(from, i + 1), m.start + from));
        from = i + 1;
      }
    }
    words.add(_Word(text.substring(from), m.start + from));
  }
  return words;
}

/// A marked part of the message, by character offsets.
typedef _Span = ({int start, int end});

class TeachSmsSheet extends StatefulWidget {
  const TeachSmsSheet({
    super.key,
    required this.database,
    required this.message,
    this.others = const [],
    this.appName,
    this.preview,
    this.replacingRuleId,
  });
  final AppDatabase database;
  final BankSms message;
  final List<BankSms> others;

  /// For an app's notification: the app, which is the bank.
  final String? appName;

  /// The original, shown at the top in place of the sender: for an app's
  /// notification, the notification as it looked on the phone.
  final Widget? preview;

  /// Teaching this message again: the rule it was taught before is replaced.
  final int? replacingRuleId;

  @override
  State<TeachSmsSheet> createState() => _TeachSmsSheetState();
}

class _TeachSmsSheetState extends State<TeachSmsSheet> {
  String get _body => widget.message.body;
  late final _words = _splitWords(_body);

  _Mark _mode = _Mark.amount;
  _Span? _amount, _account;

  /// Who was paid, as a run of words: first and last word index.
  (int, int)? _payee;
  bool? _moneyOut;
  String? _currency;
  bool _busy = false;
  String? _error;

  /// For an app's notification, which carries no account number: the account
  /// the user chose for everything it sends. Optional: left out, each
  /// payment waits in review for the user to pick one.
  int? _accountId;
  late final _accounts = AccountStore(AccountRepository(widget.database));
  bool get _choosesAccount => widget.appName != null;

  @override
  void initState() {
    super.initState();
    if (_choosesAccount) _accounts.load();
  }

  @override
  void dispose() {
    _accounts.dispose();
    super.dispose();
  }

  /// The account chosen for an app's notifications, while it still exists.
  Account? get _chosenAccount =>
      _accountId == null ? null : _accounts.byId(_accountId);

  /// The chosen account as a card: its icon and name. Tapping it opens the
  /// choice again; the cross in its top-right corner takes the choice back.
  Widget _accountCard(Account a, SheetColors colors, ColorScheme scheme) {
    final tone = scheme.primary;
    return Stack(
      children: [
        Material(
          color: tone.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: const Key('teach-account-line'),
            borderRadius: BorderRadius.circular(12),
            onTap: _busy ? null : _pickAccount,
            child: Container(
              width: double.infinity,
              // Room on the right, so the name never runs under the cross.
              padding: const EdgeInsets.fromLTRB(10, 10, 38, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: tone.withValues(alpha: .35)),
              ),
              child: Row(
                children: [
                  AppIcon(a.icon, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 5,
          right: 5,
          child: Semantics(
            button: true,
            label: 'Remove ${a.name}',
            child: InkResponse(
              key: const Key('teach-account-clear'),
              radius: 18,
              onTap: _busy ? null : () => setState(() => _accountId = null),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: colors.card,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.divider),
                ),
                child: Icon(Icons.close_rounded, size: 15, color: colors.text),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Pick one of the user's accounts in this currency, or make a new one
  /// named after the app.
  Future<void> _pickAccount() async {
    final currency = _currency ?? _guessCurrency();
    final id = await showSmsAccountPicker(
      context,
      heading: _moneyOut == false ? 'Received in' : 'Paid from',
      selected: _accountId,
      items: accountChoiceItems(_accounts, currency: currency),
      onAdd: (context) async => (await addAccountAndSelect(
        context,
        _accounts,
        initialName: widget.appName,
        initialIcon: bankInstitutionIcon(widget.appName!),
        initialCurrency: currency,
      ))?.id,
    );
    if (id != null && mounted) setState(() => _accountId = id);
  }

  String? _text(_Span? span) =>
      span == null ? null : _body.substring(span.start, span.end);

  String? get _payeeText {
    final run = _payee;
    if (run == null) return null;
    final text = _body.substring(_words[run.$1].start, _words[run.$2].end);
    // Punctuation the message wraps a name in isn't part of it.
    return text.replaceAll(RegExp(r'^[^\w]+|[^\w)]+$'), '');
  }

  /// The balance the message states, as money, or null when it gives none.
  String? _balance(String currency) {
    final minor =
        smsMetadata(_body, sender: widget.message.sender)['balanceMinor']
            as int?;
    if (minor == null) return null;
    return formatAccountMoney(
      minor,
      digits: currencyDigits(currency),
      currency: currency,
    );
  }

  /// The currency the message names, else the person's main one.
  String _guessCurrency() {
    const symbols = {
      '₹': 'INR',
      'Rs': 'INR',
      'Rs.': 'INR',
      'Dhs': 'AED',
      'Ksh': 'KES',
      r'$': 'USD',
      '£': 'GBP',
      '€': 'EUR',
    };
    for (final word in _words) {
      final clean = word.text.replaceAll(RegExp(r'[\d.,:/\-]+$'), '');
      if (symbols[clean] case final code?) return code;
      final upper = clean.toUpperCase();
      if (upper.length == 3 && knownCurrencyCodes.contains(upper)) {
        return upper;
      }
      for (final MapEntry(key: symbol, value: code) in symbols.entries) {
        if (word.text.startsWith(symbol) && RegExp(r'\d').hasMatch(word.text)) {
          return code;
        }
      }
    }
    return MainCurrencyScope.maybeOf(context)?.code ?? 'INR';
  }

  /// Marks or unmarks word [index] for the field being marked.
  void _tap(int index) {
    final word = _words[index];
    setState(() {
      _error = null;
      switch (_mode) {
        case _Mark.amount:
          final number = RegExp(r'\d[\d,.]*\d|\d').firstMatch(word.text);
          if (number == null) {
            _error = 'That word has no number in it.';
            return;
          }
          final span = (
            start: word.start + number.start,
            end: word.start + number.end,
          );
          _amount = _amount == span ? null : span;
          // On to the next thing to mark.
          if (_amount != null && _payee == null) _mode = _Mark.payee;
        case _Mark.account:
          // The digits only: "A/c*3225" marks 3225, and the "A/c*" before them
          // stays as fixed text the rule looks for.
          final digits = RegExp(r'\d+').allMatches(word.text).lastOrNull;
          if (digits == null) {
            _error = 'An account has digits in it, like XX1234.';
            return;
          }
          final span = (
            start: word.start + digits.start,
            end: word.start + digits.end,
          );
          _account = _account == span ? null : span;
        case _Mark.payee:
          final run = _payee;
          if (run == null) {
            _payee = (index, index);
          } else if (index == run.$2 + 1) {
            _payee = (run.$1, index); // one more word after
          } else if (index == run.$1 - 1) {
            _payee = (index, run.$2); // one more word before
          } else if (index == run.$1 && index == run.$2) {
            _payee = null;
          } else if (index == run.$2) {
            _payee = (run.$1, index - 1);
          } else if (index == run.$1) {
            _payee = (index + 1, run.$2);
          } else {
            _payee = (index, index);
          }
      }
    });
  }

  _Mark? _markOf(int index) {
    final word = _words[index];
    bool inside(_Span? span) =>
        span != null && word.start < span.end && word.end > span.start;
    if (inside(_amount)) return _Mark.amount;
    if (inside(_account)) return _Mark.account;
    if (_payee case final run? when index >= run.$1 && index <= run.$2) {
      return _Mark.payee;
    }
    return null;
  }

  Color _tone(_Mark mark, ColorScheme scheme) => switch (mark) {
    _Mark.amount => scheme.primary,
    _Mark.payee => scheme.tertiary,
    _Mark.account => scheme.secondary,
  };

  /// How to mark [mark], right under its row and outside the card, only
  /// while that row is the one being marked.
  Widget _hintUnder(_Mark mark, SheetColors colors) {
    if (_mode != mark) return const SizedBox.shrink();
    final text = mark == _Mark.account && _choosesAccount
        ? 'Tap the account digits in the message, or choose one of your '
              'accounts.'
        : mark.hint(_moneyOut);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
      child: Text(
        text,
        key: const Key('teach-hint'),
        style: TextStyle(fontSize: 13, height: 1.35, color: colors.muted),
      ),
    );
  }

  TextStyle _valueStyle(SheetColors colors, bool set) => TextStyle(
    fontSize: 15,
    color: set ? colors.text : colors.muted,
    fontWeight: set ? FontWeight.w600 : FontWeight.w400,
  );

  Future<void> _teach() async {
    final amount = _text(_amount);
    final out = _moneyOut;
    if (amount == null || out == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final read = await ManualSmsTeacher(widget.database).teach(
        widget.message,
        SmsLabels(
          amount: amount,
          account: _text(_account),
          payee: _payeeText,
          moneyOut: out,
          currency: _currency ?? _guessCurrency(),
        ),
        others: widget.others,
        appName: widget.appName,
        // Account digits marked in the message win over a chosen account.
        accountId: _text(_account) == null ? _accountId : null,
        replacingRuleId: widget.replacingRuleId,
      );
      if (mounted) Navigator.pop(context, read);
    } on SmsTeachException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t save. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final currency = _currency ??= _guessCurrency();
    final amount = _text(_amount);
    final account = _text(_account);
    final payee = _payeeText;
    final labelWidth = _labelColumn(context, [
      for (final mark in _Mark.values) mark.label(_moneyOut),
    ]);
    return SheetPage(
      header: const SheetHeader('Teach this message'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The original, as it looked: for an SMS its sender; for an app's
          // notification, the notification itself (never the internal ID its
          // rules are saved under).
          // Faded: a preview of the original, not something to tap.
          (widget.preview != null
                  ? Opacity(opacity: .55, child: widget.preview)
                  : null) ??
              Text(
                widget.appName != null
                    ? 'Notification from ${widget.appName}'
                    : widget.message.sender,
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
          const SizedBox(height: 12),
          // The message, word by word: tap a word to mark it.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.control,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Wrap(
              spacing: 3,
              runSpacing: 4,
              children: [
                for (final (i, word) in _words.indexed)
                  _WordChip(
                    key: Key('teach-word-$i'),
                    text: word.text,
                    tone: switch (_markOf(i)) {
                      final mark? => _tone(mark, scheme),
                      null => null,
                    },
                    onTap: _busy ? null : () => _tap(i),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // What to do next, in words: it changes as each part is marked.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _moneyOut != null && amount != null
                    ? Icons.check_circle_rounded
                    : Icons.touch_app_rounded,
                size: 20,
                color: _moneyOut != null && amount != null
                    ? colors.income
                    : colors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  key: const Key('teach-next'),
                  _moneyOut == null
                      ? 'First, did money go out or come in?'
                      : amount == null
                      ? 'Now tap the amount in the message.'
                      : 'That’s enough. Tap Teach, or mark more below.',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedPill<bool>(
            segments: [
              PillSegment(
                true,
                'Money out',
                icon: Icons.north_east_rounded,
                tone: colors.expense,
              ),
              PillSegment(
                false,
                'Money in',
                icon: Icons.south_west_rounded,
                tone: colors.income,
              ),
            ],
            value: _moneyOut,
            onChanged: _busy ? null : (out) => setState(() => _moneyOut = out),
          ),
          const SizedBox(height: 14),
          // What will be read, one row each. Tap a row, then tap its words in
          // the message: its colour matches the words it marks.
          _FieldRow(
            key: const Key('teach-field-amount'),
            labelWidth: labelWidth,
            tone: _tone(_Mark.amount, scheme),
            label: _Mark.amount.label(_moneyOut),
            active: _mode == _Mark.amount,
            onTap: () => setState(() => _mode = _Mark.amount),
            child: Row(
              children: [
                Expanded(
                  // One line: shrinks rather than breaking the number.
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        amount == null
                            ? 'Tap it in the message'
                            : '${currencyPrefix(currency)}$amount',
                        key: const Key('teach-amount'),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: amount == null ? 15 : 24,
                          fontWeight: amount == null
                              ? FontWeight.w400
                              : FontWeight.w700,
                          color: amount == null ? colors.muted : colors.text,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: currency,
                  underline: const SizedBox.shrink(),
                  // Arrow right next to the code.
                  icon: const Align(
                    alignment: Alignment.centerRight,
                    widthFactor: .35,
                    child: Icon(Icons.arrow_drop_down),
                  ),
                  menuMaxHeight: 360,
                  items: [
                    for (final code in {
                      currency,
                      ...(knownCurrencyCodes.toList()..sort()),
                    })
                      DropdownMenuItem(value: code, child: Text(code)),
                  ],
                  onChanged: _busy
                      ? null
                      : (code) => setState(() {
                          _currency = code;
                          // An account is in one currency.
                          _accountId = null;
                        }),
                ),
              ],
            ),
          ),
          _hintUnder(_Mark.amount, colors),

          _FieldRow(
            key: const Key('teach-field-payee'),
            labelWidth: labelWidth,
            tone: _tone(_Mark.payee, scheme),
            label: _Mark.payee.label(_moneyOut),
            active: _mode == _Mark.payee,
            onTap: () => setState(() => _mode = _Mark.payee),
            child: Text(
              payee ?? 'Tap the name',
              textAlign: TextAlign.end,
              style: _valueStyle(colors, payee != null),
            ),
          ),
          _hintUnder(_Mark.payee, colors),

          _FieldRow(
            key: const Key('teach-field-account'),
            labelWidth: labelWidth,
            tone: _tone(_Mark.account, scheme),
            label: _Mark.account.label(_moneyOut),
            active: _mode == _Mark.account,
            onTap: () => setState(() => _mode = _Mark.account),
            child: switch ((account, _chosenAccount)) {
              // Digits marked in the message: they are the account.
              (final digits?, _) => Text(
                digits,
                textAlign: TextAlign.end,
                style: _valueStyle(colors, true),
              ),
              // An account of the user's, chosen for everything this app
              // sends: shown as a card. Tap it to choose another; the cross
              // takes it back.
              (_, final chosen?) when _choosesAccount => _accountCard(
                chosen,
                colors,
                scheme,
              ),
              // An app's notification names no account: choose one, or leave
              // it to the review.
              (_, _) when _choosesAccount => Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Optional · choose later',
                    maxLines: 1,
                    textAlign: TextAlign.end,
                    style: _valueStyle(colors, false),
                  ),
                  const SizedBox(height: 8),
                  // Shrinks to fit a narrow screen or large text, never clipped.
                  Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: CardAction(
                        key: const Key('teach-account-line'),
                        label: 'Choose account',
                        icon: Icons.account_balance_wallet_rounded,
                        color: scheme.primary,
                        onTap: _busy ? null : _pickAccount,
                      ),
                    ),
                  ),
                ],
              ),
              (_, _) => Text(
                'Optional · tap the digits',
                textAlign: TextAlign.end,
                style: _valueStyle(colors, false),
              ),
            },
          ),
          _hintUnder(_Mark.account, colors),
          // The balance after the payment: nothing to mark, the app finds it
          // itself. Shown so it is clear it is read.
          if (_balance(currency) case final balance?) ...[
            _FieldRow(
              key: const Key('teach-field-balance'),
              labelWidth: labelWidth,
              tone: colors.muted,
              label: 'Balance',
              active: false,
              onTap: () {},
              child: Text(
                balance,
                textAlign: TextAlign.end,
                style: _valueStyle(colors, true),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
              child: Text(
                'Found in the message by itself. Nothing to mark.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: colors.muted,
                ),
              ),
            ),
          ],

          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(fontSize: 13, color: scheme.error),
              ),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _busy ? null : () => Navigator.pop(context),
        primaryLabel: _busy
            ? 'Teaching…'
            : _moneyOut == null
            ? 'Choose money out or in'
            : amount == null
            ? 'Tap the amount'
            : 'Teach',
        onPrimary: amount != null && _moneyOut != null && !_busy
            ? _teach
            : null,
        primaryColor: colors.primary,
      ),
    );
  }
}

/// One word of the message, tinted when it is marked.
class _WordChip extends StatelessWidget {
  const _WordChip({
    super.key,
    required this.text,
    required this.tone,
    required this.onTap,
  });
  final String text;
  final Color? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final marked = tone != null;
    return Semantics(
      button: true,
      selected: marked,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          // A one-letter word ("M" in a name) is still easy to hit; every
          // other word is as wide as it is.
          constraints: const BoxConstraints(minWidth: 28, minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          decoration: BoxDecoration(
            color: marked ? tone!.withValues(alpha: .18) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          // Sized to the word, so it doesn't stretch to fill the row.
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              text,
              style: TextStyle(
                fontSize: 15.5,
                height: 1.35,
                color: marked ? tone : colors.text,
                fontWeight: marked ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How a row's name is drawn.
const _fieldLabelStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600);

/// The width of the widest of [labels], so the values line up right after
/// their names instead of after the longest name there could be.
double _labelColumn(BuildContext context, List<String> labels) {
  var widest = 0.0;
  // The label is drawn in the app's font, so measure it in that too.
  final style = DefaultTextStyle.of(context).style.merge(_fieldLabelStyle);
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    if (painter.width > widest) widest = painter.width;
  }
  // A little over: rounding must never wrap a name.
  return widest.ceilToDouble() + 2;
}

/// One thing the rule will read: a colour dot (the colour of its words in the
/// message), its name and what was marked, or what to do. The one being
/// marked is outlined and says how; tapping a row chooses it.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.tone,
    required this.label,
    required this.active,
    required this.onTap,
    required this.child,
    required this.labelWidth,
  });
  final Color tone;
  final String label;

  /// Shared by the rows, so their values line up.
  final double labelWidth;
  final bool active;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: active,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              color: active ? tone.withValues(alpha: .08) : colors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active ? tone : colors.divider,
                width: active ? 1.5 : 1,
              ),
            ),
            child: Row(
              // The dot, the name and the value share one centre line,
              // whatever height the value is (a big amount, a card).
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: tone,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    label,
                    style: _fieldLabelStyle.copyWith(color: colors.muted),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
