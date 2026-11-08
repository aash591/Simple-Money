import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/rates/exchange_rates.dart';
import '../domain/currency.dart';
import '../domain/currency_scope.dart';
import 'account_store.dart';

class MainCurrencyController extends ChangeNotifier
    with WidgetsBindingObserver {
  MainCurrencyController(
    this.accounts,
    this.exchangeRates, {
    Future<bool> Function()? isOnline,
  }) : isOnline = isOnline ?? _connected;
  static const preferenceKey = 'main_currency';
  final AccountStore accounts;
  final ExchangeRates exchangeRates;
  final Future<bool> Function() isOnline;
  String code = 'INR';
  int digits = 2;
  String? territory = 'IN';
  ExchangeRateTable? table;
  bool loading = true, refreshing = false;
  bool _disposed = false, _started = false, _hasChoice = false;
  int _revision = 0;
  DateTime? _lastAttempt;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  bool get multipleCurrencies =>
      accounts.accounts.map((a) => a.currency).toSet().length >= 2;
  SingleCurrency get single => SingleCurrency(code, digits);
  CombinedCurrency get combined => CombinedCurrency(
    code,
    digits,
    rates: table?.rates ?? const {},
    rateDate: table?.date,
  );
  CurrencyScope get accountScope => multipleCurrencies
      ? combined
      : accounts.accounts.isEmpty
      ? single
      : SingleCurrency(
          accounts.accounts.first.currency,
          accounts.accounts.first.digits,
        );

  static Future<bool> _connected() async {
    try {
      return !(await Connectivity().checkConnectivity()).contains(
        ConnectivityResult.none,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    accounts.addListener(_accountsChanged);
    WidgetsBinding.instance.addObserver(this);
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(preferenceKey);
      if (_disposed) return;
      if (text != null) {
        final saved = jsonDecode(text) as Map<String, dynamic>;
        final savedCode = saved['code'] as String;
        final savedDigits = saved['digits'] as int;
        if (RegExp(r'^[A-Z]{3}$').hasMatch(savedCode) &&
            savedDigits >= 0 &&
            savedDigits <= 4) {
          code = savedCode;
          digits = savedDigits;
          territory = saved['territory'] as String?;
          _hasChoice = true;
        }
      }
    } catch (_) {
      /* Keep the account-derived default if a preference is unreadable. */
    }
    if (_disposed) return;
    loading = false;
    _accountsChanged();
    try {
      // Probe support first: EventChannel reports an unsupported platform to
      // Flutter's error handler before a stream listener can intercept it.
      await Connectivity().checkConnectivity();
      if (_disposed) return;
      _connectivity = Connectivity().onConnectivityChanged.listen((results) {
        if (!results.contains(ConnectivityResult.none)) refresh();
      }, onError: (Object _) {});
    } catch (_) {
      /* Unsupported platform: foreground refresh remains available. */
    }
    await _loadCacheAndRefresh();
  }

  void _accountsChanged() {
    if (_disposed || loading) return;
    if (!_hasChoice && accounts.accounts.isNotEmpty) {
      final first = accounts.accounts.first;
      code = first.currency;
      digits = first.digits;
      territory = first.territory;
      _hasChoice = true;
      unawaited(_persist().catchError((Object _) {}));
      unawaited(_loadCacheAndRefresh());
    }
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> _persist() async {
    final value = jsonEncode({
      'code': code,
      'digits': digits,
      'territory': territory,
    });
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(preferenceKey, value)) {
      throw StateError('Could not save currency');
    }
  }

  Future<void> setCurrency(Currency currency) async {
    // Persist before publishing so a failed write cannot change the selection.
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      preferenceKey,
      jsonEncode({
        'code': currency.code,
        'digits': currency.digits,
        'territory': currency.territory,
      }),
    )) {
      throw StateError('Could not save currency');
    }
    if (_disposed) return;
    _revision++;
    code = currency.code;
    digits = currency.digits;
    territory = currency.territory;
    _hasChoice = true;
    table = null;
    refreshing = false;
    _lastAttempt = null;
    notifyListeners();
    await _loadCacheAndRefresh();
  }

  Future<void> _loadCacheAndRefresh() async {
    final revision = _revision;
    final base = code;
    try {
      final cached = await exchangeRates.cached(base);
      if (_disposed || revision != _revision || base != code) return;
      table = cached;
      notifyListeners();
    } catch (_) {
      /* Ledger stays usable even when the cache is unavailable. */
    }
    await refresh();
  }

  /// Whether rates are in hand afterwards — false when the fetch could not
  /// happen or failed, so a user-initiated refresh can say so rather than
  /// flickering the button and leaving the same date on screen.
  Future<bool> refresh({bool force = false}) async {
    if (_disposed || loading || refreshing || !multipleCurrencies) {
      return table != null;
    }
    final now = DateTime.now().toUtc();
    if (!force &&
        table != null &&
        !table!.fetchedOn.toUtc().isBefore(
          DateTime.utc(now.year, now.month, now.day),
        )) {
      return true;
    }
    if (!force &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(minutes: 5)) {
      return table != null;
    }
    final revision = _revision;
    final base = code;
    final before = table;
    refreshing = true;
    notifyListeners();
    try {
      if (!await isOnline() ||
          _disposed ||
          revision != _revision ||
          !multipleCurrencies) {
        return false;
      }
      _lastAttempt = now;
      final next = await exchangeRates.refresh(base, force: force);
      if (!_disposed && revision == _revision && base == code) table = next;
      // The service hands back the previous table when every provider fails.
      // Each stored fetch records its own instant, so an unchanged fetch time
      // means nothing new arrived.
      return next != null && next.fetchedOn != before?.fetchedOn;
    } catch (_) {
      /* Use the last good table without interrupting the user. */
      return false;
    } finally {
      if (!_disposed && revision == _revision) {
        refreshing = false;
        notifyListeners();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    accounts.removeListener(_accountsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.cancel();
    super.dispose();
  }
}

class MainCurrencyScope extends InheritedNotifier<MainCurrencyController> {
  const MainCurrencyScope({
    super.key,
    required MainCurrencyController controller,
    required super.child,
  }) : super(notifier: controller);
  static MainCurrencyController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MainCurrencyScope>()?.notifier;
}
