package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.WavWriter
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Batch Scribe v2. Transcribed from ios/Shared/ElevenLabsBatch.swift
 * (form fields + `xi-api-key`). Do not share Swift.
 */
object ElevenLabsBatch {
    const val DEFAULT_URL = "https://api.elevenlabs.io/v1/speech-to-text"
    const val MODEL_ID = "scribe_v2"

    private val wavType = WavWriter.MIME_TYPE.toMediaType()

    private val defaultClient by lazy {
        OkHttpClient.Builder()
            .callTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    /**
     * `keyterms` are repeated form fields, same encoding as Scribe realtime.
     * Never comma-join — the server reads a joined value as one over-long term.
     */
    fun formFields(
        language: String,
        noVerbatim: Boolean,
        keyterms: List<String>,
    ): List<Pair<String, String>> {
        val fields = mutableListOf(
            "model_id" to MODEL_ID,
            "language_code" to language,
            "no_verbatim" to if (noVerbatim) "true" else "false",
        )
        for (term in keyterms) {
            fields += "keyterms" to term
        }
        return fields
    }

    fun transcribe(
        audio: File,
        apiKey: String,
        language: String = "en",
        noVerbatim: Boolean = true,
        keyterms: List<String> = emptyList(),
    ): String = transcribeAt(
        audio,
        apiKey,
        language,
        noVerbatim,
        keyterms,
        defaultClient,
        DEFAULT_URL,
    )

    fun transcribeAt(
        audio: File,
        apiKey: String,
        language: String,
        noVerbatim: Boolean,
        keyterms: List<String>,
        client: OkHttpClient,
        endpoint: String,
    ): String {
        val builder = MultipartBody.Builder().setType(MultipartBody.FORM)
        for ((name, value) in formFields(language, noVerbatim, keyterms)) {
            builder.addFormDataPart(name, value)
        }
        builder.addFormDataPart(
            "file",
            WavWriter.FILE_NAME,
            audio.asRequestBody(wavType),
        )
        val request = Request.Builder()
            .url(endpoint)
            .header("xi-api-key", apiKey)
            .post(builder.build())
            .build()
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw ElevenLabsException.Http(
                    response.code,
                    redactedBodyFragment(body, max = 160),
                )
            }
            val text = parseTranscriptText(body)?.trim().orEmpty()
            if (text.isEmpty()) throw ElevenLabsException.NoTranscript
            return text
        }
    }
}

sealed class ElevenLabsException(message: String) : Exception(message) {
    class Http(val code: Int, snippet: String) :
        ElevenLabsException("ElevenLabs HTTP $code $snippet")

    object NoTranscript : ElevenLabsException("No transcript in response")
}
