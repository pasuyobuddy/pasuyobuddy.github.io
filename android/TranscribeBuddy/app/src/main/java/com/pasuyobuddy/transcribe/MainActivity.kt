package com.pasuyobuddy.transcribe

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import com.pasuyobuddy.transcribe.audio.RecordService
import com.pasuyobuddy.transcribe.ui.App
import com.pasuyobuddy.transcribe.ui.AppTheme
import com.pasuyobuddy.transcribe.ui.Screen
import com.pasuyobuddy.transcribe.whisper.JobState
import com.pasuyobuddy.transcribe.whisper.TranscribeService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MainActivity : ComponentActivity() {

    companion object {
        const val EXTRA_OPEN_TRANSCRIPT = "openTranscript"
    }

    val screen = mutableStateOf<Screen>(Screen.Home)
    val importing = mutableStateOf(false)

    private var afterMicGranted: (() -> Unit)? = null

    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) afterMicGranted?.invoke()
        else Toast.makeText(this, "Microphone permission is needed for this feature", Toast.LENGTH_LONG).show()
        afterMicGranted = null
    }

    private val notifPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    private val pickFile = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importAndTranscribe(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        TranscribeService.ensureChannel(this)
        if (JobState.status.value.isRunning) screen.value = Screen.Job

        setContent {
            AppTheme {
                App(this)
            }
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (savedInstanceState == null) handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        intent.getStringExtra(EXTRA_OPEN_TRANSCRIPT)?.let {
            screen.value = Screen.Detail(it)
            return
        }
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_SEND -> IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        if (uri != null) importAndTranscribe(uri)
    }

    fun withMic(action: () -> Unit) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            action()
        } else {
            afterMicGranted = action
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    fun pickAudioFile() {
        if (JobState.status.value.isRunning) {
            Toast.makeText(this, "A transcription is already running", Toast.LENGTH_SHORT).show()
            screen.value = Screen.Job
            return
        }
        pickFile.launch(arrayOf("audio/*", "video/*", "application/ogg"))
    }

    fun startMeetingRecording() = withMic {
        RecordService.start(this)
    }

    fun importAndTranscribe(uri: Uri) {
        if (JobState.status.value.isRunning) {
            Toast.makeText(this, "A transcription is already running – wait for it or cancel it first", Toast.LENGTH_LONG).show()
            screen.value = Screen.Job
            return
        }
        importing.value = true
        lifecycleScope.launch {
            try {
                val (file, name) = withContext(Dispatchers.IO) { copyToCache(uri) }
                TranscribeService.start(this@MainActivity, file.path, name, "file", keepAudio = false)
                screen.value = Screen.Job
            } catch (e: Exception) {
                Toast.makeText(this@MainActivity, "Could not open file: ${e.message}", Toast.LENGTH_LONG).show()
            } finally {
                importing.value = false
            }
        }
    }

    private fun copyToCache(uri: Uri): Pair<File, String> {
        var name = "Audio file"
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0)?.let { n -> name = n }
            }
        } catch (_: Exception) { }
        val dir = File(cacheDir, "inputs").apply { mkdirs() }
        dir.listFiles()?.forEach { if (System.currentTimeMillis() - it.lastModified() > 24 * 3600_000L) it.delete() }
        val f = File(dir, "in_${System.currentTimeMillis()}")
        val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("Cannot read the file")
        input.use { i -> f.outputStream().use { o -> i.copyTo(o, 1 shl 16) } }
        return f to name.substringBeforeLast('.').ifBlank { "Audio file" }
    }
}
