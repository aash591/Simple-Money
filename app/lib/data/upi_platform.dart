import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'upi_qr_image.dart';

class UpiApp {
  const UpiApp(
    this.packageName,
    this.name,
    this.icon, {
    this.canShareQr = false,
  });
  final String packageName, name;
  final Uint8List? icon;
  final bool canShareQr;
}

/// What the payment sheet may use: the camera to scan with, how exact the
/// place is, and whether the "did it go through?" notification can show.
class UpiPermissions {
  const UpiPermissions({
    this.location = 'denied',
    this.notifications = false,
    this.camera = false,
  });
  final String location;
  final bool notifications, camera;

  bool get precise => location == 'precise';
  bool get allGranted => precise && notifications && camera;
}

class UpiPlatform {
  static const channel = MethodChannel('simple_money/upi');
  static const placeChannel = MethodChannel('simple_money/payment_place');

  /// Optional Android locality capture. Neither permission nor geocoding is
  /// awaited by the payment handoff. Unsupported/denied devices omit place.
  Future<void> preparePlace() async {
    try {
      await placeChannel.invokeMethod<void>('prepare');
    } catch (_) {}
  }

  static const _introKey = 'upi.intro_seen';

  /// Whether the Google Pay intro has been shown (and dismissed) before.
  Future<bool> introSeen() async =>
      (await SharedPreferences.getInstance()).getBool(_introKey) ?? false;

  Future<void> markIntroSeen() async =>
      (await SharedPreferences.getInstance()).setBool(_introKey, true);

  UpiPermissions _permissions(Map<String, dynamic>? map) => UpiPermissions(
    location: map?['location'] as String? ?? 'denied',
    notifications: map?['notifications'] == true,
    camera: map?['camera'] == true,
  );

  Future<UpiPermissions> permissions() async {
    try {
      return _permissions(
        await placeChannel.invokeMapMethod<String, dynamic>('status'),
      );
    } catch (_) {
      return const UpiPermissions();
    }
  }

  /// Asks for the camera, precise location and notifications together.
  Future<UpiPermissions> requestPermissions() async {
    try {
      return _permissions(
        await placeChannel.invokeMapMethod<String, dynamic>('request'),
      );
    } catch (_) {
      return const UpiPermissions();
    }
  }

  /// Asks, in [seconds], whether the payment [id] went through.
  Future<void> scheduleReminder(String id, {int seconds = 120}) async {
    try {
      await channel.invokeMethod<void>('scheduleReminder', {
        'id': id,
        'seconds': seconds,
      });
    } catch (_) {}
  }

  Future<void> cancelReminder(String id) async {
    try {
      await channel.invokeMethod<void>('cancelReminder', {'id': id});
    } catch (_) {}
  }

  Future<String?> paymentPlace() async {
    try {
      return await placeChannel
          .invokeMethod<String>('capture')
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  Future<List<UpiApp>> apps() async {
    final rows = await channel.invokeListMethod<dynamic>('apps') ?? [];
    return rows
        .map(
          (dynamic row) => UpiApp(
            row['package'] as String,
            row['name'] as String,
            row['icon'] as Uint8List?,
            canShareQr: row['canShareQr'] == true,
          ),
        )
        .toList();
  }

  Future<void> shareQr(UpiApp app, {required String payload}) async {
    if (!app.canShareQr) {
      throw StateError('QR image sharing is unavailable in this app.');
    }
    final png = await generateUpiQrPng(payload);
    await channel.invokeMethod<void>('shareQr', {
      'package': app.packageName,
      'png': png,
    });
  }

  Future<void> openApp(UpiApp app) =>
      channel.invokeMethod<void>('openApp', {'package': app.packageName});

  /// Shows a native Android toast. Unlike the in-app toast, this survives
  /// [openApp]/[shareQr] backgrounding SimpleMoney right after it is shown.
  Future<void> showToast(String message) =>
      channel.invokeMethod<void>('showToast', {'message': message});
}
