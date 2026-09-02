package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.WavWriter
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.Base64
import java.util.concurrent.TimeUnit

object GeminiBatch {
    const val DEFAULT_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"

    private val jsonType = "application/json; charset=utf-8".toMediaType()

    private val defaultClient by lazy {
        OkHttpClient.Builder()
            .callTimeout(120, TimeUnit.SECONDS)
            .build()
    }

    fun transcribe(
        audio: File,
        apiKey: String,
        language: String = "en",
        smartMode: Boolean = true,
        vocabulary: List<String> = emptyList(),
    ): String = transcribeAt(
        audio,
        apiKey,
        language,
        smartMode,
        vocabulary,
        defaultClient,
        DEFAULT_URL,
    )

    fun transcribeAt(
        audio: File,
        apiKey: String,
        language: String,
        smartMode: Boolean,
        vocabulary: List<String>,
        client: OkHttpClient,
        endpoint: String,
    ): String {
        val wavBase64 = Base64.getEncoder().encodeToString(audio.readBytes())
        val bodyMap = GeminiLiveOptions.makeBatchRequestBody(
            wavBase64 = wavBase64,
            mimeType = WavWriter.MIME_TYPE,
            smartMode = smartMode,
            vocabulary = vocabulary,
        )
        val body = JsonValue.encode(bodyMap).toRequestBody(jsonType)
        val request = Request.Builder()
            .url(endpoint)
            .header("x-goog-api-key", apiKey)
            .header("Content-Type", "application/json")
            .post(body)
            .build()
        client.newCall(request).execute().use { response ->
            val bodyText = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw GeminiException.Http(
                    response.code,
                    redactedBodyFragment(bodyText, max = 160),
                )
            }
            val text = GeminiBatchDecode.decodeTranscript(bodyText)?.trim().orEmpty()
            if (text.isEmpty()) throw GeminiException.NoTranscript
            return text
        }
    }
}

sealed class GeminiException(message: String) : Exception(message) {
    class Http(val code: Int, snippet: String) :
        GeminiException("Gemini HTTP $code $snippet")

    object NoTranscript : GeminiException("No transcript in response")
}
