import 'dart:convert';
import 'dart:io';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

/// Source indexes are filesystem metadata, resolved before compiling the DSL.
List<Map<String, dynamic>> readCountrySources(String rulesRoot) {
  final indexes =
      Directory(rulesRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last == 'country.json')
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (indexes.isEmpty) throw const FormatException('No country.json indexes');
  return indexes.map((file) {
    final source = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final references = source['banks'] as List;
    source['banks'] = references.map((reference) {
      if (reference is! String ||
          !RegExp(r'^[a-z0-9_-]+/rules\.json$').hasMatch(reference)) {
        throw const FormatException('Bank reference must be BANK/rules.json');
      }
      return jsonDecode(
        File.fromUri(file.parent.uri.resolve(reference)).readAsStringSync(),
      ) as Map<String, dynamic>;
    }).toList();
    return source;
  }).toList();
}

List<Map<String, dynamic>> readConformanceCases(String root) {
  final files =
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      ...(jsonDecode(file.readAsStringSync()) as List)
          .cast<Map<String, dynamic>>(),
  ];
}

RuntimeRulePack readRuntimePacks(String root) {
  final files =
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  const compiler = RuleCompiler();
  return compiler.mergeRuntimePacks([
    for (final file in files)
      compiler.loadRuntime(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      ),
  ]);
}
