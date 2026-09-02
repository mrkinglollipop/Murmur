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
import com.matt.murmur.android.crypto.MurmurSecrets
import com.matt.murmur.android.logic.ImeActivationCommand
import com.matt.murmur.android.logic.ImeActivationLogic
import com.matt.murmur.android.logic.ImePointer
import com.matt.murmur.android.logic.SilenceCancel
import com.matt.murmur.android.logic.TranscriptPipeline
import com.matt.murmur.android.logic.WavWriter
import com.matt.murmur.android.logic.bulkInsertChunks
import com.matt.murmur.android.logic.preparedDictationInsert
import com.matt.murmur.android.perm.MurmurPermissionActivity
import java.io.File
import java.util.concurrent.Executors

class MurmurImeService : InputMethodService(), ImeChrome.Listener {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
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
        currentTake?.capture?.stop()
        currentTake = null
        try {
            unregisterReceiver(stopReceiver)
        } catch (_: Exception) {
        }
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
        val key = try {
            MurmurSecrets.apiKeyStore(this).elevenLabsKey()
        } catch (_: Exception) {
            null
        }
        if (key.isNullOrBlank()) {
            chrome?.setStatus(getString(R.string.ime_need_key))
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
        val take = Take(
            capture = capture,
            editor = currentInputEditorInfo.editorKey(),
            apiKey = key,
        )
        currentTake = take
        chrome?.setStatus(getString(R.string.ime_recording))
        Log.i(TAG, "ime.mic.start")
        worker.execute {
            try {
                val pcm = capture.recordUntilStopped()
                completeTake(take, pcm)
            } catch (_: Exception) {
                Log.w(TAG, "mic.capture.failed")
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
        take.capture.stop()
        mainHandler.post { chrome?.setStatus("Murmur") }
    }

    private fun abortIfSecure(info: EditorInfo?) {
        val take = currentTake ?: return
        if (!info.isSecureDictationTarget()) return
        take.skipInsert = true
        take.secureSkip = true
        logSecureSkip(info)
        take.capture.stop()
        chrome?.setStatus(getString(R.string.ime_secure))
    }

    private fun completeTake(take: Take, pcm: ByteArray) {
        if (take.skipInsert) {
            if (take.secureSkip) Log.i(TAG, "insert.secure_skip")
            mainHandler.post { chrome?.setStatus("Murmur") }
            return
        }
        val seconds = SilenceCancel.pcm16MonoSeconds(pcm.size)
        if (SilenceCancel.shouldTakeSilenceCancel(everHadStreamText = false, bufferedSeconds = seconds)) {
            Log.i(TAG, "ime.silence_cancel")
            mainHandler.post { chrome?.setStatus("Murmur") }
            return
        }
        if (pcm.size < 2) {
            mainHandler.post { chrome?.setStatus("Murmur") }
            return
        }
        Log.i(TAG, "ime.pcm.bytes=${pcm.size}")
        mainHandler.post {
            chrome?.setStatus(getString(R.string.ime_transcribing))
        }
        val wav = File.createTempFile("murmur-", ".wav", cacheDir)
        try {
            WavWriter.writePcm16(pcm, wav)
            val raw = ElevenLabsBatch.transcribe(wav, take.apiKey)
            val processed = TranscriptPipeline.apply(raw)
            mainHandler.post { insertTake(take, processed) }
        } catch (_: Exception) {
            mainHandler.post {
                chrome?.setStatus(getString(R.string.ime_transcribe_failed))
            }
        } finally {
            wav.delete()
        }
    }

    private fun insertTake(take: Take, text: String) {
        if (take.skipInsert) {
            if (take.secureSkip) Log.i(TAG, "insert.secure_skip")
            chrome?.setStatus("Murmur")
            return
        }
        var ic = currentInputConnection
        var info = currentInputEditorInfo
        if (!canInsert(take, ic, info)) {
            logSecureSkip(info)
            chrome?.setStatus("Murmur")
            return
        }
        val before = try {
            ic!!.getTextBeforeCursor(64, 0)?.toString().orEmpty()
        } catch (_: Exception) {
            ""
        }
        val prepared = preparedDictationInsert(text, before, trailingSpace = true)
        if (prepared.isEmpty()) {
            chrome?.setStatus("Murmur")
            return
        }
        val chunks = bulkInsertChunks(prepared)
        for (chunk in chunks) {
            ic = currentInputConnection
            info = currentInputEditorInfo
            if (take.skipInsert || !canInsert(take, ic, info)) {
                logSecureSkip(info)
                chrome?.setStatus("Murmur")
                return
            }
            ic!!.commitText(chunk, 1)
        }
        Log.i(TAG, "insert.ok chars=${prepared.length} chunks=${chunks.size}")
        chrome?.setStatus("Murmur")
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
        val apiKey: String,
    ) {
        @Volatile
        var skipInsert: Boolean = false
        @Volatile
        var secureSkip: Boolean = false
    }

    companion object {
        private const val TAG = "murmur"
    }
}
