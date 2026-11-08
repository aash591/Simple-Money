package com.aash591.SimpleMoney

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.DateFormat
import java.util.Date

/**
 * A user-started, timed AI session. The relay connection and the tools run
 * in Dart; this foreground service only keeps the process from being frozen
 * while the user is in Claude or ChatGPT, and shows the session with
 * "+15 min" and "Stop". It never starts on its own.
 */
class AiSessionService : Service() {
    companion object {
        const val ACTION_SHOW = "show"
        const val ACTION_STOP = "stop"
        const val ACTION_EXTEND = "extend"
        private const val CHANNEL = "ai_session"
        private const val NOTIFICATION_ID = 7301

        /** Notification buttons, passed on to Dart. */
        @Volatile
        var onAction: ((String) -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP, ACTION_EXTEND -> {
                // With no app to tell (it was closed), Stop just ends the session.
                val handler = onAction
                if (handler != null) handler(intent.action!!) else if (intent.action == ACTION_STOP) stopSelf()
                return START_NOT_STICKY
            }
        }
        val endsAt = intent?.getLongExtra("endsAt", 0L) ?: 0L
        val connected = intent?.getBooleanExtra("connected", false) ?: false
        val waiting = intent?.getIntExtra("suggestions", 0) ?: 0
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, notification(endsAt, connected, waiting),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        return START_NOT_STICKY
    }

    private fun notification(endsAt: Long, connected: Boolean, waiting: Int): android.app.Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.ai_session_channel), NotificationManager.IMPORTANCE_LOW))
        fun action(name: String) = PendingIntent.getService(this, name.hashCode(),
            Intent(this, AiSessionService::class.java).setAction(name), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0,
            packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE)
        val until = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(endsAt))
        val status = getString(if (connected) R.string.ai_session_connected else R.string.ai_session_connecting)
        val text = buildString {
            append(getString(R.string.ai_session_until, until))
            append(" · ").append(status)
            if (waiting > 0) append(" · ").append(resources.getQuantityString(R.plurals.ai_session_suggestions, waiting, waiting))
        }
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification_app)
            .setContentTitle(getString(R.string.ai_session_title))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
            .addAction(0, getString(R.string.ai_session_extend), action(ACTION_EXTEND))
            .addAction(0, getString(R.string.ai_session_stop), action(ACTION_STOP))
            .build()
    }
}

/** `simple_money/ai_session`: the session service and the relay credential. */
class AiSessionBridge(private val context: Context) {
    // Outside Android backup, so a restored phone registers afresh rather than
    // sharing an identity with the old one.
    private val credential get() = File(context.noBackupFilesDir, "ai_relay_device.json")

    fun attach(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/ai_session")
        AiSessionService.onAction = { action -> channel.invokeMethod(action, null) }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val intent = Intent(context, AiSessionService::class.java)
                        .setAction(AiSessionService.ACTION_SHOW)
                        .putExtra("endsAt", call.argument<Number>("endsAt")!!.toLong())
                        .putExtra("connected", call.argument<Boolean>("connected") == true)
                        .putExtra("suggestions", call.argument<Int>("suggestions") ?: 0)
                    try {
                        ContextCompat.startForegroundService(context, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // Android refuses a foreground start from the background.
                        result.success(false)
                    }
                }
                "hide" -> {
                    context.stopService(Intent(context, AiSessionService::class.java))
                    result.success(null)
                }
                "readCredential" -> result.success(credential.takeIf { it.exists() }?.readText())
                "writeCredential" -> {
                    val value = call.arguments as String?
                    if (value == null) credential.delete() else credential.writeText(value)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        AiSessionService.onAction = null
    }
}
