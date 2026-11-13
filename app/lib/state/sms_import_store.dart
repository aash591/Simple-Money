import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../data/community/community_fixes.dart';
import '../data/repositories/sms_import_repository.dart';
import '../data/repositories/sms_review_repository.dart';
import '../data/repositories/account_repository.dart';
import '../data/repositories/category_repository.dart';
import '../data/db/app_database.dart';
import '../data/sms_inbox_platform.dart';
import '../domain/party_category.dart';
import '../data/bank_sms_parser.dart';
import '../data/user_sms_rules.dart';
import '../domain/account.dart';
import '../domain/bank_institution_icon.dart';
import '../domain/currency.dart';
import '../domain/currency_digits.dart';
import 'main_currency_controller.dart';
import '../data/sms_amounts.dart';

PortableSmsEngine _buildEngine(
  List<String> packs, [
  Map<String, SmsSenderRole> roles = const {},
]) {
  const compiler = RuleCompiler();
  return BankSmsParser(
    compiler.mergeRuntimePacks(
      packs
          .map(
            (p) => compiler.loadRuntime(jsonDecode(p) as Map<String, dynamic>),
          )
          .toList(),
    ),
    roles: roles,
  );
}

PortableSmsEngine _buildBundledEngine(List<String> packs) =>
    _buildEngine(packs);

/// Bundled packs plus the user's own rules, plus shared ones from other
/// users. A pack that can't merge (one repeating a bundled pattern, say) is
/// dropped rather than stopping SMS import: the shared pack first, then the
/// user's, unless that is all there is.
PortableSmsEngine _buildEngineWithUser(
  (List<String>, String?, String?, Map<String, SmsSenderRole>) input,
) {
  final (bundled, user, community, roles) = input;
  final attempts = [
    if (community != null) [...bundled, ?user, community],
    if (user != null) [...bundled, user],
  ];
  RuleValidationException? failure;
  for (final packs in attempts) {
    try {
      return _buildEngine(packs, roles);
    } on RuleValidationException catch (error) {
      failure ??= error;
    }
  }
  if (bundled.isEmpty && failure != null) throw failure;
  return _buildEngine(bundled, roles);
}

/// The user's approved SMS rules as a runtime pack, or null.
Future<String?> userSmsPack(AppDatabase database) async {
  try {
    return await UserSmsRuleRepository(database).runtimePack();
  } catch (_) {
    return null;
  }
}

/// Shared SMS rules from other users as a runtime pack, or null.
Future<String?> communitySmsPack(AppDatabase database) async {
  try {
    return await CommunityFixRepository(database).runtimePack();
  } catch (_) {
    return null;
  }
}

/// Senders of the user's and shared rules that hold no money of the user's
/// (shops, billers…), with their roles. Empty when the rules can't be read.
Future<Map<String, SmsSenderRole>> smsSenderRoles(AppDatabase database) async {
  try {
    return nonHolderSenders([
      ...await UserSmsRuleRepository(database).load(),
      ...await CommunityFixRepository(database).smsRules(),
    ]);
  } catch (_) {
    return const {};
  }
}

Future<PortableSmsEngine> loadBundledSmsEngine() async =>
    compute(_buildBundledEngine, await _bundledPacks());

/// The engine the app reads bank SMS with: bundled packs, the user's rules
/// and shared ones.
Future<PortableSmsEngine> loadSmsEngine(AppDatabase database) async =>
    compute(_buildEngineWithUser, (
      await _bundledPacks(countries: await smsCountries(database)),
      await userSmsPack(database),
      await communitySmsPack(database),
      await smsSenderRoles(database),
    ));

/// The bundled packs' JSON, optionally only those whose text passes [where].
Future<List<String>> bundledSmsPacks({bool Function(String text)? where}) =>
    _bundledPacks(where: where);

/// A small engine for one incoming message: only the packs that register its
/// sender are compiled, on the calling isolate. Null when no pack (and no
/// host-only family) knows the sender, so the message cannot be a transaction.
///
/// Every pack carries the same shared category lists, and a sender's rules all
/// live in the packs that name it, so the result matches the full engine.
///
/// [userPack] is the user's own rules ([userSmsPack]) and [communityPack]
/// the shared ones ([communitySmsPack]), each used when it names the sender.
Future<PortableSmsEngine?> loadBundledSmsEngineFor(
  String sender, {
  String? userPack,
  String? communityPack,
  Map<String, SmsSenderRole> roles = const {},
}) async {
  final normalized = normalizeRuleSender(sender);
  if (normalized == null) return null;
  final matching = await _bundledPacks(
    where: (text) => text.contains('"$normalized"'),
  );
  String? naming(String? pack) =>
      pack != null && pack.contains('"$normalized"') ? pack : null;
  final user = naming(userPack);
  final community = naming(communityPack);
  if (matching.isNotEmpty || user != null || community != null) {
    try {
      return _buildEngineWithUser((matching, user, community, roles));
    } on RuleValidationException {
      return null;
    }
  }
  return BankSmsParser.hostOnlySenders.containsKey(normalized)
      ? _buildEngine(await _bundledPacks())
      : null;
}

Future<PartyCategorizer>? _categorizer;

/// The shared category rules, for whatever isn't an SMS: a statement row, a
/// scanned UPI QR. Every pack carries all of them, so one pack is enough.
Future<PartyCategorizer> loadBundledCategorizer() =>
    _categorizer ??= _bundledPacks(first: true)
        .then(
          (packs) => PartyCategorizer(
            PortableCategorizer(
              const RuleCompiler().loadRuntime(
                jsonDecode(packs.single) as Map<String, dynamic>,
              ),
            ),
          ),
        )
        .catchError((Object error) {
          _categorizer = null;
          throw error;
        });

/// Only the packs that are returned are hash-verified.
/// The countries whose banks the user's SMS can come from, so only their
/// bundled packs are compiled: the country picked at setup (from the time
/// zone, or changed by the user), the phone's region, the countries of the
/// user's accounts and of banks already read from SMS, and those of the
/// user's own rules. One person may bank in several. Null when none is
/// known yet: then every country is read.
Future<Set<String>?> smsCountries(AppDatabase database) async {
  final countries = <String>{};
  void add(Object? code) {
    if (code is String && RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
      countries.add(code);
    }
  }

  try {
    final saved = (await SharedPreferences.getInstance()).getString(
      MainCurrencyController.preferenceKey,
    );
    if (saved != null) add((jsonDecode(saved) as Map)['territory']);
    (await SharedPreferences.getInstance())
        .getStringList(_seenCountriesKey)
        ?.forEach(add);
  } catch (_) {
    /* Not set up yet, or read where preferences aren't available. */
  }
  try {
    add(Currency.deviceRegion());
  } catch (_) {
    /* No platform locale here (a background isolate). */
  }
  try {
    final rows = await database
        .customSelect(
          'SELECT DISTINCT territory, currency FROM accounts '
          'WHERE archived_at IS NULL',
        )
        .get();
    final untracked = <String>{};
    for (final r in rows) {
      final territory = r.readNullable<String>('territory');
      territory == null
          ? untracked.add(r.read<String>('currency'))
          : add(territory);
    }
    // An account made before territories were kept: every country that
    // uses its currency.
    for (final code in untracked) {
      currencyTerritories[code]?.forEach(add);
    }
    for (final r
        in await database
            .customSelect(
              "SELECT DISTINCT json_extract(data,'\$.countryCode') AS c "
              'FROM sms_detected_accounts',
            )
            .get()) {
      add(r.readNullable<String>('c'));
    }
    for (final rule in await UserSmsRuleRepository(database).load()) {
      add(ruleCountry(rule.format));
    }
  } catch (_) {
    /* Read every country rather than miss a bank. */
  }
  return countries.isEmpty ? null : countries;
}

Future<List<String>> _bundledPacks({
  bool Function(String text)? where,
  bool first = false,
  Set<String>? countries,
}) async {
  const root = 'packages/universal_bank_sms_parser/distribution/';
  final manifest = jsonDecode(
    await rootBundle.loadString('${root}manifest.json'),
  ) as Map<String, dynamic>;
  // Every country's banks: one person may bank in several. India's packs
  // lead, as the shared category lists are read from the first pack.
  bool wanted(Object? p) =>
      countries == null ||
      ((p as Map)['countries'] as List).any(countries.contains);
  final packList = manifest['packs'] as List;
  // No bundled bank in the user's countries yet: read them all, as before.
  final any = packList.any(wanted);
  final all =
      [
        for (final p in packList)
          if (!any || wanted(p)) p,
      ]..sort(
        (a, b) =>
            ((b['countries'] as List).contains('IN') ? 1 : 0) -
            ((a['countries'] as List).contains('IN') ? 1 : 0),
      );
  // The category lists come from India's first pack, whatever the countries.
  final chosen = first
      ? [
          (manifest['packs'] as List).firstWhere(
            (p) => (p['countries'] as List).contains('IN'),
          ),
        ]
      : all;
  final packs = await Future.wait(
    chosen.map((p) async {
      final bytes = await rootBundle.load('$root${p['path']}');
      final data = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      final text = utf8.decode(data);
      if (where != null && !where(text)) return null;
      if (data.length != p['sizeBytes'] ||
          sha256.convert(data).toString() != p['sha256']) {
        throw const FormatException('Invalid bundled SMS rules');
      }
      return text;
    }),
  );
  return packs.nonNulls.toList();
}

// Keep the closures outside the store so no notifier, platform channel or UI
// state can be captured and sent to the worker isolate.
Future<(int, int, Set<String>, Set<String>)> _processStagedPage(
  AppDatabase database,
  PortableSmsEngine engine,
) => database.computeWithDatabase(
  connect: AppDatabase.new,
  computation: (AppDatabase workerDb) async {
    final repository = SmsImportRepository(workerDb);
    final page = await repository.stagedPage();
    var found = 0;
    final unknown = <String>{};

    await workerDb.transaction(() async {
      for (final row in page) {
        final result = engine.parse(row.sms);
        if (result.reason == 'unregisteredSender' &&
            isBusinessSender(row.sms)) {
          unknown.add(normalizeRuleSender(row.sms.sender)!);
        }
        if (engine is BankSmsParser) {
          final snapshot = engine.balanceSnapshot(row.sms);
          if (snapshot != null) {
            await repository.recordBalance(snapshot, row.sms.receivedAt);
          }
        }
        await repository.enqueue(
          row.sms,
          result,
          role: smsSenderRole(engine, row.sms.sender),
        );
        if (result.candidate != null) {
          found++;
        }
      }
      // Queue consumption and parsed records commit together.
      await repository.clearStagedPage();
    });
    // Use the same resolved groups as review, including suffix-less messages
    // that can now be matched to a known account.
    final accounts = (await repository.detectedAccounts())
        .map((sms) => sms.bankKey)
        .toSet();
    return (page.length, found, accounts, unknown);
  },
);

/// Where [smsCountries] keeps countries found from the inbox itself.
const _seenCountriesKey = 'sms_countries_seen';

/// Countries whose bundled packs know one of [senders] though [loaded]
/// left them out: someone who picked AED at setup but still banks in India.
/// They are remembered, so the next engine reads them. Empty when nothing
/// new turned up, or every country was already read.
Future<Set<String>> discoverSmsCountries(
  Set<String> senders,
  Set<String>? loaded,
) async {
  if (senders.isEmpty || loaded == null) return const {};
  const root = 'packages/universal_bank_sms_parser/distribution/';
  final manifest = jsonDecode(
    await rootBundle.loadString('${root}manifest.json'),
  ) as Map<String, dynamic>;
  final found = <String>{};
  for (final p in manifest['packs'] as List) {
    final countries = (p['countries'] as List).cast<String>();
    if (countries.any(loaded.contains) || countries.every(found.contains)) {
      continue;
    }
    final text = await rootBundle.loadString('$root${p['path']}');
    if (senders.any((s) => text.contains('"$s"'))) found.addAll(countries);
  }
  if (found.isEmpty) return const {};
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_seenCountriesKey, [
      ...{...?prefs.getStringList(_seenCountriesKey), ...found},
    ]);
  } catch (_) {
    /* Found again on the next scan. */
  }
  return found;
}

class _ReviewData {
  const _ReviewData(
    this.enabled,
    this.pending,
    this.detected,
    this.links,
    this.balances,
    this.creditLimits,
    this.totalLimits,
    this.accountMessageCounts,
    this.count,
    this.ready,
    this.cashCurrencies,
    this.cashMessageCounts,
    this.changed,
  );
  final bool enabled;
  final int count, ready;
  final Set<String> cashCurrencies;
  final Map<String, int> cashMessageCounts;
  final bool changed;
  final List<PendingSmsImport> pending, detected;
  final Map<String, int> links, balances, creditLimits, totalLimits;
  final Map<String, int> accountMessageCounts;
}

Future<_ReviewData> _loadReviewData(
  AppDatabase database,
  PortableSmsEngine engine,
  Map<String, int> selections,
  bool rebuild,
  Set<String> refreshIds,
  String rules,
) => database.computeWithDatabase(
  connect: AppDatabase.new,
  computation: (AppDatabase workerDb) async {
    final repository = SmsImportRepository(workerDb);
    final enabled = (await repository.state()).$1;
    final review = SmsReviewRepository(workerDb);
    var changed = false;
    await workerDb.transaction(() async {
      final signature = await review.contextSignature(rules);
      rebuild = rebuild || await review.contextChanged(signature);
      changed = await review.cleanReviewed(compact: rebuild) > 0;
      if (rebuild) {
        changed =
            await workerDb.customUpdate('DELETE FROM sms_review') > 0 ||
            changed;
      } else if (refreshIds.isNotEmpty) {
        final placeholders = List.filled(refreshIds.length, '?').join(',');
        changed =
            await workerDb.customUpdate(
                  'DELETE FROM sms_review WHERE fingerprint IN ($placeholders)',
                  variables: refreshIds.map(Variable.new).toList(),
                ) >
                0 ||
            changed;
      }
      if (rebuild || refreshIds.isNotEmpty || await review.needsSync()) {
        final accounts = await AccountRepository(workerDb).load();
        final categories = await CategoryRepository(workerDb)
            .load(includeDrafts: true);
        final links = await repository.accountLinks();
        final detected = await repository.detectedAccounts();
        final notifications = <String, BankSms>{};
        // Only messages absent from the persistent review index are decoded
        // and reparsed. Ordinary refreshes therefore stay O(page size), not
        // O(the user's entire SMS history).
        while (true) {
          final queued = await repository.pendingWithoutReview();
          if (queued.isEmpty) break;
          changed = true;
          final prepared = _preparePending(
            (engine, queued),
            notifications,
            reparse: rebuild,
          );
          final included = prepared.map((sms) => sms.id).toSet();
          for (final sms in prepared) {
            await review.put(
              sms,
              accounts,
              categories,
              links,
              selections[sms.id],
              detected: detected,
            );
          }
          for (final sms in queued) {
            if (!included.contains(sms.id)) await review.putIgnored(sms);
          }
        }
      }
      if (rebuild) await review.recordContext(signature);
    });
    final links = await repository.accountLinks();
    final page = await review.page();
    return _ReviewData(
      enabled,
      page.map((row) => row.sms).toList(),
      await repository.detectedAccounts(),
      links,
      await repository.latestBalances(backfill: false),
      await repository.latestCreditLimits(),
      await repository.latestTotalCreditLimits(),
      await repository.detectedAccountMessageCounts(),
      await review.count(),
      await review.count(const SmsReviewFilter(ready: true)),
      await review.cashCurrencies(),
      await review.cashCurrencyMessageCounts(),
      changed,
    );
  },
);

/// Rows queued since the last rebuild were parsed by this same rule context, so
/// only a rebuild (rules, accounts or host version changed) parses them again.
List<PendingSmsImport> _preparePending(
  (PortableSmsEngine, List<PendingSmsImport>) input,
  Map<String, BankSms> notifications, {
  required bool reparse,
}) {
  final engine = input.$1;
  final rows = <PendingSmsImport>[];
  for (final sms in input.$2) {
    final message = BankSms(
      sender: sms.sender,
      body: sms.body,
      receivedAt: sms.receivedAt,
    );
    final identity = smsNotificationIdentity(message);
    final previous = notifications[identity];
    if (previous != null && isRepeatedSmsNotification(previous, message)) {
      continue;
    }
    notifications[identity] = message;
    final parsed = reparse ? engine.parse(message) : null;
    if (parsed != null &&
        parsed.classification != RuleClassification.unknown &&
        parsed.candidate == null) {
      continue;
    }
    // Prefer the current rule pack's candidate so newly added formats repair
    // pending rows that were scanned with an older pack. Stored host metadata
    // is merged back below; unknown messages retain their saved candidate.
    final candidate =
        parsed?.candidate ??
        SmsTransactionCandidate.fromJson({
          ...sms.data,
          'occurredAt':
              sms.data['occurredAt'] ?? sms.receivedAt.toIso8601String(),
        });
    final enriched = engine.enrichCandidate(message, candidate);
    final data = {...sms.data, ...enriched.toJson()};
    // A fresh parse counts in the rule's decimal places; a stored row
    // already in the app's.
    if (parsed?.candidate case final read?) {
      data['amountMinor'] = smsAmountToApp(read.amountMinor, read.currencyCode);
    }
    // Rows queued before the sender's role was known get it here.
    applySenderRole(data, smsSenderRole(engine, sms.sender));
    // A number kept apart (a shop's, a loan account's) stays apart.
    if (data.containsKey(otherAccountKey)) data.remove('accountLast4');
    rows.add(
      PendingSmsImport(
        id: sms.id,
        sender: sms.sender,
        body: sms.body,
        receivedAt: sms.receivedAt,
        data: data,
      ),
    );
  }
  return rows;
}

/// What the last scan did on its own, for the home card.
class SmsScanSummary {
  const SmsScanSummary({required this.accountsAdded, required this.saved});
  final int accountsAdded, saved;
}

Future<int> _saveReady(AppDatabase database) => database.computeWithDatabase(
  connect: AppDatabase.new,
  computation: (AppDatabase workerDb) =>
      SmsReviewRepository(workerDb).saveReady(),
);

class SmsImportStore extends ChangeNotifier {
  SmsImportStore(
    this.repository, {
    SmsInboxPlatform? platform,
    Future<PortableSmsEngine> Function()? engineLoader,
    this.autoImport = true,
  }) : platform = platform ?? SmsInboxPlatform(),
       _usesBundledEngine = engineLoader == null,
       engineLoader =
           engineLoader ?? (() => loadSmsEngine(repository.database));
  final SmsImportRepository repository;
  final SmsInboxPlatform platform;

  /// Whether a finished scan adds accounts and saves ready transactions.
  final bool autoImport;
  final Future<PortableSmsEngine> Function() engineLoader;
  Future<PortableSmsEngine>? _engine;
  final bool _usesBundledEngine;

  /// The countries the cached engine reads ([smsCountries]); a change, such
  /// as a new country picked in settings, builds it again.
  Set<String>? _engineCountries;
  Future<String>? _rulesSignature;

  /// Only the first review page, for the dashboard. All rows remain in SQLite.
  List<PendingSmsImport> pending = [];
  int pendingCount = 0, readyCount = 0, reviewRevision = 0;
  Set<String> cashCurrencies = {};
  Map<String, int> cashMessageCounts = {};
  late final SmsReviewRepository review = SmsReviewRepository(
    repository.database,
  );
  List<PendingSmsImport> detectedAccounts = [];
  Map<String, int> accountLinks = {};
  Map<String, int> smsBalances = {};
  Map<String, int> smsCreditLimits = {};
  Map<String, int> smsTotalCreditLimits = {};
  Map<String, int> accountMessageCounts = {};
  final Map<String, int> selectedCategories = {};
  Future<void> selectCategory(PendingSmsImport sms, int id) async {
    selectedCategories[sms.id] = id;
    await reload(refreshIds: {sms.id});
  }

  bool enabled = false, busy = false, _disposed = false;

  /// Whether the waiting messages have been read once, so a screen can show
  /// the card with everything else instead of after it.
  bool loaded = false;
  void _markLoaded() {
    loaded = true;
    _notify();
  }

  bool scanning = false;

  /// After reading the inbox: adding accounts and saving transactions.
  bool importing = false;
  SmsScanSummary? lastScan;

  /// Called after a scan adds accounts or saves transactions, so the ledger
  /// screens can reload.
  VoidCallback? onLedgerChanged;
  int scannedMessages = 0, foundTransactions = 0;
  final Set<String> foundAccounts = {};
  String? error;
  bool get supported => platform.supported;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  int _reloadVersion = 0;
  Future<void> reload({
    bool rebuildReview = false,
    Set<String> refreshIds = const {},
  }) async {
    if (_disposed) return;
    final version = ++_reloadVersion;
    _rulesSignature ??= _usesBundledEngine
        ? _bundledRulesSignature()
        : Future.value('custom-engine');
    _engine ??= engineLoader();
    final engine = await _engine!;
    final data = await _loadReviewData(
      repository.database,
      engine,
      Map.of(selectedCategories),
      rebuildReview,
      Set.of(refreshIds),
      await _rulesSignature!,
    );
    if (_disposed || version != _reloadVersion) return;
    final changed =
        data.changed || pendingCount != data.count || readyCount != data.ready;
    enabled = data.enabled;
    pending = data.pending;
    pendingCount = data.count;
    readyCount = data.ready;
    cashCurrencies = data.cashCurrencies;
    cashMessageCounts = data.cashMessageCounts;
    if (changed) reviewRevision++;
    if (pendingCount == 0) selectedCategories.clear();
    smsBalances = data.balances;
    accountLinks = data.links;
    smsCreditLimits = data.creditLimits;
    smsTotalCreditLimits = data.totalLimits;
    accountMessageCounts = data.accountMessageCounts;
    detectedAccounts = data.detected;
    _notify();
  }

  /// The bundled packs, the user's own rules and shared ones, which all
  /// decide how pending messages read.
  Future<String> _bundledRulesSignature() async =>
      '${await rootBundle.loadString('packages/universal_bank_sms_parser/distribution/manifest.json')}'
      '\nuser:${await UserSmsRuleRepository(repository.database).signature()}'
      '\ncommunity:${await CommunityFixRepository(repository.database).signature()}';

  /// The user's SMS rules changed. Pending messages are read again with the
  /// new set, and the whole inbox is scanned so messages no rule caught
  /// before can be found.
  Future<void> rulesChanged() async {
    _engine = null;
    _rulesSignature = null;
    if (enabled && supported) {
      await scan(full: true);
    } else {
      await reload();
    }
  }

  Future<void> initialize() async {
    try {
      enabled = (await repository.state()).$1;
      // The waiting messages first: they are a local read, and the Home card
      // should not wait on the permission and realtime round trips below.
      await reload();
      _markLoaded();
      if (enabled && supported && !await platform.hasPermission()) {
        enabled = false;
        await repository.enable(false);
      }
      await platform.setRealtimeEnabled(enabled);
      if (enabled) await scan(automatic: true);
    } catch (_) {
      error = 'Could not load bank messages. Please try again.';
      _markLoaded();
      _notify();
    }
  }

  Future<void> enable() async {
    if (busy || !supported || _disposed) return;
    busy = true;
    error = null;
    _notify();
    var allowed = false;
    try {
      allowed = await platform.requestPermission();
      if (!allowed) {
        error = 'SMS access was not granted. Try again in More › Settings.';
      } else if (!_disposed) {
        enabled = true;
        await repository.enable(true);
        await platform.setRealtimeEnabled(true);
      }
    } catch (_) {
      allowed = false;
      error = 'Could not access the SMS inbox. Please try again.';
    } finally {
      busy = false;
      _notify();
    }
    if (allowed && !_disposed) await scan();
  }

  Future<void> disable() async {
    enabled = false;
    await repository.enable(false);
    await platform.setRealtimeEnabled(false);
    _notify();
  }

  Future<void> scan({bool full = false, bool automatic = false}) async {
    if (busy || !enabled || !supported || _disposed) return;
    // A completed scan survives app restarts. Opening/resuming the app should
    // reuse its saved review queue; only an explicit scan reads the inbox again.
    // An interrupted first scan has no checkpoint and can still recover.
    if (automatic) {
      try {
        if ((await repository.state()).$2 > 0) return;
      } catch (_) {
        error = 'Could not load bank messages. Please try again.';
        _notify();
        return;
      }
    }
    // Another scan may have started while reading the persisted checkpoint.
    if (busy || !enabled || !supported || _disposed) return;
    busy = true;
    error = null;
    _notify();
    scanning = true;
    scannedMessages = 0;
    foundTransactions = 0;
    foundAccounts.clear();
    lastScan = null;
    _notify();
    var completed = false;
    final started = DateTime.now().millisecondsSinceEpoch;
    try {
      if (!await platform.hasPermission()) {
        enabled = false;
        await repository.enable(false);
        error = 'SMS access is off. Turn it on again in More › Settings.';
        await platform.setRealtimeEnabled(false);
        return;
      }
      final checkpoint = (await repository.state()).$2;
      final since = full
          ? 0
          : (checkpoint - const Duration(days: 1).inMilliseconds).clamp(
              0,
              started,
            );
      // A second pass only when the first found banks of a country the
      // engine left out; messages already queued are not queued twice.
      for (var pass = 0; pass < 2; pass++) {
        final countries = _usesBundledEngine
            ? await smsCountries(repository.database)
            : null;
        if (!setEquals(countries, _engineCountries)) _engine = null;
        _engineCountries = countries;
        _engine ??= engineLoader();
        final engine = await _engine!;
        final unknown = <String>{};
        var afterId = 0;
        while (!_disposed && enabled) {
          final page = await platform.readPage(afterId: afterId, since: since);
          if (page.isEmpty) break;
          for (final row in page) {
            if (row.id <= afterId) {
              throw StateError('Invalid inbox pagination');
            }
            afterId = row.id;
          }
          if (_disposed || !enabled) break;
          await repository.stagePage(page);
          final progress = await _processStagedPage(
            repository.database,
            engine,
          );
          if (pass == 0) scannedMessages += progress.$1;
          foundTransactions += progress.$2;
          foundAccounts
            ..clear()
            ..addAll(progress.$3);
          unknown.addAll(progress.$4);
          _notify();
          await Future<void>.delayed(Duration.zero);
        }
        if (pass > 0 ||
            _disposed ||
            !enabled ||
            (await discoverSmsCountries(unknown, countries)).isEmpty) {
          break;
        }
        _engine = null;
      }
      if (enabled && !_disposed) {
        await repository.checkpoint(started);
        completed = true;
      }
    } catch (_) {
      _engine = null;
      error = 'Could not finish reading SMS. Your pending messages are kept; scan again to retry.';
    } finally {
      // Refresh once, including partially committed pages after a read error.
      try {
        await repository.clearStagedPage();
        await reload();
      } catch (_) {
        error ??= 'Could not refresh bank messages. Please try again.';
      }
      if (autoImport && completed && error == null && !_disposed) {
        importing = true;
        _notify();
        try {
          lastScan = await _autoImport();
          onLedgerChanged?.call();
        } catch (_) {
          error = 'Could not save everything. Your messages are kept; scan again to retry.';
        }
        importing = false;
      }
      scanning = false;
      busy = false;
      _notify();
    }
  }

  /// A scan only asks about what it cannot decide. Banks whose messages carry
  /// an account number get an account, ATM messages get a Cash account, and
  /// every transaction with an account and category is saved. Unnumbered
  /// banks to link and transactions to check are left for review.
  Future<SmsScanSummary> _autoImport() async {
    final accounts = AccountRepository(repository.database);
    final before = await accounts.load();
    bool active(int? id) => before.any((a) => a.id == id && !a.isArchived);
    final numbered = [
      for (final sms in detectedAccounts)
        if (sms.accountLast4 != null && !active(accountLinks[sms.bankKey])) sms,
    ];
    await repository.createDetectedAccounts(
      numbered,
      icons: {
        for (final sms in numbered)
          sms.bankKey: bankInstitutionIcon(
            sms.bankName,
            creditCard: sms.creditCard,
          ),
      },
    );
    for (final currency in cashCurrencies) {
      if (before.any(
        (a) =>
            a.type == AccountType.cash &&
            a.currency == currency &&
            !a.isArchived,
      )) {
        continue;
      }
      await accounts.save(
        name: 'Cash',
        currency: currency,
        digits: currencyDigits(currency),
        openingBalance: 0,
        type: AccountType.cash,
        icon: 'wallet_one',
      );
    }
    final added = (await accounts.load()).length - before.length;
    await reload();
    final saved = await _saveReady(repository.database);
    await reload();
    return SmsScanSummary(accountsAdded: added, saved: saved);
  }

  Future<int> saveReady() async {
    await reload();
    return _saveReady(repository.database);
  }

  Future<void> dismiss(PendingSmsImport sms) async {
    await repository.dismiss(sms.id);
    await reload();
  }

  Future<void> linkAccount(PendingSmsImport sms, int id) async {
    await repository.linkAccount(sms, id);
    accountLinks = {...accountLinks, sms.bankKey: id};
    _notify();
    // The reference-table signature invalidates matching only when it changes.
    await reload();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
