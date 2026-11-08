package com.aash591.SimpleMoney

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.widget.RemoteViews

internal fun quickAction(intent: Intent): String? =
    intent.getStringExtra("quick_action")?.takeIf { it in listOf("upi", "income", "expense") }

internal fun quickEntryIntent(context: Context, action: String) =
    Intent(context, QuickEntryActivity::class.java)
        // PendingIntent identity ignores extras. Include the action here so a
        // single widget can never replace a grid button's income/expense/UPI.
        .setAction("${context.packageName}.quick.$action")
        .putExtra("quick_action", action)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

private fun quickEntryPending(context: Context, requestCode: Int, action: String) =
    PendingIntent.getActivity(context, requestCode, quickEntryIntent(context, action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

abstract class QuickActionWidget(private val action: String, private val layout: Int) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, layout)
            views.setOnClickPendingIntent(R.id.quick_widget, quickEntryPending(context, id, action))
            manager.updateAppWidget(id, views)
        }
    }
}
class ScanUpiWidget : QuickActionWidget("upi", R.layout.scan_upi_widget)
class AddIncomeWidget : QuickActionWidget("income", R.layout.add_income_widget)
class AddExpenseWidget : QuickActionWidget("expense", R.layout.add_expense_widget)

/** 2x2 grid: open the app, add income, add expense, scan UPI. */
class QuickActionsGridWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.quick_actions_grid_widget)
            val open = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Widget id + intent action identify each button without overlapping
            // the request codes used by the individual widgets.
            views.setOnClickPendingIntent(R.id.grid_app, PendingIntent.getActivity(context, id, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            views.setOnClickPendingIntent(R.id.grid_income, quickEntryPending(context, id, "income"))
            views.setOnClickPendingIntent(R.id.grid_expense, quickEntryPending(context, id, "expense"))
            views.setOnClickPendingIntent(R.id.grid_upi, quickEntryPending(context, id, "upi"))
            manager.updateAppWidget(id, views)
        }
    }
}

/** Replace saved RemoteViews too, so existing widgets pick up intent fixes. */
internal fun refreshQuickActionWidgets(context: Context) {
    val manager = AppWidgetManager.getInstance(context)
    for (provider in listOf(ScanUpiWidget(), AddIncomeWidget(), AddExpenseWidget(), QuickActionsGridWidget())) {
        val ids = manager.getAppWidgetIds(ComponentName(context, provider.javaClass))
        if (ids.isNotEmpty()) provider.onUpdate(context, manager, ids)
    }
}

/**
 * Long-press app icon shortcuts. Published at runtime rather than from a
 * static shortcuts.xml, which would hardcode the package and miss the
 * .profile build's suffixed application id.
 */
object QuickShortcuts {
    /** Intent extra marking a launch from an app-icon shortcut; see QuickEntryActivity. */
    const val FROM_SHORTCUT = "from_shortcut"

    fun publish(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return
        fun shortcut(action: String, label: Int, icon: Int, rank: Int) =
            ShortcutInfo.Builder(context, action)
                .setActivity(ComponentName(context, MainActivity::class.java))
                .setShortLabel(context.getString(label))
                .setIcon(Icon.createWithResource(context, icon))
                .setIntent(quickEntryIntent(context, action).putExtra(FROM_SHORTCUT, true))
                .setRank(rank)
                .build()
        manager.dynamicShortcuts = listOf(
            shortcut("expense", R.string.shortcut_expense, R.drawable.shortcut_expense, 0),
            shortcut("income", R.string.shortcut_income, R.drawable.shortcut_income, 1),
            shortcut("upi", R.string.shortcut_scan, R.drawable.shortcut_scan, 2),
        )
    }
}
