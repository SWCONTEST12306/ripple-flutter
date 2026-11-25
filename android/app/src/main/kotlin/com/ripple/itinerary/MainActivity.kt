package com.ripple.itinerary

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var inboxChannel: MethodChannel? = null
    private var inboxEvents: EventChannel? = null
    private var modelChannel: MethodChannel? = null
    private var sourcesChannel: MethodChannel? = null
    private var logChannel: MethodChannel? = null
    private var changed: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ripple/backdrop",
            BackdropViewFactory()
        )

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        modelChannel = ModelSettings.register(applicationContext, messenger)
        sourcesChannel = NotificationSources.register(applicationContext, messenger)
        logChannel = DiagnosticLog.register(applicationContext, messenger)
        inboxChannel = MethodChannel(messenger, "ripple/notifications").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "inbox" -> NotificationInbox.snapshot(applicationContext, result)
                    "openSettings" -> try {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    } catch (_: ActivityNotFoundException) {
                        result.error("settings_unavailable", null, null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        inboxEvents = EventChannel(messenger, "ripple/notifications/changes").apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    stopObserving()
                    val listener: () -> Unit = { events.success(true) }
                    changed = listener
                    NotificationInbox.observers.add(listener)
                }

                override fun onCancel(arguments: Any?) = stopObserving()
            })
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopObserving()
        inboxChannel?.setMethodCallHandler(null)
        inboxEvents?.setStreamHandler(null)
        modelChannel?.setMethodCallHandler(null)
        sourcesChannel?.setMethodCallHandler(null)
        logChannel?.setMethodCallHandler(null)
        inboxChannel = null
        inboxEvents = null
        modelChannel = null
        sourcesChannel = null
        logChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun stopObserving() {
        changed?.let(NotificationInbox.observers::remove)
        changed = null
    }
}
