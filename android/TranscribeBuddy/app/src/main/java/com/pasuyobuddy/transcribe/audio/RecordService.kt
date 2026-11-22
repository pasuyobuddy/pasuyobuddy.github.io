package com.pasuyobuddy.transcribe.audio

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.pasuyobuddy.transcribe.MainActivity
import com.pasuyobuddy.transcribe.whisper.RecordState
import com.pasuyobuddy.transcribe.whisper.RecordStatus
import com.pasuyobuddy.transcribe.whisper.TranscribeService
import java.io.File

/** Records a meeting to an .m4a file in the background (screen can be off), then hands it to TranscribeService. */
class RecordService : Service() {

    companion object {
        private const val ACTION_START = "start"
        private const val ACTION_STOP = "stop"
        private const val ACTION_PAUSE = "pause"
        private const val ACTION_RESUME = "resume"
        private const val EXTRA_TRANSCRIBE = "transcribe"
        private const val NOTIF_ID = 51

        fun start(ctx: Context) {
            ContextCompat.startForegroundService(ctx, Intent(ctx, RecordService::class.java).setAction(ACTION_START))
        }

        fun pause(ctx: Context) {
            ctx.startService(Intent(ctx, RecordService::class.java).setAction(ACTION_PAUSE))
        }

        fun resume(ctx: Context) {
            ctx.startService(Intent(ctx, RecordService::class.java).setAction(ACTION_RESUME))
        }

        fun stop(ctx: Context, transcribe: Boolean) {
            ctx.startService(Intent(ctx, RecordService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_TRANSCRIBE, transcribe))
        }
    }

    private var recorder: MediaRecorder? = null
    private var file: File? = null                 // phones below Android 10
    private var uri: android.net.Uri? = null       // Android 10+: shared Recordings folder
    private var pfd: android.os.ParcelFileDescriptor? = null
    private var title: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRecording()
            ACTION_STOP -> stopRecording(intent.getBooleanExtra(EXTRA_TRANSCRIBE, false))
            ACTION_PAUSE -> pauseRecording()
            ACTION_RESUME -> resumeRecording()
        }
        return START_NOT_STICKY
    }

    private fun startRecording() {
        if (recorder != null) return
        TranscribeService.ensureChannel(this)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
        ServiceCompat.startForeground(this, NOTIF_ID, notification(), type)

        val ts = System.currentTimeMillis()
        title = Recordings.titleFor(ts)
        file = null; uri = null; pfd = null
        try {
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(44_100)
            r.setAudioEncodingBitRate(64_000)
            val shared = Recordings.createShared(this, ts)
            val ref: String
            if (shared != null) {
                uri = shared
                pfd = contentResolver.openFileDescriptor(shared, "rw")
                r.setOutputFile(pfd!!.fileDescriptor)
                ref = shared.toString()
            } else {
                val f = File(Recordings.privateDir(this), "meeting_$ts.m4a")
                file = f
                r.setOutputFile(f.path)
                ref = f.path
            }
            r.prepare()
            r.start()
            recorder = r
            RecordState.status.value = RecordStatus(true, System.currentTimeMillis(), ref)
        } catch (e: Exception) {
            RecordState.status.value = RecordStatus(false, error = "Could not start recording: ${e.message}")
            try { pfd?.close() } catch (_: Exception) { }
            uri?.let { try { contentResolver.delete(it, null, null) } catch (_: Exception) { } }
            stopSelfSafely()
        }
    }

    private fun pauseRecording() {
        val r = recorder ?: return
        val st = RecordState.status.value
        if (st.paused) return
        try {
            r.pause()
            RecordState.status.value = st.copy(paused = true, pausedAt = System.currentTimeMillis())
            updateNotification()
        } catch (_: Exception) { }
    }

    private fun resumeRecording() {
        val r = recorder ?: return
        val st = RecordState.status.value
        if (!st.paused) return
        try {
            r.resume()
            RecordState.status.value = st.copy(
                paused = false,
                pausedTotalMs = st.pausedTotalMs + (System.currentTimeMillis() - st.pausedAt)
            )
            updateNotification()
        } catch (_: Exception) { }
    }

    private fun updateNotification() {
        getSystemService(android.app.NotificationManager::class.java).notify(NOTIF_ID, notification())
    }

    private fun stopRecording(transcribe: Boolean) {
        val r = recorder
        recorder = null
        var ok = false
        if (r != null) {
            ok = try { r.stop(); true } catch (e: Exception) { false } // stop() throws if nothing was recorded
            r.release()
        }
        try { pfd?.close() } catch (_: Exception) { }
        pfd = null
        val f = file
        val u = uri
        val ref = u?.toString() ?: f?.path
        RecordState.status.value = RecordStatus(false, path = ref)
        val good = ok && ((u != null) || (f != null && f.length() > 0))
        if (good) {
            if (u != null) Recordings.publish(this, u)          // now visible in the Files app and file picker
            if (transcribe && ref != null) {
                val local = Recordings.toLocalFile(this, ref)
                TranscribeService.start(this, local.path, title, "meeting", keepAudio = u == null, audioRef = ref)
            }
        } else {
            f?.delete()
            u?.let { try { contentResolver.delete(it, null, null) } catch (_: Exception) { } }
            if (r != null) RecordState.status.value = RecordStatus(false, error = "Recording was too short.")
        }
        uri = null; file = null
        stopSelfSafely()
    }

    private fun stopSelfSafely() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        recorder?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        recorder = null
        if (RecordState.status.value.recording) RecordState.status.value = RecordStatus(false)
        super.onDestroy()
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 2,
            Intent(this, RecordService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_TRANSCRIBE, false),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val paused = RecordState.status.value.paused
        val toggle = PendingIntent.getService(
            this, 3,
            Intent(this, RecordService::class.java).setAction(if (paused) ACTION_RESUME else ACTION_PAUSE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, "jobs")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(if (paused) "Recording paused" else "Recording…")
            .setContentText("Tap Stop & save when finished")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, if (paused) "Resume" else "Pause", toggle)
            .addAction(0, "Stop & save", stop)
            .build()
    }
}
