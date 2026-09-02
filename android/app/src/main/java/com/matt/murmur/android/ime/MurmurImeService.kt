package com.matt.murmur.android.ime

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.inputmethod.EditorInfo
import com.matt.murmur.android.capture.MicCapture
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MurmurImeService : InputMethodService(), ImeChrome.Listener {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val captureInFlight = AtomicBoolean(false)
    private var chrome: ImeChrome? = null
    private var inputViewVisible = false
    @Volatile
    private var activeCapture: MicCapture? = null

    override fun onCreateInputView(): View {
        inputViewVisible = true
        val view = ImeChrome(this, this)
        chrome = view
        return view
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        inputViewVisible = true
    }

    override fun onWindowShown() {
        super.onWindowShown()
        inputViewVisible = true
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        inputViewVisible = false
        // Keep an already-started microphone FGS. Do not startForeground here.
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        setInputView(onCreateInputView())
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onDestroy() {
        ImeMicForeground.stop(this)
        activeCapture?.stop()
        activeCapture = null
        captureInFlight.set(false)
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

    override fun onMicTap() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            chrome?.setStatus("Allow microphone in Murmur")
            return
        }
        if (!captureInFlight.compareAndSet(false, true)) return
        val viewShown = inputViewVisible
        if (!ImeMicForeground.start(this, inputViewShown = viewShown)) {
            captureInFlight.set(false)
            chrome?.setStatus("Microphone start denied")
            return
        }
        chrome?.setStatus("Recording…")
        val capture = MicCapture(this)
        activeCapture = capture
        worker.execute {
            try {
                val pcm = capture.record(3_000L)
                if (captureInFlight.get()) {
                    mainHandler.post { chrome?.setStatus("captured ${pcm.size} bytes") }
                }
            } catch (_: Exception) {
                if (captureInFlight.get()) {
                    mainHandler.post { chrome?.setStatus("Mic capture failed") }
                }
            } finally {
                capture.stop()
                if (activeCapture === capture) activeCapture = null
                ImeMicForeground.stop(this)
                captureInFlight.set(false)
            }
        }
    }
}
