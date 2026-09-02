package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImeActivationLogicTest {

    @Test
    fun tapDownDoesNotStart() {
        val logic = ImeActivationLogic()
        assertEquals(ImeActivationCommand.NONE, logic.onPointer(ImePointer.DOWN))
        assertFalse(logic.sessionActive)
    }

    @Test
    fun tapDownUpStarts() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.START, logic.onPointer(ImePointer.UP))
        assertTrue(logic.sessionActive)
    }

    @Test
    fun tapSecondDownUpStopsWithoutClearingSession() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        logic.onPointer(ImePointer.UP)
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.STOP, logic.onPointer(ImePointer.UP))
        assertTrue(logic.sessionActive)
        logic.reset()
        assertFalse(logic.sessionActive)
    }

    @Test
    fun tapCancelAfterDownDoesNotStart() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.NONE, logic.onPointer(ImePointer.CANCEL))
        assertFalse(logic.sessionActive)
        assertEquals(ImeActivationCommand.NONE, logic.onPointer(ImePointer.UP))
    }

    @Test
    fun tapCancelWhileRecordingDoesNotStop() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        logic.onPointer(ImePointer.UP)
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.NONE, logic.onPointer(ImePointer.CANCEL))
        assertTrue(logic.sessionActive)
    }

    @Test
    fun tapSpuriousUpWithoutDownIsNone() {
        val logic = ImeActivationLogic()
        assertEquals(ImeActivationCommand.NONE, logic.onPointer(ImePointer.UP))
    }

    @Test
    fun holdDownStartsImmediately() {
        val logic = ImeActivationLogic(ImeActivationMode.PRESS_AND_HOLD)
        assertEquals(ImeActivationCommand.START, logic.onPointer(ImePointer.DOWN))
        assertTrue(logic.sessionActive)
    }

    @Test
    fun holdUpStops() {
        val logic = ImeActivationLogic(ImeActivationMode.PRESS_AND_HOLD)
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.STOP, logic.onPointer(ImePointer.UP))
        assertTrue(logic.sessionActive)
    }

    @Test
    fun holdCancelAborts() {
        val logic = ImeActivationLogic(ImeActivationMode.PRESS_AND_HOLD)
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.CANCEL, logic.onPointer(ImePointer.CANCEL))
        assertTrue(logic.sessionActive)
    }

    @Test
    fun holdDownWhileAlreadyActiveIsNone() {
        val logic = ImeActivationLogic(ImeActivationMode.PRESS_AND_HOLD)
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.NONE, logic.onPointer(ImePointer.DOWN))
    }

    @Test
    fun finishInputViewWithoutFgsCancels() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        logic.onPointer(ImePointer.UP)
        assertEquals(
            ImeActivationCommand.CANCEL,
            logic.onFinishInputView(fgsRunning = false),
        )
        assertTrue(logic.sessionActive)
    }

    @Test
    fun finishInputViewWithFgsKeepsSession() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        logic.onPointer(ImePointer.UP)
        assertEquals(
            ImeActivationCommand.NONE,
            logic.onFinishInputView(fgsRunning = true),
        )
        assertTrue(logic.sessionActive)
    }

    @Test
    fun windowHiddenMatchesFinishInputView() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        logic.onPointer(ImePointer.UP)
        assertEquals(
            ImeActivationCommand.NONE,
            logic.onWindowHidden(fgsRunning = true),
        )
        assertEquals(
            ImeActivationCommand.CANCEL,
            logic.onWindowHidden(fgsRunning = false),
        )
    }

    @Test
    fun viewGoneWhileIdleIsNone() {
        val logic = ImeActivationLogic()
        assertEquals(ImeActivationCommand.NONE, logic.onFinishInputView(false))
        assertEquals(ImeActivationCommand.NONE, logic.onWindowHidden(true))
    }

    @Test
    fun resetAfterDeniedStartAllowsRetry() {
        val logic = ImeActivationLogic()
        logic.onPointer(ImePointer.DOWN)
        logic.onPointer(ImePointer.UP)
        logic.reset()
        logic.onPointer(ImePointer.DOWN)
        assertEquals(ImeActivationCommand.START, logic.onPointer(ImePointer.UP))
    }

    @Test
    fun holdViewGoneWithoutFgsCancels() {
        val logic = ImeActivationLogic(ImeActivationMode.PRESS_AND_HOLD)
        logic.onPointer(ImePointer.DOWN)
        assertEquals(
            ImeActivationCommand.CANCEL,
            logic.onFinishInputView(fgsRunning = false),
        )
    }
}
