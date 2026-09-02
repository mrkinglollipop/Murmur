package com.matt.murmur.android.logic

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MicForegroundGateTest {
    @Test
    fun startAllowedWhileInputViewShown() {
        assertTrue(MicForegroundGate.canStartMicrophoneForeground(inputViewShown = true))
    }

    @Test
    fun startDeniedAfterInputViewGone() {
        assertFalse(MicForegroundGate.canStartMicrophoneForeground(inputViewShown = false))
    }
}
