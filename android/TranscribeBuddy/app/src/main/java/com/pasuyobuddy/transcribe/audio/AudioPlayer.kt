package com.pasuyobuddy.transcribe.audio

import android.content.ContentValues
import android.content.Context
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pasuyobuddy.transcribe.data.TranscriptStore
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** An audio reference is either a file path or a content:// URI (recordings saved in the phone's Recordings folder). */
fun isContentRef(ref: String) = ref.startsWith("content://")

/** Small wrapper around MediaPlayer with Compose-observable state. */
class AudioPlayer(ctx: Context, ref: String) {
    private val mp = MediaPlayer()
    val durationMs: Int
    var playing by mutableStateOf(false)
        private set
    var positionMs by mutableIntStateOf(0)
        private set

    init {
        if (isContentRef(ref)) mp.setDataSource(ctx, Uri.parse(ref)) else mp.setDataSource(ref)
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
        fun create(ctx: Context, ref: String): AudioPlayer? = try { AudioPlayer(ctx, ref) } catch (_: Exception) { null }
    }
}

data class Recording(val ref: String, val title: String, val createdAt: Long, val durationMs: Long)

/**
 * Recordings. On Android 10+ they are saved in the phone's shared "Recordings/Transcribe Buddy" folder
 * (Music/Transcribe Buddy on Android 10–11) so the file picker, Files app and other apps can see them.
 * Older phones keep them in the app's private folder.
 */
object Recordings {
    private const val FOLDER = "Transcribe Buddy"
    private val nameFmt get() = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US)

    val usesSharedFolder: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    fun folderLabel(): String = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "Recordings › $FOLDER" else "Music › $FOLDER"

    private fun relativePath(): String =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Environment.DIRECTORY_RECORDINGS else Environment.DIRECTORY_MUSIC) + "/" + FOLDER

    private fun collection(): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

    fun privateDir(ctx: Context): File = File(ctx.filesDir, "recordings").apply { mkdirs() }

    fun titleFor(ts: Long): String =
        "Recording " + SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.US).format(Date(ts))

    /** Creates a new (pending) recording entry in the shared folder. Android 10+ only. */
    fun createShared(ctx: Context, ts: Long): Uri? {
        if (!usesSharedFolder) return null
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, "Recording ${nameFmt.format(Date(ts))}.m4a")
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
            put(MediaStore.Audio.Media.RELATIVE_PATH, relativePath())
            put(MediaStore.Audio.Media.TITLE, titleFor(ts))
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }
        return ctx.contentResolver.insert(collection(), values)
    }

    /** Makes a finished recording visible to other apps. */
    fun publish(ctx: Context, uri: Uri) {
        if (!usesSharedFolder) return
        val values = ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) }
        ctx.contentResolver.update(uri, values, null, null)
    }

    fun list(ctx: Context): List<Recording> {
        val out = ArrayList<Recording>()
        if (usesSharedFolder) {
            val proj = arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.DISPLAY_NAME, MediaStore.Audio.Media.DATE_ADDED, MediaStore.Audio.Media.DURATION)
            try {
                ctx.contentResolver.query(
                    collection(), proj,
                    "${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ? AND ${MediaStore.Audio.Media.IS_PENDING} = 0",
                    arrayOf("%$FOLDER%"), "${MediaStore.Audio.Media.DATE_ADDED} DESC"
                )?.use { c ->
                    while (c.moveToNext()) {
                        val id = c.getLong(0)
                        val name = c.getString(1) ?: "Recording"
                        val added = c.getLong(2) * 1000
                        val uri = Uri.withAppendedPath(collection(), id.toString()).toString()
                        val dur = c.getLong(3).takeIf { it > 0 } ?: durationOf(ctx, uri)
                        out.add(Recording(uri, name.substringBeforeLast('.'), added, dur))
                    }
                }
            } catch (_: Exception) { }
        }
        // older recordings still in the private folder (phones below Android 10, or not moved yet)
        privateDir(ctx).listFiles { f -> f.isFile && f.length() > 0 }?.forEach { f ->
            val ts = f.nameWithoutExtension.substringAfter("meeting_").toLongOrNull() ?: f.lastModified()
            out.add(Recording(f.path, titleFor(ts), ts, durationOf(ctx, f.path)))
        }
        return out.sortedByDescending { it.createdAt }
    }

    /** Moves recordings from the old private folder into the shared folder (Android 10+). */
    fun migratePrivate(ctx: Context) {
        if (!usesSharedFolder) return
        val files = privateDir(ctx).listFiles { f -> f.isFile && f.length() > 0 } ?: return
        if (files.isEmpty()) return
        val transcripts = TranscriptStore.list(ctx)
        for (f in files) {
            try {
                val ts = f.nameWithoutExtension.substringAfter("meeting_").toLongOrNull() ?: f.lastModified()
                val uri = createShared(ctx, ts) ?: continue
                ctx.contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out) } }
                publish(ctx, uri)
                transcripts.filter { it.audioPath == f.path }.forEach { TranscriptStore.save(ctx, it.copy(audioPath = uri.toString())) }
                f.delete()
            } catch (_: Exception) { /* keep the private copy if anything fails */ }
        }
    }

    fun exists(ctx: Context, ref: String): Boolean =
        if (isContentRef(ref)) try { ctx.contentResolver.openFileDescriptor(Uri.parse(ref), "r")?.use { true } ?: false } catch (_: Exception) { false }
        else File(ref).exists()

    /** Returns true if deleted. A recording made before reinstalling the app may need to be deleted in the Files app. */
    fun delete(ctx: Context, ref: String): Boolean =
        try {
            if (isContentRef(ref)) ctx.contentResolver.delete(Uri.parse(ref), null, null) > 0 else File(ref).delete()
        } catch (_: Exception) { false }

    /** Whisper needs a real file: copy a shared recording to the cache first. */
    fun toLocalFile(ctx: Context, ref: String): File {
        if (!isContentRef(ref)) return File(ref)
        val dir = File(ctx.cacheDir, "inputs").apply { mkdirs() }
        val f = File(dir, "rec_${System.currentTimeMillis()}.m4a")
        ctx.contentResolver.openInputStream(Uri.parse(ref))!!.use { i -> f.outputStream().use { o -> i.copyTo(o) } }
        return f
    }

    fun durationOf(ctx: Context, ref: String): Long {
        val r = MediaMetadataRetriever()
        return try {
            if (isContentRef(ref)) r.setDataSource(ctx, Uri.parse(ref)) else r.setDataSource(ref)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try { r.release() } catch (_: Exception) { }
        }
    }
}
