package com.aash591.SimpleMoney

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class ImprovementBridge(private val activity: FlutterFragmentActivity) {
    companion object { private val busy = AtomicBoolean(false) }
    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/help_improve")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSettings" -> {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:" + activity.packageName)))
                        result.success(null)
                    }
                    "credentials" -> result.success(
                        mapOf("token" to BuildConfig.IMPROVEMENT_TOKEN, "chat" to BuildConfig.IMPROVEMENT_CHAT),
                    )
                    "report" -> {
                        val messages = call.argument<List<Map<String, Any>>>("messages").orEmpty()
                        when {
                            Build.VERSION.SDK_INT < 26 -> result.error("unsupported", "Requires Android 8 or later.", null)
                            BuildConfig.IMPROVEMENT_TOKEN.isEmpty() -> result.error("configuration", "Reporting is not configured in this build.", null)
                            messages.isEmpty() -> result.error("empty", "Choose a message to report.", null)
                            !busy.compareAndSet(false, true) -> result.error("busy", "A report is already being sent.", null)
                            else -> Thread {
                                try {
                                    val count = ImprovementExporter(activity.applicationContext).report(messages)
                                    activity.runOnUiThread { result.success(count) }
                                } catch (_: Exception) {
                                    activity.runOnUiThread { result.error("delivery", "Delivery could not be confirmed. Check with the developer before retrying to avoid duplicates.", null) }
                                } finally { busy.set(false) }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
