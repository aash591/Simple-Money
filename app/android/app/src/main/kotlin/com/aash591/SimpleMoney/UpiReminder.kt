package com.aash591.SimpleMoney

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * "Did your payment go through?" for a UPI payment started from Simple Money.
 * Shown a little after the payment app opens, while the payment is still
 * pending, with the likeliest categories as pills.
 */
object UpiNotifications {
    private const val CHANNEL = "bank_transactions"
    private fun work(id: String) = "upi_reminder_$id"

    fun schedule(context: Context, id: String, seconds: Int) {
        val request = OneTimeWorkRequestBuilder<UpiReminderWorker>()
            .setInitialDelay(seconds.toLong().coerceIn(15, 3600), TimeUnit.SECONDS)
            .setInputData(workDataOf("id" to id)).build()
        WorkManager.getInstance(context).enqueueUniqueWork(work(id), ExistingWorkPolicy.REPLACE, request)
    }

    fun cancel(context: Context, id: String) {
        WorkManager.getInstance(context).cancelUniqueWork(work(id))
        context.getSystemService(NotificationManager::class.java).cancel("upi:$id", 1)
    }

    fun attach(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/upi_notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            show(context, call.arguments as Map<String, Any>)
                            result.success(null)
                        } catch (_: Exception) { result.error("notification", "Could not show notification", null) }
                    }
                    "cancel" -> {
                        cancel(context, call.arguments as String)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun show(context: Context, data: Map<String, Any>) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context,
                Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.sms_channel_name),
                NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.sms_channel_description)
            })
        val id = data["id"] as String
        fun text(key: String) = data[key] as? String ?: ""
        // A tap on the body opens the app, which then asks about pending payments.
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_sms_transaction)
            .setContentTitle(text("title"))
            .setContentText(text("text"))
            .setStyle(NotificationCompat.BigTextStyle().bigText(text("text")))
            .setAutoCancel(true).setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_sms_transaction)
                .setContentTitle(context.getString(R.string.upi_public_title)).build())
        if (open != null) builder.setContentIntent(PendingIntent.getActivity(context, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        if (data["done"] == true) {
            // "keep": news worth reading later (the bank confirmed a payment).
            if (data["keep"] != true) builder.setTimeoutAfter(60_000)
        } else {
            // Android shows three actions: up to two category pills, then "Not paid".
            @Suppress("UNCHECKED_CAST")
            val pills = (data["suggestions"] as? List<Map<String, Any>>).orEmpty()
            for (pill in pills.take(2)) {
                builder.addAction(0, pill["label"] as String,
                    receiver(context, id, "pay/${(pill["id"] as Number).toInt()}")
                        { putExtra("category_id", (pill["id"] as Number).toInt()) })
            }
            builder.addAction(0, context.getString(R.string.upi_action_not_paid),
                receiver(context, id, "discard") { putExtra("discard", true) })
        }
        manager.notify("upi:$id", 1, builder.build())
    }

    private fun receiver(context: Context, id: String, path: String, extras: Intent.() -> Unit): PendingIntent {
        val intent = Intent(context, UpiPaymentReceiver::class.java)
            .setData(Uri.parse("simplemoney://upi/$id/$path")).putExtra("upi_id", id).apply(extras)
        return PendingIntent.getBroadcast(context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}

class UpiReminderWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val id = inputData.getString("id") ?: return Result.failure()
        val payload = JSONObject().put("id", id).put("remind", true).toString()
        if (runDart(applicationContext, "upiPaymentMain", payload)) return Result.success()
        return if (runAttemptCount < 2) Result.retry() else Result.failure()
    }
}

/** A tap on a pill or "Not paid": saved in the background, without opening the app. */
class UpiPaymentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("upi_id") ?: return
        val data = workDataOf("id" to id,
            "category" to (if (intent.hasExtra("category_id")) intent.getIntExtra("category_id", 0) else 0),
            "discard" to intent.getBooleanExtra("discard", false))
        val request = OneTimeWorkRequestBuilder<UpiPaymentWorker>().setInputData(data)
        if (Build.VERSION.SDK_INT >= 31) request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        WorkManager.getInstance(context).enqueueUniqueWork(
            "upi_payment_$id", ExistingWorkPolicy.APPEND_OR_REPLACE, request.build())
    }
}

class UpiPaymentWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val payload = JSONObject().put("id", inputData.getString("id"))
            .put("category", inputData.getInt("category", 0))
            .put("discard", inputData.getBoolean("discard", false)).toString()
        if (runDart(applicationContext, "upiPaymentMain", payload)) return Result.success()
        return if (runAttemptCount < 2) Result.retry() else Result.failure()
    }
}
