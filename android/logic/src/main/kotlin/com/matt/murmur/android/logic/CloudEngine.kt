package com.matt.murmur.android.logic

/** iOS `SelectedCloudEngine`. Default is ElevenLabs, matching the iOS host. */
enum class CloudEngine(val raw: String, val displayName: String) {
    ELEVEN_LABS("elevenLabs", "ElevenLabs Scribe v2"),
    GEMINI("gemini", "Gemini 3.5 Transcribe"),
    ;

    companion object {
        val DEFAULT = ELEVEN_LABS

        fun fromRaw(raw: String?): CloudEngine =
            entries.firstOrNull { it.raw == raw } ?: DEFAULT
    }
}

/** Gemini Live handshake is unverified; skip live after a failed start. */
object GeminiLiveGate {
    fun shouldAttemptLive(handshakeFailed: Boolean): Boolean = !handshakeFailed

    /**
     * Persist the device gate only for a real setup failure while the take
     * is still active. Local teardown (cancel, finalize, interrupt) must not.
     */
    fun shouldPersistHandshakeFailure(
        handshakeFailure: Boolean,
        skipInsert: Boolean,
        sessionClosedByIme: Boolean,
        interrupted: Boolean,
    ): Boolean = handshakeFailure && !skipInsert && !sessionClosedByIme && !interrupted
}
