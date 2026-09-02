package com.matt.murmur.android.logic

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 16 kHz / 16-bit / mono PCM WAV. Contract of ios/Shared/WAVTranscoder.swift
 * and Sources/Voice/CloudAudioTranscoder.swift — not the AVFoundation implementation.
 */
object WavWriter {
    const val SAMPLE_RATE = 16_000
    const val CHANNELS = 1
    const val BITS_PER_SAMPLE = 16
    const val MIME_TYPE = "audio/wav"
    const val FILE_NAME = "audio.wav"
    const val HEADER_BYTES = 44

    fun wrapPcm16(pcm: ByteArray): ByteArray {
        require(pcm.isNotEmpty()) { "empty PCM" }
        require(pcm.size % 2 == 0) { "PCM16 length must be even" }
        val out = ByteArray(HEADER_BYTES + pcm.size)
        writeHeader(out, pcm.size)
        System.arraycopy(pcm, 0, out, HEADER_BYTES, pcm.size)
        return out
    }

    fun writePcm16(pcm: ByteArray, dest: File) {
        dest.writeBytes(wrapPcm16(pcm))
    }

    private fun writeHeader(out: ByteArray, dataBytes: Int) {
        val buf = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        buf.put('R'.code.toByte())
        buf.put('I'.code.toByte())
        buf.put('F'.code.toByte())
        buf.put('F'.code.toByte())
        buf.putInt(36 + dataBytes)
        buf.put('W'.code.toByte())
        buf.put('A'.code.toByte())
        buf.put('V'.code.toByte())
        buf.put('E'.code.toByte())
        buf.put('f'.code.toByte())
        buf.put('m'.code.toByte())
        buf.put('t'.code.toByte())
        buf.put(' '.code.toByte())
        buf.putInt(16)
        buf.putShort(1) // PCM
        buf.putShort(CHANNELS.toShort())
        buf.putInt(SAMPLE_RATE)
        val byteRate = SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8)
        buf.putInt(byteRate)
        buf.putShort((CHANNELS * (BITS_PER_SAMPLE / 8)).toShort())
        buf.putShort(BITS_PER_SAMPLE.toShort())
        buf.put('d'.code.toByte())
        buf.put('a'.code.toByte())
        buf.put('t'.code.toByte())
        buf.put('a'.code.toByte())
        buf.putInt(dataBytes)
    }
}
