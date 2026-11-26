package com.ripple.itinerary

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
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
    private var debugChannel: MethodChannel? = null
    private var imageChannel: MethodChannel? = null
    private var imageShares: EventChannel? = null
    private var changed: (() -> Unit)? = null
    private var sharedImage: (() -> Unit)? = null
    private var pickResult: MethodChannel.Result? = null
    private lateinit var pickImage: ActivityResultLauncher<PickVisualMediaRequest>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 系统照片选择器：Android 13 及以上是 Photo Picker，旧版本自动回退。
        pickImage = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
            val result = pickResult
            pickResult = null
            if (uri == null) {
                result?.success(null)
                return@registerForActivityResult
            }
            ImageSchedule.copyPicked(this, uri) { path, message ->
                if (path != null) {
                    result?.success(path)
                } else {
                    result?.error("image_unreadable", message ?: "无法读取图片。", null)
                }
            }
        }
        // 冷启动时可能是从别的应用分享图片进入的。
        if (ImageSchedule.acceptShare(this, intent)) {
            // 消费掉分享意图，避免 Activity 重建时把同一张图再导入一次。
            setIntent(Intent(this, MainActivity::class.java))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 应用已在运行时再次分享，走这里。分享意图不保留在 getIntent() 里。
        if (ImageSchedule.acceptShare(this, intent)) {
            setIntent(Intent(this, MainActivity::class.java))
        }
    }

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
        debugChannel = DebugSettings.register(applicationContext, messenger)
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
        imageChannel = MethodChannel(messenger, "ripple/image-schedule").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> openImagePicker(result)
                    "consumeShared" -> result.success(ImageSchedule.takePendingShare())
                    "analyze" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("image_missing", "缺少图片路径。", null)
                        } else {
                            ImageSchedule.analyze(applicationContext, path, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        imageShares = EventChannel(messenger, "ripple/image-schedule/share").apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    stopShareObserving()
                    val listener: () -> Unit = { events.success(true) }
                    sharedImage = listener
                    ImageSchedule.observers.add(listener)
                    // 分享可能在 Dart 开始监听前就复制完成，这里补发一次。
                    if (ImageSchedule.hasPendingShare()) events.success(true)
                }

                override fun onCancel(arguments: Any?) = stopShareObserving()
            })
        }
    }

    private fun openImagePicker(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "正在打开图片选择器。", null)
            return
        }
        pickResult = result
        try {
            pickImage.launch(
                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
            )
        } catch (_: Exception) {
            pickResult = null
            result.error("picker_unavailable", "无法打开图片选择器。", null)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopObserving()
        stopShareObserving()
        inboxChannel?.setMethodCallHandler(null)
        inboxEvents?.setStreamHandler(null)
        modelChannel?.setMethodCallHandler(null)
        sourcesChannel?.setMethodCallHandler(null)
        logChannel?.setMethodCallHandler(null)
        debugChannel?.setMethodCallHandler(null)
        imageChannel?.setMethodCallHandler(null)
        imageShares?.setStreamHandler(null)
        inboxChannel = null
        inboxEvents = null
        modelChannel = null
        sourcesChannel = null
        logChannel = null
        debugChannel = null
        imageChannel = null
        imageShares = null
        pickResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun stopObserving() {
        changed?.let(NotificationInbox.observers::remove)
        changed = null
    }

    private fun stopShareObserving() {
        sharedImage?.let(ImageSchedule.observers::remove)
        sharedImage = null
    }
}
