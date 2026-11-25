import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'keep_alive_phones.dart';

/// One step and where it stands.
class KeepStatus {
  const KeepStatus(
    this.step,
    this.done, {
    required this.confirmable,
    this.byUser = false,
  });
  final KeepStep step;
  final bool done;

  /// Done only because the user said so, not because Android said it.
  final bool byUser;

  /// The phone may say "off" while the maker's own switch is on, or have no
  /// way to say at all: the user can mark the step done themselves.
  final bool confirmable;
}

/// Where every step stands on this phone, most urgent first.
class KeepAliveState {
  const KeepAliveState(this.family, this.steps);
  final PhoneFamily family;
  final List<KeepStatus> steps;

  int get left => steps.where((s) => !s.done).length;
}

/// Android's battery, background, permission-reset and maker-specific
/// settings, for the steps that keep SimpleMoney from being stopped.
class KeepAlivePlatform {
  static const _channel = MethodChannel('simple_money/keep_alive');

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<KeepAliveState> state() async =>
      parseState(await _channel.invokeMapMethod<String, dynamic>('state'));

  /// What the phone reported, as steps. Visible for tests.
  @visibleForTesting
  static KeepAliveState parseState(Map<String, dynamic>? map) {
    final family = PhoneFamily.parse(map?['family']);
    final confirmed = {...?(map?['confirmed'] as List?)?.cast<String>()};
    final asked = <String, bool?>{
      'battery': map?['battery'] as bool?,
      'background': map?['background'] as bool?,
      'access': map?['access'] as bool?,
    };
    return KeepAliveState(family, [
      for (final step in keepStepsFor(family, access: asked['access'] != null))
        KeepStatus(
          step,
          // What Android says, or what the user confirmed.
          (step.checked && asked[step.id] == true) ||
              confirmed.contains(step.id),
          byUser:
              confirmed.contains(step.id) &&
              !(step.checked && asked[step.id] == true),
          // A stock phone's answer is the truth; a maker's skin can differ.
          // A maker's own switch can only be confirmed.
          confirmable: !step.checked || family != PhoneFamily.stock,
        ),
    ]);
  }

  /// Opens the Android page for [stepId].
  Future<void> open(String stepId) =>
      _channel.invokeMethod<void>('open', stepId);

  /// Marks [stepId] done (or not) by the user's word.
  Future<void> setConfirmed(String stepId, bool done) =>
      _channel.invokeMethod<void>('setConfirmed', {'id': stepId, 'done': done});
}
