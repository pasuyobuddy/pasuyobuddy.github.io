package com.pasuyobuddy.transcribe.audio

import android.content.Context
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Small wrapper around MediaPlayer with Compose-observable state. */
class AudioPlayer(path: String) {
    private val mp = MediaPlayer()
    val durationMs: Int
    var playing by mutableStateOf(false)
        private set
    var positionMs by mutableIntStateOf(0)
        private set

    init {
        mp.setDataSource(path)
        mp.prepare()
        durationMs = mp.duration.coerceAtLeast(0)
        mp.setOnCompletionListener {
            playing = false
            positionMs = durationMs
        }
    }

    fun toggle() {
        if (playing) {
            mp.pause(); playing = false
        } else {
            if (positionMs >= durationMs - 50) mp.seekTo(0)
            mp.start(); playing = true
        }
    }

    fun seekTo(ms: Int, play: Boolean) {
        val target = ms.coerceIn(0, durationMs)
        mp.seekTo(target)
        positionMs = target
        if (play && !playing) { mp.start(); playing = true }
    }

    /** Call periodically (e.g. every 250 ms) while visible to refresh [positionMs]. */
    fun tick() {
        if (playing) positionMs = try { mp.currentPosition } catch (_: Exception) { positionMs }
    }

    fun release() {
        try { mp.stop() } catch (_: Exception) { }
        mp.release()
        playing = false
    }

    companion object {
        fun create(path: String): AudioPlayer? = try { AudioPlayer(path) } catch (_: Exception) { null }
    }
}

data class Recording(val file: File, val title: String, val createdAt: Long, val durationMs: Long)

/** Meeting recordings saved in the app's private "recordings" folder. */
object Recordings {
    fun dir(ctx: Context): File = File(ctx.filesDir, "recordings").apply { mkdirs() }

    fun list(ctx: Context): List<Recording> =
        dir(ctx).listFiles { f -> f.isFile && f.length() > 0 }
            ?.map { f ->
                val ts = f.nameWithoutExtension.substringAfter("meeting_").toLongOrNull() ?: f.lastModified()
                Recording(f, titleFor(ts), ts, durationOf(f))
            }
            ?.sortedByDescending { it.createdAt }
            ?: emptyList()

    fun titleFor(ts: Long): String =
        "Meeting " + SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.US).format(Date(ts))

    private fun durationOf(f: File): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(f.path)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try { r.release() } catch (_: Exception) { }
        }
    }
}
