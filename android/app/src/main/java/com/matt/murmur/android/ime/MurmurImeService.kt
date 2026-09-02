package com.matt.murmur.android.ime

import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo

class MurmurImeService : InputMethodService(), ImeChrome.Listener {

    override fun onCreateInputView(): View {
        return ImeChrome(this, this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        setInputView(onCreateInputView())
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onCommit(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    override fun onDelete() {
        currentInputConnection?.deleteSurroundingText(1, 0)
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

    override fun onMicPlaceholder() {
        // Visible only. Recording is a later PR; do not request RECORD_AUDIO.
    }
}
