@file:OptIn(ExperimentalMaterial3Api::class)

package com.pasuyobuddy.transcribe.ui

import android.content.Context
import android.content.Intent
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.pasuyobuddy.transcribe.MainActivity
import com.pasuyobuddy.transcribe.audio.AudioPlayer
import com.pasuyobuddy.transcribe.audio.RecordService
import com.pasuyobuddy.transcribe.audio.Recording
import com.pasuyobuddy.transcribe.audio.Recordings
import com.pasuyobuddy.transcribe.data.AppPrefs
import com.pasuyobuddy.transcribe.data.Formats
import com.pasuyobuddy.transcribe.data.Lang
import com.pasuyobuddy.transcribe.data.Languages
import com.pasuyobuddy.transcribe.data.Segment
import com.pasuyobuddy.transcribe.data.Transcript
import com.pasuyobuddy.transcribe.data.TranscriptStore
import com.pasuyobuddy.transcribe.live.LiveTranscriber
import com.pasuyobuddy.transcribe.whisper.JobState
import com.pasuyobuddy.transcribe.whisper.ModelManager
import com.pasuyobuddy.transcribe.whisper.Phase
import com.pasuyobuddy.transcribe.whisper.RecordState
import com.pasuyobuddy.transcribe.whisper.TranscribeService
import com.pasuyobuddy.transcribe.whisper.WhisperLib
import com.pasuyobuddy.transcribe.whisper.WhisperModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.UUID

sealed class Screen {
    data object Home : Screen()
    data object Live : Screen()
    data object Record : Screen()
    data object Job : Screen()
    data object History : Screen()
    data object Recordings : Screen()
    data object Settings : Screen()
    data class Detail(val id: String) : Screen()
}

private val Blue = Color(0xFF1E3A8A)
private val Amber = Color(0xFFF59E0B)

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    val scheme = if (isSystemInDarkTheme())
        darkColorScheme(primary = Color(0xFF93C5FD), secondary = Amber)
    else
        lightColorScheme(primary = Blue, secondary = Amber, primaryContainer = Color(0xFFDBEAFE))
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
fun App(activity: MainActivity) {
    val screen by activity.screen
    val go: (Screen) -> Unit = { activity.screen.value = it }

    BackHandler(enabled = screen != Screen.Home) {
        go(if (screen is Screen.Detail) Screen.History else Screen.Home)
    }

    when (val s = screen) {
        Screen.Home -> HomeScreen(activity, go)
        Screen.Live -> LiveScreen(go)
        Screen.Record -> RecordScreen(activity, go)
        Screen.Job -> JobScreen(go)
        Screen.History -> HistoryScreen(go)
        Screen.Recordings -> RecordingsScreen(go)
        Screen.Settings -> SettingsScreen(go)
        is Screen.Detail -> DetailScreen(s.id, go)
    }
}

@Composable
private fun Bar(title: String, onBack: (() -> Unit)?, actions: @Composable () -> Unit = {}) {
    TopAppBar(
        title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = {
            if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        },
        actions = { actions() },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.primary,
            titleContentColor = MaterialTheme.colorScheme.onPrimary,
            navigationIconContentColor = MaterialTheme.colorScheme.onPrimary,
            actionIconContentColor = MaterialTheme.colorScheme.onPrimary
        )
    )
}

// ---------------------------------------------------------------- Home

@Composable
private fun HomeScreen(activity: MainActivity, go: (Screen) -> Unit) {
    val job by JobState.status.collectAsState()
    val rec by RecordState.status.collectAsState()
    val importing by activity.importing

    Scaffold(topBar = {
        Bar("Transcribe Buddy", null) {
            IconButton(onClick = { go(Screen.Settings) }) { Icon(Icons.Filled.Settings, "Settings") }
        }
    }) { pad ->
        Column(
            Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (importing) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text("Opening file…")
                }
            }
            if (job.isRunning) {
                Card(Modifier.fillMaxWidth().clickable { go(Screen.Job) },
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                    Column(Modifier.padding(14.dp)) {
                        Text("Transcribing: ${job.title}", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.height(6.dp))
                        LinearProgressIndicator(progress = { job.progress }, modifier = Modifier.fillMaxWidth())
                        Text("Tap to view", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            if (rec.recording) {
                Card(Modifier.fillMaxWidth().clickable { go(Screen.Record) },
                    colors = CardDefaults.cardColors(containerColor = Color(0xFFFEE2E2))) {
                    Text("● Recording meeting – tap to open", Modifier.padding(14.dp), color = Color(0xFFB91C1C))
                }
            }

            BigAction(Icons.Filled.Mic, "Live", "Speak and see the text right away (needs internet)") {
                activity.withMic { go(Screen.Live) }
            }
            BigAction(Icons.Filled.AudioFile, "Transcribe a file", "Voice notes, mp3, m4a, videos… works offline") {
                activity.pickAudioFile()
            }
            BigAction(Icons.Filled.RecordVoiceOver, "Record meeting", "Record now, transcribe with timestamps when you stop") {
                go(Screen.Record)
            }
            TranslateSwitchCard()
            BigAction(Icons.Filled.History, "History", "All your saved transcripts") { go(Screen.History) }
            BigAction(Icons.Filled.LibraryMusic, "Recordings", "Listen to, share or transcribe your recordings") { go(Screen.Recordings) }

            Text(
                "Tip: in WhatsApp, Messenger, Telegram or your Recorder app, tap Share → Transcribe Buddy.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun BigAction(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth().clickable(onClick = onClick), elevation = CardDefaults.cardElevation(2.dp)) {
        Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(16.dp))
            Column {
                Text(title, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

// ---------------------------------------------------------------- Live

@Composable
private fun LiveScreen(go: (Screen) -> Unit) {
    val ctx = LocalContext.current
    val prefs = remember { AppPrefs(ctx) }
    var lang by remember { mutableStateOf(prefs.liveLang) }
    var segments by remember { mutableStateOf<List<Segment>>(emptyList()) }
    var partial by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("Tap Start and speak") }
    var listening by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val listState = rememberLazyListState()

    val live = remember {
        LiveTranscriber(ctx,
            onUpdate = { s, p -> segments = s; partial = p; saved = false },
            onStatus = { status = it })
    }

    DisposableEffect(Unit) {
        val window = (ctx as? MainActivity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            live.stop()
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
    LaunchedEffect(segments.size, partial) {
        val count = segments.size + if (partial.isNotEmpty()) 1 else 0
        if (count > 0) listState.animateScrollToItem(count - 1)
    }

    fun saveToHistory() {
        if (segments.isEmpty()) return
        val now = System.currentTimeMillis()
        TranscriptStore.save(ctx, Transcript(
            id = UUID.randomUUID().toString(),
            title = "Live " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(now)),
            createdAt = now, source = "live", language = lang,
            durationMs = segments.last().endMs, segments = segments
        ))
        saved = true
    }

    Scaffold(topBar = {
        Bar("Live", { go(Screen.Home) }) {
            IconButton(onClick = { clipboard.setText(AnnotatedString(Formats.toTxt(segments, false))) }) {
                Icon(Icons.Filled.ContentCopy, "Copy")
            }
            IconButton(onClick = { shareText(ctx, "Transcript", Formats.toTxt(segments, false)) }) {
                Icon(Icons.Filled.Share, "Share")
            }
        }
    }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().padding(16.dp)) {
            LanguagePicker("Language", Languages.live, lang, enabled = !listening) {
                lang = it; prefs.liveLang = it
            }
            Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            Card(Modifier.fillMaxWidth().weight(1f)) {
                SelectionContainer {
                    LazyColumn(state = listState, contentPadding = PaddingValues(12.dp)) {
                        items(segments) { seg ->
                            Text(buildLine(seg, true), Modifier.padding(vertical = 3.dp), fontSize = 17.sp)
                        }
                        if (partial.isNotEmpty()) item {
                            Text(partial, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 17.sp)
                        }
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = {
                        if (listening) { live.stop(); listening = false }
                        else { live.start(lang); listening = live.isListening }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = if (listening) Color(0xFFDC2626) else MaterialTheme.colorScheme.primary),
                    modifier = Modifier.weight(1f).height(56.dp)
                ) {
                    Icon(if (listening) Icons.Filled.Stop else Icons.Filled.Mic, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (listening) "Stop" else "Start", fontSize = 18.sp)
                }
                OutlinedButton(onClick = { saveToHistory() }, enabled = segments.isNotEmpty() && !saved, modifier = Modifier.height(56.dp)) {
                    Icon(Icons.Filled.Save, null); Spacer(Modifier.width(4.dp)); Text(if (saved) "Saved" else "Save")
                }
                OutlinedButton(onClick = { live.clear() }, enabled = segments.isNotEmpty(), modifier = Modifier.height(56.dp)) {
                    Text("Clear")
                }
            }
        }
    }
}

// ---------------------------------------------------------------- Record meeting

@Composable
private fun RecordScreen(activity: MainActivity, go: (Screen) -> Unit) {
    val rec by RecordState.status.collectAsState()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val ctx = LocalContext.current
    val prefs = remember { AppPrefs(ctx) }
    var lang by remember { mutableStateOf(prefs.whisperLang) }

    LaunchedEffect(rec.recording) {
        while (rec.recording) { now = System.currentTimeMillis(); delay(500) }
    }

    Scaffold(topBar = { Bar("Record meeting", { go(Screen.Home) }) }) { pad ->
        Column(
            Modifier.padding(pad).fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            LanguagePicker("Language of the meeting", Languages.whisper, lang, enabled = true) {
                lang = it; prefs.whisperLang = it
            }
            TranslateSwitchCard()
            Spacer(Modifier.height(8.dp))
            if (rec.recording) {
                Icon(
                    if (rec.paused) Icons.Filled.Pause else Icons.Filled.FiberManualRecord, null, Modifier.size(56.dp),
                    tint = if (rec.paused) MaterialTheme.colorScheme.onSurfaceVariant else Color(0xFFDC2626)
                )
                Text(Formats.clock(rec.elapsedMs(now)), fontSize = 48.sp, fontWeight = FontWeight.Light)
                Text(
                    if (rec.paused) "Paused" else "Recording… you can turn off the screen.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedButton(
                    onClick = { if (rec.paused) RecordService.resume(ctx) else RecordService.pause(ctx) },
                    modifier = Modifier.fillMaxWidth().height(52.dp)
                ) {
                    Icon(if (rec.paused) Icons.Filled.FiberManualRecord else Icons.Filled.Pause, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (rec.paused) "Resume" else "Pause", fontSize = 17.sp)
                }
                Button(
                    onClick = { RecordService.stop(ctx, transcribe = true); go(Screen.Job) },
                    modifier = Modifier.fillMaxWidth().height(56.dp)
                ) { Icon(Icons.Filled.Stop, null); Spacer(Modifier.width(8.dp)); Text("Stop & transcribe", fontSize = 18.sp) }
                TextButton(onClick = { RecordService.stop(ctx, transcribe = false); go(Screen.Recordings) }) { Text("Stop without transcribing (save to Recordings)") }
            } else {
                Button(
                    onClick = { activity.startMeetingRecording() },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626)),
                    modifier = Modifier.fillMaxWidth().height(64.dp)
                ) { Icon(Icons.Filled.FiberManualRecord, null); Spacer(Modifier.width(8.dp)); Text("Start recording", fontSize = 18.sp) }
                rec.error?.let { Text(it, color = Color(0xFFDC2626)) }
                Text(
                    "Put the phone in the middle of the table for best results.\n\n" +
                        "Phone calls: Android doesn't let apps record the other person directly. " +
                        "Use your phone's built-in call recorder and share the file here, or put the call on speaker and record.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

// ---------------------------------------------------------------- Job progress

@Composable
private fun JobScreen(go: (Screen) -> Unit) {
    val job by JobState.status.collectAsState()
    val ctx = LocalContext.current
    val listState = rememberLazyListState()

    LaunchedEffect(job.phase, job.transcriptId) {
        if (job.phase == Phase.DONE && job.transcriptId != null) {
            delay(600)
            go(Screen.Detail(job.transcriptId!!))
        }
    }
    LaunchedEffect(job.segments.size) {
        if (job.segments.isNotEmpty()) listState.animateScrollToItem(job.segments.size - 1)
    }

    Scaffold(topBar = { Bar(job.title.ifBlank { "Transcription" }, { go(Screen.Home) }) }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val label = when (job.phase) {
                Phase.IDLE -> "Nothing running"
                Phase.PREPARING -> "Preparing…"
                Phase.DOWNLOADING_MODEL -> "Downloading speech model (one time only)…"
                Phase.DECODING -> "Reading audio…"
                Phase.TRANSCRIBING -> "Transcribing… you can leave the app, we'll notify you."
                Phase.DONE -> "Done!"
                Phase.ERROR -> "Something went wrong"
                Phase.CANCELLED -> "Cancelled"
            }
            Text(label, fontWeight = FontWeight.SemiBold)
            if (job.isRunning) {
                LinearProgressIndicator(progress = { job.progress }, modifier = Modifier.fillMaxWidth())
                Text("${(job.progress * 100).toInt()}%", style = MaterialTheme.typography.bodySmall)
            }
            job.error?.let { if (job.phase == Phase.ERROR) Text(it, color = Color(0xFFDC2626)) }

            Card(Modifier.fillMaxWidth().weight(1f)) {
                if (job.segments.isEmpty()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            if (job.isRunning) "Text will appear here as it's transcribed" else "",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                } else {
                    LazyColumn(state = listState, contentPadding = PaddingValues(12.dp)) {
                        items(job.segments) { Text(buildLine(it, true), Modifier.padding(vertical = 3.dp)) }
                    }
                }
            }
            if (job.isRunning) {
                OutlinedButton(onClick = { TranscribeService.cancel(ctx) }, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
            } else {
                Button(onClick = { go(Screen.Home) }, modifier = Modifier.fillMaxWidth()) { Text("Back to home") }
            }
        }
    }
}

// ---------------------------------------------------------------- History

@Composable
private fun HistoryScreen(go: (Screen) -> Unit) {
    val ctx = LocalContext.current
    var items by remember { mutableStateOf<List<Transcript>?>(null) }
    LaunchedEffect(Unit) { items = withContext(Dispatchers.IO) { TranscriptStore.list(ctx) } }

    Scaffold(topBar = { Bar("History", { go(Screen.Home) }) }) { pad ->
        val list = items
        when {
            list == null -> Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            list.isEmpty() -> Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No transcripts yet", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> LazyColumn(Modifier.padding(pad), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(list, key = { it.id }) { t ->
                    Card(Modifier.fillMaxWidth().clickable { go(Screen.Detail(t.id)) }) {
                        Column(Modifier.padding(14.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    when (t.source) { "live" -> Icons.Filled.Mic; "meeting" -> Icons.Filled.RecordVoiceOver; else -> Icons.Filled.AudioFile },
                                    null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(t.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            Text(
                                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(t.createdAt)) +
                                    " · " + Formats.clock(t.durationMs),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            if (t.preview.isNotBlank()) Text(t.preview, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- Transcript detail

@Composable
private fun DetailScreen(id: String, go: (Screen) -> Unit) {
    val ctx = LocalContext.current
    val prefs = remember { AppPrefs(ctx) }
    var t by remember { mutableStateOf<Transcript?>(null) }
    var timestamps by remember { mutableStateOf(prefs.showTimestamps) }
    var confirmDelete by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    LaunchedEffect(id) { t = withContext(Dispatchers.IO) { TranscriptStore.load(ctx, id) } }

    val tr = t
    val audioPath = tr?.audioPath?.takeIf { File(it).exists() }
    val player = remember(audioPath) { audioPath?.let { AudioPlayer.create(it) } }
    DisposableEffect(player) { onDispose { player?.release() } }
    Scaffold(topBar = {
        Bar(tr?.title ?: "Transcript", { go(Screen.History) }) {
            if (tr != null) {
                IconButton(onClick = { renaming = true }) { Icon(Icons.Filled.Edit, "Rename") }
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Filled.Delete, "Delete") }
            }
        }
    }) { pad ->
        if (tr == null) {
            Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.Center) { Text("Loading…") }
            return@Scaffold
        }
        Column(Modifier.padding(pad).fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${Formats.clock(tr.durationMs)} · ${langName(tr)} · ${tr.segments.size} lines",
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f)
                )
                Text("Times", style = MaterialTheme.typography.bodySmall)
                Switch(checked = timestamps, onCheckedChange = { timestamps = it; prefs.showTimestamps = it })
            }
            Card(Modifier.fillMaxWidth().weight(1f)) {
                if (tr.segments.isEmpty()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No speech was found in this recording.") }
                } else SelectionContainer {
                    LazyColumn(contentPadding = PaddingValues(12.dp)) {
                        items(tr.segments) { seg ->
                            val pos = player?.positionMs?.toLong() ?: -1L
                            val current = player != null && player.playing && pos >= seg.startMs && pos < seg.endMs
                            var mod = Modifier.fillMaxWidth().padding(vertical = 1.dp)
                            if (current) mod = mod.background(MaterialTheme.colorScheme.primaryContainer)
                            if (player != null) mod = mod.clickable { player.seekTo(seg.startMs.toInt(), play = true) }
                            Text(buildLine(seg, timestamps), mod.padding(vertical = 2.dp), fontSize = 16.sp)
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { clipboard.setText(AnnotatedString(Formats.toTxt(tr.segments, timestamps))) }, Modifier.weight(1f)) {
                    Icon(Icons.Filled.ContentCopy, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text("Copy")
                }
                OutlinedButton(onClick = { shareFile(ctx, tr.title, "txt", Formats.toTxt(tr.segments, timestamps), "text/plain") }, Modifier.weight(1f)) {
                    Icon(Icons.Filled.Share, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text(".txt")
                }
                OutlinedButton(onClick = { shareFile(ctx, tr.title, "srt", Formats.toSrt(tr.segments), "application/x-subrip") }, Modifier.weight(1f)) {
                    Icon(Icons.Filled.Subtitles, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text(".srt")
                }
            }
            if (player != null) {
                PlayerBar(player)
                Text("Tip: tap a line to play from that moment.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (audioPath != null) {
                TextButton(onClick = { shareAudio(ctx, File(audioPath)) }) { Text("Share the recording (.m4a)") }
            }
        }
    }

    if (confirmDelete && tr != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete transcript?") },
            text = { Text("\"${tr.title}\" will be deleted from this phone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch {
                        withContext(Dispatchers.IO) { TranscriptStore.delete(ctx, tr.id) }
                        go(Screen.History)
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } }
        )
    }
    if (renaming && tr != null) {
        var name by remember { mutableStateOf(tr.title) }
        AlertDialog(
            onDismissRequest = { renaming = false },
            title = { Text("Rename") },
            text = { OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true) },
            confirmButton = {
                TextButton(onClick = {
                    renaming = false
                    val newTitle = name.trim().ifBlank { tr.title }
                    TranscriptStore.rename(ctx, tr.id, newTitle)
                    t = tr.copy(title = newTitle)
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { renaming = false }) { Text("Cancel") } }
        )
    }
}

private fun langName(t: Transcript): String {
    val src = when {
        t.language.isBlank() -> "auto"
        t.source == "live" -> Languages.liveLabel(t.language)
        else -> Languages.whisperLabel(t.language)
    }
    return if (t.translated) "$src → English" else src
}

// ---------------------------------------------------------------- Settings

@Composable
private fun SettingsScreen(go: (Screen) -> Unit) {
    val ctx = LocalContext.current
    val prefs = remember { AppPrefs(ctx) }
    val scope = rememberCoroutineScope()
    var model by remember { mutableStateOf(prefs.model) }
    var whisperLang by remember { mutableStateOf(prefs.whisperLang) }
    var liveLang by remember { mutableStateOf(prefs.liveLang) }
    var refresh by remember { mutableIntStateOf(0) }
    var downloading by remember { mutableStateOf<WhisperModel?>(null) }
    var dlProgress by remember { mutableFloatStateOf(0f) }
    var dlError by remember { mutableStateOf<String?>(null) }

    Scaffold(topBar = { Bar("Settings", { go(Screen.Home) }) }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {

            Text("Speech model (files & meetings)", fontWeight = FontWeight.SemiBold)
            Text("Runs on your phone – audio is never uploaded. Downloaded once.", style = MaterialTheme.typography.bodySmall)
            refresh.let { _ ->
                WhisperModel.entries.forEach { m ->
                    val have = ModelManager.isDownloaded(ctx, m)
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()
                        .clickable { model = m.id; prefs.model = m.id }) {
                        RadioButton(selected = model == m.id, onClick = { model = m.id; prefs.model = m.id })
                        Column(Modifier.weight(1f)) {
                            Text(m.label)
                            Text("${m.sizeMb} MB · " + if (have) "downloaded" else "not downloaded",
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        when {
                            downloading == m -> Text("${(dlProgress * 100).toInt()}%")
                            have -> TextButton(onClick = { ModelManager.delete(ctx, m); refresh++ }) { Text("Delete") }
                            else -> TextButton(enabled = downloading == null, onClick = {
                                downloading = m; dlProgress = 0f; dlError = null
                                scope.launch {
                                    try {
                                        ModelManager.download(ctx, m) { p -> dlProgress = p }
                                    } catch (e: Exception) {
                                        dlError = e.message
                                    } finally {
                                        downloading = null; refresh++
                                    }
                                }
                            }) { Text("Download") }
                        }
                    }
                }
            }
            dlError?.let { Text(it, color = Color(0xFFDC2626)) }

            HorizontalDivider()
            LanguagePicker("Language for files & meetings", Languages.whisper, whisperLang, true) {
                whisperLang = it; prefs.whisperLang = it
            }
            Text("Auto-detect works for most recordings. For Taglish, try Tagalog or Auto.", style = MaterialTheme.typography.bodySmall)
            TranslateSwitchCard()
            LanguagePicker("Language for Live", Languages.live, liveLang, true) {
                liveLang = it; prefs.liveLang = it
            }

            HorizontalDivider()
            var info by remember { mutableStateOf("") }
            LaunchedEffect(Unit) { info = withContext(Dispatchers.Default) { try { WhisperLib.systemInfo() } catch (e: Throwable) { "native library not loaded: ${e.message}" } } }
            Text("About", fontWeight = FontWeight.SemiBold)
            Text("Transcribe Buddy · on-device Whisper (whisper.cpp)\n$info", style = MaterialTheme.typography.bodySmall)
        }
    }
}

// ---------------------------------------------------------------- Shared bits

@Composable
private fun LanguagePicker(label: String, options: List<Lang>, selected: String, enabled: Boolean, onSelect: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Box {
            OutlinedButton(onClick = { open = true }, enabled = enabled) {
                Text(options.firstOrNull { it.code == selected }?.label ?: selected)
                Text("  ▾")
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                options.forEach { o ->
                    DropdownMenuItem(text = { Text(o.label) }, onClick = { open = false; onSelect(o.code) })
                }
            }
        }
    }
}

private fun buildLine(seg: Segment, withTime: Boolean): String =
    if (withTime) "[${Formats.clock(seg.startMs)}]  ${seg.text.trim()}" else seg.text.trim()

private fun shareText(ctx: Context, subject: String, text: String) {
    if (text.isBlank()) return
    val i = Intent(Intent.ACTION_SEND).setType("text/plain")
        .putExtra(Intent.EXTRA_SUBJECT, subject)
        .putExtra(Intent.EXTRA_TEXT, text)
    ctx.startActivity(Intent.createChooser(i, "Share transcript"))
}

private fun shareFile(ctx: Context, title: String, ext: String, content: String, mime: String) {
    val dir = File(ctx.cacheDir, "exports").apply { mkdirs() }
    val safe = title.replace(Regex("[^A-Za-z0-9 ._-]"), "_").take(60).ifBlank { "transcript" }
    val f = File(dir, "$safe.$ext")
    f.writeText(content)
    val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
    val i = Intent(Intent.ACTION_SEND).setType(mime)
        .putExtra(Intent.EXTRA_STREAM, uri)
        .putExtra(Intent.EXTRA_SUBJECT, title)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    ctx.startActivity(Intent.createChooser(i, "Share $ext"))
}

private fun shareAudio(ctx: Context, f: File) {
    val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
    val i = Intent(Intent.ACTION_SEND).setType("audio/mp4")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    ctx.startActivity(Intent.createChooser(i, "Share recording"))
}

// ---------------------------------------------------------------- Translate switch

@Composable
private fun TranslateSwitchCard() {
    val ctx = LocalContext.current
    val prefs = remember { AppPrefs(ctx) }
    var on by remember { mutableStateOf(prefs.translateToEnglish) }
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Translate, null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("Translate to English", fontWeight = FontWeight.SemiBold)
                    Text("Hindi, Korean, Tagalog & more → English (files & meetings)",
                        style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = on, onCheckedChange = { on = it; prefs.translateToEnglish = it })
            }
            if (on && prefs.model != WhisperModel.SMALL.id) {
                Text("Tip: choose the Small model in Settings for better translations.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

// ---------------------------------------------------------------- Audio player

@Composable
private fun PlayerBar(player: AudioPlayer) {
    LaunchedEffect(player, player.playing) {
        while (player.playing) { player.tick(); delay(250) }
    }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        IconButton(onClick = { player.toggle() }) {
            Icon(if (player.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (player.playing) "Pause" else "Play")
        }
        Slider(
            value = player.positionMs.toFloat().coerceIn(0f, player.durationMs.toFloat().coerceAtLeast(1f)),
            onValueChange = { player.seekTo(it.toInt(), play = false) },
            valueRange = 0f..player.durationMs.toFloat().coerceAtLeast(1f),
            modifier = Modifier.weight(1f)
        )
        Spacer(Modifier.width(8.dp))
        Text("${Formats.clock(player.positionMs.toLong())} / ${Formats.clock(player.durationMs.toLong())}",
            style = MaterialTheme.typography.bodySmall)
    }
}

// ---------------------------------------------------------------- Recordings

@Composable
private fun RecordingsScreen(go: (Screen) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<Recording>?>(null) }
    var transcriptByPath by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var refresh by remember { mutableIntStateOf(0) }
    var openPath by remember { mutableStateOf<String?>(null) }
    var toDelete by remember { mutableStateOf<Recording?>(null) }
    val job by JobState.status.collectAsState()

    LaunchedEffect(refresh) {
        withContext(Dispatchers.IO) {
            items = Recordings.list(ctx)
            transcriptByPath = TranscriptStore.list(ctx).mapNotNull { t -> t.audioPath?.let { it to t.id } }.toMap()
        }
    }

    Scaffold(topBar = { Bar("Recordings", { go(Screen.Home) }) }) { pad ->
        val list = items
        when {
            list == null -> Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            list.isEmpty() -> Box(Modifier.padding(pad).fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Text("No recordings yet. Use Record meeting on the home screen.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> LazyColumn(Modifier.padding(pad), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(list, key = { it.file.path }) { rec ->
                    val path = rec.file.path
                    val transcriptId = transcriptByPath[path]
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable {
                                openPath = if (openPath == path) null else path
                            }) {
                                Icon(Icons.Filled.RecordVoiceOver, null, tint = MaterialTheme.colorScheme.primary)
                                Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(rec.title, fontWeight = FontWeight.SemiBold)
                                    Text(Formats.clock(rec.durationMs) + " · " +
                                        (if (transcriptId != null) "transcribed" else "not transcribed yet"),
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Icon(if (openPath == path) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play")
                            }
                            if (openPath == path) {
                                val player = remember(path) { AudioPlayer.create(path) }
                                DisposableEffect(player) {
                                    player?.toggle()
                                    onDispose { player?.release() }
                                }
                                if (player != null) PlayerBar(player) else Text("Cannot play this file.")
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                if (transcriptId != null) {
                                    TextButton(onClick = { go(Screen.Detail(transcriptId)) }) { Text("Open text") }
                                }
                                TextButton(enabled = !job.isRunning, onClick = {
                                    openPath = null
                                    TranscribeService.start(ctx, path, rec.title, "meeting", keepAudio = true)
                                    go(Screen.Job)
                                }) { Text(if (transcriptId != null) "Transcribe again" else "Transcribe") }
                                IconButton(onClick = { shareAudio(ctx, rec.file) }) { Icon(Icons.Filled.Share, "Share") }
                                IconButton(onClick = { toDelete = rec }) { Icon(Icons.Filled.Delete, "Delete") }
                            }
                        }
                    }
                }
            }
        }
    }

    toDelete?.let { rec ->
        AlertDialog(
            onDismissRequest = { toDelete = null },
            title = { Text("Delete recording?") },
            text = { Text("The audio file \"${rec.title}\" will be deleted. Transcripts made from it stay in History.") },
            confirmButton = {
                TextButton(onClick = {
                    toDelete = null
                    if (openPath == rec.file.path) openPath = null
                    scope.launch {
                        withContext(Dispatchers.IO) { rec.file.delete() }
                        refresh++
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { toDelete = null }) { Text("Cancel") } }
        )
    }
}
