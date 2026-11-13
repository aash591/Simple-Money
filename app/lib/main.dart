import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/device_performance.dart';
import 'data/realtime_sms.dart';
import 'data/upi_reminder.dart';
import 'state/appearance_controller.dart';
import 'state/onboarding.dart';
import 'state/vibration_settings.dart';

@pragma('vm:entry-point')
Future<void> smsBackgroundMain() => processBackgroundSms();

@pragma('vm:entry-point')
Future<void> smsCategoryMain() => processBackgroundCategoryPick();

@pragma('vm:entry-point')
Future<void> upiPaymentMain() => processBackgroundUpiPayment();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (_, _, onboarding, _) = await (
    VibrationSettings.instance.restore(),
    DevicePerformance.restore(),
    Onboarding.needed(),
    // The saved style and colours, ready for the very first frame.
    AppearanceController.preload(),
  ).wait;
  // Lets Flutter draw behind the status bar, so screens can show content (or
  // a blurred scrim) through it instead of a solid OS-painted bar.y
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(SimpleMoneyApp(onboarding: onboarding));
}
