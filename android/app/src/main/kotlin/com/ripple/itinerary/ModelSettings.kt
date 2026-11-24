package com.ripple.itinerary

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object ModelSettings {
    private const val KEY_ALIAS = "ripple.notification-model.v1"
    private const val IV_SIZE = 12

    data class Source(val name: String, val since: Long)

    data class Configuration(
        val url: String,
        val model: String,
        val credential: String,
        val sources: Map<String, Source>,
    ) {
        fun allows(entry: NotificationEntry): Boolean {
            val source = sources[entry.packageName] ?: return false
            return entry.postedAt >= source.since && !entry.sensitive
        }
    }

    @Synchronized
    fun current(context: Context): Configuration? = read(file(context))?.let { saved ->
        val sources = saved.optJSONObject("sources") ?: JSONObject()
        Configuration(
            saved.getString("url"), saved.getString("model"), saved.getString("credential"),
            sources.keys().asSequence().associateWith { id ->
                val source = sources.getJSONObject(id)
                Source(source.getString("name"), source.getLong("since"))
            },
        )
    }

    fun register(context: Context, messenger: BinaryMessenger): MethodChannel = MethodChannel(
        messenger,
        "ripple/model",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(),
    ).apply {
        setMethodCallHandler { call, result ->
            try {
                handle(context, call, result)
            } catch (_: Exception) {
                result.error("model_storage_unavailable", null, null)
            }
        }
    }

    @Synchronized
    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val file = file(context)
        when (call.method) {
            "read" -> {
                val saved = current(context)
                result.success(saved?.let {
                    mapOf("url" to it.url, "model" to it.model, "sources" to it.sources.mapValues { (_, source) -> source.name })
                })
            }
            "save" -> {
                val url = call.argument<String>("url")!!
                val model = call.argument<String>("model")!!
                val supplied = call.argument<String>("credential")
                val previous = if (supplied == null) current(context) else runCatching { current(context) }.getOrNull()
                val credential = supplied ?: previous?.takeIf { it.url == url }?.credential
                if (credential.isNullOrBlank()) {
                    result.error("credential_required", null, null)
                    return
                }
                val now = System.currentTimeMillis()
                val previousSources = previous?.takeIf { it.url == url }?.sources.orEmpty()
                val selected = call.argument<Map<String, String>>("sources").orEmpty()
                val sources = selected.mapValues { (id, name) ->
                    JSONObject(mapOf("name" to name, "since" to (previousSources[id]?.since ?: now)))
                }
                write(file, JSONObject(mapOf(
                    "url" to url, "model" to model, "credential" to credential, "sources" to JSONObject(sources),
                )))
                NotificationInbox.settingsChanged(context, retryFailures = previous?.let {
                    it.url == url && (it.credential != credential || it.model != model)
                } == true)
                result.success(null)
            }
            "remove" -> {
                val keyStore = keyStore()
                keyStore.deleteEntry(KEY_ALIAS)
                file.delete()
                NotificationInbox.settingsChanged(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "notification-model.enc"))

    private fun read(file: AtomicFile): JSONObject? {
        val bytes = try {
            file.readFully()
        } catch (_: FileNotFoundException) {
            return null
        }
        val key = keyStore().getKey(KEY_ALIAS, null) as SecretKey
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes, 0, IV_SIZE))
        return JSONObject(cipher.doFinal(bytes, IV_SIZE, bytes.size - IV_SIZE).toString(Charsets.UTF_8))
    }

    private fun write(file: AtomicFile, settings: JSONObject) {
        val key = keyStore().getKey(KEY_ALIAS, null) as? SecretKey ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(
                    KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build())
            }.generateKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        check(cipher.iv.size == IV_SIZE)
        val bytes = cipher.iv + cipher.doFinal(settings.toString().toByteArray(Charsets.UTF_8))
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (error: IOException) {
            file.failWrite(stream)
            throw error
        }
    }
}
