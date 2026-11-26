package com.pasuyobuddy.transcribe.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.pasuyobuddy.transcribe.MainActivity
import com.pasuyobuddy.transcribe.audio.AudioDecoder
import com.pasuyobuddy.transcribe.audio.PcmUtils
import com.pasuyobuddy.transcribe.data.AppPrefs
import com.pasuyobuddy.transcribe.data.Formats
import com.pasuyobuddy.transcribe.data.Segment
import com.pasuyobuddy.transcribe.data.Transcript
import com.pasuyobuddy.transcribe.data.TranscriptStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import kotlin.coroutines.coroutineContext

/**
 * Foreground service that runs a whole file/meeting transcription in the background:
 * download model (if needed) -> decode audio to 16 kHz PCM -> Whisper in chunks -> save transcript.
 */
class TranscribeService : Service() {

    companion object {
        private const val EXTRA_PATH = "path"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_SOURCE = "source"
        private const val EXTRA_KEEP_AUDIO = "keepAudio"
        private const val EXTRA_AUDIO_REF = "audioRef"
        private const val ACTION_CANCEL = "com.pasuyobuddy.transcribe.CANCEL"
        private const val CHANNEL = "jobs"
        private const val NOTIF_ID = 42
        private const val DONE_NOTIF_ID = 43
        private const val CHUNK_SECONDS = 120

        /** [path] = local file to transcribe; [audioRef] = where the recording lives (for playback), if different. */
        fun start(ctx: Context, path: String, title: String, source: String, keepAudio: Boolean, audioRef: String? = null) {
            val i = Intent(ctx, TranscribeService::class.java)
                .putExtra(EXTRA_PATH, path)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_SOURCE, source)
                .putExtra(EXTRA_KEEP_AUDIO, keepAudio)
                .putExtra(EXTRA_AUDIO_REF, audioRef)
            ContextCompat.startForegroundService(ctx, i)
        }

        fun cancel(ctx: Context) {
            WhisperLib.setAbort(true)
            ctx.startService(Intent(ctx, TranscribeService::class.java).setAction(ACTION_CANCEL))
        }

        fun ensureChannel(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Transcription", NotificationManager.IMPORTANCE_LOW))
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastNotifPct = -1
    private var lastNotifPhase: Phase? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            WhisperLib.setAbort(true)
            job?.cancel()
            if (job == null) stopSelf()
            return START_NOT_STICKY
        }
        val path = intent?.getStringExtra(EXTRA_PATH)
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Recording"
        val source = intent?.getStringExtra(EXTRA_SOURCE) ?: "file"
        val keepAudio = intent?.getBooleanExtra(EXTRA_KEEP_AUDIO, false) ?: false
        val audioRef = intent?.getStringExtra(EXTRA_AUDIO_REF)

        ensureChannel(this)
        startInForeground(buildNotification("Starting…", 0, true))

        if (path == null) { stopSelf(); return START_NOT_STICKY }
        if (job?.isActive == true) {
            Toast.makeText(this, "Already transcribing – please wait or cancel first", Toast.LENGTH_LONG).show()
            return START_NOT_STICKY
        }

        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TranscribeBuddy:job").apply { acquire(6 * 60 * 60 * 1000L) }

        JobState.status.value = JobStatus(Phase.PREPARING, title, 0f, startedAt = System.currentTimeMillis())
        job = scope.launch {
            try {
                run(File(path), title, source, keepAudio, audioRef)
            } finally {
                wakeLock?.let { if (it.isHeld) it.release() }
                ServiceCompat.stopForeground(this@TranscribeService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        WhisperLib.setAbort(true)
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun run(input: File, title: String, source: String, keepAudio: Boolean, audioRef: String?) {
        val prefs = AppPrefs(this)
        val model = WhisperModel.byId(prefs.model)
        val lang = prefs.whisperLang
        val translate = prefs.translateToEnglish && lang != "en"
        val pcm = File(cacheDir, "job_${System.currentTimeMillis()}.pcm")
        var ctxPtr = 0L
        try {
            // 1) Model
            if (!ModelManager.isDownloaded(this, model)) {
                update(Phase.DOWNLOADING_MODEL, 0f)
                ModelManager.download(this, model) { p -> update(Phase.DOWNLOADING_MODEL, p) }
            }

            // 2) Decode audio
            update(Phase.DECODING, 0f)
            val totalSamples = AudioDecoder.decodeToPcm16k(
                input, pcm,
                onProgress = { p -> update(Phase.DECODING, p) },
                isCancelled = { job?.isCancelled == true }
            )
            if (totalSamples < PcmUtils.TARGET_RATE / 2) throw IllegalStateException("The audio is empty or too short.")
            coroutineContext.ensureActive()

            // 3) Whisper
            update(Phase.TRANSCRIBING, 0f)
            WhisperLib.setAbort(false)
            WhisperLib.ensureBackends(this)
            ctxPtr = WhisperLib.initContext(ModelManager.file(this, model).path)
            if (ctxPtr == 0L) {
                ModelManager.delete(this, model)
                throw IllegalStateException("The speech model failed to load (corrupted download?). It was deleted – please try again to re-download it.")
            }
            val threads = WhisperLib.recommendedThreads()
            val chunkSamples = PcmUtils.TARGET_RATE * CHUNK_SECONDS
            val segments = ArrayList<Segment>()
            var detectedLang = if (lang == "auto") "" else lang
            var processed = 0L

            DataInputStream(BufferedInputStream(FileInputStream(pcm), 1 shl 16)).use { din ->
                while (processed < totalSamples) {
                    coroutineContext.ensureActive()
                    val n = minOf(chunkSamples.toLong(), totalSamples - processed).toInt()
                    val bytes = ByteArray(n * 2)
                    var got = 0
                    while (got < bytes.size) {
                        val r = din.read(bytes, got, bytes.size - got)
                        if (r < 0) break
                        got += r
                    }
                    val read = got / 2
                    val shorts = ByteBuffer.wrap(bytes, 0, read * 2).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    val chunk = FloatArray(read) { shorts.get(it) / 32768f }
                    val offsetMs = processed * 1000 / PcmUtils.TARGET_RATE

                    if (rms(chunk) > 0.003f) { // skip pure silence (Whisper may "hallucinate" on it)
                        val chunkLang = if (lang == "auto" && detectedLang.isNotEmpty()) detectedLang else lang
                        val lines = WhisperLib.transcribe(ctxPtr, chunk, chunkLang, threads, true, translate)
                        coroutineContext.ensureActive()
                        if (lines == null) throw IllegalStateException("Transcription failed.")
                        for ((i, line) in lines.withIndex()) {
                            if (i == 0) {
                                if (detectedLang.isEmpty() && line.startsWith("LANG|")) detectedLang = line.removePrefix("LANG|")
                                continue
                            }
                            val seg = Formats.parseNativeLine(line, offsetMs) ?: continue
                            if (!Formats.isNoise(seg.text)) segments.add(seg)
                        }
                    }
                    processed += if (read > 0) read else n
                    update(Phase.TRANSCRIBING, processed.toFloat() / totalSamples, ArrayList(segments))
                    if (read == 0) break
                }
            }

            // 4) Save
            val id = UUID.randomUUID().toString()
            TranscriptStore.save(
                this, Transcript(
                    id = id,
                    title = title,
                    createdAt = System.currentTimeMillis(),
                    source = source,
                    language = detectedLang,
                    durationMs = totalSamples * 1000 / PcmUtils.TARGET_RATE,
                    segments = segments,
                    audioPath = audioRef ?: if (keepAudio) input.path else null,
                    translated = translate && detectedLang != "en"
                )
            )
            JobState.status.value = JobState.status.value.copy(phase = Phase.DONE, progress = 1f, segments = segments, transcriptId = id)
            notifyDone(title, "Done – tap to open", id)
        } catch (e: Throwable) {
            val cancelled = e is CancellationException || e is InterruptedException || job?.isCancelled == true
            if (cancelled) {
                JobState.status.value = JobState.status.value.copy(phase = Phase.CANCELLED)
            } else {
                JobState.status.value = JobState.status.value.copy(phase = Phase.ERROR, error = e.message ?: e.toString())
                notifyDone(title, "Failed: ${e.message}", null)
            }
        } finally {
            if (ctxPtr != 0L) WhisperLib.freeContext(ctxPtr)
            pcm.delete()
            if (!keepAudio) input.delete()
        }
    }

    private fun rms(x: FloatArray): Float {
        if (x.isEmpty()) return 0f
        var s = 0.0
        for (v in x) s += v * v
        return Math.sqrt(s / x.size).toFloat()
    }

    private fun update(phase: Phase, progress: Float, segments: List<Segment>? = null) {
        val cur = JobState.status.value
        JobState.status.value = cur.copy(phase = phase, progress = progress, segments = segments ?: cur.segments)
        val pct = (progress * 100).toInt()
        if (pct != lastNotifPct || phase != lastNotifPhase) {
            lastNotifPct = pct
            lastNotifPhase = phase
            val label = when (phase) {
                Phase.DOWNLOADING_MODEL -> "Downloading speech model (one time)… $pct%"
                Phase.DECODING -> "Reading audio… $pct%"
                Phase.TRANSCRIBING -> (if (AppPrefs(this).translateToEnglish) "Translating to English… " else "Transcribing… ") + "$pct%"
                else -> "Preparing…"
            }
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(label, pct, false))
        }
    }

    private fun openAppIntent(transcriptId: String?): PendingIntent {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (transcriptId != null) i.putExtra(MainActivity.EXTRA_OPEN_TRANSCRIPT, transcriptId)
        return PendingIntent.getActivity(this, transcriptId.hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun buildNotification(text: String, pct: Int, indeterminate: Boolean): Notification {
        val cancelPi = PendingIntent.getService(
            this, 1, Intent(this, TranscribeService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(JobState.status.value.title.ifBlank { "Transcribe Buddy" })
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(100, pct, indeterminate)
            .setContentIntent(openAppIntent(null))
            .addAction(0, "Cancel", cancelPi)
            .build()
    }

    private fun notifyDone(title: String, text: String, transcriptId: String?) {
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(transcriptId))
            .build()
        try {
            getSystemService(NotificationManager::class.java).notify(DONE_NOTIF_ID, n)
        } catch (_: SecurityException) { }
    }

    private fun startInForeground(n: Notification) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, NOTIF_ID, n, type)
    }
}
