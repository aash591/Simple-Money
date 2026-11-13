package com.aash591.SimpleMoney

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.RenderMode
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class TransactionSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val prefs = context.getSharedPreferences("realtime_sms", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", false)) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (parts.isEmpty()) return
        enqueue(context, parts.first().originatingAddress ?: "",
            parts.joinToString("") { it.messageBody ?: "" }, parts.first().timestampMillis)
    }

    companion object {
        fun enqueue(context: Context, sender: String, body: String, receivedAt: Long) {
            val prefs = context.getSharedPreferences("realtime_sms", Context.MODE_PRIVATE)
            val payload = JSONObject().put("sender", sender).put("body", body)
                .put("receivedAt", receivedAt).toString()
            val key = MessageDigest.getInstance("SHA-256").digest(payload.toByteArray())
                .joinToString("") { "%02x".format(it) }
            // Keep large multipart messages out of WorkManager's limited Data object.
            if (!prefs.edit().putString(key, payload).commit()) return
            val request = OneTimeWorkRequestBuilder<TransactionSmsWorker>()
                .setInputData(workDataOf("key" to key))
            if (Build.VERSION.SDK_INT >= 31) request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            WorkManager.getInstance(context).enqueueUniqueWork(
                "transaction_sms", ExistingWorkPolicy.APPEND_OR_REPLACE, request.build())
        }
    }
}

class TransactionSmsWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val key = inputData.getString("key") ?: return Result.failure()
        val prefs = applicationContext.getSharedPreferences("realtime_sms", Context.MODE_PRIVATE)
        val raw = prefs.getString(key, null) ?: return Result.success()
        if (!prefs.getBoolean("enabled", false)) {
            prefs.edit().remove(key).commit()
            return Result.success()
        }
        if (!runDart(applicationContext, "smsBackgroundMain", raw)) return Result.retry()
        prefs.edit().remove(key).commit()
        return Result.success()
    }
}

/** A tap on a category pill: saved in the background, without opening the app. */
class SmsCategoryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("sms_id") ?: return
        if (!intent.hasExtra("category_id")) return
        val request = OneTimeWorkRequestBuilder<SmsCategoryWorker>().setInputData(workDataOf(
            "id" to id, "category" to intent.getIntExtra("category_id", 0)))
        if (Build.VERSION.SDK_INT >= 31) request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        // Queued in order, so the last pill tapped is the one that stays.
        WorkManager.getInstance(context).enqueueUniqueWork(
            "sms_category", ExistingWorkPolicy.APPEND_OR_REPLACE, request.build())
    }
}

class SmsCategoryWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val payload = JSONObject().put("id", inputData.getString("id"))
            .put("category", inputData.getInt("category", 0)).toString()
        if (runDart(applicationContext, "smsCategoryMain", payload)) return Result.success()
        return if (runAttemptCount < 2) Result.retry() else Result.failure()
    }
}

/** Runs a Dart entrypoint in a headless engine, handing it [payload]; true once it reports success. */
internal fun runDart(context: Context, entrypoint: String, payload: String): Boolean {
    val main = Handler(Looper.getMainLooper())
    val completed = CountDownLatch(1)
    var engine: FlutterEngine? = null
    var success = false
    main.post {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
            val created = FlutterEngine(context)
            engine = created
            RealtimeSmsNotifications.attach(context, created)
            UpiNotifications.attach(context, created)
            MethodChannel(created.dartExecutor.binaryMessenger, "simple_money/sms_worker")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "message" -> result.success(payload)
                        "complete" -> {
                            success = call.arguments == true
                            result.success(null)
                            completed.countDown()
                        }
                        else -> result.notImplemented()
                    }
                }
            created.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), entrypoint))
        } catch (_: Exception) { completed.countDown() }
    }
    try { completed.await(90, TimeUnit.SECONDS) } finally {
        main.post { engine?.destroy() }
    }
    return success
}

object RealtimeSmsNotifications {
    fun attach(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/sms_notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "activeIds" -> result.success(context.getSystemService(NotificationManager::class.java)
                        .activeNotifications.filter { it.id == 0 && it.tag != null }.map { it.tag })
                    "enabled" -> {
                        context.getSharedPreferences("realtime_sms", Context.MODE_PRIVATE)
                            .edit().putBoolean("enabled", call.arguments == true).apply()
                        result.success(null)
                    }
                    "show" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            show(context, call.arguments as Map<String, Any>)
                            context.sendBroadcast(Intent("${context.packageName}.SMS_LEDGER_CHANGED").setPackage(context.packageName))
                            result.success(null)
                        } catch (_: Exception) { result.error("notification", "Could not update notification", null) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun show(context: Context, data: Map<String, Any>) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context,
                Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = "bank_transactions"
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(channel, context.getString(R.string.sms_channel_name),
                NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.sms_channel_description)
            })
        val id = data["id"] as String
        fun action(field: String): PendingIntent {
            val intent = Intent(context, SmsNotificationActivity::class.java)
                .setData(Uri.parse("simplemoney://sms/$id/$field"))
                .putExtra("sms_id", id).putExtra("sms_field", field)
            return PendingIntent.getActivity(context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        if (data["savedTitle"] != null) {
            val message = data["savedMessage"] as String
            manager.notify(id, 0, NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_sms_transaction)
                .setContentTitle(data["savedTitle"] as String)
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .addAction(0, context.getString(R.string.sms_action_undo),
                    action("undo_category:${data["undoToken"]}"))
                .setContentIntent(action("transaction"))
                .setAutoCancel(false).setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).build())
            return
        }
        val credit = data["credit"] == true
        val accent = ContextCompat.getColor(context, if (credit) R.color.sms_credit else R.color.sms_debit)
        fun text(key: String) = data[key] as? String ?: ""
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_sms_transaction)
            .setColor(accent)
            .setContentTitle(text("title"))
            .setContentText(text("text"))
            .setWhen((data["receivedAt"] as? Number)?.toLong() ?: System.currentTimeMillis())
            .setShowWhen(true)
            .setContentIntent(action("transaction"))
            .setAutoCancel(false).setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            // Lock screen: say something arrived without revealing the amount.
            .setPublicVersion(NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_sms_transaction)
                .setContentTitle(context.getString(R.string.sms_public_title))
                .setContentText(text("bank")).build())
        // Android shows three actions. Account steps come first, "More…" is always
        // last, and category pills take whatever room is left.
        var taken = 0
        fun step(show: Boolean, label: Int, field: String) {
            if (!show) return
            builder.addAction(0, context.getString(label), action(field))
            taken++
        }
        step(data["needsAccount"] == true, R.string.sms_action_add_account, "create_account")
        step(data["chooseAccount"] == true, R.string.sms_action_choose_account, "account")
        step(data["newAccount"] == true, R.string.sms_action_undo, "undo_account")
        @Suppress("UNCHECKED_CAST")
        val pills = (data["suggestions"] as? List<Map<String, Any>>).orEmpty()
        for (pill in pills.take((2 - taken).coerceAtLeast(0))) {
            val category = (pill["id"] as Number).toInt()
            val intent = Intent(context, SmsCategoryReceiver::class.java)
                .setData(Uri.parse("simplemoney://sms/$id/pick/$category"))
                .putExtra("sms_id", id).putExtra("category_id", category)
            builder.addAction(0, pill["label"] as String, PendingIntent.getBroadcast(context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        builder.addAction(0, context.getString(R.string.sms_action_more), action("category"))
        manager.notify(id, 0, builder.build())
    }
}

class SmsNotificationActivity : MainActivity() {
    private var modalBlur: ModalBackgroundBlur? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        modalBlur = ModalBackgroundBlur(this, flutterEngine)
    }
    override fun onDestroy() {
        modalBlur?.dispose()
        super.onDestroy()
    }
    override fun getBackgroundMode() = BackgroundMode.transparent
    // See QuickEntryActivity: a transparent SurfaceView, not a TextureView.
    override fun getRenderMode() = RenderMode.surface
    override fun getInitialRoute() = "/sms/${intent.getStringExtra("sms_id")}/${intent.getStringExtra("sms_field")}"
}
