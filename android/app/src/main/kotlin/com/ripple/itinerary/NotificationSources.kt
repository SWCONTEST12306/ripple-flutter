package com.ripple.itinerary

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.text.Collator
import java.util.Locale

/**
 * Which applications Ripple may read notifications from. The list is written by the
 * settings page and read by the listener, the extractor and the inbox.
 */
internal object NotificationSources {
    private const val ICON_SIZE = 96
    private val icons = HashMap<String, ByteArray?>()

    data class Configuration(val master: Boolean, val apps: Map<String, String>) {
        fun records(entry: NotificationEntry): Boolean =
            master && apps.containsKey(entry.packageName)

        fun analyzes(entry: NotificationEntry): Boolean = records(entry) && !entry.sensitive
    }

    @Synchronized
    fun current(context: Context): Configuration {
        val file = file(context)
        read(file)?.let { return it }
        val migrated = migrate(context)
        runCatching { write(file, migrated) }
        return migrated
    }

    @Synchronized
    fun save(context: Context, config: Configuration) = write(file(context), config)

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel = MethodChannel(
        messenger,
        "ripple/notification-sources",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(),
    ).apply {
        setMethodCallHandler { call, result ->
            try {
                handle(context, call, result)
            } catch (_: Exception) {
                result.error("sources_unavailable", null, null)
            }
        }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "read" -> {
                val config = current(context)
                result.success(
                    mapOf(
                        "authorized" to NotificationInbox.hasAccess(context),
                        "master" to config.master,
                        "apps" to config.apps,
                    ),
                )
            }
            "save" -> {
                val master = call.argument<Boolean>("master") == true
                val apps = call.argument<Map<String, String>>("apps").orEmpty()
                val previous = current(context)
                save(context, Configuration(master, apps))
                NotificationInbox.settingsChanged(
                    context,
                    retryFailures = master && (!previous.master || apps.keys.any { it !in previous.apps }),
                )
                result.success(null)
            }
            "apps" -> result.success(installed(context).map {
                mapOf("packageName" to it.key, "label" to it.value)
            })
            "icon" -> result.success(icon(context, call.arguments as? String ?: ""))
            else -> result.notImplemented()
        }
    }

    /** Launchable applications, sorted like the system app list. */
    private fun installed(context: Context): Map<String, String> {
        val labels = HashMap<String, String>()
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val activities = try {
            context.packageManager.queryIntentActivities(intent, 0)
        } catch (_: Exception) {
            emptyList()
        }
        for (activity in activities) {
            val packageName = activity.activityInfo?.packageName ?: continue
            if (packageName == context.packageName) continue
            val label = try {
                activity.loadLabel(context.packageManager).toString().trim()
            } catch (_: Exception) {
                ""
            }.ifEmpty { packageName }
            val existing = labels[packageName]
            if (existing == null || label.length < existing.length) labels[packageName] = label
        }
        for ((packageName, label) in current(context).apps) labels.putIfAbsent(packageName, label)
        val collator = Collator.getInstance(Locale.getDefault())
        val sorted = LinkedHashMap<String, String>()
        val order = Comparator<Map.Entry<String, String>> { first, second ->
            collator.compare(first.value, second.value)
        }
        for (entry in labels.entries.sortedWith(order)) sorted[entry.key] = entry.value
        return sorted
    }

    private fun icon(context: Context, packageName: String): ByteArray? = synchronized(icons) {
        if (!icons.containsKey(packageName)) {
            icons[packageName] = runCatching {
                context.packageManager.getApplicationIcon(packageName).toPng(ICON_SIZE)
            }.getOrNull()
        }
        icons[packageName]
    }

    private fun Drawable.toPng(size: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        try {
            setBounds(0, 0, size, size)
            draw(Canvas(bitmap))
            val output = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            return output.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "notification-sources.json"))

    private fun read(file: AtomicFile): Configuration? = try {
        val data = JSONObject(file.readFully().toString(Charsets.UTF_8))
        val apps = data.optJSONObject("apps") ?: JSONObject()
        Configuration(
            data.optBoolean("master"),
            apps.keys().asSequence().associateWith { apps.optString(it) },
        )
    } catch (_: FileNotFoundException) {
        null
    } catch (_: Exception) {
        null
    }

    private fun write(file: AtomicFile, config: Configuration) {
        val apps = JSONObject()
        for ((packageName, label) in config.apps) apps.put(packageName, label)
        val bytes = JSONObject(mapOf("master" to config.master, "apps" to apps))
            .toString().toByteArray(Charsets.UTF_8)
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (error: IOException) {
            file.failWrite(stream)
            throw error
        }
    }

    /** Keeps the application choices made in the previous version of the model settings. */
    private fun migrate(context: Context): Configuration {
        val legacy = runCatching {
            ModelSettings.raw(context)?.optJSONObject("sources")
        }.getOrNull() ?: return Configuration(false, emptyMap())
        val apps = legacy.keys().asSequence().associateWith { legacy.optString(it) }
        return Configuration(apps.isNotEmpty(), apps)
    }
}
