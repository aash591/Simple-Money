import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/sms_inbox_platform.dart';
import 'package:simple_money/state/onboarding.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/welcome/onboarding_screen.dart';
import 'package:simple_money/ui/welcome/privacy_card.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

class _Inbox extends SmsInboxPlatform {
  bool granted = true;
  int requests = 0;
  List<InboxSms> rows = [];
  @override
  bool get supported => true;
  @override
  Future<void> setRealtimeEnabled(bool enabled) async {}
  @override
  Future<bool> hasPermission() async => granted && requests > 0;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return granted;
  }

  @override
  Future<List<InboxSms>> readPage({
    required int afterId,
    required int since,
  }) async => rows.where((r) => r.id > afterId).toList();
}

class _Sync extends SyncController {
  _Sync(super.repository);
  @override
  bool get supported => true;
}

void main() {
  late BankSmsParser engine;
  late AppDatabase db;
  late _Inbox inbox;
  late SmsImportStore store;
  late bool done;

  setUpAll(() {
    engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory(), false);
    inbox = _Inbox();
    store = SmsImportStore(
      SmsImportRepository(db),
      platform: inbox,
      engineLoader: () async => engine,
    );
    done = false;
  });
  tearDown(() async {
    store.dispose();
    await db.close();
  });

  /// Lets the database and scan work run until [ready].
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (!ready()) {
      // What the screen showed instead, to see where it stopped.
      final texts = find
          .byType(Text)
          .evaluate()
          .map(
            (e) =>
                (e.widget as Text).data ??
                (e.widget as Text).textSpan?.toPlainText(),
          );
      fail('Still showing: ${texts.join(' | ')}');
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  bool shows(String text) =>
      find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

  Future<void> open(WidgetTester tester, {SyncController? sync}) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          database: db,
          sync: sync,
          sms: store,
          onDone: () => done = true,
        ),
      ),
    );
  }

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  testWidgets('backup, then SMS; Skip finishes without asking', (tester) async {
    final sync = _Sync(SyncRepository(db));
    addTearDown(sync.dispose);
    await open(tester, sync: sync);
    await waitFor(tester, () => shows('Welcome to Simple Money'));
    // The welcome lists every step that follows.
    expect(find.text('Back up to Google Drive'), findsOneWidget);
    expect(find.text('Add payments from SMS'), findsOneWidget);
    expect(find.text('Check your accounts'), findsOneWidget);
    expect(find.bySemanticsLabel('Step 1 of 4'), findsOneWidget);
    final heroTop = tester.getRect(find.byType(HeroSlot)).top;
    final heroSize = tester.getSize(find.byType(HeroSlot));
    await tester.tap(find.text('Get started'));
    await waitFor(tester, () => shows('Keep your data safe'));
    expect(find.text('Continue with Google'), findsOneWidget);
    // Says where the backup lives, before asking to sign in.
    expect(shows('private, hidden app data folder'), isTrue);
    expect(shows('Only Simple Money can open it'), isTrue);
    expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);
    // The picture is the same size and in the same place on every page.
    expect(tester.getRect(find.byType(HeroSlot)).top, heroTop);
    expect(tester.getSize(find.byType(HeroSlot)), heroSize);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Skip'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));
    expect(tester.getRect(find.byType(HeroSlot)).top, heroTop);
    expect(tester.takeException(), isNull);

    // Back returns to the backup step.
    await tester.binding.handlePopRoute();
    await waitFor(tester, () => shows('Keep your data safe'));
    await tester.tap(find.text('Skip'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));

    await tester.tap(find.text('Skip'));
    await waitFor(tester, () => done);
    expect(inbox.requests, 0);
    expect((await prefs()).getBool(Onboarding.doneKey), isTrue);
    expect((await prefs()).getBool(Onboarding.backupSeenKey), isTrue);
  });

  testWidgets('without Drive there is no backup step', (tester) async {
    await open(tester);
    await waitFor(tester, () => shows('Welcome to Simple Money'));
    expect(find.text('Back up to Google Drive'), findsNothing);
    await tester.tap(find.text('Get started'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));
    await tester.tap(find.text('Skip'));
    await waitFor(tester, () => done);
    // No backup step was shown, so it isn't marked seen.
    expect((await prefs()).getBool(Onboarding.backupSeenKey), isNull);
  });

  testWidgets('the SMS step says what is used before it asks', (tester) async {
    await open(tester);
    await waitFor(tester, () => shows('Welcome to Simple Money'));
    await tester.tap(find.text('Get started'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));
    expect(shows('Bank transactions are picked out of your SMS'), isTrue);
    expect(find.text('Your Privacy Matters'), findsOneWidget);
    expect(
      find.text('Only bank transaction messages are used'),
      findsOneWidget,
    );
    expect(
      find.text('Messages are read on your device and never uploaded'),
      findsOneWidget,
    );
    expect(shows('ask to allow SMS and notifications'), isTrue);
    // Skip is at the top right; Setup Permissions is the one bottom button.
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Setup Permissions'), findsOneWidget);
    // Nothing is asked until the button is tapped.
    expect(inbox.requests, 0);
  });

  testWidgets('a refused prompt keeps the page; Skip then ends the setup', (
    tester,
  ) async {
    inbox.granted = false;
    await open(tester);
    await waitFor(tester, () => shows('Welcome to Simple Money'));
    await tester.tap(find.text('Get started'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));
    await tester.tap(find.text('Setup Permissions'));
    await waitFor(tester, () => shows('Permission wasn’t given'));
    // Still on the same page, nothing finished, SMS off.
    expect(inbox.requests, 1);
    expect(done, isFalse);
    expect(store.enabled, isFalse);
    expect((await prefs()).getBool(Onboarding.doneKey), isNull);
    expect(find.text('Setup Permissions'), findsOneWidget);

    // Trying again asks again, and is refused again.
    await tester.tap(find.text('Setup Permissions'));
    await waitFor(tester, () => inbox.requests == 2);
    await waitFor(tester, () => shows('Permission wasn’t given'));
    expect(done, isFalse);

    await tester.tap(find.text('Skip'));
    await waitFor(tester, () => done);
    expect((await prefs()).getBool(Onboarding.doneKey), isTrue);
  });

  testWidgets('allowed: scans, lists the accounts found, saves a balance', (
    tester,
  ) async {
    inbox.rows = [
      InboxSms(
        1,
        BankSms(
          sender: 'ATMSBI',
          body:
              'Rs.500 debited from A/c X1234 on 13Sep25. Avl Bal Rs.999999999',
          receivedAt: DateTime(2026, 10, 7, 12),
        ),
      ),
    ];
    await open(tester);
    await waitFor(tester, () => shows('Welcome to Simple Money'));
    await tester.tap(find.text('Get started'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));
    await tester.tap(find.text('Setup Permissions'));
    await waitFor(tester, () => inbox.requests == 1);
    await waitFor(tester, () => store.enabled);
    // The scan ends on its result; the balances wait for the person to go on.
    await waitFor(tester, () => shows('Scan complete'));
    expect(shows('Check your balances'), isFalse);
    expect(inbox.requests, 1);
    expect(store.enabled, isTrue);
    expect(find.bySemanticsLabel('Step 3 of 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Check accounts'));
    await waitFor(tester, () => shows('Check your balances'));

    final accounts = await tester.runAsync(() => AccountRepository(db).load());
    final bank = accounts!.single;
    expect(bank.lastDigits, isNotNull);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '2500.50');
    await tester.tap(find.text('Finish'));
    await waitFor(tester, () => done);
    final saved = await tester.runAsync(() => AccountRepository(db).load());
    expect(saved!.single.balanceMinor, 250050);
    expect((await prefs()).getBool(Onboarding.doneKey), isTrue);
  });

  testWidgets('SMS already on: one step, Finish only', (tester) async {
    inbox.requests = 1; // granted earlier
    await tester.runAsync(() => SmsImportRepository(db).enable(true));
    await open(tester);
    await waitFor(tester, () => shows('Welcome to Simple Money'));
    await tester.tap(find.text('Get started'));
    await waitFor(tester, () => shows('Enable Automatic Detection'));
    expect(find.text('Skip'), findsNothing);
    expect(find.bySemanticsLabel('Step 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Finish'));
    await waitFor(tester, () => done);
    expect(inbox.requests, 1);
  });
}
