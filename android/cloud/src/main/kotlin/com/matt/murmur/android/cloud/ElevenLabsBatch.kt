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

/** Same 20+ char token strip as CloudTranscriptionError.redactedBodyFragment. */
fun redactedBodyFragment(body: String, max: Int = 300): String {
    val redacted = Regex("[A-Za-z0-9_\\-]{20,}").replace(body, "…")
    return if (redacted.length <= max) redacted else redacted.substring(0, max)
}

/** Top-level JSON `"text"` only — nested `words[].text` must not win. */
internal fun parseTranscriptText(json: String): String? {
    return JsonReader(json).topLevelString("text")
}

private class JsonReader(private val s: String) {
    private var i = 0

    fun topLevelString(want: String): String? {
        skipWs()
        if (!consume('{')) return null
        while (true) {
            skipWs()
            if (peek() == '}') return null
            if (peek() != '"') return null
            val key = parseString() ?: return null
            skipWs()
            if (!consume(':')) return null
            skipWs()
            if (key == want && peek() == '"') {
                return parseString()
            }
            if (!skipValue()) return null
            skipWs()
            when (peek()) {
                ',' -> i++
                '}' -> return null
                else -> return null
            }
        }
    }

    private fun parseString(): String? {
        if (!consume('"')) return null
        val sb = StringBuilder()
        while (i < s.length) {
            val c = s[i]
            when {
                c == '"' -> {
                    i++
                    return sb.toString()
                }
                c == '\\' && i + 1 < s.length -> {
                    when (val n = s[i + 1]) {
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        '"' -> sb.append('"')
                        '\\' -> sb.append('\\')
                        '/' -> sb.append('/')
                        'u' -> {
                            if (i + 5 >= s.length) return null
                            sb.append(s.substring(i + 2, i + 6).toInt(16).toChar())
                            i += 4
                        }
                        else -> sb.append(n)
                    }
                    i += 2
                }
                else -> {
                    sb.append(c)
                    i++
                }
            }
        }
        return null
    }

    private fun skipValue(): Boolean {
        skipWs()
        val c = peek() ?: return false
        return when (c) {
            '"' -> parseString() != null
            '{' -> skipDelimited('{', '}')
            '[' -> skipDelimited('[', ']')
            't' -> consumeLiteral("true")
            'f' -> consumeLiteral("false")
            'n' -> consumeLiteral("null")
            '-' -> skipNumber()
            in '0'..'9' -> skipNumber()
            else -> false
        }
    }

    private fun skipDelimited(open: Char, close: Char): Boolean {
        if (!consume(open)) return false
        var depth = 1
        while (i < s.length && depth > 0) {
            when (s[i]) {
                '"' -> {
                    if (parseString() == null) return false
                    continue
                }
                open -> depth++
                close -> depth--
            }
            i++
        }
        return depth == 0
    }

    private fun skipNumber(): Boolean {
        if (peek() == '-') i++
        if (i >= s.length) return false
        val start = i
        while (i < s.length) {
            val c = s[i]
            if (c.isDigit() || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                i++
            } else {
                break
            }
        }
        return i > start
    }

    private fun consumeLiteral(lit: String): Boolean {
        if (!s.startsWith(lit, i)) return false
        i += lit.length
        return true
    }

    private fun consume(c: Char): Boolean {
        if (peek() != c) return false
        i++
        return true
    }

    private fun peek(): Char? = if (i < s.length) s[i] else null

    private fun skipWs() {
        while (i < s.length && s[i].isWhitespace()) i++
    }
}
