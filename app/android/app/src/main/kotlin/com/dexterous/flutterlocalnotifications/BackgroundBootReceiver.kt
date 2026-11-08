// Lives in the plugin's package: rescheduleNotifications is package-private.
package com.dexterous.flutterlocalnotifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Does what the plugin's ScheduledNotificationBootReceiver does, off the
 * main thread.
 *
 * Re-arming means parsing the plugin's whole cache of scheduled reminders
 * and making an AlarmManager call for each one — most of a second with a
 * few hundred of them. Android 15+ also sends BOOT_COMPLETED whenever a
 * force-stopped app starts again (which some launchers do on swiping it from
 * Recents), and Dart draws on the main thread, so the plugin's receiver
 * froze that launch. Re-arming only reads the cache, never writes it.
 */
class BackgroundBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> Unit
            else -> return
        }
        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                FlutterLocalNotificationsPlugin.rescheduleNotifications(app)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
