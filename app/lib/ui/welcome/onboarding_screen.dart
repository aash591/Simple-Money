import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/account_repository.dart';
import '../../data/community/community_fixes.dart';
import '../../data/repositories/sms_import_repository.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../domain/account.dart';
import '../../domain/currency.dart';
import '../../state/account_store.dart';
import '../../state/main_currency_controller.dart';
import '../../state/onboarding.dart';
import '../../state/sms_import_store.dart';
import '../../state/sync_controller.dart';
import '../../state/transaction_store.dart';
import '../components/action_buttons.dart';
import '../components/common.dart';
import '../components/currency_flag.dart';
import '../components/feature_page.dart';
import '../components/menu_list.dart';
import '../more/accounts/account_card.dart';
import '../more/accounts/currency_screen.dart';
import '../more/accounts/edit_account_screen.dart';
import '../more/settings/sync/backup_widgets.dart';
import '../more/settings/sync/backup_pin_screen.dart';
import '../more/settings/sync/sync_flow.dart';
import 'backup_welcome_screen.dart';
import 'privacy_card.dart';

enum _Step { welcome, currency, backup, sms, accounts, save }

/// The first-open setup, one step at a time with its buttons at the bottom:
/// a welcome that lists what comes next, the main currency (guessed from the
/// phone's region), Drive backup, then bank SMS (one
/// prompt for SMS and alerts), then the accounts the first scan found, with
/// their balances to check.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.database,
    required this.onDone,
    this.sync,
    this.community,
    this.sms,
    this.smsOnly = false,
  });
  final AppDatabase database;
  final SyncController? sync;

  /// Shared SMS rules, downloaded here so the first scan already knows them
  /// rather than waiting for the home screen.
  final CommunitySync? community;

  /// Called once, after the choices are saved.
  final VoidCallback onDone;

  /// The SMS store to use instead of a new one, for tests.
  final SmsImportStore? sms;

  /// Only the SMS step, opened later from Settings: no welcome or backup,
  /// and finishing does not mark the first-run setup as done.
  final bool smsOnly;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final SmsImportStore _sms =
      widget.sms ?? SmsImportStore(SmsImportRepository(widget.database));
  List<_Step>? _steps;
  int _index = 0;

  /// SMS import was on before: nothing to ask or scan.
  bool _smsWasOn = false;
  bool _asking = false, _saving = false, _done = false;

  /// The scan result has been seen and the person went on to the balances.
  bool _checking = false;

  /// The SMS prompt was refused or dismissed: the page stays, with a note.
  bool _smsDenied = false;
  final _scroll = ScrollController();

  // The accounts step reuses the Accounts screen: its own stores, so a card
  // opens the same account page (balance, menu) as in More › Accounts.
  AccountStore? _accountStore;
  TransactionStore? _transactionStore;
  bool _accountsReady = false;
  List<Account>? get _rows => _accountsReady ? _accountStore!.accounts : null;
  String? _error;

  /// The main currency on offer: the phone's region to begin with.
  Currency? _currency;

  _Step? get _step => _steps?[_index];

  @override
  void initState() {
    super.initState();
    _sms.addListener(_smsChanged);
    // Starts now, so it is done by the time the SMS step scans.
    _rules = widget.community?.refresh(force: true);
    _decide();
  }

  /// The shared rules' download, if there is one.
  Future<bool>? _rules;

  @override
  void dispose() {
    _sms.removeListener(_smsChanged);
    if (widget.sms == null) _sms.dispose();
    _transactionStore?.dispose();
    _accountStore?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _decide() async {
    if (widget.smsOnly) {
      if (!mounted) return;
      setState(() => _steps = [_Step.sms]);
      return;
    }
    final sync = widget.sync;
    var backup = false;
    try {
      if (sync != null && sync.supported && !await Onboarding.backupSeen()) {
        if (sync.status == null) await sync.refresh();
        backup = sync.status?.email == null;
      }
    } catch (_) {}
    if (_sms.supported) {
      try {
        _smsWasOn =
            (await _sms.repository.state()).$1 &&
            await _sms.platform.hasPermission();
      } catch (_) {}
    }
    // Always offered where the app can keep the answer. A currency saved
    // before (restored by Android backup after a reinstall, say) is the one
    // on offer; otherwise the phone's region.
    var currency = false;
    // Not dependOn…: this can run inside initState.
    if (mounted &&
        context.getInheritedWidgetOfExactType<MainCurrencyScope>() != null) {
      try {
        final all = await Currency.load();
        _currency =
            await _savedCurrency(all) ??
            Currency.forRegion(all, Currency.deviceRegion()) ??
            Currency.forRegion(all, 'IN');
        currency = _currency != null;
      } catch (_) {}
    }
    final setup = [
      if (currency) _Step.currency,
      if (backup) _Step.backup,
      if (_sms.supported) _Step.sms,
    ];
    if (!mounted) return;
    if (setup.isEmpty) return _finish();
    setState(() => _steps = [_Step.welcome, ...setup]);
  }

  void _next() {
    if (_index + 1 < _steps!.length) {
      setState(() => _index++);
    } else {
      _finish();
    }
  }

  /// The main currency saved on an earlier run, if there is one.
  Future<Currency?> _savedCurrency(List<Currency> all) async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(MainCurrencyController.preferenceKey);
    if (text == null) return null;
    final saved = jsonDecode(text) as Map<String, dynamic>;
    final byCountry = Currency.forRegion(all, saved['territory'] as String?);
    if (byCountry != null && byCountry.code == saved['code']) return byCountry;
    for (final currency in all) {
      if (currency.code == saved['code']) return currency;
    }
    return null;
  }

  Future<void> _pickCurrency() async {
    final current = _currency!;
    final picked = await Navigator.of(context).push<Currency>(
      FeatureRoute<Currency>(
        CurrencyScreen(
          selectedCode: current.code,
          selectedTerritory: current.territory,
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _currency = picked);
  }

  Future<void> _saveCurrency() async {
    final controller = MainCurrencyScope.maybeOf(context);
    final currency = _currency;
    if (controller != null && currency != null) {
      setState(() {
        _saving = true;
        _error = null;
      });
      try {
        await controller.setCurrency(currency);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = 'Could not save the currency. Please try again.';
        });
        return;
      }
      if (!mounted) return;
      setState(() => _saving = false);
    }
    _next();
  }

  Future<void> _connect() async {
    final sync = widget.sync!;
    if (!await connectDrive(context, sync) || !mounted) return;
    // Backups can be locked with a PIN from the start; skipping is fine.
    if (sync.status?.encryption == null) {
      await showBackupPinFlow(
        context,
        purpose: BackupPinPurpose.enable,
        optional: true,
        onSubmit: (pin) => sync.setEncryption(true, pin),
      );
    }
    if (mounted) _next();
  }

  /// One system prompt covers SMS and alerts. Once allowed, the first scan
  /// runs here. Refused or dismissed, the page stays so the choice is
  /// made on purpose: Setup Permissions again, or Skip.
  void _allowSms() {
    if (_smsWasOn) {
      _finish();
      return;
    }
    // The scan adds accounts but holds the transactions it finds: whether to
    // save them is asked on the last step, after the accounts are checked.
    _sms.saveFound = false;
    setState(() {
      _asking = true;
      _smsDenied = false;
    });
    unawaited(
      _rulesThenEnable().whenComplete(() {
        if (!mounted) return;
        if (_sms.enabled) {
          _loadAccounts();
        } else {
          setState(() {
            _asking = false;
            _smsDenied = true;
          });
        }
      }),
    );
  }

  /// Waits (briefly) for the shared rules, so the first scan reads messages
  /// with them; offline or slow, the scan goes ahead without.
  Future<void> _rulesThenEnable() async {
    try {
      await _rules?.timeout(const Duration(seconds: 6));
    } catch (_) {}
    await _sms.enable();
  }

  void _smsChanged() {
    if (!mounted || _steps == null) return;
    if (_step == _Step.sms && _sms.enabled) {
      setState(() {
        _asking = false;
        _steps = [..._steps!, _Step.accounts, _Step.save];
        _index = _steps!.length - 2;
      });
    } else if (_step == _Step.accounts) {
      setState(() {});
    }
  }

  Future<void> _loadAccounts() async {
    final accounts = AccountStore(AccountRepository(widget.database));
    _accountStore = accounts;
    _transactionStore = TransactionStore(
      TransactionRepository(widget.database),
      accounts,
    );
    accounts.addListener(_accountsChanged);
    await accounts.load();
    if (mounted) setState(() => _accountsReady = true);
  }

  void _accountsChanged() {
    if (mounted) setState(() {});
  }

  /// Opens an account on its own page, as Accounts does.
  void _openAccount(Account account) => Navigator.of(context).push(
    FeatureRoute<void>(
      EditAccountScreen(
        store: _accountStore!,
        account: account,
        transactionStore: _transactionStore,
        onboarding: true,
      ),
    ),
  );

  Future<void> _finish() async {
    if (_done) return;
    _done = true;
    final steps = _steps ?? const <_Step>[];
    if (!widget.smsOnly) {
      try {
        await Onboarding.finish(sawBackup: steps.contains(_Step.backup));
      } catch (_) {}
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = _step;
    return PopScope(
      // Back steps back; it can't leave the scan, which is already running.
      canPop: step == null || _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && step != _Step.accounts && _index > 0) {
          setState(() => _index--);
        }
      },
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.center,
              colors: [
                theme.colorScheme.primary.withValues(alpha: .1),
                theme.scaffoldBackgroundColor,
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: step == null
                    ? const SizedBox.expand()
                    : AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        child: SizedBox.expand(
                          key: ValueKey(step),
                          child: _page(context, step),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// How many steps the dots show: the accounts step joins once SMS is on.
  int get _planned {
    final steps = _steps!;
    return steps.length +
        (steps.contains(_Step.sms) &&
                !_smsWasOn &&
                !steps.contains(_Step.accounts)
            ? 2
            : 0);
  }

  /// The welcome fills the page: the hero floats in the space above, the
  /// setup list rests at the bottom, and a small screen or a big font just
  /// scrolls.
  Widget _welcomePage() => CustomScrollView(
    slivers: [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: _WelcomeContent(
            currency: _steps!.contains(_Step.currency),
            backup: _steps!.contains(_Step.backup),
            sms: _steps!.contains(_Step.sms),
          ),
        ),
      ),
    ],
  );

  Widget _page(BuildContext context, _Step step) => Column(
    children: [
      _header(step),
      Expanded(
        child: step == _Step.welcome
            ? _welcomePage()
            : LayoutBuilder(
                builder: (context, box) => Scrollbar(
                  controller: step == _Step.accounts ? _scroll : null,
                  // The balances list is long: keep its handle on show.
                  thumbVisibility: step == _Step.accounts,
                  thickness: 5,
                  radius: const Radius.circular(3),
                  child: SingleChildScrollView(
                    controller: step == _Step.accounts ? _scroll : null,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: box.maxHeight),
                      // Pictures sit at the top, so they stay put from page to page;
                      // only the accounts step, which has none, is centred.
                      child: Align(
                        alignment: step == _Step.accounts
                            ? Alignment.center
                            : const Alignment(0, -1),
                        child: switch (step) {
                          _Step.welcome => const SizedBox.shrink(),
                          _Step.currency => _currencyContent(context),
                          _Step.backup => const BackupWelcomeContent(),
                          _Step.sms => _SmsContent(denied: _smsDenied),
                          _Step.accounts => _accountsContent(context),
                          _Step.save => _saveContent(context),
                        },
                      ),
                    ),
                  ),
                ),
              ),
      ),
      switch (step) {
        _Step.welcome => _welcomeBar(),
        _Step.currency => _currencyBar(),
        _Step.backup => _backupBar(),
        _Step.sms => _smsBar(),
        _Step.accounts => _accountsBar(),
        _Step.save => _saveBar(),
      },
    ],
  );

  /// The step dots, with Skip at the top right on the backup and SMS steps.
  Widget _header(_Step step) {
    final dots = _Dots(count: _planned, current: _index);
    if (step == _Step.sms) {
      // Already on, there is nothing to skip: just Finish.
      return _smsWasOn
          ? dots
          : _withSkip(
              dots,
              TextButton(
                onPressed: _asking ? null : _finish,
                child: const Text('Skip'),
              ),
            );
    }
    if (step != _Step.backup) return dots;
    final sync = widget.sync!;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => _withSkip(
        dots,
        TextButton(
          onPressed: sync.connecting || sync.restoring ? null : _next,
          child: const Text('Skip'),
        ),
      ),
    );
  }

  Widget _withSkip(Widget dots, Widget skip) => Stack(
    alignment: Alignment.center,
    children: [
      dots,
      Align(
        alignment: Alignment.centerRight,
        child: Padding(padding: const EdgeInsets.only(right: 8), child: skip),
      ),
    ],
  );

  Widget _welcomeBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: SizedBox(
      width: double.infinity,
      child: PillButton(label: 'Get started', onPressed: _next),
    ),
  );

  Widget _currencyBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: SizedBox(
      width: double.infinity,
      child: PillButton(
        label: 'Continue',
        loading: _saving,
        onPressed: _saveCurrency,
      ),
    ),
  );

  Widget _currencyContent(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final currency = _currency!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HeroSlot(child: RoundIcon(Icons.currency_exchange_rounded)),
        const SizedBox(height: 24),
        Text(
          'Choose your currency',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Each account can have its own currency, so you can mix them. This '
          'main one is used for combined totals and summaries. Change it '
          'anytime in More › Settings.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
        MoneyCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CurrencyFlag(currency.territory),
              title: Text(currency.code, style: text.titleMedium),
              subtitle: Text(currency.name),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickCurrency,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          ErrorBanner(_error!),
        ],
      ],
    );
  }

  Widget _backupBar() {
    final sync = widget.sync!;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final busy = sync.connecting || sync.restoring;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sync.actionError != null) ...[
                ErrorBanner(sync.actionError!),
                const SizedBox(height: 12),
              ],
              GoogleSignInButton(
                label: 'Continue with Google',
                busy: busy,
                busyLabel: sync.restoring ? 'Restoring your data…' : null,
                onPressed: _connect,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _smsBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: SizedBox(
      width: double.infinity,
      child: PillButton(
        label: _smsWasOn ? 'Finish' : 'Setup Permissions',
        loading: _asking,
        onPressed: _allowSms,
      ),
    ),
  );

  Widget _accountsBar() {
    final rows = _rows;
    // Scanning (rows not known yet): Finish is disabled until the scan is
    // done. The result comes next, then the balances, each only when the
    // person chooses to go on.
    final onResult = rows != null && rows.isNotEmpty && !_checking;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: PillButton(
          label: onResult
              ? 'Check accounts'
              : rows != null && rows.isNotEmpty
              ? 'Continue'
              : 'Finish',
          loading: _saving,
          onPressed: rows == null
              ? null
              : onResult
              ? () => setState(() => _checking = true)
              : rows.isEmpty || _sms.foundTransactions == 0
              ? _finish
              : _next,
        ),
      ),
    );
  }

  Widget _saveBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PillButton(
          label: 'Save found transactions',
          loading: _saving,
          onPressed: _saving ? null : () => _chooseSaving(true),
        ),
        const SizedBox(height: 10),
        PillButton(
          label: 'Only save from now on',
          primary: false,
          onPressed: _saving ? null : () => _chooseSaving(false),
        ),
      ],
    ),
  );

  /// Saves what the scan found, or sets it aside so only new SMS are saved.
  /// The accounts stay as they are either way.
  Future<void> _chooseSaving(bool saveFound) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (saveFound) {
        await _sms.saveReady();
      } else {
        await _sms.dismissPending();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save. Please try again.';
      });
      return;
    }
    await _finish();
  }

  Widget _saveContent(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final number = NumberFormat.decimalPattern();
    final accounts = _rows?.length ?? 0;
    final found = _sms.foundTransactions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const RoundIcon(Icons.receipt_long_rounded),
        const SizedBox(height: 24),
        Text(
          'Save your transactions?',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Here are your ${number.format(accounts)} ${accounts == 1 ? 'account' : 'accounts'}, '
          'and we found ${number.format(found)} ${found == 1 ? 'transaction' : 'transactions'} '
          'in your SMS. You can go back to edit your accounts. Your accounts '
          'are kept either way.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(child: _Figure(number.format(found), 'Transactions')),
            const SizedBox(width: 10),
            Expanded(child: _Figure(number.format(accounts), 'Accounts')),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          ErrorBanner(_error!),
        ],
      ],
    );
  }

  /// What the scan found, before the balances: how much it added, and a
  /// button to go and check the accounts.
  Widget _scanResult(BuildContext context, List<Account> rows) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final number = NumberFormat.decimalPattern();
    final saved = _sms.foundTransactions;
    final banks = _sms.foundAccounts.length;
    final muted = text.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const RoundIcon(Icons.task_alt_rounded),
        const SizedBox(height: 24),
        Text(
          'Scan complete',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Balances are taken from your bank SMS. Banks don’t always send the '
          'latest balance, so check each one next. You can adjust a balance '
          'later too.',
          textAlign: TextAlign.center,
          style: muted,
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(child: _Figure(number.format(saved), 'Transactions')),
            const SizedBox(width: 10),
            Expanded(child: _Figure(number.format(banks), 'Banks')),
          ],
        ),
        if (_sms.error != null) ...[
          const SizedBox(height: 14),
          ErrorBanner(_sms.error!),
        ],
      ],
    );
  }

  Widget _accountsContent(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final number = NumberFormat.decimalPattern();
    final muted = text.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );
    final rows = _rows;
    if (rows == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const RoundIcon(Icons.manage_search_rounded),
          const SizedBox(height: 24),
          Text(
            'Finding your accounts',
            textAlign: TextAlign.center,
            style: text.headlineMedium,
          ),
          const SizedBox(height: 10),
          Text(
            _sms.importing
                ? 'Saving your transactions…'
                : '${number.format(_sms.scannedMessages)} messages checked',
            textAlign: TextAlign.center,
            style: muted,
          ),
          const SizedBox(height: 22),
          const LinearProgressIndicator(
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  number.format(_sms.foundTransactions),
                  'Transactions',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Figure(
                  number.format(_sms.foundAccounts.length),
                  'Banks',
                ),
              ),
            ],
          ),
        ],
      );
    }
    if (rows.isNotEmpty && !_checking) return _scanResult(context, rows);
    final saved = _sms.foundTransactions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          rows.isEmpty ? 'All set' : 'Check your balances',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          rows.isEmpty
              ? 'No bank SMS yet. New ones are added as they arrive.'
              : [
                  if (saved > 0)
                    '${number.format(saved)} ${saved == 1 ? 'transaction' : 'transactions'} found.',
                  'Balances from your bank’s SMS are filled in.',
                ].join(' '),
          textAlign: TextAlign.center,
          style: muted,
        ),
        if (_sms.error != null) ...[
          const SizedBox(height: 14),
          ErrorBanner(_sms.error!),
        ],
        const SizedBox(height: 20),
        for (final account in rows) ...[
          AccountCard(
            account: account,
            showTransactionCount: false,
            subtitle: account.balanceReportedAt != null
                ? 'Balance from your SMS'
                : 'Tap to check the balance',
            onTap: () => _openAccount(account),
          ),
          const SizedBox(height: 12),
        ],
        if (_error != null) ErrorBanner(_error!),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// The welcome: what Simple Money does, and the steps that follow.
class _WelcomeContent extends StatelessWidget {
  const _WelcomeContent({
    required this.currency,
    required this.backup,
    required this.sms,
  });
  final bool currency, backup, sms;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    // The hero floats a little above the middle of the free space, and the
    // setup list rests at the bottom.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Align(
            alignment: const Alignment(0, -.25),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HeroSlot(child: AppLogoTile(size: 120)),
                const SizedBox(height: 28),
                Text(
                  'Welcome to Simple Money',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'See where your money goes and stay on top of your budget.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        MenuGroup(
          label: 'Quick setup',
          children: [
            if (currency)
              const MenuRow(
                icon: Icons.currency_exchange_rounded,
                title: 'Currency',
                trailing: SizedBox.shrink(),
              ),
            if (backup)
              MenuRow(
                icon: Icons.cloud_rounded,
                title: 'Google Drive backup',
                trailing: const SizedBox.shrink(),
              ),
            if (sms)
              MenuRow(
                icon: Icons.sms_rounded,
                title: 'Payments from SMS',
                trailing: const SizedBox.shrink(),
              ),
            if (sms)
              const MenuRow(
                icon: Icons.account_balance_wallet_rounded,
                title: 'Your accounts',
                trailing: SizedBox.shrink(),
              ),
          ],
        ),
        // Air between the list and the button below.
        const SizedBox(height: 12),
      ],
    );
  }
}

/// The step before the SMS permission prompt: what is used, and what isn't.
class _SmsContent extends StatelessWidget {
  const _SmsContent({this.denied = false});

  /// The permission was refused or dismissed.
  final bool denied;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = text.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HeroSlot(child: RoundIcon(Icons.sms_rounded)),
        const SizedBox(height: 24),
        Text(
          'Enable Automatic Detection',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Bank transactions are picked out of your SMS and added for you, '
          'including new ones as they arrive.',
          textAlign: TextAlign.center,
          style: muted,
        ),
        const SizedBox(height: 24),
        const PrivacyCard(
          title: 'Your Privacy Matters',
          points: [
            'Only bank transaction messages are used',
            'Messages are read on your device and never uploaded',
            'Not sold or shared with anyone',
            'OTPs and personal messages are ignored',
            'You can turn this off anytime in More › Settings',
          ],
        ),
        if (denied) ...[
          const SizedBox(height: 14),
          const ErrorBanner(
            'Permission wasn’t given. Tap Setup Permissions to try again, '
            'or turn it on in Android Settings › Apps › Simple Money › '
            'Permissions.',
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'Your phone will ask to allow SMS and notifications. '
          'You can skip this and add transactions yourself.',
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.current});
  final int count, current;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      // As tall as a Skip button, so the pages below start at the same place.
      padding: const EdgeInsets.symmetric(vertical: 21),
      child: Semantics(
        label: 'Step ${current + 1} of $count',
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              Container(
                width: i == current ? 18 : 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i == current
                      ? colors.primary
                      : colors.onSurface.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.value, this.label);
  final String value, label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MoneyCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      child: Column(
        children: [
          Text(value, style: text.titleLarge),
          const SizedBox(height: 2),
          Text(label, style: text.bodySmall),
        ],
      ),
    );
  }
}
