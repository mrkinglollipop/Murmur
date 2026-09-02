package com.matt.murmur.android.cloud

/**
 * Live STT session. [sendPcm16] must return without waiting on the socket.
 * Partials go to [onInterim] only — callers must not commit them.
 */
interface LiveTranscriber {
    var onInterim: ((String) -> Unit)?
    val hasEverHadNonEmptyStreamText: Boolean

    /** Begin accepting PCM before [start] waits on the handshake. */
    fun arm()

    fun start()

    fun sendPcm16(pcm: ByteArray)

    fun joinedTranscriptSnapshot(): String

    fun finalize(recordingDurationSeconds: Double = 0.0): String

    fun cancel()
}

class LiveStartException(
    message: String,
    val handshake: Boolean,
) : Exception(message) {
    companion object {
        fun handshake(message: String) = LiveStartException(message, handshake = true)
        fun cancelled(message: String = "cancelled") = LiveStartException(message, handshake = false)
    }
}
