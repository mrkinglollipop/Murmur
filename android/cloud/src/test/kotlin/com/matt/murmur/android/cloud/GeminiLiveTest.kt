package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.DictionaryEntry
import com.matt.murmur.android.logic.WavWriter
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

class GeminiLiveTest {

    @Test
    fun setupJsonManualOmitsVadSensitivityFields() {
        val json = GeminiLiveOptions.makeSetupMessageJson(
            language = "en",
            smartMode = true,
            vocabulary = listOf("Murmur"),
            options = GeminiLiveOptions.DEFAULTS,
        )
        val root = JsonValue.obj(json)!!
        val setup = root.obj("setup")!!
        val realtime = setup.obj("realtimeInputConfig")!!
        val aad = realtime.obj("automaticActivityDetection")!!
        assertEquals(true, aad.bool("disabled"))
        assertNull(aad.get("startOfSpeechSensitivity"))
        assertNull(aad.get("prefixPaddingMs"))
        val transcription = setup.obj("inputAudioTranscription")!!
        assertEquals("SMART", transcription.string("mode"))
        val langs = transcription.arr("languageCodes")!!.map { (it as JsonValue.Str).value }
        assertEquals(listOf("en-US"), langs)
        val vocab = transcription.arr("customVocabulary")!!.map { (it as JsonValue.Str).value }
        assertEquals(listOf("Murmur"), vocab)
        assertFalse(json.contains("SECRET_KEY"))
    }

    @Test
    fun setupJsonAutomaticIncludesVadFields() {
        val options = GeminiLiveOptions.DEFAULTS.copy(vadMode = GeminiVadMode.AUTOMATIC)
        val json = GeminiLiveOptions.makeSetupMessageJson(
            language = "en",
            smartMode = false,
            vocabulary = emptyList(),
            options = options,
        )
        val setup = JsonValue.obj(json)!!.obj("setup")!!
        assertEquals("VERBATIM", setup.obj("inputAudioTranscription")!!.string("mode"))
        val aad = setup.obj("realtimeInputConfig")!!.obj("automaticActivityDetection")!!
        assertEquals(false, aad.bool("disabled"))
        assertEquals("START_SENSITIVITY_HIGH", aad.string("startOfSpeechSensitivity"))
        assertEquals("END_SENSITIVITY_HIGH", aad.string("endOfSpeechSensitivity"))
        assertEquals("20", (aad.get("prefixPaddingMs") as JsonValue.Num).raw)
        assertEquals("100", (aad.get("silenceDurationMs") as JsonValue.Num).raw)
        assertNull(setup.obj("inputAudioTranscription")!!.arr("customVocabulary"))
    }

    @Test
    fun manualPttFrames() {
        val start = GeminiLiveOptions.makeActivityStartFrameJson()
        assertTrue(start.contains("activityStart"))
        val end = GeminiLiveOptions.makeActivityEndFrameJson()
        assertTrue(end.contains("activityEnd"))
        val audio = GeminiLiveOptions.makeAudioFrameJson(byteArrayOf(0, 1))
        val audioJson = JsonValue.obj(audio)!!
        val node = audioJson.obj("realtimeInput")!!.obj("audio")!!
        assertEquals("audio/pcm;rate=16000", node.string("mimeType"))
    }

    @Test
    fun hybridAudioStreamEndFrame() {
        val frame = GeminiLiveOptions.makeAudioStreamEndFrameJson()
        assertTrue(frame.contains("audioStreamEnd"))
    }

    @Test
    fun selectVocabularyCapsAt100AndPrefersFixCount() {
        val entries = (0 until 120).map { index ->
            DictionaryEntry(term = "term$index", fixCount = index)
        }
        val selected = GeminiLiveTranscriber.selectVocabulary(entries)
        assertEquals(100, selected.size)
        assertEquals("term119", selected.first())
    }

    @Test
    fun joinedTranscriptDeduplicatesContainedPartial() {
        assertEquals(
            "hello world",
            GeminiLiveTranscriber.joinedTranscript(listOf("hello world"), "world"),
        )
    }

    @Test
    fun buildSocketUrlHostPathAndKeyQuery() {
        val url = GeminiLiveTranscriber.buildSocketUrl("test-key-value")
        val http = url.replaceFirst("wss://", "https://").toHttpUrl()
        assertEquals("generativelanguage.googleapis.com", http.host)
        assertTrue(http.encodedPath.contains("BidiGenerateContent"))
        assertEquals("test-key-value", http.queryParameter("key"))
    }

    @Test
    fun sessionCapHelper() {
        assertFalse(GeminiLiveTranscriber.sessionCapExceeded(580.0))
        assertTrue(GeminiLiveTranscriber.sessionCapExceeded(581.0))
    }

    @Test
    fun batchDecodeOutputText() {
        assertEquals("hello", GeminiBatchDecode.decodeTranscript(fixture("gemini-batch-output-text.json")))
    }

    @Test
    fun batchDecodeStepsContentText() {
        assertEquals(
            "hello from steps",
            GeminiBatchDecode.decodeTranscript(fixture("gemini-batch-steps.json")),
        )
    }

    @Test
    fun serverErrorMakesFinalizeShortCircuit() {
        val transcriber = GeminiLiveTranscriber(apiKey = "test-key-value")
        transcriber.handleServerEvent(fixture("gemini-error.json"))
        val started = System.currentTimeMillis()
        val text = transcriber.finalize(10.0)
        assertEquals("", text)
        assertTrue(System.currentTimeMillis() - started < 1500)
    }

    @Test
    fun batchRequestBodyRespectsFillerAndVocabulary() {
        val verbatim = GeminiLiveOptions.makeBatchRequestBody(
            wavBase64 = "AA==",
            mimeType = "audio/wav",
            smartMode = false,
            vocabulary = listOf("Murmur"),
        )
        assertEquals("gemini-3.5-transcribe", verbatim["model"])
        @Suppress("UNCHECKED_CAST")
        val config = ((verbatim["generation_config"] as Map<*, *>)["transcription_config"] as Map<*, *>)
        @Suppress("UNCHECKED_CAST")
        assertEquals("verbatim", (config["mode"] as Map<*, *>)["type"])
        assertEquals(listOf("Murmur"), config["custom_vocabulary"])

        val smartEmpty = GeminiLiveOptions.makeBatchRequestBody(
            wavBase64 = "AA==",
            mimeType = "audio/wav",
            smartMode = true,
            vocabulary = emptyList(),
        )
        @Suppress("UNCHECKED_CAST")
        val smartConfig = ((smartEmpty["generation_config"] as Map<*, *>)["transcription_config"] as Map<*, *>)
        @Suppress("UNCHECKED_CAST")
        assertEquals("smart", (smartConfig["mode"] as Map<*, *>)["type"])
        assertFalse(smartConfig.containsKey("custom_vocabulary"))
    }

    @Test
    fun bcp47LanguageCodesMapIso6391() {
        assertEquals(listOf("en-US"), GeminiLiveOptions.bcp47LanguageCodes("en"))
        assertEquals(listOf("en-GB"), GeminiLiveOptions.bcp47LanguageCodes("en-GB"))
        assertEquals(emptyList<String>(), GeminiLiveOptions.bcp47LanguageCodes(""))
        assertEquals(emptyList<String>(), GeminiLiveOptions.bcp47LanguageCodes("xx"))
    }

    @Test
    fun binaryWebSocketPayloadDecodesAsUtf8Json() {
        val binary = "{\"setupComplete\":{}}\n".toByteArray()
        assertEquals(
            "{\"setupComplete\":{}}\n",
            GeminiLiveTranscriber.utf8JsonText(binary),
        )
    }

    @Test
    fun capReachedFinalizeTextPreservesAccumulatedTranscript() {
        assertEquals("hello world", GeminiLiveTranscriber.capReachedFinalizeText("hello world"))
        assertEquals("", GeminiLiveTranscriber.capReachedFinalizeText(""))
    }

    @Test
    fun goldenFixturesParseTopLevelServerFields() {
        val setup = JsonValue.obj(fixture("gemini-setup-complete.json"))!!
        assertTrue(setup.has("setupComplete"))
        val snake = JsonValue.obj(fixture("gemini-setup-complete-snake.json"))!!
        assertTrue(snake.has("setup_complete"))
        val session = GeminiLiveTranscriber(apiKey = "k")
        session.handleServerEvent(fixture("gemini-setup-complete.json"))
        session.handleServerEvent(fixture("gemini-interim.json"))
        assertEquals("hello there", session.joinedTranscriptSnapshot())
        session.handleServerEvent(fixture("gemini-input-transcription.json"))
        assertEquals("hello there friend", session.joinedTranscriptSnapshot())
    }

    @Test
    fun transcribePostsJsonAndGoogApiKey() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody(fixture("gemini-batch-output-text.json")))
        server.start()
        try {
            val wav = tempWav()
            val text = GeminiBatch.transcribeAt(
                audio = wav,
                apiKey = "goog-test-key",
                language = "en",
                smartMode = true,
                vocabulary = listOf("Murmur"),
                client = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS).build(),
                endpoint = server.url("/v1beta/interactions").toString(),
            )
            assertEquals("hello", text)
            val recorded = server.takeRequest()
            assertEquals("POST", recorded.method)
            assertEquals("goog-test-key", recorded.getHeader("x-goog-api-key"))
            val body = recorded.body.readUtf8()
            assertTrue(body.contains("gemini-3.5-transcribe"))
            assertTrue(body.contains("Murmur"))
            assertTrue(body.contains("audio/wav"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun httpErrorRedactsLongTokens() {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setResponseCode(401)
                .setBody("unauthorized token=abcdefghijklmnopqrstuvwxyz"),
        )
        server.start()
        try {
            GeminiBatch.transcribeAt(
                audio = tempWav(),
                apiKey = "k",
                language = "en",
                smartMode = true,
                vocabulary = emptyList(),
                client = OkHttpClient(),
                endpoint = server.url("/").toString(),
            )
            fail("expected Http")
        } catch (e: GeminiException.Http) {
            assertEquals(401, e.code)
            assertFalse(e.message!!.contains("abcdefghijklmnopqrstuvwxyz"))
            assertTrue(e.message!!.contains("…"))
        } finally {
            server.shutdown()
        }
    }

    private fun tempWav(): File {
        val pcm = ByteArray(320) { 1 }
        val file = File.createTempFile("murmur-gm-", ".wav")
        WavWriter.writePcm16(pcm, file)
        file.deleteOnExit()
        return file
    }
}
