package com.matt.murmur.android.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
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

    fun record(durationMs: Long): ByteArray {
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
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            WavWriter.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize,
        )
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            Log.w(TAG, "AudioRecord.init.failed")
            throw IllegalStateException("AudioRecord.init.failed")
        }
        val am = context.getSystemService(AudioManager::class.java)
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .build()
        am.requestAudioFocus(focusRequest)
        val out = ByteArrayOutputStream()
        val chunk = ByteArray(minBuf)
        try {
            recorder.startRecording()
            Log.i(TAG, "mic.capture.started")
            val deadline = SystemClock.elapsedRealtime() + durationMs
            while (SystemClock.elapsedRealtime() < deadline) {
                val n = recorder.read(chunk, 0, chunk.size)
                if (n < 0) {
                    Log.w(TAG, "mic.capture.failed")
                    throw IllegalStateException("mic.capture.failed")
                }
                if (n > 0) out.write(chunk, 0, n)
            }
        } finally {
            try {
                recorder.stop()
            } catch (_: Exception) {
            }
            recorder.release()
            am.abandonAudioFocusRequest(focusRequest)
        }
        return out.toByteArray()
    }

    companion object {
        private const val TAG = "murmur"
    }
}
