import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/statements/pending_statement_files.dart';
import 'package:simple_money/state/ad_gate.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  // Statement files kept for a one-tap import go to a throwaway folder.
  final pending = Directory.systemTemp.createTempSync('simple_money_test');
  PendingStatementFiles.defaultDirectory = () async => pending;
  // No ad SDK answers in tests: an ad-to-unlock goes straight through.
  AdGate.enabled = false;
  await testMain();
}
