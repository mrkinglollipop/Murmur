package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.DictionaryEntry
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

enum class ElevenLabsCommitStrategy(val raw: String) {
    MANUAL("manual"),
    VAD("vad"),
    ;

    companion object {
        fun fromRaw(raw: String?): ElevenLabsCommitStrategy =
            entries.firstOrNull { it.raw == raw } ?: MANUAL
    }
}

data class ElevenLabsRealtimeOptions(
    val filterBackgroundAudio: Boolean = false,
    val commitStrategy: ElevenLabsCommitStrategy = ElevenLabsCommitStrategy.MANUAL,
    val vadThreshold: Double = 0.4,
    val vadSilenceThresholdSecs: Double = 1.5,
    val minSpeechDurationMs: Int = 100,
    val minSilenceDurationMs: Int = 100,
) {
    fun clamped(): ElevenLabsRealtimeOptions = copy(
        vadThreshold = vadThreshold.coerceIn(VAD_THRESHOLD_RANGE),
        vadSilenceThresholdSecs = vadSilenceThresholdSecs.coerceIn(VAD_SILENCE_RANGE),
        minSpeechDurationMs = minSpeechDurationMs.coerceIn(MIN_SPEECH_MS_RANGE),
        minSilenceDurationMs = minSilenceDurationMs.coerceIn(MIN_SILENCE_MS_RANGE),
    )

    /** VAD numeric params only for `commit_strategy=vad`. Filter omitted when off. */
    fun queryItems(): List<Pair<String, String>> {
        val value = clamped()
        val items = mutableListOf("commit_strategy" to value.commitStrategy.raw)
        if (value.filterBackgroundAudio) {
            items += "filter_background_audio" to "true"
        }
        if (value.commitStrategy == ElevenLabsCommitStrategy.VAD) {
            items += "vad_threshold" to decimalString(value.vadThreshold)
            items += "vad_silence_threshold_secs" to decimalString(value.vadSilenceThresholdSecs)
            items += "min_speech_duration_ms" to value.minSpeechDurationMs.toString()
            items += "min_silence_duration_ms" to value.minSilenceDurationMs.toString()
        }
        return items
    }

    companion object {
        val DEFAULTS = ElevenLabsRealtimeOptions()
        val VAD_THRESHOLD_RANGE = 0.1..0.9
        val VAD_SILENCE_RANGE = 0.3..3.0
        val MIN_SPEECH_MS_RANGE = 50..500
        val MIN_SILENCE_MS_RANGE = 50..500

        internal fun decimalString(value: Double): String {
            val asLong = value.toLong()
            return if (value == asLong.toDouble()) asLong.toString() else value.toString()
        }
    }
}

class ElevenLabsRealtimeTranscriber(
    private val apiKey: String,
    private val language: String = "en",
    private val noVerbatim: Boolean = true,
    private val keyterms: List<String> = emptyList(),
    realtimeOptions: ElevenLabsRealtimeOptions = ElevenLabsRealtimeOptions.DEFAULTS,
    private val client: OkHttpClient = defaultWsClient(),
    private val urlOverride: String? = null,
) : LiveTranscriber {
    private val realtimeOptions = realtimeOptions.clamped()
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
    @Volatile private var readyError: Exception? = null
    @Volatile private var doneResolved = false
    @Volatile private var everHad = false
    @Volatile override var onInterim: ((String) -> Unit)? = null

    private var committedSegments: MutableList<String> = mutableListOf()
    private var latestPartial: String = ""
    private var webSocket: WebSocket? = null
    private var senderThread: Thread? = null
    private var doneText: String = ""

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
            if (tornDown) throw LiveStartException("cancelled")
            resetTranscriptStateLocked()
        }
        val url = urlOverride ?: buildSocketUrl(
            language = language,
            noVerbatim = noVerbatim,
            keyterms = keyterms,
            options = realtimeOptions,
        )
        val request = Request.Builder()
            .url(toHttpUrlForRequest(url))
            .header("xi-api-key", apiKey)
            .build()
        val ws = client.newWebSocket(request, Listener())
        synchronized(lock) { webSocket = ws }
        if (!readyLatch.await(5, TimeUnit.SECONDS)) {
            cancel()
            throw LiveStartException("Timed out waiting for session_started")
        }
        readyError?.let {
            cancel()
            throw it
        }
        startSender(ws)
    }

    override fun sendPcm16(pcm: ByteArray) {
        if (!accepting || tornDown) return
        frames.offer(makeInputAudioChunkFrame(pcm, commit = false))
    }

    override fun finalize(recordingDurationSeconds: Double): String {
        synchronized(lock) {
            if (tornDown) {
                return joinedTranscript(committedSegments, latestPartial)
            }
            tornDown = true
            finalizeRequested = true
            accepting = false
        }
        frames.offer(poison)
        senderThread?.join(2_000)
        senderThread = null

        val closed: Boolean
        val accumulated: String
        synchronized(lock) {
            closed = socketClosed
            accumulated = joinedTranscript(committedSegments, latestPartial)
        }
        if (closed) {
            tearDownSocket()
            synchronized(lock) { resetTranscriptStateLocked() }
            return accumulated
        }

        webSocket?.send(makeInputAudioChunkFrame(ByteArray(0), commit = true))

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
        failReady("cancelled")
        completeDone(synchronized(lock) { joinedTranscript(committedSegments, latestPartial) })
        synchronized(lock) { resetTranscriptStateLocked() }
        tearDownSocket()
    }

    fun handleServerEvent(text: String) {
        val json = JsonValue.obj(text) ?: return
        val messageType = json.string("message_type") ?: return
        when (messageType) {
            "session_started" -> {
                markReady()
            }
            "partial_transcript" -> {
                val partialText = json.string("text").orEmpty()
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
            "committed_transcript" -> {
                val committedText = json.string("text").orEmpty()
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
            "committed_transcript_with_timestamps" -> Unit
            "input_error", "transcriber_error", "chunk_size_exceeded",
            "queue_overflow", "resource_exhausted", "session_time_limit_exceeded",
            "insufficient_audio_activity",
            -> Unit
            else -> Unit
        }
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
        }, "el-ws-send")
        thread.isDaemon = true
        senderThread = thread
        thread.start()
    }

    private fun markReady() {
        if (readyResolved) return
        readyResolved = true
        readyError = null
        readyLatch.countDown()
    }

    private fun failReady(reason: String) {
        socketClosed = true
        if (!readyResolved) {
            readyResolved = true
            readyError = LiveStartException(reason)
            readyLatch.countDown()
        }
        completeDone(synchronized(lock) { joinedTranscript(committedSegments, latestPartial) })
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
    }

    private fun tearDownSocket() {
        senderThread?.interrupt()
        senderThread = null
        webSocket?.close(1000, null)
        webSocket = null
    }

    private inner class Listener : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            handleServerEvent(text)
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
        const val MODEL_ID = "scribe_v2_realtime"
        const val SAMPLE_RATE = 16_000
        const val MAX_KEYTERMS = 50
        const val MAX_KEYTERM_LENGTH = 20
        const val HOST = "api.elevenlabs.io"
        const val PATH = "v1/speech-to-text/realtime"

        private val sharedWsClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.SECONDS)
                .writeTimeout(10, TimeUnit.SECONDS)
                .pingInterval(15, TimeUnit.SECONDS)
                .build()
        }

        fun defaultWsClient(): OkHttpClient = sharedWsClient

        fun buildSocketUrl(
            language: String,
            noVerbatim: Boolean,
            keyterms: List<String>,
            options: ElevenLabsRealtimeOptions = ElevenLabsRealtimeOptions.DEFAULTS,
            host: String = HOST,
            port: Int? = null,
            tls: Boolean = true,
        ): String {
            val builder = HttpUrl.Builder()
                .scheme(if (tls) "https" else "http")
                .host(host)
                .addPathSegments(PATH)
                .addQueryParameter("model_id", MODEL_ID)
                .addQueryParameter("audio_format", "pcm_16000")
                .addQueryParameter("language_code", language)
                .addQueryParameter("no_verbatim", if (noVerbatim) "true" else "false")
            if (port != null) builder.port(port)
            for ((name, value) in options.queryItems()) {
                builder.addQueryParameter(name, value)
            }
            for (term in keyterms) {
                builder.addQueryParameter("keyterms", term)
            }
            val http = builder.build().toString()
            return if (tls) http.replaceFirst("https://", "wss://")
            else http.replaceFirst("http://", "ws://")
        }

        fun selectKeyterms(entries: List<DictionaryEntry>): List<String> {
            val seen = mutableSetOf<String>()
            data class Candidate(val term: String, val fixCount: Int, val index: Int)
            val candidates = mutableListOf<Candidate>()
            for ((index, entry) in entries.withIndex()) {
                val term = entry.term.trim()
                if (term.length <= 1) continue
                if (term.toByteArray(Charsets.UTF_8).size > MAX_KEYTERM_LENGTH) continue
                val key = term.lowercase()
                if (!seen.add(key)) continue
                candidates += Candidate(term, entry.fixCount, index)
            }
            candidates.sortWith(
                compareByDescending<Candidate> { it.fixCount }
                    .thenByDescending { it.index },
            )
            return candidates.take(MAX_KEYTERMS).map { it.term }
        }

        fun joinedTranscript(segments: List<String>, partial: String): String {
            val committed = segments.joinToString(" ")
            val trimmedPartial = partial.trim()
            if (trimmedPartial.isEmpty()) return committed
            if (committed.isEmpty()) return trimmedPartial
            if (committed.contains(trimmedPartial, ignoreCase = true)) return committed
            return "$committed $trimmedPartial"
        }

        fun makeInputAudioChunkFrame(pcmData: ByteArray, commit: Boolean): String {
            val payload = linkedMapOf<String, Any>(
                "message_type" to "input_audio_chunk",
                "audio_base_64" to Base64.getEncoder().encodeToString(pcmData),
                "commit" to commit,
                "sample_rate" to SAMPLE_RATE,
            )
            return JsonValue.encode(payload)
        }

        private fun toHttpUrlForRequest(wsUrl: String): String = when {
            wsUrl.startsWith("wss://") -> "https://" + wsUrl.removePrefix("wss://")
            wsUrl.startsWith("ws://") -> "http://" + wsUrl.removePrefix("ws://")
            else -> wsUrl
        }
    }
}
