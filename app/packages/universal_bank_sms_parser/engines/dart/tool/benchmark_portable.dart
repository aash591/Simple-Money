import 'dart:convert';
import 'dart:io';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'project_data.dart';

/// Run from engines/dart. This reports warm interpreter latency only.
void main() {
  final activation = Stopwatch()..start();
  final pack = readRuntimePacks('../../distribution/packs');
  final json = pack.toJson();
  final engine = PortableSmsEngine(pack);
  activation.stop();
  final fixtures = readConformanceCases('../../tests/conformance');
  final messages = fixtures
      .map(
        (f) => BankSms(
          sender: f['input']['sender'],
          body: f['input']['body'],
          receivedAt: DateTime.parse(f['input']['receivedAt']),
        ),
      )
      .toList();
  for (var i = 0; i < 5000; i++) {
    engine.parse(messages[i % messages.length]);
  }
  final samples = <double>[];
  var candidates = 0;
  final watch = Stopwatch();
  for (var i = 0; i < 10000; i++) {
    watch
      ..reset()
      ..start();
    final result = engine.parse(messages[i % messages.length]);
    watch.stop();
    samples.add(watch.elapsedTicks * 1000000 / watch.frequency);
    if (result.candidate != null) candidates++;
  }
  samples.sort();
  stdout.writeln(
    jsonEncode({
      'engineVersion': portableEngineVersion,
      'packVersion': engine.packVersion,
      'formats': json['rules'].length,
      'samples': samples.length,
      'activationMs': activation.elapsedMicroseconds / 1000,
      'warmMedianUs': samples[samples.length ~/ 2],
      'warmP95Us': samples[(samples.length * 0.95).floor()],
      'candidates': candidates,
      'dartVersion': Platform.version,
    }),
  );
}
