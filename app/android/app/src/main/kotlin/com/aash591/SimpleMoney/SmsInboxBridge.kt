package com.aash591.SimpleMoney

import android.Manifest
import android.content.pm.PackageManager
import android.provider.Telephony
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Read-only inbox access, requested only after the user enables bank SMS. */
class SmsInboxBridge(private val activity: FlutterFragmentActivity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingPermission: MethodChannel.Result? = null
    @Volatile private var disposed = false
    private val permission = activity.registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        pendingPermission?.success(granted() && receivesSms())
        pendingPermission = null
    }

    private fun granted() = ContextCompat.checkSelfPermission(
        activity, Manifest.permission.READ_SMS
    ) == PackageManager.PERMISSION_GRANTED

    private fun receivesSms() = ContextCompat.checkSelfPermission(
        activity, Manifest.permission.RECEIVE_SMS
    ) == PackageManager.PERMISSION_GRANTED

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/sms_inbox")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(granted() && receivesSms())
                    "requestPermission" -> {
                        if (pendingPermission != null) result.error("busy", "SMS permission is already being requested.", null)
                        else {
                            pendingPermission = result
                            permission.launch(arrayOf(Manifest.permission.READ_SMS,
                                Manifest.permission.RECEIVE_SMS,
                                *if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray()))
                        }
                    }
                    "readPage" -> {
                        if (!granted()) {
                            result.error("permission", "Allow SMS access to read your inbox.", null)
                            return@setMethodCallHandler
                        }
                        val afterId = (call.argument<Number>("afterId")?.toLong() ?: 0L).coerceAtLeast(0L)
                        val since = (call.argument<Number>("since")?.toLong() ?: 0L).coerceAtLeast(0L)
                        val limit = (call.argument<Number>("limit")?.toInt() ?: 200).coerceIn(1, 200)
                        worker.execute {
                            try {
                                val rows = mutableListOf<Map<String, Any>>()
                                activity.contentResolver.query(
                                    Telephony.Sms.Inbox.CONTENT_URI,
                                    arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
                                    "${Telephony.Sms._ID} > ? AND ${Telephony.Sms.DATE} >= ?",
                                    arrayOf(afterId.toString(), since.toString()),
                                    "${Telephony.Sms._ID} ASC"
                                ).use { cursor ->
                                    checkNotNull(cursor) { "The SMS provider is unavailable." }
                                    while (rows.size < limit && cursor.moveToNext()) {
                                        rows.add(mapOf("id" to cursor.getLong(0),
                                            "sender" to (cursor.getString(1) ?: ""),
                                            "body" to (cursor.getString(2) ?: ""),
                                            "receivedAt" to cursor.getLong(3)))
                                    }
                                }
                                activity.runOnUiThread { if (!disposed) result.success(rows) }
                            } catch (error: Exception) {
                                activity.runOnUiThread { if (!disposed) result.error("inbox", "Could not read the SMS inbox. Check SMS permission and try again.", null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    fun dispose() {
        disposed = true
        pendingPermission?.success(false)
        pendingPermission = null
        worker.shutdownNow()
    }
}
