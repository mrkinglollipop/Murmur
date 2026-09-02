package com.matt.murmur.android.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import com.matt.murmur.android.logic.WavWriter
import java.io.ByteArrayOutputStream

/**
 * AudioRecord at 16 kHz / mono / PCM16, source VOICE_RECOGNITION.
 * Do not use AudioSource.MIC when VOICE_RECOGNITION is available;
 * do not use VOICE_COMMUNICATION (call AEC/NS).
 */
class MicCapture(private val context: Context) {
    private val lock = Any()
    private var recorder: AudioRecord? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null

    @Volatile
    private var released = false

    fun record(durationMs: Long): ByteArray {
        if (released) return ByteArray(0)
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "mic.capture.failed")
            throw SecurityException("RECORD_AUDIO denied")
        }
        val minBuf = AudioRecord.getMinBufferSize(
            WavWriter.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf == AudioRecord.ERROR || minBuf == AudioRecord.ERROR_BAD_VALUE) {
            Log.w(TAG, "AudioRecord.init.failed")
            throw IllegalStateException("AudioRecord.init.failed")
        }
        val bufSize = maxOf(minBuf, WavWriter.SAMPLE_RATE * 2)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            WavWriter.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            Log.w(TAG, "AudioRecord.init.failed")
            throw IllegalStateException("AudioRecord.init.failed")
        }
        val am = context.getSystemService(AudioManager::class.java)
        val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .build()
        synchronized(lock) {
            if (released) {
                rec.release()
                return ByteArray(0)
            }
            recorder = rec
            audioManager = am
            focusRequest = focus
        }
        am.requestAudioFocus(focus)
        val out = ByteArrayOutputStream()
        val chunk = ByteArray(minBuf)
        try {
            rec.startRecording()
            Log.i(TAG, "mic.capture.started")
            val deadline = SystemClock.elapsedRealtime() + durationMs
            while (!released && SystemClock.elapsedRealtime() < deadline) {
                val n = try {
                    rec.read(chunk, 0, chunk.size)
                } catch (_: IllegalStateException) {
                    break
                }
                if (released) break
                if (n < 0) {
                    Log.w(TAG, "mic.capture.failed")
                    throw IllegalStateException("mic.capture.failed")
                }
                if (n > 0) out.write(chunk, 0, n)
            }
        } finally {
            stop()
        }
        return out.toByteArray()
    }

    /** Unblocks a blocking [record] from another thread. Idempotent if never started. */
    fun stop() {
        released = true
        synchronized(lock) {
            val rec = recorder
            recorder = null
            if (rec != null) {
                try {
                    rec.stop()
                } catch (_: Exception) {
                }
                rec.release()
            }
            val req = focusRequest
            focusRequest = null
            if (req != null) {
                audioManager?.abandonAudioFocusRequest(req)
            }
            audioManager = null
        }
    }

    companion object {
        private const val TAG = "murmur"
    }
}
