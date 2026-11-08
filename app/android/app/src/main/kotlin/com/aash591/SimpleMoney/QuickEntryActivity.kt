package com.aash591.SimpleMoney

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine

/** A separate translucent task: closing the sheet returns to the launcher. */
class QuickEntryActivity : MainActivity() {
    private var modalBlur: ModalBackgroundBlur? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        modalBlur = ModalBackgroundBlur(this, flutterEngine)
    }

    override fun onDestroy() {
        modalBlur?.dispose()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Launchers such as ColorOS/OxygenOS stop drawing the home screen
        // while "opening" an app from an icon shortcut, which left only black
        // behind this translucent sheet. Draw the wallpaper ourselves there.
        // Keep the same fallback for widgets and reused/legacy shortcuts too:
        // the launcher can stop drawing after the opening animation finishes.
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
        super.onCreate(savedInstanceState)
    }

    override fun getBackgroundMode() = BackgroundMode.transparent

    override fun getInitialRoute() = "/quick/${quickAction(intent) ?: "expense"}"

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = quickAction(intent) ?: return
        // Some launchers reuse the top activity. Flutter's initial route only
        // applies to a new engine, so replace the old sheet for this new tap.
        val entry = quickEntryIntent(this, action)
            .putExtra(QuickShortcuts.FROM_SHORTCUT,
                intent.getBooleanExtra(QuickShortcuts.FROM_SHORTCUT, false))
        finish()
        startActivity(entry)
    }
}
