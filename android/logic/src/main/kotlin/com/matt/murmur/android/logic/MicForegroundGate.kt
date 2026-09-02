package com.matt.murmur.android.logic

/**
 * Fail-closed microphone FGS: start only while the IME input view is shown.
 * Being the current IME is a generic FGS background-start exemption, not
 * microphone while-in-use. Do not startForeground(MICROPHONE) after the
 * input view is gone ([inputViewShown] = false, e.g. onFinishInputView).
 */
object MicForegroundGate {
    fun canStartMicrophoneForeground(inputViewShown: Boolean): Boolean = inputViewShown
}
