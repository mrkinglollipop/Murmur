package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.DictionaryEntry
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

enum class GeminiVadMode(val raw: String) {
    MANUAL("manual"),
    AUTOMATIC("automatic"),
    HYBRID("hybrid"),
    ;

    companion object {
        fun fromRaw(raw: String?): GeminiVadMode =
            entries.firstOrNull { it.raw == raw } ?: MANUAL
    }
}

enum class GeminiStartSensitivity(val raw: String) {
    HIGH("START_SENSITIVITY_HIGH"),
    LOW("START_SENSITIVITY_LOW"),
}

enum class GeminiEndSensitivity(val raw: String) {
    HIGH("END_SENSITIVITY_HIGH"),
    LOW("END_SENSITIVITY_LOW"),
}

data class GeminiLiveOptions(
    val vadMode: GeminiVadMode = GeminiVadMode.MANUAL,
    val startSensitivity: GeminiStartSensitivity = GeminiStartSensitivity.HIGH,
    val endSensitivity: GeminiEndSensitivity = GeminiEndSensitivity.HIGH,
    val prefixPaddingMs: Int = 20,
    val silenceDurationMs: Int = 100,
) {
    fun clamped(): GeminiLiveOptions = copy(
        prefixPaddingMs = prefixPaddingMs.coerceIn(PREFIX_PADDING_RANGE),
        silenceDurationMs = silenceDurationMs.coerceIn(SILENCE_DURATION_RANGE),
    )

    companion object {
        val DEFAULTS = GeminiLiveOptions()
        val PREFIX_PADDING_RANGE = 0..500
        val SILENCE_DURATION_RANGE = 0..2000

        fun bcp47LanguageCodes(selectedLanguage: String): List<String> {
            val trimmed = selectedLanguage.trim()
            if (trimmed.isEmpty()) return emptyList()
            if (trimmed.contains('-')) return listOf(trimmed)
            val mapped = mapOf(
                "en" to "en-US",
                "es" to "es-US",
                "fr" to "fr-FR",
                "de" to "de-DE",
                "it" to "it-IT",
                "pt" to "pt-BR",
                "nl" to "nl-NL",
                "ja" to "ja-JP",
                "ko" to "ko-KR",
                "zh" to "cmn-Hans-CN",
                "ru" to "ru-RU",
                "ar" to "ar-EG",
                "hi" to "hi-IN",
            )
            val code = mapped[trimmed.lowercase()] ?: return emptyList()
            return listOf(code)
        }

        fun makeSetupMessageJson(
            language: String,
            smartMode: Boolean,
            vocabulary: List<String>,
            options: GeminiLiveOptions,
        ): String {
            val opts = options.clamped()
            val inputAudioTranscription = linkedMapOf<String, Any>(
                "mode" to if (smartMode) "SMART" else "VERBATIM",
                "languageCodes" to bcp47LanguageCodes(language),
            )
            if (vocabulary.isNotEmpty()) {
                inputAudioTranscription["customVocabulary"] = vocabulary
            }
            val automaticActivityDetection = linkedMapOf<String, Any>()
            when (opts.vadMode) {
                GeminiVadMode.MANUAL -> automaticActivityDetection["disabled"] = true
                GeminiVadMode.AUTOMATIC, GeminiVadMode.HYBRID -> {
                    automaticActivityDetection["disabled"] = false
                    automaticActivityDetection["startOfSpeechSensitivity"] = opts.startSensitivity.raw
                    automaticActivityDetection["endOfSpeechSensitivity"] = opts.endSensitivity.raw
                    automaticActivityDetection["prefixPaddingMs"] = opts.prefixPaddingMs
                    automaticActivityDetection["silenceDurationMs"] = opts.silenceDurationMs
                }
            }
            val setup = linkedMapOf(
                "model" to "models/gemini-3.5-transcribe-live",
                "generationConfig" to mapOf("responseModalities" to listOf("TEXT")),
                "inputAudioTranscription" to inputAudioTranscription,
                "realtimeInputConfig" to mapOf(
                    "automaticActivityDetection" to automaticActivityDetection,
                ),
            )
            return JsonValue.encode(mapOf("setup" to setup))
        }

        fun makeActivityStartFrameJson(): String =
            JsonValue.encode(mapOf("realtimeInput" to mapOf("activityStart" to emptyMap<String, Any>())))

        fun makeActivityEndFrameJson(): String =
            JsonValue.encode(mapOf("realtimeInput" to mapOf("activityEnd" to emptyMap<String, Any>())))

        fun makeAudioFrameJson(pcmData: ByteArray): String =
            JsonValue.encode(
                mapOf(
                    "realtimeInput" to mapOf(
                        "audio" to linkedMapOf(
                            "mimeType" to "audio/pcm;rate=16000",
                            "data" to Base64.getEncoder().encodeToString(pcmData),
                        ),
                    ),
                ),
            )

        fun makeAudioStreamEndFrameJson(): String =
            JsonValue.encode(mapOf("realtimeInput" to mapOf("audioStreamEnd" to true)))

        fun makeBatchRequestBody(
            wavBase64: String,
            mimeType: String,
            smartMode: Boolean,
            vocabulary: List<String>,
        ): Map<String, Any> {
            val transcriptionConfig = linkedMapOf<String, Any>(
                "mode" to mapOf("type" to if (smartMode) "smart" else "verbatim"),
            )
            if (vocabulary.isNotEmpty()) {
                transcriptionConfig["custom_vocabulary"] = vocabulary
            }
            return linkedMapOf(
                "model" to "gemini-3.5-transcribe",
                "input" to listOf(
                    linkedMapOf(
                        "type" to "audio",
                        "data" to wavBase64,
                        "mime_type" to mimeType,
                    ),
                ),
                "generation_config" to mapOf(
                    "transcription_config" to transcriptionConfig,
                ),
            )
        }
    }
}

class GeminiLiveTranscriber(
    private val apiKey: String,
    private val language: String = "en",
    private val smartMode: Boolean = true,
    private val vocabulary: List<String> = emptyList(),
    liveOptions: GeminiLiveOptions = GeminiLiveOptions.DEFAULTS,
    private val client: OkHttpClient = ElevenLabsRealtimeTranscriber.defaultWsClient(),
    private val urlOverride: String? = null,
) : LiveTranscriber {
    private val liveOptions = liveOptions.clamped()
    private val lock = Any()
    private val frames = LinkedBlockingQueue<Any>()
    private val readyLatch = CountDownLatch(1)
    private val doneLatch = CountDownLatch(1)
    private val poison = Any()

    @Volatile private var accepting = false
    @Volatile private var tornDown = false
    @Volatile private var socketClosed = false
    @Volatile private var finalizeRequested = false
    @Volatile private var readyResolved = false
    @Volatile private var sessionReady = false
    @Volatile private var readyError: LiveStartException? = null
    @Volatile private var doneResolved = false
    @Volatile private var everHad = false
    @Volatile private var sessionCapReached = false
    @Volatile private var activityStartSent = false
    @Volatile override var onInterim: ((String) -> Unit)? = null

    private var committedSegments: MutableList<String> = mutableListOf()
    private var latestPartial: String = ""
    private var webSocket: WebSocket? = null
    private var senderThread: Thread? = null
    private var doneText: String = ""
    private var sessionStartMs: Long = 0L

    override val hasEverHadNonEmptyStreamText: Boolean
        get() = synchronized(lock) { everHad }

    override fun joinedTranscriptSnapshot(): String = synchronized(lock) {
        joinedTranscript(committedSegments, latestPartial)
    }

    override fun arm() {
        synchronized(lock) {
            if (tornDown) return
            accepting = true
        }
    }

    override fun start() {
        arm()
        synchronized(lock) {
            if (tornDown) throw LiveStartException.cancelled()
            resetTranscriptStateLocked()
            sessionStartMs = System.currentTimeMillis()
        }
        val url = urlOverride ?: buildSocketUrl(apiKey)
        val request = Request.Builder()
            .url(toHttpUrlForRequest(url))
            .build()
        val ws = client.newWebSocket(request, Listener())
        synchronized(lock) { webSocket = ws }
        ws.send(
            GeminiLiveOptions.makeSetupMessageJson(
                language = language,
                smartMode = smartMode,
                vocabulary = vocabulary,
                options = liveOptions,
            ),
        )
        awaitReady("Timed out waiting for setupComplete")
        if (liveOptions.vadMode == GeminiVadMode.MANUAL && !activityStartSent) {
            ws.send(GeminiLiveOptions.makeActivityStartFrameJson())
            activityStartSent = true
        }
        startSender(ws)
    }

    override fun sendPcm16(pcm: ByteArray) {
        if (!accepting || tornDown) return
        val now = System.currentTimeMillis()
        synchronized(lock) {
            if (!sessionCapReached && sessionStartMs > 0 &&
                sessionCapExceeded((now - sessionStartMs) / 1000.0)
            ) {
                sessionCapReached = true
            }
            if (sessionCapReached) return
        }
        frames.offer(GeminiLiveOptions.makeAudioFrameJson(pcm))
    }

    override fun finalize(recordingDurationSeconds: Double): String {
        val capReached: Boolean
        synchronized(lock) {
            if (tornDown) {
                return joinedTranscript(committedSegments, latestPartial)
            }
            tornDown = true
            finalizeRequested = true
            accepting = false
            capReached = sessionCapReached
        }
        failReadyLatch(LiveStartException.cancelled("finalized"))
        frames.offer(poison)
        senderThread?.join(2_000)
        senderThread = null

        val closed: Boolean
        val accumulated: String
        val ready: Boolean
        synchronized(lock) {
            closed = socketClosed
            ready = sessionReady
            accumulated = joinedTranscript(committedSegments, latestPartial)
        }
        if (!ready) {
            tearDownSocket()
            synchronized(lock) { resetTranscriptStateLocked() }
            return accumulated
        }
        if (capReached) {
            tearDownSocket()
            val capText = capReachedFinalizeText(accumulated)
            synchronized(lock) { resetTranscriptStateLocked() }
            return capText
        }
        if (closed) {
            tearDownSocket()
            synchronized(lock) { resetTranscriptStateLocked() }
            return accumulated
        }

        when (liveOptions.vadMode) {
            GeminiVadMode.MANUAL -> webSocket?.send(GeminiLiveOptions.makeActivityEndFrameJson())
            GeminiVadMode.HYBRID -> webSocket?.send(GeminiLiveOptions.makeAudioStreamEndFrameJson())
            GeminiVadMode.AUTOMATIC -> Unit
        }

        val waitSeconds = minOf(30.0, maxOf(3.0, recordingDurationSeconds * 0.25 + 3.0))
        doneLatch.await((waitSeconds * 1000).toLong(), TimeUnit.MILLISECONDS)
        val result = synchronized(lock) {
            if (doneResolved) doneText else joinedTranscript(committedSegments, latestPartial)
        }
        tearDownSocket()
        synchronized(lock) { resetTranscriptStateLocked() }
        return result
    }

    override fun cancel() {
        synchronized(lock) {
            if (tornDown) return
            tornDown = true
            accepting = false
        }
        frames.offer(poison)
        failReady(LiveStartException.cancelled())
        completeDone(synchronized(lock) { joinedTranscript(committedSegments, latestPartial) })
        synchronized(lock) { resetTranscriptStateLocked() }
        tearDownSocket()
    }

    fun handleServerEvent(text: String) {
        val json = JsonValue.obj(text) ?: return
        if (json.has("error")) {
            failReady("server error")
            return
        }
        if (json.has("setupComplete") || json.has("setup_complete")) {
            markReady()
            return
        }
        val serverContent = json.objAny("serverContent", "server_content") ?: return
        transcriptionText(serverContent, "interimInputTranscription", "interim_input_transcription")
            ?.let { applyPartial(it) }
        transcriptionText(serverContent, "inputTranscription", "input_transcription")
            ?.let { applyCommitted(it) }
    }

    private fun transcriptionText(serverContent: JsonValue.Obj, vararg keys: String): String? {
        for (key in keys) {
            val node = serverContent.obj(key) ?: continue
            val text = node.string("text")
            if (text != null) return text
        }
        return null
    }

    private fun applyPartial(partialText: String) {
        val running: String
        synchronized(lock) {
            val trimmed = partialText.trim()
            if (trimmed.isNotEmpty()) {
                latestPartial = partialText
                everHad = true
            }
            running = joinedTranscript(committedSegments, latestPartial)
        }
        onInterim?.invoke(running)
    }

    private fun applyCommitted(committedText: String) {
        val running: String
        val shouldResolve: Boolean
        synchronized(lock) {
            val trimmed = committedText.trim()
            if (trimmed.isNotEmpty()) {
                committedSegments += trimmed
                everHad = true
                latestPartial = ""
            }
            running = joinedTranscript(committedSegments, latestPartial)
            shouldResolve = finalizeRequested && !doneResolved
            if (shouldResolve) {
                doneResolved = true
                doneText = running
            }
        }
        if (shouldResolve) doneLatch.countDown()
        onInterim?.invoke(running)
    }

    private fun startSender(ws: WebSocket) {
        val thread = Thread({
            while (true) {
                val item = try {
                    frames.take()
                } catch (_: InterruptedException) {
                    break
                }
                if (item === poison) break
                if (item is String) {
                    if (!ws.send(item)) break
                }
            }
        }, "gemini-ws-send")
        thread.isDaemon = true
        senderThread = thread
        thread.start()
    }

    private fun markReady() {
        if (readyResolved) return
        readyResolved = true
        sessionReady = true
        readyError = null
        readyLatch.countDown()
    }

    private fun awaitReady(timeoutMessage: String) {
        val countedDown = try {
            readyLatch.await(5, TimeUnit.SECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw LiveStartException.cancelled("interrupted")
        }
        if (!countedDown) {
            if (tornDown) throw LiveStartException.cancelled()
            cancel()
            throw LiveStartException.handshake(timeoutMessage)
        }
        val error = readyError
        if (error != null) {
            if (error.handshake) cancel()
            throw error
        }
    }

    private fun failReadyLatch(error: LiveStartException) {
        if (!readyResolved) {
            readyResolved = true
            readyError = error
            readyLatch.countDown()
        }
    }

    private fun failReady(error: LiveStartException) {
        socketClosed = true
        failReadyLatch(error)
        completeDone(synchronized(lock) { joinedTranscript(committedSegments, latestPartial) })
    }

    private fun failReady(reason: String) {
        failReady(LiveStartException.handshake(reason))
    }

    private fun completeDone(text: String) {
        synchronized(lock) {
            if (doneResolved) return
            doneResolved = true
            doneText = text
        }
        doneLatch.countDown()
    }

    private fun resetTranscriptStateLocked() {
        committedSegments = mutableListOf()
        latestPartial = ""
        everHad = false
        finalizeRequested = false
        activityStartSent = false
        sessionCapReached = false
        sessionStartMs = 0L
        sessionReady = false
    }

    private fun tearDownSocket() {
        senderThread?.interrupt()
        senderThread = null
        val ws = webSocket
        webSocket = null
        ws?.close(1000, null)
        ws?.cancel()
    }

    private inner class Listener : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            handleServerEvent(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            utf8JsonText(bytes.toByteArray())?.let { handleServerEvent(it) }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            failReady("closed code $code")
            webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            failReady("closed code $code")
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            failReady("receive: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        const val SESSION_CAP_SECONDS = 580.0
        const val MAX_VOCABULARY_TERMS = 100
        const val HOST = "generativelanguage.googleapis.com"
        const val PATH = "ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

        fun utf8JsonText(data: ByteArray): String? = String(data, Charsets.UTF_8)

        fun buildSocketUrl(apiKey: String, host: String = HOST, port: Int? = null, tls: Boolean = true): String {
            val builder = HttpUrl.Builder()
                .scheme(if (tls) "https" else "http")
                .host(host)
                .addPathSegments(PATH)
                .addQueryParameter("key", apiKey)
            if (port != null) builder.port(port)
            val http = builder.build().toString()
            return if (tls) http.replaceFirst("https://", "wss://")
            else http.replaceFirst("http://", "ws://")
        }

        fun selectVocabulary(entries: List<DictionaryEntry>): List<String> {
            val seen = mutableSetOf<String>()
            data class Candidate(val term: String, val fixCount: Int, val index: Int)
            val candidates = mutableListOf<Candidate>()
            for ((index, entry) in entries.withIndex()) {
                val term = entry.term.trim()
                if (term.length <= 1) continue
                val key = term.lowercase()
                if (!seen.add(key)) continue
                candidates += Candidate(term, entry.fixCount, index)
            }
            candidates.sortWith(
                compareByDescending<Candidate> { it.fixCount }
                    .thenByDescending { it.index },
            )
            return candidates.take(MAX_VOCABULARY_TERMS).map { it.term }
        }

        fun joinedTranscript(segments: List<String>, partial: String): String {
            val committed = segments.joinToString(" ")
            val trimmedPartial = partial.trim()
            if (trimmedPartial.isEmpty()) return committed
            if (committed.isEmpty()) return trimmedPartial
            if (committed.contains(trimmedPartial, ignoreCase = true)) return committed
            return "$committed $trimmedPartial"
        }

        fun sessionCapExceeded(elapsed: Double): Boolean = elapsed > SESSION_CAP_SECONDS

        fun capReachedFinalizeText(accumulatedSoFar: String): String = accumulatedSoFar

        private fun toHttpUrlForRequest(wsUrl: String): String = when {
            wsUrl.startsWith("wss://") -> "https://" + wsUrl.removePrefix("wss://")
            wsUrl.startsWith("ws://") -> "http://" + wsUrl.removePrefix("ws://")
            else -> wsUrl
        }
    }
}

object GeminiBatchDecode {
    fun decodeTranscript(json: String): String? {
        val obj = JsonValue.obj(json) ?: return null
        obj.string("output_text")?.trim()?.takeIf { it.isNotEmpty() }?.let { return obj.string("output_text") }
        val output = obj.get("output")
        when (output) {
            is JsonValue.Str -> {
                if (output.value.trim().isNotEmpty()) return output.value
            }
            is JsonValue.Arr -> {
                val joined = output.items.mapNotNull { item ->
                    val node = item as? JsonValue.Obj ?: return@mapNotNull null
                    node.string("text") ?: node.string("content")
                }.joinToString(" ")
                if (joined.trim().isNotEmpty()) return joined
            }
            is JsonValue.Obj -> {
                for (key in listOf("text", "content", "transcript")) {
                    val text = output.string(key)
                    if (!text.isNullOrBlank()) return text
                }
            }
            else -> Unit
        }
        val steps = obj.arr("steps") ?: return null
        val parts = mutableListOf<String>()
        for (step in steps) {
            val stepObj = step as? JsonValue.Obj ?: continue
            val content = stepObj.arr("content").orEmpty()
            for (item in content) {
                val node = item as? JsonValue.Obj ?: continue
                val text = node.string("text") ?: continue
                if (text.trim().isNotEmpty()) parts += text
            }
        }
        val joined = parts.joinToString(" ")
        return joined.takeIf { it.trim().isNotEmpty() }
    }
}
