package com.matt.murmur.android.cloud

import com.matt.murmur.android.logic.WavWriter
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

class ElevenLabsBatchTest {

    @Test
    fun formFieldsMatchSwiftContract() {
        val fields = ElevenLabsBatch.formFields(
            language = "en",
            noVerbatim = true,
            keyterms = listOf("Xcodegen", "Keychain"),
        )
        assertEquals(
            listOf(
                "model_id" to "scribe_v2",
                "language_code" to "en",
                "no_verbatim" to "true",
                "keyterms" to "Xcodegen",
                "keyterms" to "Keychain",
            ),
            fields,
        )
        assertEquals(2, fields.count { it.first == "keyterms" })
        assertFalse(fields.any { it.second.contains(",") && it.first == "keyterms" })
    }

    @Test
    fun formFieldsNoVerbatimFalseAndEmptyKeyterms() {
        val fields = ElevenLabsBatch.formFields("de", noVerbatim = false, keyterms = emptyList())
        assertEquals("false", fields.first { it.first == "no_verbatim" }.second)
        assertEquals("de", fields.first { it.first == "language_code" }.second)
        assertTrue(fields.none { it.first == "keyterms" })
    }

    @Test
    fun transcribePostsMultipartAndXiApiKey() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"text":"hello world"}"""))
        server.start()
        try {
            val wav = tempWav()
            val text = ElevenLabsBatch.transcribeAt(
                audio = wav,
                apiKey = "xi-test-key",
                language = "en",
                noVerbatim = true,
                keyterms = listOf("Xcodegen", "C++"),
                client = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS).build(),
                endpoint = server.url("/v1/speech-to-text").toString(),
            )
            assertEquals("hello world", text)
            val recorded = server.takeRequest()
            assertEquals("POST", recorded.method)
            assertEquals("xi-test-key", recorded.getHeader("xi-api-key"))
            val contentType = recorded.getHeader("Content-Type") ?: ""
            assertTrue(contentType.startsWith("multipart/form-data"))
            val body = recorded.body.readUtf8()
            assertTrue(body.contains("name=\"model_id\""))
            assertTrue(body.contains("scribe_v2"))
            assertTrue(body.contains("name=\"language_code\""))
            assertTrue(body.contains("name=\"no_verbatim\""))
            assertTrue(body.contains("name=\"keyterms\""))
            assertTrue(body.contains("Xcodegen"))
            assertTrue(body.contains("C++"))
            assertFalse(body.contains("Xcodegen,C++"))
            assertTrue(body.contains("filename=\"${WavWriter.FILE_NAME}\""))
            assertTrue(body.contains(WavWriter.MIME_TYPE))
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
            ElevenLabsBatch.transcribeAt(
                audio = tempWav(),
                apiKey = "k",
                language = "en",
                noVerbatim = true,
                keyterms = emptyList(),
                client = OkHttpClient(),
                endpoint = server.url("/").toString(),
            )
            fail("expected Http")
        } catch (e: ElevenLabsException.Http) {
            assertEquals(401, e.code)
            assertFalse(e.message!!.contains("abcdefghijklmnopqrstuvwxyz"))
            assertTrue(e.message!!.contains("…"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun emptyTranscriptThrows() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"text":"   "}"""))
        server.start()
        try {
            ElevenLabsBatch.transcribeAt(
                audio = tempWav(),
                apiKey = "k",
                language = "en",
                noVerbatim = true,
                keyterms = emptyList(),
                client = OkHttpClient(),
                endpoint = server.url("/").toString(),
            )
            fail("expected NoTranscript")
        } catch (e: ElevenLabsException.NoTranscript) {
            // ok
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun redactedBodyFragmentStripsTwentyPlusCharTokens() {
        val body = "err key=abcdefghijklmnopqrstuvwxyz leftover"
        assertEquals("err key=… leftover", redactedBodyFragment(body))
    }

    private fun tempWav(): File {
        val pcm = ByteArray(320) { 1 }
        val file = File.createTempFile("murmur-el-", ".wav")
        WavWriter.writePcm16(pcm, file)
        file.deleteOnExit()
        return file
    }
}
