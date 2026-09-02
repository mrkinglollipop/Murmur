package com.matt.murmur.android.ime

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import com.matt.murmur.android.R
import com.matt.murmur.android.capture.MicCapture
import com.matt.murmur.android.cloud.ElevenLabsBatch
import com.matt.murmur.android.cloud.ElevenLabsRealtimeTranscriber
import com.matt.murmur.android.cloud.GeminiBatch
import com.matt.murmur.android.cloud.GeminiLiveTranscriber
import com.matt.murmur.android.cloud.LiveStartException
import com.matt.murmur.android.cloud.LiveTranscriber
import com.matt.murmur.android.crypto.MurmurSecrets
import com.matt.murmur.android.logic.CloudEngine
import com.matt.murmur.android.logic.DictionaryStore
import com.matt.murmur.android.logic.GeminiLiveGate
import com.matt.murmur.android.logic.HistoryStore
import com.matt.murmur.android.logic.ImeActivationCommand
import com.matt.murmur.android.logic.ImeActivationLogic
import com.matt.murmur.android.logic.ImePointer
import com.matt.murmur.android.logic.MurmurFiles
import com.matt.murmur.android.logic.SettingsStore
import com.matt.murmur.android.logic.SilenceCancel
import com.matt.murmur.android.logic.SnippetsStore
import com.matt.murmur.android.logic.StreamingCoordinator
import com.matt.murmur.android.logic.StyleStore
import com.matt.murmur.android.logic.TranscriptPipeline
import com.matt.murmur.android.logic.WavWriter
import com.matt.murmur.android.logic.bulkInsertChunks
import com.matt.murmur.android.logic.preparedDictationInsert
import com.matt.murmur.android.perm.MurmurPermissionActivity
import com.matt.murmur.android.prefs.EnginePrefs
import java.io.File
import java.util.concurrent.Executors

class MurmurImeService : InputMethodService(), ImeChrome.Listener {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val liveStart = Executors.newCachedThreadPool()
    private val activation = ImeActivationLogic()
    private var chrome: ImeChrome? = null
    private var inputViewVisible = false
    private var fgsRunning = false
    @Volatile
    private var currentTake: Take? = null

    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ImeMicForeground.ACTION_STOP) {
                stopTake()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        registerReceiver(stopReceiver, IntentFilter(ImeMicForeground.ACTION_STOP), RECEIVER_NOT_EXPORTED)
    }

    override fun onCreateInputView(): View {
        inputViewVisible = true
        val view = ImeChrome(this, this)
        chrome = view
        if (currentTake != null && currentTake?.skipInsert != true) {
            view.setStatus(getString(R.string.ime_recording))
        }
        return view
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        abortIfSecure(attribute)
    }

    override fun onFinishInput() {
        super.onFinishInput()
        abortIfSecure(currentInputEditorInfo)
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        inputViewVisible = true
        refreshActivationMode()
        abortIfSecure(info)
    }

    override fun onWindowShown() {
        super.onWindowShown()
        inputViewVisible = true
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        inputViewVisible = false
        applyActivation(activation.onFinishInputView(fgsRunning))
    }

    override fun onWindowHidden() {
        super.onWindowHidden()
        inputViewVisible = false
        applyActivation(activation.onWindowHidden(fgsRunning))
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (!fgsRunning) {
            cancelTake()
        }
        return super.onUnbind(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        setInputView(onCreateInputView())
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onDestroy() {
        ImeMicForeground.stop(this)
        fgsRunning = false
        currentTake?.skipInsert = true
        currentTake?.sessionClosedByIme = true
        currentTake?.session?.onInterim = null
        currentTake?.session?.cancel()
        currentTake?.capture?.stop()
        currentTake = null
        try {
            unregisterReceiver(stopReceiver)
        } catch (_: Exception) {
        }
        liveStart.shutdownNow()
        worker.shutdownNow()
        super.onDestroy()
    }

    override fun onCommit(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    override fun onDelete() {
        val ic = currentInputConnection ?: return
        if (!ic.getSelectedText(0).isNullOrEmpty()) {
            ic.commitText("", 1)
        } else {
            ic.deleteSurroundingText(1, 0)
        }
    }

    override fun onEnter() {
        val ic = currentInputConnection ?: return
        val action = currentInputEditorInfo?.imeOptions?.and(EditorInfo.IME_MASK_ACTION)
            ?: EditorInfo.IME_ACTION_UNSPECIFIED
        if (action != EditorInfo.IME_ACTION_NONE &&
            action != EditorInfo.IME_ACTION_UNSPECIFIED &&
            ic.performEditorAction(action)
        ) {
            return
        }
        ic.commitText("\n", 1)
    }

    override fun onSwitchIme() {
        switchToNextInputMethod(false)
    }

    override fun onMicPointer(event: ImePointer) {
        activation.mode = SettingsStore.cachedActivationMode
        applyActivation(activation.onPointer(event))
    }

    private fun applyActivation(command: ImeActivationCommand) {
        when (command) {
            ImeActivationCommand.NONE -> Unit
            ImeActivationCommand.START -> startTake()
            ImeActivationCommand.STOP -> stopTake()
            ImeActivationCommand.CANCEL -> cancelTake()
        }
    }

    private fun startTake() {
        if (currentTake != null) return
        val info = currentInputEditorInfo
        if (info.isSecureDictationTarget()) {
            logSecureSkip(info)
            chrome?.setStatus(getString(R.string.ime_secure))
            activation.reset()
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            chrome?.setStatus(getString(R.string.ime_allow_mic))
            launchPermission()
            activation.reset()
            return
        }
        val engine = EnginePrefs.engine(this)
        val store = try {
            MurmurSecrets.apiKeyStore(this)
        } catch (_: Exception) {
            null
        }
        val key = when (engine) {
            CloudEngine.ELEVEN_LABS -> store?.elevenLabsKey()
            CloudEngine.GEMINI -> store?.geminiKey()
        }
        if (key.isNullOrBlank()) {
            chrome?.setStatus(
                getString(
                    when (engine) {
                        CloudEngine.ELEVEN_LABS -> R.string.ime_need_key
                        CloudEngine.GEMINI -> R.string.ime_need_gemini_key
                    },
                ),
            )
            activation.reset()
            return
        }
        val viewShown = inputViewVisible
        if (!ImeMicForeground.start(this, inputViewShown = viewShown)) {
            chrome?.setStatus(getString(R.string.ime_mic_denied))
            activation.reset()
            return
        }
        fgsRunning = true
        val capture = MicCapture(this)
        val keyterms = dictionaryKeyterms()
        val attemptLive = engine != CloudEngine.GEMINI ||
            GeminiLiveGate.shouldAttemptLive(EnginePrefs.geminiLiveHandshakeFailed(this))
        val session = if (attemptLive) makeLiveSession(engine, key, keyterms) else null
        val take = Take(
            capture = capture,
            editor = currentInputEditorInfo.editorKey(),
            engine = engine,
            apiKey = key,
            session = session,
            keyterms = keyterms,
        )
        currentTake = take
        chrome?.setStatus(getString(R.string.ime_recording))
        Log.i(TAG, "ime.mic.start")
        session?.arm()
        session?.onInterim = { text ->
            if (text.isNotBlank()) {
                mainHandler.post {
                    if (currentTake === take && !take.skipInsert) {
                        chrome?.setStatus(text)
                    }
                }
            }
        }
        if (session != null) {
            liveStart.execute {
                try {
                    session.start()
                } catch (e: Exception) {
                    if (e is InterruptedException) Thread.currentThread().interrupt()
                    val persist = engine == CloudEngine.GEMINI &&
                        GeminiLiveGate.shouldPersistHandshakeFailure(
                            handshakeFailure = (e as? LiveStartException)?.handshake == true,
                            skipInsert = take.skipInsert,
                            sessionClosedByIme = take.sessionClosedByIme,
                            interrupted = e is InterruptedException,
                        )
                    if (persist) {
                        take.liveStartFailed = true
                        EnginePrefs.setGeminiLiveHandshakeFailed(this, true)
                    } else if (!take.sessionClosedByIme) {
                        take.liveStartFailed = true
                    }
                    if (!take.sessionClosedByIme) {
                        session.cancel()
                    }
                }
            }
        }
        worker.execute {
            try {
                val pcm = capture.recordUntilStopped { chunk, length ->
                    session?.sendPcm16(chunk.copyOf(length))
                }
                completeTake(take, pcm)
            } catch (_: Exception) {
                Log.w(TAG, "mic.capture.failed")
                take.sessionClosedByIme = true
                session?.onInterim = null
                session?.cancel()
                mainHandler.post {
                    chrome?.setStatus(getString(R.string.ime_mic_failed))
                }
            } finally {
                capture.stop()
                if (currentTake === take) currentTake = null
                mainHandler.post {
                    ImeMicForeground.stop(this)
                    fgsRunning = false
                    activation.reset()
                }
            }
        }
    }

    private fun stopTake() {
        val take = currentTake ?: return
        Log.i(TAG, "ime.mic.stop")
        take.capture.stop()
    }

    private fun cancelTake() {
        val take = currentTake ?: return
        take.skipInsert = true
        take.sessionClosedByIme = true
        take.session?.onInterim = null
        take.session?.cancel()
        take.capture.stop()
        mainHandler.post { chrome?.setStatus("Murmur") }
    }

    private fun abortIfSecure(info: EditorInfo?) {
        val take = currentTake ?: return
        if (!info.isSecureDictationTarget()) return
        take.skipInsert = true
        take.secureSkip = true
        take.sessionClosedByIme = true
        logSecureSkip(info)
        take.session?.onInterim = null
        take.session?.cancel()
        take.capture.stop()
        chrome?.setStatus(getString(R.string.ime_secure))
    }

    private fun completeTake(take: Take, pcm: ByteArray) {
        val session = take.session
        session?.onInterim = null
        if (take.skipInsert) {
            take.sessionClosedByIme = true
            session?.cancel()
            if (take.secureSkip) Log.i(TAG, "insert.secure_skip")
            mainHandler.post { chrome?.setStatus("Murmur") }
            return
        }
        val seconds = SilenceCancel.pcm16MonoSeconds(pcm.size)
        val everHad = session?.hasEverHadNonEmptyStreamText == true
        if (StreamingCoordinator.shouldTakeSilenceCancel(everHad, seconds)) {
            take.sessionClosedByIme = true
            session?.cancel()
            Log.i(TAG, "ime.silence_cancel")
            mainHandler.post { chrome?.setStatus("Murmur") }
            return
        }
        mainHandler.post {
            chrome?.setStatus(getString(R.string.ime_transcribing))
        }
        take.sessionClosedByIme = true
        val snapshot = session?.joinedTranscriptSnapshot().orEmpty()
        val finalizeText = if (session != null && !take.liveStartFailed) {
            session.finalize(seconds)
        } else {
            session?.cancel()
            ""
        }
        val truncated = StreamingCoordinator.streamResultLooksTruncated(finalizeText, seconds)
        val liveText = StreamingCoordinator.streamSuccessTextOrBatchFallback(
            finalizeText = finalizeText,
            preFinalizeSnapshot = snapshot,
            duration = seconds,
            truncated = truncated,
        )
        if (liveText != null) {
            val processed = processTranscript(liveText)
            mainHandler.post { insertTake(take, processed) }
            return
        }
        if (pcm.size < 2) {
            mainHandler.post { chrome?.setStatus("Murmur") }
            return
        }
        Log.i(TAG, "ime.pcm.bytes=${pcm.size}")
        val wav = File.createTempFile("murmur-", ".wav", cacheDir)
        try {
            WavWriter.writePcm16(pcm, wav)
            val raw = batchTranscribe(take, wav)
            val processed = processTranscript(raw)
            mainHandler.post { insertTake(take, processed) }
        } catch (_: Exception) {
            mainHandler.post {
                chrome?.setStatus(getString(R.string.ime_transcribe_failed))
            }
        } finally {
            wav.delete()
        }
    }

    private fun processTranscript(raw: String): String {
        val settings = SettingsStore(MurmurFiles.settings(filesDir))
        val dictionary = DictionaryStore(file = MurmurFiles.dictionary(filesDir))
        val snippets = SnippetsStore(file = MurmurFiles.snippets(filesDir))
        val style = StyleStore(MurmurFiles.style(filesDir))
        return TranscriptPipeline.apply(
            raw,
            codeAware = settings.codeAware,
            dictionary = dictionary,
            style = style.selected,
            snippets = snippets,
        )
    }

    private fun dictionaryKeyterms(): List<String> {
        return try {
            DictionaryStore.selectKeyterms(
                DictionaryStore(file = MurmurFiles.dictionary(filesDir)).entries,
            )
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun batchTranscribe(take: Take, wav: File): String {
        val settings = try {
            SettingsStore(MurmurFiles.settings(filesDir))
        } catch (_: Exception) {
            null
        }
        val noVerbatim = settings?.removeFillerWords ?: true
        return when (take.engine) {
            CloudEngine.ELEVEN_LABS -> ElevenLabsBatch.transcribe(
                audio = wav,
                apiKey = take.apiKey,
                noVerbatim = noVerbatim,
                keyterms = take.keyterms,
            )
            CloudEngine.GEMINI -> GeminiBatch.transcribe(
                audio = wav,
                apiKey = take.apiKey,
                vocabulary = take.keyterms,
            )
        }
    }

    private fun makeLiveSession(engine: CloudEngine, key: String, keyterms: List<String>): LiveTranscriber {
        return when (engine) {
            CloudEngine.ELEVEN_LABS -> ElevenLabsRealtimeTranscriber(
                apiKey = key,
                keyterms = keyterms,
            )
            CloudEngine.GEMINI -> GeminiLiveTranscriber(
                apiKey = key,
                vocabulary = keyterms,
            )
        }
    }

    private fun insertTake(take: Take, text: String) {
        try {
            if (take.skipInsert) {
                if (take.secureSkip) Log.i(TAG, "insert.secure_skip")
                return
            }
            var ic = currentInputConnection
            var info = currentInputEditorInfo
            if (!canInsert(take, ic, info)) {
                logSecureSkip(info)
                return
            }
            val before = try {
                ic!!.getTextBeforeCursor(64, 0)?.toString().orEmpty()
            } catch (_: Exception) {
                ""
            }
            val prepared = preparedDictationInsert(text, before, trailingSpace = true)
            if (prepared.isEmpty()) return
            val chunks = bulkInsertChunks(prepared)
            for (chunk in chunks) {
                ic = currentInputConnection
                info = currentInputEditorInfo
                if (take.skipInsert || !canInsert(take, ic, info)) {
                    logSecureSkip(info)
                    return
                }
                ic!!.commitText(chunk, 1)
            }
            Log.i(TAG, "insert.ok chars=${prepared.length} chunks=${chunks.size}")
            try {
                HistoryStore(file = MurmurFiles.history(filesDir)).append(text, failed = false)
            } catch (_: Exception) {
            }
        } finally {
            chrome?.setStatus("Murmur")
        }
    }

    private fun refreshActivationMode() {
        activation.mode = try {
            SettingsStore(MurmurFiles.settings(filesDir)).activationMode
        } catch (_: Exception) {
            activation.mode
        }
    }

    private fun canInsert(take: Take, ic: InputConnection?, info: EditorInfo?): Boolean {
        if (ic == null || info == null || take.editor == null) return false
        if (info.isSecureDictationTarget()) return false
        return info.editorKey() == take.editor
    }

    private fun EditorInfo?.editorKey(): EditorKey? {
        if (this == null) return null
        return EditorKey(packageName, fieldId)
    }

    private fun launchPermission() {
        val intent = Intent(MurmurPermissionActivity.ACTION_REQUEST_MIC)
            .setClass(this, MurmurPermissionActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun logSecureSkip(info: EditorInfo?) {
        val hex = info?.inputType?.toString(16) ?: "none"
        val hints = info?.autofillHintsForLog().orEmpty()
        Log.i(TAG, "insert.secure_skip inputType=$hex hints=$hints")
    }

    private data class EditorKey(val packageName: String?, val fieldId: Int)

    private class Take(
        val capture: MicCapture,
        val editor: EditorKey?,
        val engine: CloudEngine,
        val apiKey: String,
        val session: LiveTranscriber?,
        val keyterms: List<String>,
    ) {
        @Volatile
        var skipInsert: Boolean = false
        @Volatile
        var secureSkip: Boolean = false
        @Volatile
        var liveStartFailed: Boolean = false
        @Volatile
        var sessionClosedByIme: Boolean = false
    }

    companion object {
        private const val TAG = "murmur"
    }
}
