package com.aash591.SimpleMoney

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import androidx.core.os.CancellationSignal
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/** Best-effort locality, captured while opening a payment. No tracking service,
 * API key, coordinates on disk, or background-location permission. */
class PaymentPlaceBridge(private val activity: FlutterFragmentActivity) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val preferences by lazy { activity.getSharedPreferences("PaymentPlace", Context.MODE_PRIVATE) }
    private val manager by lazy { activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager }
    private val waiting = mutableListOf<(String?) -> Unit>()
    private var active = false
    private var generation = 0
    private var signal: CancellationSignal? = null
    private var timeout: Runnable? = null
    private var lastPlace: String? = null
    private var lastFixAt = 0L
    private data class CachedPlace(val value: String, val at: Long)
    private val cache = linkedMapOf<String, CachedPlace>()
    private var asking: MethodChannel.Result? = null
    private val permission = activity.registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (permitted()) capture { }
        asking?.success(status())
        asking = null
    }

    private fun granted(name: String) = ContextCompat.checkSelfPermission(activity, name) == PackageManager.PERMISSION_GRANTED
    private fun permitted() = granted(Manifest.permission.ACCESS_FINE_LOCATION) || granted(Manifest.permission.ACCESS_COARSE_LOCATION)

    /** What the payment sheet can rely on: camera, location precision, and whether notifications may show. */
    private fun status() = mapOf(
        "location" to when {
            granted(Manifest.permission.ACCESS_FINE_LOCATION) -> "precise"
            granted(Manifest.permission.ACCESS_COARSE_LOCATION) -> "approximate"
            else -> "denied"
        },
        "notifications" to (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)),
        "camera" to granted(Manifest.permission.CAMERA),
    )

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "simple_money/payment_place").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    if (permitted()) capture { }
                    result.success(null)
                }
                "status" -> result.success(status())
                // Precise first: Android 12+ lets the user narrow it to approximate.
                "request" -> {
                    if (asking != null) { result.success(status()); return@setMethodCallHandler }
                    asking = result
                    preferences.edit().putBoolean("asked", true).apply()
                    val wanted = mutableListOf(Manifest.permission.CAMERA, Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                    if (Build.VERSION.SDK_INT >= 33) wanted.add(Manifest.permission.POST_NOTIFICATIONS)
                    permission.launch(wanted.toTypedArray())
                }
                "capture" -> capture { result.success(it) }
                else -> result.notImplemented()
            }
        }
    }

    private fun capture(done: (String?) -> Unit) {
        if (!permitted() || !Geocoder.isPresent()) { done(null); return }
        val now = SystemClock.elapsedRealtime()
        if (lastPlace != null && now - lastFixAt in 0..120_000) { done(lastPlace); return }
        waiting.add(done)
        if (active) return
        active = true
        val token = ++generation
        fun finish(place: String?, fixAt: Long = 0L) {
            if (token != generation || !active) return
            active = false
            timeout?.let { main.removeCallbacks(it) }
            signal?.cancel()
            signal = null
            if (place != null) { lastPlace = place; lastFixAt = fixAt }
            val callbacks = waiting.toList()
            waiting.clear()
            callbacks.forEach { it(place) }
        }
        fun located(location: Location?) {
            if (token != generation || !active) return
            if (location == null || now - location.elapsedRealtimeNanos / 1_000_000 !in -10_000..120_000 || location.accuracy > 5000) {
                finish(null); return
            }
            val fixAt = location.elapsedRealtimeNanos / 1_000_000
            val key = "${(location.latitude * 100).roundToInt()}:${(location.longitude * 100).roundToInt()}"
            val cached = cache[key]
            if (cached != null && now - cached.at < 6 * 60 * 60 * 1000) { finish(cached.value, fixAt); return }
            fun resolved(addresses: List<Address>) {
                main.post {
                    if (token != generation || !active) return@post
                    val address = addresses.firstOrNull()
                    val place = address?.let {
                        listOfNotNull(it.subLocality, it.locality ?: it.subAdminArea)
                            .map(String::trim).filter(String::isNotEmpty).distinct().joinToString(", ")
                            .ifEmpty { it.adminArea ?: "" }.take(120).ifEmpty { null }
                    }
                    if (place != null) {
                        if (cache.size >= 16) cache.remove(cache.keys.first())
                        cache[key] = CachedPlace(place, now)
                    }
                    finish(place, fixAt)
                }
            }
            val geocoder = Geocoder(activity.applicationContext, Locale.getDefault())
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    geocoder.getFromLocation(location.latitude, location.longitude, 1, object : Geocoder.GeocodeListener {
                        override fun onGeocode(addresses: MutableList<Address>) { resolved(addresses) }
                        override fun onError(errorMessage: String?) { main.post { finish(null) } }
                    })
                } else {
                    worker.execute {
                        try {
                            @Suppress("DEPRECATION")
                            val addresses = geocoder.getFromLocation(location.latitude, location.longitude, 1)
                            resolved(addresses.orEmpty())
                        } catch (_: Exception) { main.post { finish(null) } }
                    }
                }
            } catch (_: Exception) { finish(null) }
        }
        timeout = Runnable { finish(null) }.also { main.postDelayed(it, 8_000) }
        try {
            val last = manager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            if (last != null && now - last.elapsedRealtimeNanos / 1_000_000 in 0..120_000 && last.accuracy <= 5000) {
                located(last)
            } else if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                signal = CancellationSignal()
                LocationManagerCompat.getCurrentLocation(manager, LocationManager.NETWORK_PROVIDER, signal,
                    ContextCompat.getMainExecutor(activity)) { located(it) }
            } else { finish(null) }
        } catch (_: Exception) { finish(null) }
    }

    fun dispose() {
        generation++
        timeout?.let { main.removeCallbacks(it) }
        signal?.cancel()
        waiting.toList().forEach { it(null) }
        waiting.clear()
        worker.shutdownNow()
    }
}
