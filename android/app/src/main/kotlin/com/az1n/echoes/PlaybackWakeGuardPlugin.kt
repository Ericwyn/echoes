package com.az1n.echoes

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.session.MediaController
import android.media.session.MediaSession
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Keeps the CPU awake across decoder completion and Dart-driven next-track work.
 * Dart sends a heartbeat while playback is requested. Explicit pause/stop releases
 * the lock; a missing heartbeat eventually releases it if Dart stops responding.
 */
class PlaybackWakeGuardPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private companion object {
        const val TAG = "EchoWakeGuard"
        const val HEARTBEAT_TIMEOUT_MS = 5 * 60_000L
    }

    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var active = false
    // Bounded native history survives Dart suspension until the next snapshot.
    private val diagnosticEvents = ArrayDeque<Map<String, Any?>>()
    private var diagnosticSequence = 0L
    private var lastHeartbeatElapsed: Long? = null
    private var lastLockReason = "not_requested"
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            recordDiagnostic(intent.action?.substringAfterLast('.') ?: "power_event")
        }
    }
    private val heartbeatTimeout = Runnable {
        if (active) {
            Log.w(TAG, "heartbeat_timeout releasing playback lock")
            setPlaybackLock(false, "heartbeat_timeout")
            recordDiagnostic("heartbeat_timeout")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.az1n.echoes/playback_wake_guard")
        channel.setMethodCallHandler(this)
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "echoes:playback")
            .apply { setReferenceCounted(false) }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(powerReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(powerReceiver, filter)
        }
        recordDiagnostic("engine_attached")
    }

    @Suppress("DEPRECATION")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf(
                "setActive", "getStatus", "openBatterySettings",
                "openAppSettings", "openPowerSettings", "openSamsungSettings"
            )) {
            result.notImplemented()
            return
        }
        try {
            if (call.method.startsWith("open")) {
                val intent = when (call.method) {
                    "openBatterySettings" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    "openPowerSettings" -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
                    "openSamsungSettings" -> Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY")
                        .setPackage("com.samsung.android.lool").putExtra("activity_type", 2)
                    else -> appSettingsIntent()
                }
                // Some OEMs omit these settings screens; app details is a safe fallback.
                try {
                    context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: ActivityNotFoundException) {
                    context.startActivity(appSettingsIntent())
                } catch (_: SecurityException) {
                    context.startActivity(appSettingsIntent())
                }
                result.success(true)
                return
            }
            if (call.method == "setActive") {
                setPlaybackLock(
                    call.argument<Boolean>("active") == true,
                    call.argument<String>("reason") ?: "unknown"
                )
            }
            val snapshot = recordDiagnostic(call.argument<String>("reason") ?: call.method)
            result.success(snapshot + mapOf("nativeEvents" to diagnosticEvents.toList()))
        } catch (error: Exception) {
            result.error("PLAYBACK_WAKE_GUARD", error.javaClass.simpleName, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun recordDiagnostic(reason: String): Map<String, Any?> {
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val elapsed = SystemClock.elapsedRealtime()
        val snapshot = mutableMapOf<String, Any?>(
                "sequence" to ++diagnosticSequence,
                "reason" to reason,
                "timeMs" to System.currentTimeMillis(),
                "held" to (wakeLock?.isHeld == true),
                "requested" to active,
                "lockReason" to lastLockReason,
                "heartbeatAgeMs" to lastHeartbeatElapsed?.let { elapsed - it },
                "interactive" to power.isInteractive,
                "deviceIdle" to power.isDeviceIdleMode,
                "powerSaveMode" to power.isPowerSaveMode,
                "manufacturer" to Build.MANUFACTURER,
                "batteryExempt" to power.isIgnoringBatteryOptimizations(context.packageName),
                "pid" to Process.myPid(),
                "sdk" to Build.VERSION.SDK_INT,
                "elapsedMs" to elapsed,
                "uptimeMs" to SystemClock.uptimeMillis()
        )
        if (reason == "engine_attached") {
            try {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                snapshot["appVersion"] = info.versionName
                snapshot["appBuild"] = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            } catch (error: Exception) {
                snapshot["versionInspectionError"] = error.javaClass.simpleName
            }
        }
        // A failed inspection must be reported as unknown, not as "service gone".
        try {
            val activity = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val service = activity.getRunningServices(Int.MAX_VALUE).firstOrNull {
                it.service.className == "com.ryanheise.audioservice.AudioService"
            }
            snapshot["servicePresent"] = service != null
            snapshot["serviceForeground"] = service?.foreground
            snapshot["serviceStarted"] = service?.started
            snapshot["servicePid"] = service?.pid
            snapshot["serviceCrashCount"] = service?.crashCount
        } catch (error: Exception) {
            snapshot["serviceInspectionError"] = error.javaClass.simpleName
        }
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val notifications = manager.activeNotifications.filter {
                if (Build.VERSION.SDK_INT >= 26) {
                    it.notification.channelId == "com.az1n.echoes.audio"
                } else {
                    it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)
                }
            }
            snapshot["notificationsEnabled"] = if (Build.VERSION.SDK_INT >= 24) manager.areNotificationsEnabled() else null
            snapshot["mediaNotificationCount"] = notifications.size
            snapshot["notificationOngoing"] = notifications.firstOrNull()?.isOngoing
            val token = notifications.firstOrNull()?.notification?.extras
                ?.getParcelable<MediaSession.Token>(Notification.EXTRA_MEDIA_SESSION)
            snapshot["mediaPlaybackState"] = token?.let { MediaController(context, it).playbackState?.state }
        } catch (error: Exception) {
            snapshot["notificationInspectionError"] = error.javaClass.simpleName
        }
        try {
            val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = connectivity.activeNetwork
            val caps = network?.let { connectivity.getNetworkCapabilities(it) }
            snapshot["networkPresent"] = network != null
            snapshot["networkInternet"] = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            snapshot["networkValidated"] = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            snapshot["networkMetered"] = network?.let { connectivity.isActiveNetworkMetered }
            snapshot["restrictBackground"] = if (Build.VERSION.SDK_INT >= 24) connectivity.restrictBackgroundStatus else null
            snapshot["networkTransport"] = caps?.let {
                listOf(
                    NetworkCapabilities.TRANSPORT_WIFI to "wifi",
                    NetworkCapabilities.TRANSPORT_CELLULAR to "cellular",
                    NetworkCapabilities.TRANSPORT_VPN to "vpn",
                    NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet"
                ).filter { (transport, _) -> it.hasTransport(transport) }
                    .joinToString("+") { (_, name) -> name }
            }
        } catch (error: Exception) {
            snapshot["networkInspectionError"] = error.javaClass.simpleName
        }
        diagnosticEvents.addLast(snapshot)
        if (diagnosticEvents.size > 40) diagnosticEvents.removeFirst()
        return snapshot
    }

    private fun appSettingsIntent() = Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.parse("package:${context.packageName}")
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    @SuppressLint("WakelockTimeout") // Native heartbeat watchdog releases stale playback intent.
    private fun setPlaybackLock(requested: Boolean, reason: String) {
        active = requested
        lastLockReason = reason
        if (requested) lastHeartbeatElapsed = SystemClock.elapsedRealtime()
        handler.removeCallbacks(heartbeatTimeout)
        if (requested) {
            // A non-reference-counted acquire also reasserts the lock if an OEM
            // power manager dropped it while the Java object still reports held.
            val wasHeld = wakeLock?.isHeld == true
            wakeLock?.acquire()
            if (!wasHeld) {
                Log.i(TAG, "acquired reason=$reason")
            }
            handler.postDelayed(heartbeatTimeout, HEARTBEAT_TIMEOUT_MS)
        } else if (wakeLock?.isHeld == true) {
            wakeLock?.release()
            Log.i(TAG, "released reason=$reason")
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        setPlaybackLock(false, "engine_detached")
        context.unregisterReceiver(powerReceiver)
        wakeLock = null
    }
}
