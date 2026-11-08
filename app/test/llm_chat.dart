// Drives a real model through the AI tools for the live tests: any
// OpenAI-compatible chat endpoint (llama.cpp, Ollama, ...) with tool calls.
// LLM_URL, LLM_KEY and LLM_MODEL pick it; the conversation is printed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simple_money/data/agent/agent_tools.dart';

final llmUrl = Platform.environment['LLM_URL'];
final _key = Platform.environment['LLM_KEY'] ?? '';
final _model = Platform.environment['LLM_MODEL'] ?? 'default';

/// Why a live test is skipped, or false.
Object get llmSkip =>
    llmUrl == null ? 'Set LLM_URL to run against a model' : false;

class LlmRun {
  final calls = <({String name, Map<String, Object?> args, String reply})>[];
  String answer = '';

  bool called(String name, [bool Function(Map<String, Object?>)? where]) =>
      calls.any((c) => c.name == name && (where == null || where(c.args)));
}

/// Lets the model work with [tools] on [task] until it answers without a
/// tool call. [only] limits the tools offered.
Future<LlmRun> converse(
  AgentTools tools,
  String task, {
  Set<String>? only,
  int turns = 16,
}) async {
  final run = LlmRun();
  final offered = [
    for (final d in tools.definitions)
      if (only == null || only.contains(d['name']))
        {
          'type': 'function',
          'function': {
            'name': d['name'],
            'description': d['description'],
            'parameters': d['inputSchema'],
          },
        },
  ];
  final messages = <Map<String, Object?>>[
    {
      'role': 'system',
      'content':
          '${AgentTools.instructions} Today is '
          '${DateTime.now().toIso8601String().substring(0, 10)}.',
    },
    {'role': 'user', 'content': task},
  ];
  for (var turn = 0; turn < turns; turn++) {
    final response = await http.post(
      Uri.parse('$llmUrl/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_key',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': messages,
        'tools': offered,
        'temperature': 0.2,
        'max_tokens': 4096,
      }),
    );
    expect(response.statusCode, 200, reason: response.body);
    final choice =
        ((jsonDecode(utf8.decode(response.bodyBytes)) as Map)['choices']
                    as List)
                .first
            as Map;
    final message = Map<String, Object?>.from(choice['message'] as Map);
    messages.add({
      'role': 'assistant',
      'content': message['content'] ?? '',
      if (message['tool_calls'] != null) 'tool_calls': message['tool_calls'],
    });
    final toolCalls = (message['tool_calls'] as List?) ?? const [];
    if (toolCalls.isEmpty) {
      run.answer = (message['content'] as String?) ?? '';
      if (run.answer.trim().isEmpty) {
        // ignore: avoid_print
        print('EMPTY (finish_reason: ${choice['finish_reason']})');
      }
      // ignore: avoid_print
      print('MODEL: ${run.answer}');
      break;
    }
    for (final call in toolCalls.cast<Map>()) {
      final fn = call['function'] as Map;
      Map<String, Object?> args;
      try {
        args = Map<String, Object?>.from(
          jsonDecode(fn['arguments'] as String? ?? '{}') as Map,
        );
      } catch (_) {
        args = {};
      }
      final result = await tools.call(fn['name'] as String, args);
      final text =
          ((result['content'] as List).single as Map)['text'] as String;
      run.calls.add((name: fn['name'] as String, args: args, reply: text));
      // ignore: avoid_print
      print(
        'CALL ${fn['name']} ${jsonEncode(args)}\n  → '
        '${text.length > 400 ? '${text.substring(0, 400)}…' : text}',
      );
      messages.add({
        'role': 'tool',
        'tool_call_id': call['id'],
        'content': text,
      });
    }
  }
  // ignore: avoid_print
  print('Tool calls: ${run.calls.length}');
  return run;
}

/// Whether [answer] states [amount] (a decimal string like "12345.60"),
/// written any common way: 12345.60, 12,345.60, ₹12,345.6 or rounded to
/// rupees.
bool statesAmount(String answer, String amount) {
  final plain = answer.replaceAll(RegExp(r'(?<=\d),(?=\d)'), '');
  final value = double.parse(amount);
  for (final m in RegExp(r'\d+(?:\.\d+)?').allMatches(plain)) {
    final n = double.parse(m[0]!);
    if ((n - value).abs() < 1.0) return true;
  }
  return false;
}
