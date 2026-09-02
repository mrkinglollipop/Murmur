package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.DictionaryEntry
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class ElevenLabsRealtimeTest {

    @Test
    fun inputAudioChunkFrameContainsAllRequiredFields() {
        val pcm = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        val frame = ElevenLabsRealtimeTranscriber.makeInputAudioChunkFrame(pcm, commit = false)
        val json = JsonValue.obj(frame)!!
        assertEquals("input_audio_chunk", json.string("message_type"))
        assertEquals(Base64.getEncoder().encodeToString(pcm), json.string("audio_base_64"))
        assertEquals(false, json.bool("commit"))
        assertEquals("16000", (json.get("sample_rate") as JsonValue.Num).raw)
    }

    @Test
    fun inputAudioChunkFrameCommitTrueOnFinalFrame() {
        val frame = ElevenLabsRealtimeTranscriber.makeInputAudioChunkFrame(ByteArray(0), commit = true)
        val json = JsonValue.obj(frame)!!
        assertEquals(true, json.bool("commit"))
        assertEquals("", json.string("audio_base_64"))
    }

    @Test
    fun goldenFixturesUseMessageTypeNotType() {
        val started = JsonValue.obj(fixture("el-session-started.json"))!!
        assertEquals("session_started", started.string("message_type"))
        assertEquals("abc123", started.string("session_id"))
        val partial = JsonValue.obj(fixture("el-partial.json"))!!
        assertEquals("partial_transcript", partial.string("message_type"))
        assertEquals("The first move is what sets", partial.string("text"))
        val committed = JsonValue.obj(fixture("el-committed.json"))!!
        assertEquals("committed_transcript", committed.string("message_type"))
        assertEquals("The first move is what sets everything in motion.", committed.string("text"))
    }

    @Test
    fun parseTranscriptTextIgnoresNestedWordText() {
        assertEquals("hello world", parseTranscriptText(fixture("el-words-before-text.json")))
    }

    @Test
    fun joinedTranscriptSingleCommittedSegment() {
        assertEquals(
            "The first move is what sets everything in motion.",
            ElevenLabsRealtimeTranscriber.joinedTranscript(
                listOf("The first move is what sets everything in motion."),
                "",
            ),
        )
    }

    @Test
    fun joinedTranscriptMultipleCommittedSegmentsInOrder() {
        assertEquals(
            "We need to finish the report by Friday. Then send it to the team.",
            ElevenLabsRealtimeTranscriber.joinedTranscript(
                listOf("We need to finish the report by Friday.", "Then send it to the team."),
                "",
            ),
        )
    }

    @Test
    fun joinedTranscriptAppendsInFlightPartialTail() {
        assertEquals(
            "We need to finish the report. Then send it to the",
            ElevenLabsRealtimeTranscriber.joinedTranscript(
                listOf("We need to finish the report."),
                "Then send it to the",
            ),
        )
    }

    @Test
    fun joinedTranscriptPartialOnlyBeforeAnyCommit() {
        assertEquals(
            "The first move is what sets",
            ElevenLabsRealtimeTranscriber.joinedTranscript(emptyList(), "The first move is what sets"),
        )
    }

    @Test
    fun joinedTranscriptDropsPartialAlreadyContainedInCommitted() {
        assertEquals(
            "The first move is what sets everything in motion.",
            ElevenLabsRealtimeTranscriber.joinedTranscript(
                listOf("The first move is what sets everything in motion."),
                "everything in motion",
            ),
        )
    }

    @Test
    fun joinedTranscriptEmptyWhenNothingReceived() {
        assertEquals("", ElevenLabsRealtimeTranscriber.joinedTranscript(emptyList(), ""))
    }

    @Test
    fun emptyCommittedTranscriptRetainsPartialAndEverHadLatch() {
        val session = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        session.handleServerEvent(fixture("el-partial.json"))
        assertTrue(session.hasEverHadNonEmptyStreamText)
        assertEquals("The first move is what sets", session.joinedTranscriptSnapshot())
        session.handleServerEvent(fixture("el-committed-empty.json"))
        assertTrue(session.hasEverHadNonEmptyStreamText)
        assertEquals("The first move is what sets", session.joinedTranscriptSnapshot())
    }

    @Test
    fun emptyPartialTranscriptRetainsPriorPartialAndEverHadLatch() {
        val session = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        session.handleServerEvent("""{"message_type":"partial_transcript","text":"hello there"}""")
        session.handleServerEvent("""{"message_type":"partial_transcript","text":""}""")
        assertTrue(session.hasEverHadNonEmptyStreamText)
        assertEquals("hello there", session.joinedTranscriptSnapshot())
        session.handleServerEvent("""{"message_type":"partial_transcript","text":"   "}""")
        assertEquals("hello there", session.joinedTranscriptSnapshot())
    }

    @Test
    fun nonEmptyCommittedTranscriptClearsPartial() {
        val session = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        session.handleServerEvent("""{"message_type":"partial_transcript","text":"hello there friend"}""")
        session.handleServerEvent("""{"message_type":"committed_transcript","text":"hello there friend"}""")
        assertEquals("hello there friend", session.joinedTranscriptSnapshot())
        assertTrue(session.hasEverHadNonEmptyStreamText)
    }

    @Test
    fun concurrentCancelAndFinalizeDoesNotHang() {
        val transcriber = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        val done = CountDownLatch(1)
        Thread {
            transcriber.finalize(0.0)
            done.countDown()
        }.start()
        transcriber.cancel()
        assertTrue(done.await(5, TimeUnit.SECONDS))
    }

    @Test
    fun repeatedCancelDoesNotCrash() {
        val transcriber = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        transcriber.cancel()
        transcriber.cancel()
        transcriber.cancel()
        transcriber.sendPcm16(byteArrayOf(1, 0))
    }

    @Test
    fun sendAfterCancelIsSafeNoOp() {
        val transcriber = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        transcriber.cancel()
        transcriber.sendPcm16(byteArrayOf(1, 0))
    }

    @Test
    fun repeatedFinalizeIsIdempotent() {
        val transcriber = ElevenLabsRealtimeTranscriber(apiKey = "test-key")
        val first = transcriber.finalize(0.0)
        val second = transcriber.finalize(0.0)
        assertEquals(first, second)
    }

    @Test
    fun selectKeytermsReturnsCanonicalTermsOnly() {
        val entries = listOf(
            DictionaryEntry(term = "Xcodegen", variants = listOf("ex codegen", "eggs codegen")),
            DictionaryEntry(term = "Keychain", variants = listOf("key chain")),
        )
        val result = ElevenLabsRealtimeTranscriber.selectKeyterms(entries)
        assertEquals(setOf("Xcodegen", "Keychain"), result.toSet())
        for (variant in listOf("ex codegen", "eggs codegen", "key chain")) {
            assertFalse(result.contains(variant))
        }
    }

    @Test
    fun selectKeytermsDeduplicatesCaseInsensitively() {
        val entries = listOf(
            DictionaryEntry(term = "Scribe"),
            DictionaryEntry(term = "scribe"),
            DictionaryEntry(term = "SCRIBE"),
        )
        assertEquals(1, ElevenLabsRealtimeTranscriber.selectKeyterms(entries).size)
    }

    @Test
    fun selectKeytermsDropsEmptySingleCharAndOverlong() {
        val entries = listOf(
            DictionaryEntry(term = ""),
            DictionaryEntry(term = "   "),
            DictionaryEntry(term = "a"),
            DictionaryEntry(term = "AI"),
            DictionaryEntry(term = "ElevenLabsRealtimeTranscriber"),
            DictionaryEntry(term = "b".repeat(20)),
        )
        assertEquals(listOf("b".repeat(20), "AI"), ElevenLabsRealtimeTranscriber.selectKeyterms(entries))
    }

    @Test
    fun selectKeytermsCapsAtServerLimitPreferringHighestFixCount() {
        val entries = (0 until 150).map { i ->
            DictionaryEntry(term = "term$i", fixCount = i)
        }
        val result = ElevenLabsRealtimeTranscriber.selectKeyterms(entries)
        assertEquals(50, ElevenLabsRealtimeTranscriber.MAX_KEYTERMS)
        assertEquals(50, result.size)
        assertTrue(result.contains("term149"))
        assertTrue(result.contains("term100"))
        assertFalse(result.contains("term99"))
    }

    @Test
    fun selectKeytermsLengthLimitCountsUtf8Bytes() {
        val accented = "é".repeat(15)
        val entries = listOf(
            DictionaryEntry(term = accented),
            DictionaryEntry(term = "plainAscii"),
        )
        assertEquals(listOf("plainAscii"), ElevenLabsRealtimeTranscriber.selectKeyterms(entries))
    }

    @Test
    fun buildSocketUrlIncludesNoVerbatimAndRepeatedKeyterms() {
        val url = ElevenLabsRealtimeTranscriber.buildSocketUrl(
            language = "en",
            noVerbatim = true,
            keyterms = listOf("Xcodegen", "Keychain"),
        )
        val http = url.replaceFirst("wss://", "https://").toHttpUrl()
        assertEquals("scribe_v2_realtime", http.queryParameter("model_id"))
        assertEquals("pcm_16000", http.queryParameter("audio_format"))
        assertEquals("true", http.queryParameter("no_verbatim"))
        assertEquals(listOf("Xcodegen", "Keychain"), http.queryParameterValues("keyterms"))
        assertFalse(http.query?.contains("Xcodegen,Keychain") == true)
        assertEquals("manual", http.queryParameter("commit_strategy"))
        assertNull(http.queryParameter("filter_background_audio"))
        assertNull(http.queryParameter("vad_threshold"))
        assertNull(http.queryParameter("include_timestamps"))
    }

    @Test
    fun buildSocketUrlPercentEncodesPlusInKeyterms() {
        val url = ElevenLabsRealtimeTranscriber.buildSocketUrl(
            language = "en",
            noVerbatim = false,
            keyterms = listOf("C++", "g++"),
        )
        assertTrue(url.contains("keyterms=C%2B%2B"))
        assertFalse(url.contains("keyterms=C++"))
        val http = url.replaceFirst("wss://", "https://").toHttpUrl()
        assertEquals(listOf("C++", "g++"), http.queryParameterValues("keyterms"))
        assertEquals("false", http.queryParameter("no_verbatim"))
    }

    @Test
    fun buildSocketUrlOmitsKeytermsWhenEmpty() {
        val url = ElevenLabsRealtimeTranscriber.buildSocketUrl("en", noVerbatim = true, keyterms = emptyList())
        val http = url.replaceFirst("wss://", "https://").toHttpUrl()
        assertTrue(http.queryParameterValues("keyterms").isEmpty())
    }

    @Test
    fun buildSocketUrlSendsVadParamsOnlyWhenCommitIsVad() {
        val options = ElevenLabsRealtimeOptions(commitStrategy = ElevenLabsCommitStrategy.VAD)
        val url = ElevenLabsRealtimeTranscriber.buildSocketUrl(
            language = "en",
            noVerbatim = true,
            keyterms = emptyList(),
            options = options,
        )
        val http = url.replaceFirst("wss://", "https://").toHttpUrl()
        assertEquals("vad", http.queryParameter("commit_strategy"))
        assertEquals("0.4", http.queryParameter("vad_threshold"))
        assertEquals("1.5", http.queryParameter("vad_silence_threshold_secs"))
        assertEquals("100", http.queryParameter("min_speech_duration_ms"))
        assertEquals("100", http.queryParameter("min_silence_duration_ms"))
    }

    @Test
    fun sendDoesNotBlockWhenSocketListenerIsSlow() {
        val server = MockWebServer()
        val received = CopyOnWriteArrayList<String>()
        val slow = AtomicBoolean(true)
        val opened = CountDownLatch(1)
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send(fixture("el-session-started.json").trim())
                    opened.countDown()
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (slow.get()) Thread.sleep(400)
                    received += text
                }
            }),
        )
        server.start()
        val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.SECONDS).build()
        val session = ElevenLabsRealtimeTranscriber(
            apiKey = "k",
            client = client,
            urlOverride = wsUrl(server, "/v1/speech-to-text/realtime"),
        )
        try {
            val start = Thread { session.start() }
            start.start()
            assertTrue(start.join(5_000).let { !start.isAlive })
            assertTrue(opened.await(2, TimeUnit.SECONDS))
            val elapsed = AtomicLong(0)
            val t0 = System.nanoTime()
            session.sendPcm16(ByteArray(320))
            elapsed.set((System.nanoTime() - t0) / 1_000_000)
            assertTrue("send blocked ${elapsed.get()}ms", elapsed.get() < 150)
            slow.set(false)
            session.cancel()
        } finally {
            server.shutdown()
            client.dispatcher.executorService.shutdown()
        }
    }

    @Test
    fun socketCloseDuringSessionFinalizesWithoutHang() {
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send(fixture("el-session-started.json").trim())
                    webSocket.send("""{"message_type":"partial_transcript","text":"hello"}""")
                    webSocket.close(1001, "going away")
                }
            }),
        )
        server.start()
        val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.SECONDS).build()
        val session = ElevenLabsRealtimeTranscriber(
            apiKey = "k",
            client = client,
            urlOverride = wsUrl(server, "/"),
        )
        try {
            val start = Thread {
                try {
                    session.start()
                } catch (_: Exception) {
                }
            }
            start.start()
            start.join(5_000)
            val t0 = System.currentTimeMillis()
            val text = session.finalize(10.0)
            val elapsed = System.currentTimeMillis() - t0
            assertTrue("finalize hung ${elapsed}ms", elapsed < 1500)
            assertTrue(text == "hello" || text.isEmpty())
        } finally {
            server.shutdown()
            client.dispatcher.executorService.shutdown()
        }
    }

    companion object {
        fun wsUrl(server: MockWebServer, path: String): String {
            val http = server.url(path).toString()
            return http.replaceFirst("http://", "ws://")
        }
    }
}
