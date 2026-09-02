package com.matt.murmur.android.logic

/**
 * Drop a take instead of batch when there was never stream text and the
 * capture is at most [MAX_BUFFERED_SECONDS]. Inclusive so a 0.5 s ghost
 * does not hammer batch. Loudness is not consulted.
 */
object SilenceCancel {
    const val MAX_BUFFERED_SECONDS = 0.5

    fun shouldTakeSilenceCancel(
        everHadStreamText: Boolean,
        bufferedSeconds: Double,
    ): Boolean = !everHadStreamText && bufferedSeconds <= MAX_BUFFERED_SECONDS

    fun pcm16MonoSeconds(
        pcmBytes: Int,
        sampleRate: Int = WavWriter.SAMPLE_RATE,
    ): Double {
        if (pcmBytes <= 0 || sampleRate <= 0) return 0.0
        val bytesPerSecond = sampleRate * (WavWriter.BITS_PER_SAMPLE / 8) * WavWriter.CHANNELS
        return pcmBytes.toDouble() / bytesPerSecond
    }
}
