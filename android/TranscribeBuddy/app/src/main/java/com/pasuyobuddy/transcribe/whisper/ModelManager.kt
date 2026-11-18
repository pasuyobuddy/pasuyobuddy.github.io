package com.pasuyobuddy.transcribe.whisper

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext

enum class WhisperModel(val id: String, val label: String, val fileName: String, val sizeMb: Int) {
    BASE("base", "Base – faster", "ggml-base-q5_1.bin", 57),
    SMALL("small", "Small – more accurate (best for Tagalog)", "ggml-small-q5_1.bin", 181);

    val url: String get() = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$fileName"

    companion object {
        fun byId(id: String) = entries.firstOrNull { it.id == id } ?: BASE
    }
}

object ModelManager {

    fun file(ctx: Context, m: WhisperModel): File = File(File(ctx.filesDir, "models").apply { mkdirs() }, m.fileName)

    fun isDownloaded(ctx: Context, m: WhisperModel): Boolean {
        val f = file(ctx, m)
        // sanity check: at least 80% of the expected size
        return f.exists() && f.length() > m.sizeMb * 1024L * 1024L * 8 / 10
    }

    fun delete(ctx: Context, m: WhisperModel) {
        file(ctx, m).delete()
    }

    /** Downloads the model, reporting progress 0..1. Resumes a partial download when possible. */
    suspend fun download(ctx: Context, m: WhisperModel, onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val target = file(ctx, m)
        val part = File(target.path + ".part")
        var attempt = 0
        while (true) {
            try {
                downloadOnce(m, part, onProgress)
                break
            } catch (e: IOException) {
                attempt++
                if (attempt >= 4) throw IOException("Model download failed: ${e.message}. Check your internet and try again.", e)
                delay(2000L * attempt)
            }
        }
        if (!part.renameTo(target)) throw IOException("Could not save model file")
    }

    private suspend fun downloadOnce(m: WhisperModel, part: File, onProgress: (Float) -> Unit) {
        val existing = if (part.exists()) part.length() else 0L
        val conn = (URL(m.url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            if (existing > 0) setRequestProperty("Range", "bytes=$existing-")
        }
        try {
            val code = conn.responseCode
            val append = code == HttpURLConnection.HTTP_PARTIAL
            if (code != HttpURLConnection.HTTP_OK && !append) throw IOException("HTTP $code")
            val already = if (append) existing else 0L
            val total = conn.contentLengthLong.let { if (it > 0) it + already else m.sizeMb * 1024L * 1024L }
            var done = already
            var lastReport = -1
            conn.inputStream.use { input ->
                java.io.FileOutputStream(part, append).use { out ->
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        val pct = ((done * 1000) / total).toInt()
                        if (pct != lastReport) {
                            lastReport = pct
                            onProgress((done.toFloat() / total).coerceIn(0f, 1f))
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }
}
