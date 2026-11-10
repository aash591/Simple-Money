import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/repositories/upi_repository.dart';
import 'package:simple_money/data/upi_platform.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/upi_payment.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/upi_settings.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';
import 'package:simple_money/ui/transactions/transaction_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/ui/upi/upi_payment_flow.dart';
import 'package:simple_money/ui/welcome/upi_intro.dart';
import 'package:simple_money/ui/more/more_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

class FakeUpiPlatform extends UpiPlatform {
  Completer<String?>? placeResult;
  int placeRequests = 0;
  @override
  Future<void> preparePlace() async {}
  bool seenIntro = true;
  UpiPermissions granted = const UpiPermissions(
    location: 'precise',
    notifications: true,
    camera: true,
  );
  int permissionRequests = 0;
  final reminders = <String>[];
  final cancelled = <String>[];
  @override
  Future<bool> introSeen() async => seenIntro;
  @override
  Future<void> markIntroSeen() async => seenIntro = true;
  @override
  Future<UpiPermissions> permissions() async => granted;
  @override
  Future<UpiPermissions> requestPermissions() async {
    permissionRequests++;
    return granted = const UpiPermissions(
      location: 'precise',
      notifications: true,
      camera: true,
    );
  }

  @override
  Future<void> scheduleReminder(String id, {int seconds = 120}) async =>
      reminders.add(id);
  @override
  Future<void> cancelReminder(String id) async => cancelled.add(id);
  @override
  Future<String?> paymentPlace() async {
    placeRequests++;
    return placeResult == null ? null : await placeResult!.future;
  }

  bool failLaunch = false;
  int launches = 0;
  String? launchedUri;
  int directOpens = 0;
  @override
  Future<void> openApp(UpiApp app) async {
    directOpens++;
  }

  @override
  Future<List<UpiApp>> apps() async => [
    const UpiApp('test.upi', 'Test UPI', null, canShareQr: true),
  ];
  @override
  Future<void> shareQr(UpiApp app, {required String payload}) async {
    launches++;
    launchedUri = payload;
    if (failLaunch) throw StateError('App removed');
  }

  int toasts = 0;
  @override
  Future<void> showToast(String message) async {
    toasts++;
  }
}

class FakeScanner extends MobileScannerPlatform {
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(400, 400),
      numberOfCameras: 1,
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}
}

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore transactions;
  late FakeUpiPlatform platform;
  late MobileScannerPlatform previousScanner;
  late FakeScanner scanner;
  late UpiSettings upiSettings;
  final capture = GlobalKey();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'upi.intro_seen': true});
    await SharedPreferences.getInstance(); // cached, so the intro check is instant
    for (final channel in [UpiPlatform.channel, UpiPlatform.placeChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    }
    previousScanner = MobileScannerPlatform.instance;
    scanner = FakeScanner();
    MobileScannerPlatform.instance = scanner;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    categories = CategoryStore(CategoryRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    platform = FakeUpiPlatform();
    upiSettings = UpiSettings();
    await upiSettings.setEnabled(true);
    await accounts.save(
      name: 'My bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 10000,
    );
    await categories.load();
    await transactions.load();
  });
  tearDown(() async {
    MobileScannerPlatform.instance = previousScanner;
    upiSettings.dispose();
    accounts.dispose();
    categories.dispose();
    transactions.dispose();
    await db.close();
  });

  void testUpiWidgets(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    bool fullSheet = false,
    bool reviewPending = false,
    Brightness? brightness,
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == null ? null : appTheme(brightness),
        // A fresh key on every call forces Flutter to unmount the previous
        // MaterialApp (and any routes pushed on its Navigator) rather than
        // updating it in place — otherwise a route pushed by an earlier
        // pump() stays stuck on top of this rebuilt tree.
        key: UniqueKey(),
        builder: (context, child) => RepaintBoundary(
          key: capture,
          child: UpiSettingsScope(settings: upiSettings, child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                if (fullSheet) {
                  showAddTransactionSheet(
                    context,
                    accountStore: accounts,
                    categoryStore: categories,
                    transactionStore: transactions,
                  );
                } else {
                  showAdaptiveSheet<void>(
                    context,
                    entrance: SheetEntrance.fadeRise,
                    topClearance: 62,
                    dismissible: false,
                    builder: (context) => UpiPaymentFlow(
                      accountStore: accounts,
                      categoryStore: categories,
                      transactionStore: transactions,
                      platform: platform,
                      reviewPending: reviewPending,
                      onBack: () => Navigator.pop(context),
                      onClose: () => Navigator.pop(context),
                    ),
                  );
                }
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testUpiWidgets('pending UPI can be saved as a transfer between accounts', (
    tester,
  ) async {
    await accounts.save(
      name: 'Savings',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
    );
    final source = accounts.accounts.firstWhere((a) => a.name == 'My bank');
    final destination = accounts.accounts.firstWhere(
      (a) => a.name == 'Savings',
    );
    final repo = UpiRepository(db);
    await repo.put(
      PendingUpiPayment(
        id: 'transfer-draft',
        recipient: UpiRecipient.parse('upi://pay?pa=me@bank&pn=Me'),
        amountText: '25',
        categoryId: null,
        accountId: source.id,
        date: DateTime(2026, 9, 12),
      ),
    );
    await pump(tester, reviewPending: true);
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer between accounts'));
    await tester.pumpAndSettle();
    expect(find.text('From account'), findsOneWidget);
    await tester.tap(find.text('My bank'));
    await tester.pumpAndSettle();
    expect(find.text('To account'), findsOneWidget);
    expect(find.text('My bank'), findsNothing);
    await tester.tap(find.text('Savings'));
    await tester.pumpAndSettle();
    expect(find.text('Save this transfer'), findsOneWidget);
    final draft = (await repo.load()).single;
    expect(draft.isTransfer, isTrue);
    expect(draft.toAccountId, destination.id);
    expect(await TransactionRepository(db).load(), isEmpty);
    await tester.tap(find.text('Save transfer'));
    await tester.pumpAndSettle();
    await repo.confirm('transfer-draft');
    final saved = (await TransactionRepository(db).load()).single;
    expect(saved.type.name, 'transfer');
    expect(saved.categoryId, isNull);
    expect(saved.amountMinor, 2500);
    expect(await repo.load(), isEmpty);
    expect(
      accounts.accounts.firstWhere((a) => a.id == source.id).balanceMinor,
      7500,
    );
    expect(
      accounts.accounts.firstWhere((a) => a.id == destination.id).balanceMinor,
      2500,
    );
  });

  testUpiWidgets('More opt-in controls UPI visibility in Add transaction', (
    tester,
  ) async {
    await upiSettings.setEnabled(false);
    await pump(tester, fullSheet: true);
    expect(find.text('Pay with UPI'), findsNothing);
    expect(find.text('Add a transaction'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        builder: (context, child) =>
            UpiSettingsScope(settings: upiSettings, child: child!),
        home: Scaffold(
          body: MoreScreen(
            store: accounts,
            categoryStore: categories,
            transactionStore: transactions,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The toggle moved out of the removed Extras screen and into Settings,
    // where it is a switch row rather than a tappable menu row.
    await tester.ensureVisible(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Google Pay option'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Google Pay option'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(upiSettings.enabled, isTrue);
    await pump(tester, fullSheet: true);
    expect(find.text('Pay with UPI'), findsOneWidget);
    await upiSettings.setEnabled(false);
    await tester.pumpAndSettle();
    expect(find.text('Pay with UPI'), findsNothing);
  });

  Future<void> preparePayment(WidgetTester tester) async {
    expect(find.byTooltip('Pick from contacts'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [
          Barcode(
            rawValue: 'upi://pay?pa=alex@bank&pn=Alex&cu=INR',
            format: BarcodeFormat.qrCode,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(platform.launches, 0);
    expect(find.byType(NumberKeypad), findsOneWidget);
    for (final digit in ['2', '5']) {
      await tester.tap(
        find.descendant(
          of: find.byType(NumberKeypad),
          matching: find.text(digit),
        ),
      );
      await tester.pump();
    }
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(platform.launches, 1);
    expect(Uri.parse(platform.launchedUri!).queryParameters['am'], '25');
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Category'));
    await tester.pumpAndSettle();
    final category = categories.categories.firstWhere(
      (c) => c.type == CategoryType.expense && c.parentId == null,
    );
    await tester.tap(find.text(category.name));
    await tester.pumpAndSettle();
    expect(find.text('Record expense in'), findsOneWidget);
    expect(find.text('Choose expense category'), findsNothing);
    expect(tester.widget<StepSlider>(find.byType(StepSlider)).forward, isTrue);
    await tester.tap(find.text(accounts.accounts.single.name));
    await tester.pumpAndSettle();
    expect(find.text('Save this expense'), findsOneWidget);
    expect(tester.widget<StepSlider>(find.byType(StepSlider)).forward, isTrue);

    // Account review is the final step; the QR was shared before review.
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_UPI_FLOW')) return;
    await tester.runAsync(() async {
      for (final entry in {
        'Roboto':
            "${Platform.environment['FLUTTER_ROOT'] ?? 'C:/tools/flutter'}/bin/cache/artifacts/material_fonts/roboto-regular.ttf",
        'MaterialIcons':
            'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final file = File(entry.value);
        if (await file.exists()) {
          await (FontLoader(entry.key)..addFont(
                Future.value(ByteData.sublistView(await file.readAsBytes())),
              ))
              .load();
        }
      }
    });
    await tester.pumpAndSettle();
    final boundary =
        capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/upi-flow-review').create(recursive: true);
      await File('build/upi-flow-review/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testUpiWidgets(
    'Place arrives during review without blocking payment or losing edits',
    (tester) async {
      platform.placeResult = Completer<String?>();
      await pump(tester);
      await preparePayment(tester);
      expect(platform.placeRequests, 1);
      expect(find.text('Save this expense'), findsOneWidget);
      platform.placeResult!.complete('Indiranagar, Bengaluru');
      await tester.pumpAndSettle();
      expect(find.text('Near Indiranagar, Bengaluru'), findsOneWidget);
      final pending = (await UpiRepository(db).load()).single;
      expect(pending.amountText, '25');
      expect(pending.categoryId, isNotNull);
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      expect(
        transactions.transactions.single.note,
        contains('Near Indiranagar, Bengaluru'),
      );
      expect(await UpiRepository(db).load(), isEmpty);
    },
  );

  testUpiWidgets(
    'The merchant name is never the title; it stays in the note, and a '
    'typed title is saved and offered to the next payment to the same '
    'merchant, clearable with the X',
    (tester) async {
      await pump(tester);
      await preparePayment(tester);
      expect(find.text('Title'), findsOneWidget);
      // The QR carried a real name ("Alex"), so it's prefilled already,
      // clear button and all.
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Add a title'))
            .controller!
            .text,
        'Alex',
      );
      expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Add a title'),
        'Evening snacks',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Add a note'),
        'Shared dinner',
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cancel_rounded), findsNWidgets(2));
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      final first = transactions.transactions.single;
      expect(first.title, 'Evening snacks');
      expect(first.note, contains('Shared dinner'));
      // The merchant's display name lands in the note, not the title.
      expect(first.note, contains('Alex'));
      expect(first.note, isNot(contains('Evening snacks')));

      // A second payment to the same UPI address prefills the saved title.
      // Saving with nothing left pending closes the sheet; reopen it.
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
        BarcodeCapture(
          barcodes: [
            Barcode(
              rawValue: 'upi://pay?pa=alex@bank&pn=Alex&cu=INR',
              format: BarcodeFormat.qrCode,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      for (final digit in ['1', '0']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
        await tester.pump();
      }
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(accounts.accounts.single.name));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Add a title'))
            .controller!
            .text,
        'Evening snacks',
      );
      // Clearing it with the X leaves the next save untitled. (A chip
      // offering the same title back, from category history, is fine.)
      await tester.tap(find.byIcon(Icons.cancel_rounded));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Add a title'))
            .controller!
            .text,
        '',
      );
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      final second = transactions.transactions.firstWhere(
        (t) => t.id != first.id,
      );
      expect(second.title, isNull);
      expect(second.note, contains('Alex'));
    },
  );

  testUpiWidgets(
    "A payment app's own generic name is left out of the title, though it "
    'still appears in the note',
    (tester) async {
      await pump(tester);
      tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
        BarcodeCapture(
          barcodes: [
            Barcode(
              rawValue:
                  'upi://pay?pa=merchant@ybl&pn=PhonePe%20Merchant&cu=INR',
              format: BarcodeFormat.qrCode,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      for (final digit in ['1', '5']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
        await tester.pump();
      }
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();
      final category = categories.categories.firstWhere(
        (c) => c.type == CategoryType.expense && c.parentId == null,
      );
      await tester.tap(find.text(category.name));
      await tester.pumpAndSettle();
      await tester.tap(find.text(accounts.accounts.single.name));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Add a title'))
            .controller!
            .text,
        '',
      );
      expect(find.byIcon(Icons.cancel_rounded), findsNothing);
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      final saved = transactions.transactions.single;
      expect(saved.title, isNull);
      expect(saved.note, contains('PhonePe Merchant'));
    },
  );

  for (final brightness in Brightness.values) {
    testUpiWidgets(
      'Saved payment context and selected category on ${brightness.name} narrow screen',
      (tester) async {
        final repo = UpiRepository(db);
        final category = categories.categories.firstWhere(
          (c) => c.type == CategoryType.expense && c.parentId == null,
        );
        final recipient = UpiRecipient.parse(
          'upi://pay?pa=tea@bank&pn=Tea%20Shop&am=125.50',
        );
        final paid = PendingUpiPayment(
          id: 'previous',
          recipient: recipient,
          amountText: '125.50',
          categoryId: category.id,
          accountId: accounts.accounts.single.id,
          date: DateTime(2026, 9, 20),
          place: 'Indiranagar, Bengaluru',
        );
        await repo.put(paid);
        await repo.confirm(paid.id);
        await repo.put(
          PendingUpiPayment(
            id: 'pending',
            recipient: recipient,
            amountText: '',
            categoryId: null,
            accountId: null,
            date: DateTime(2020, 9, 22, 14, 35),
            place: 'Indiranagar, Bengaluru',
          ),
        );
        await pump(
          tester,
          reviewPending: true,
          brightness: brightness,
          size: const Size(320, 720),
        );
        expect(find.text('Is the payment completed?'), findsOneWidget);
        expect(find.text('22 Sep 2020 · 2:35 PM'), findsOneWidget);
        expect(find.text('Near Indiranagar, Bengaluru'), findsOneWidget);
        expect(platform.placeRequests, 0);
        await shot(tester, 'completed-${brightness.name}');
        await tester.tap(find.text('Yes'));
        await tester.pumpAndSettle();
        expect(find.text('₹125.50'), findsOneWidget);
        await shot(tester, 'amount-${brightness.name}');
        expect(find.text(category.name), findsOneWidget);
        await shot(tester, 'category-${brightness.name}');
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text('Record expense in'), findsOneWidget);
        await tester.tap(find.text(accounts.accounts.single.name));
        await tester.pumpAndSettle();
        await shot(tester, 'save-${brightness.name}');
        await tester.tap(find.text('Save expense'));
        await tester.pumpAndSettle();
        expect(await repo.load(), isEmpty);
        expect(platform.placeRequests, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<void> returnToQuestion(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(find.text('Is the payment completed?'), findsOneWidget);
  }

  Future<void> finishPrefilled(WidgetTester tester) async {
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    if (find.text('Choose category').evaluate().isNotEmpty) {
      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();
      final c = categories.categories.firstWhere(
        (c) => c.type == CategoryType.expense && c.parentId == null,
      );
      await tester.tap(find.text(c.name));
      await tester.pumpAndSettle();
    } else {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Record expense in'), findsOneWidget);
    await tester.tap(find.text(accounts.accounts.single.name));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save expense'));
    await tester.pumpAndSettle();
  }

  testUpiWidgets(
    'UPI button is below income; scanner grows and system back returns to type',
    (tester) async {
      await pump(tester, fullSheet: true);
      expect(
        tester.getTopLeft(find.text('Pay with UPI')).dy,
        greaterThan(tester.getTopLeft(find.text('Add income')).dy),
      );
      await tester.tap(find.text('Pay with UPI'));
      await tester.pumpAndSettle();
      expect(find.text('Scan a UPI QR code'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Pay with UPI')).dy, lessThan(160));
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Add income'), findsOneWidget);
      expect(find.text('Add a transaction'), findsOneWidget);
    },
  );

  testUpiWidgets(
    'handoff keeps balance unchanged until user confirms success',
    (tester) async {
      await pump(tester);
      await preparePayment(tester);
      expect(platform.launches, 1);
      expect(find.text('Save this expense'), findsOneWidget);
      expect((await UpiRepository(db).load()).length, 1);
      expect(accounts.accounts.single.balanceMinor, 10000);
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      expect(transactions.transactions.single.amountMinor, 2500);
      expect(accounts.accounts.single.balanceMinor, 7500);
      expect(await UpiRepository(db).load(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testUpiWidgets(
    'No can keep pending, reopen and delete without posting expense',
    (tester) async {
      await pump(tester);
      await preparePayment(tester);
      await returnToQuestion(tester);
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      // Dismissing the centered alert returns to the same review step.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Is the payment completed?'), findsOneWidget);
      expect((await UpiRepository(db).load()).length, 1);
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep pending'));
      await tester.pumpAndSettle();
      // Let the confirmation toast dismiss before reopening beneath it.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect((await UpiRepository(db).load()).length, 1);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Pending UPI payments (1)'));
      await tester.tap(find.text('Pending UPI payments (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alex'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete draft'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this draft?'), findsOneWidget);
      expect((await UpiRepository(db).load()).length, 1);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await UpiRepository(db).load()).length, 1);
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes, delete'));
      await tester.pumpAndSettle();
      expect(await UpiRepository(db).load(), isEmpty);
      expect(transactions.transactions, isEmpty);
      expect(accounts.accounts.single.balanceMinor, 10000);
    },
  );

  testUpiWidgets('failed app launch keeps recoverable draft and shows error', (
    tester,
  ) async {
    platform.failLaunch = true;
    await pump(tester);
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [
          Barcode(
            rawValue: 'upi://pay?pa=alex@bank&am=25',
            format: BarcodeFormat.qrCode,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Couldn’t open the payment.'), findsOneWidget);
    expect((await UpiRepository(db).load()).length, 1);
    expect(transactions.transactions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testUpiWidgets('QR prefills amount and stops camera before app handoff', (
    tester,
  ) async {
    await pump(tester);
    expect(scanner.starts, 1);
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [
          Barcode(
            rawValue:
                'upi://pay?pa=shop@bank&pn=Tea%20Shop&am=125.50&tr=order123',
            format: BarcodeFormat.qrCode,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Tea Shop'), findsOneWidget);
    expect(find.text('Is the payment completed?'), findsOneWidget);
    expect(
      scanner.starts,
      1,
      reason: 'The outgoing scanner must not restart during its slide.',
    );
    expect(find.byType(MobileScanner), findsNothing);
    // Scanner disposal awaits cancellation of its barcode recurring payment.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(scanner.stops + scanner.disposals, greaterThan(0));
    final uri = Uri.parse(platform.launchedUri!);
    expect(uri.queryParameters['am'], '125.50');
    expect(uri.queryParameters['tr'], 'order123');
    await tester.tap(find.text('₹125.50'));
    await tester.pumpAndSettle();
    expect(find.byType(NumberKeypad), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(NumberKeypad), findsNothing);
    expect(platform.launches, 1);
    expect((await UpiRepository(db).load()).single.amountText, '125.50');
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(find.text('₹125.50'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testUpiWidgets(
    'blocked payment can open direct scanner and reuse its draft',
    (tester) async {
      await pump(tester);
      await preparePayment(tester);
      final draftId = (await UpiRepository(db).load()).single.id;
      await returnToQuestion(tester);
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan directly in a UPI app'));
      await tester.pumpAndSettle();
      expect(find.text('Scan in your UPI app'), findsOneWidget);
      await tester.tap(find.text('Test UPI'));
      await tester.pumpAndSettle();
      expect(platform.launches, 1);
      expect(platform.directOpens, 1);
      expect((await UpiRepository(db).load()).single.id, draftId);
      expect(accounts.accounts.single.balanceMinor, 10000);
      await finishPrefilled(tester);
      expect(transactions.transactions.length, 1);
      expect(accounts.accounts.single.balanceMinor, 7500);
      expect(await UpiRepository(db).load(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testUpiWidgets('above 2000 opens Google Pay itself; 2000 still shares QR', (
    tester,
  ) async {
    await pump(tester);
    void scan(String amount) =>
        tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
          BarcodeCapture(
            barcodes: [
              Barcode(
                rawValue: 'upi://pay?pa=shop@bank&am=$amount',
                format: BarcodeFormat.qrCode,
              ),
            ],
          ),
        );
    scan('2000');
    await tester.pumpAndSettle();
    expect(platform.launches, 1);
    await tester.ensureVisible(find.text('Scan another QR'));
    await tester.tap(find.text('Scan another QR'));
    await tester.pumpAndSettle();
    scan('2000.01');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open Google Pay scanner'), findsOneWidget);
    expect(platform.directOpens, 0);
    await tester.tap(find.text('Open Google Pay'));
    await tester.pumpAndSettle();
    expect(platform.directOpens, 1);
    expect(platform.launches, 1);
    expect((await UpiRepository(db).load()).length, 2);
  });

  testUpiWidgets(
    'queue saves sequentially and reuses merchant category with edits',
    (tester) async {
      await pump(tester);
      await preparePayment(tester);
      await returnToQuestion(tester);
      await tester.ensureVisible(find.text('Scan another QR'));
      await tester.tap(find.text('Scan another QR'));
      await tester.pumpAndSettle();
      tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
        BarcodeCapture(
          barcodes: [
            Barcode(
              rawValue: 'upi://pay?pa=alex@bank&pn=Alex&am=50',
              format: BarcodeFormat.qrCode,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect((await UpiRepository(db).load()).length, 2);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Review payments later?'), findsOneWidget);
      await tester.tap(find.text('Review next'));
      await tester.pumpAndSettle();
      expect(find.text('Is the payment completed?'), findsOneWidget);
      expect((await UpiRepository(db).load()).length, 2);
      expect(transactions.transactions, isEmpty);
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      expect(find.text('Payment not completed'), findsOneWidget);
      await tester.tap(find.text('Review next'));
      await tester.pumpAndSettle();
      expect(find.text('Alex'), findsOneWidget);
      expect((await UpiRepository(db).load()).length, 2);
      expect(transactions.transactions, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep reviewing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();
      final category = categories.categories.firstWhere(
        (c) => c.type == CategoryType.expense && c.parentId == null,
      );
      await tester.tap(find.text(category.name));
      await tester.pumpAndSettle();
      expect(find.text('Record expense in'), findsOneWidget);
      await tester.tap(find.text(accounts.accounts.single.name));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      expect(find.text('Is the payment completed?'), findsOneWidget);
      expect((await UpiRepository(db).load()).length, 1);
      await finishPrefilled(tester);
      expect(await UpiRepository(db).load(), isEmpty);
      expect(transactions.transactions.length, 2);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
        BarcodeCapture(
          barcodes: [
            Barcode(
              rawValue: 'upi://pay?pa=alex@bank&pn=New%20display%20name&am=10',
              format: BarcodeFormat.qrCode,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(find.text(category.name), findsOneWidget);
      expect((await UpiRepository(db).load()).single.categoryId, category.id);
      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();
      expect(find.text('Choose expense category'), findsOneWidget);
    },
  );

  testUpiWidgets(
    'the first time, a full-screen intro comes before the scanner',
    (tester) async {
      platform
        ..seenIntro = false
        ..granted = const UpiPermissions();
      await pump(tester);
      expect(find.byType(UpiIntroScreen), findsOneWidget);
      expect(find.text('Pay with Google Pay'), findsOneWidget);
      expect(find.text('How it works'), findsOneWidget);
      expect(find.byType(MobileScanner), findsNothing);
      await tester.tap(find.text('Set up permissions'));
      await tester.pumpAndSettle();
      expect(platform.permissionRequests, 1);
      expect(platform.seenIntro, isTrue);
      expect(find.byType(UpiIntroScreen), findsNothing);
      expect(find.text('Scan a UPI QR code'), findsOneWidget);
      expect(find.byType(MobileScanner), findsOneWidget);
    },
  );

  testUpiWidgets('Skip leaves the permissions alone but opens the scanner', (
    tester,
  ) async {
    platform
      ..seenIntro = false
      ..granted = const UpiPermissions();
    await pump(tester);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(platform.permissionRequests, 0);
    expect(platform.seenIntro, isTrue);
    expect(find.text('Scan a UPI QR code'), findsOneWidget);
    // Nothing is asked until the button is pressed.
    expect(find.byType(MobileScanner), findsNothing);
    await tester.tap(find.text('Allow permissions'));
    await tester.pumpAndSettle();
    expect(platform.permissionRequests, 1);
    expect(find.byType(MobileScanner), findsOneWidget);
  });

  testUpiWidgets('once set up, the intro offers Continue', (tester) async {
    platform
      ..seenIntro = false
      ..granted = const UpiPermissions(
        location: 'precise',
        notifications: true,
        camera: true,
      );
    await pump(tester);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(platform.permissionRequests, 0);
    expect(find.text('Scan a UPI QR code'), findsOneWidget);
  });

  testUpiWidgets('the intro shows only once', (tester) async {
    await pump(tester);
    expect(find.byType(UpiIntroScreen), findsNothing);
    expect(find.text('Scan a UPI QR code'), findsOneWidget);
  });

  testUpiWidgets('a started payment asks later if it went through', (
    tester,
  ) async {
    await pump(tester);
    await preparePayment(tester);
    final id = (await UpiRepository(db).load()).single.id;
    expect(platform.reminders, [id]);
    expect(platform.cancelled, isEmpty);
    await tester.tap(find.text('Save expense'));
    await tester.pumpAndSettle();
    expect(platform.cancelled, [id]);
  });
}
