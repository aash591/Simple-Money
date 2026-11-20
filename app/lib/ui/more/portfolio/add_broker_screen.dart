import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/bank_institution_icon.dart';
import '../../../domain/currency.dart';
import '../../../state/account_store.dart';
import '../../components/action_buttons.dart';
import '../../components/app_icon.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/currency_flag.dart';
import '../../components/feature_page.dart';
import '../../components/select_icon_screen.dart';
import '../accounts/currency_screen.dart';

/// Adds a broker or investing platform, laid out like adding an account:
/// name with its icon, currency, then the cash already there. Pops with the
/// new broker's account id.
class AddBrokerScreen extends StatefulWidget {
  const AddBrokerScreen({super.key, required this.accounts});
  final AccountStore accounts;

  @override
  State<AddBrokerScreen> createState() => _AddBrokerScreenState();
}

class _AddBrokerScreenState extends State<AddBrokerScreen> {
  final _name = TextEditingController();
  final _cash = TextEditingController();
  String _currency = 'INR';
  int _digits = 2;
  String? _territory = 'IN';
  String? _icon;

  /// Once an icon is picked by hand, typing no longer changes it.
  bool _iconChosen = false;

  /// The name this screen filled in from a logo, so choosing a different
  /// logo can replace it while a name typed by hand is left alone.
  String? _autoName;
  String? _error;
  bool _saving = false, _leaving = false, _asking = false;

  @override
  void dispose() {
    _name.dispose();
    _cash.dispose();
    super.dispose();
  }

  int? get _cashMinor =>
      parseAccountAmount(_cash.text.replaceAll(',', ''), _digits);
  bool get _valid => _name.text.trim().isNotEmpty && (_cashMinor ?? -1) >= 0;
  bool get _dirty =>
      _name.text.trim().isNotEmpty ||
      _cash.text.trim().isNotEmpty ||
      _iconChosen;

  Future<void> _pickCurrency() async {
    FocusScope.of(context).unfocus();
    final currency = await Navigator.of(context).push(
      FeatureRoute<Currency>(
        CurrencyScreen(selectedCode: _currency, selectedTerritory: _territory),
      ),
    );
    if (currency != null && mounted) {
      setState(() {
        _currency = currency.code;
        _digits = currency.digits;
        _territory = currency.territory;
        _error = null;
      });
    }
  }

  Future<void> _pickIcon() async {
    FocusScope.of(context).unfocus();
    final icon = await Navigator.of(context)
        .push(FeatureRoute<String>(SelectIconScreen(selectedKey: _icon)));
    if (icon != null && mounted) {
      setState(() {
        _icon = icon;
        _iconChosen = true;
        final name = nameForIcon(icon);
        final current = _name.text.trim();
        if (name != null && (current.isEmpty || current == _autoName)) {
          _name.text = name;
          _autoName = name;
          _error = null;
        }
      });
    }
  }

  /// Typing a broker we have a logo for picks that logo, until an icon is
  /// chosen by hand. Clearing the name clears an icon picked this way.
  void _onName(String value) {
    setState(() {
      _error = null;
      if (!_iconChosen) _icon = matchingInstitutionIcon(value);
      // Typing takes over from a name that was filled in for a logo.
      if (value.trim() != _autoName) _autoName = null;
    });
  }

  Future<void> _discard() async {
    if (_saving || _asking) return;
    _asking = true;
    final discard = await showConfirmationAlert(
      context,
      title: 'Discard changes?',
      message: 'Your unsaved account details will be lost.',
      cancelLabel: 'Keep editing',
      confirmLabel: 'Discard',
    );
    _asking = false;
    if (discard && mounted) {
      setState(() => _leaving = true);
      Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    final before = widget.accounts.accounts.map((a) => a.id).toSet();
    try {
      await widget.accounts.save(
        name: _name.text,
        currency: _currency,
        territory: _territory,
        icon: _icon,
        digits: _digits,
        openingBalance: _cashMinor!,
        broker: true,
      );
    } catch (e, stack) {
      debugPrint('Could not save account: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is ArgumentError
            ? '${e.message}'
            : 'Could not save. Please try again.';
      });
      return;
    }
    if (!mounted) return;
    final added = widget.accounts.accounts.where((a) => !before.contains(a.id));
    setState(() => _leaving = true);
    Navigator.of(context).pop(added.firstOrNull?.id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _leaving || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _discard();
      },
      child: FeaturePage(
        title: 'Add account',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  MoneyCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                          child: Row(
                            children: [
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  customBorder: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      34 * .4,
                                    ),
                                  ),
                                  onTap: _saving ? null : _pickIcon,
                                  child: AppIcon(_icon, size: 34),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  key: const Key('broker-name'),
                                  controller: _name,
                                  enabled: !_saving,
                                  maxLength: 40,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                  onChanged: _onName,
                                  decoration: const InputDecoration(
                                    labelText: 'Name',
                                    hintText: 'e.g. Zerodha or Robinhood',
                                    filled: false,
                                    contentPadding: EdgeInsets.zero,
                                    counterText: '',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 18),
                          child: Divider(height: 24),
                        ),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(24),
                            ),
                            onTap: _saving ? null : _pickCurrency,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
                              child: Row(
                                children: [
                                  _territory == null
                                      ? const IconTile(
                                          Icons.language_rounded,
                                          size: 34,
                                        )
                                      : CurrencyFlag(
                                          _territory!,
                                          width: 34,
                                          height: 34,
                                          borderRadius: 34 * .4,
                                        ),
                                  const SizedBox(width: 12),
                                  const Expanded(child: Text('Currency')),
                                  Text(
                                    _currency,
                                    style: text.titleMedium?.copyWith(
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 20,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  MoneyCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cash in this account',
                          style: text.bodySmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('broker-cash'),
                          controller: _cash,
                          enabled: !_saving,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.done,
                          style: text.headlineLarge?.copyWith(fontSize: 30),
                          onChanged: (_) => setState(() => _error = null),
                          decoration: InputDecoration(
                            hintText: '0',
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 0,
                              minHeight: 0,
                            ),
                            prefixIcon: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text(
                                _currency,
                                style: text.titleMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            filled: false,
                            contentPadding: EdgeInsets.zero,
                            errorText: _cashMinor == null
                                ? (_digits == 0
                                      ? 'Enter a whole number for $_currency.'
                                      : 'Use a number with up to $_digits decimal places.')
                                : (_cashMinor! < 0
                                      ? 'Cash can’t be negative.'
                                      : null),
                            errorMaxLines: 3,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Money sitting there, ready to invest. Zero is fine, '
                          'too. Add stocks and funds after.',
                          style: text.bodySmall?.copyWith(height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Saved on your device',
                            style: text.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ActionButtonBar(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              secondaryLabel: 'Cancel',
              onSecondary: _saving ? null : () => Navigator.maybePop(context),
              primaryLabel: _saving ? 'Saving…' : 'Add account',
              onPrimary: _valid && !_saving ? _save : null,
            ),
          ],
        ),
      ),
    );
  }
}
