package com.matt.murmur.android.logic

enum class ImeActivationMode {
    TAP_TOGGLE,
    PRESS_AND_HOLD,
}

enum class ImePointer {
    DOWN,
    UP,
    CANCEL,
}

enum class ImeActivationCommand {
    NONE,
    START,
    STOP,
    CANCEL,
}

/**
 * IME mic pointer machine. Tap-to-toggle is primary; press-and-hold starts on
 * DOWN immediately. Session stays active until [reset] so a failed start can
 * retry and a stop during transcribe does not open a second take.
 */
class ImeActivationLogic(
    var mode: ImeActivationMode = ImeActivationMode.TAP_TOGGLE,
) {
    var sessionActive: Boolean = false
        private set

    private var pointerDown: Boolean = false

    fun onPointer(event: ImePointer): ImeActivationCommand {
        return when (mode) {
            ImeActivationMode.TAP_TOGGLE -> onTap(event)
            ImeActivationMode.PRESS_AND_HOLD -> onHold(event)
        }
    }

    fun onFinishInputView(fgsRunning: Boolean): ImeActivationCommand = onViewGone(fgsRunning)

    fun onWindowHidden(fgsRunning: Boolean): ImeActivationCommand = onViewGone(fgsRunning)

    fun reset() {
        sessionActive = false
        pointerDown = false
    }

    private fun onTap(event: ImePointer): ImeActivationCommand {
        when (event) {
            ImePointer.DOWN -> {
                pointerDown = true
                return ImeActivationCommand.NONE
            }
            ImePointer.UP -> {
                if (!pointerDown) return ImeActivationCommand.NONE
                pointerDown = false
                if (sessionActive) return ImeActivationCommand.STOP
                sessionActive = true
                return ImeActivationCommand.START
            }
            ImePointer.CANCEL -> {
                pointerDown = false
                return ImeActivationCommand.NONE
            }
        }
    }

    private fun onHold(event: ImePointer): ImeActivationCommand {
        when (event) {
            ImePointer.DOWN -> {
                pointerDown = true
                if (sessionActive) return ImeActivationCommand.NONE
                sessionActive = true
                return ImeActivationCommand.START
            }
            ImePointer.UP -> {
                pointerDown = false
                if (!sessionActive) return ImeActivationCommand.NONE
                return ImeActivationCommand.STOP
            }
            ImePointer.CANCEL -> {
                pointerDown = false
                if (!sessionActive) return ImeActivationCommand.NONE
                return ImeActivationCommand.CANCEL
            }
        }
    }

    private fun onViewGone(fgsRunning: Boolean): ImeActivationCommand {
        pointerDown = false
        if (!sessionActive) return ImeActivationCommand.NONE
        if (fgsRunning) return ImeActivationCommand.NONE
        return ImeActivationCommand.CANCEL
    }
}
