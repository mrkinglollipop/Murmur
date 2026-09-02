package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class ApiKeyStoreTest {

    @Test
    fun throwawayAliasNeverTouchesProduction() {
        assertEquals("com.matt.murmur.android.apikeys.TESTS", ApiKeyStore.TEST_ALIAS)
        assertEquals("com.matt.murmur.android.apikeys", ApiKeyStore.PRODUCTION_ALIAS)
        assertNotEquals(ApiKeyStore.PRODUCTION_ALIAS, ApiKeyStore.TEST_ALIAS)
        assertTrue(ApiKeyStore.TEST_ALIAS.endsWith(".TESTS"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun unknownAliasRejected() {
        ApiKeyStore(tmpDir(), "com.matt.murmur.android.apikeys.OTHER", softwareKey())
    }

    @Test
    fun envelopeIsVersionIvCiphertextTag() {
        val dir = tmpDir()
        val store = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey())
        store.saveElevenLabsKey("sk_test_key_value")
        val raw = File(dir, ApiKeyStore.FILENAME).readBytes()
        assertEquals(ApiKeyStore.VERSION, raw[0])
        assertTrue(raw.size >= 1 + ApiKeyStore.IV_BYTES + ApiKeyStore.TAG_BYTES)
        assertEquals(0x01.toByte(), raw[0])
        val body = raw.copyOfRange(1 + ApiKeyStore.IV_BYTES, raw.size)
        assertTrue(body.size >= ApiKeyStore.TAG_BYTES)
        assertNull(File(dir, "apikeys.bin.tmp").takeIf { it.exists() })
    }

    @Test
    fun roundTripElevenLabsKey() {
        val dir = tmpDir()
        val key = softwareKey()
        val store = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, key)
        store.saveElevenLabsKey("xi-hello\"world\\")
        assertEquals("xi-hello\"world\\", store.elevenLabsKey())
        val again = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, key)
        assertEquals("xi-hello\"world\\", again.elevenLabsKey())
    }

    @Test
    fun missingFileReturnsNull() {
        val store = ApiKeyStore(tmpDir(), ApiKeyStore.TEST_ALIAS, softwareKey())
        assertNull(store.elevenLabsKey())
    }

    @Test
    fun unknownVersionRefusesDecrypt() {
        val dir = tmpDir()
        val store = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey())
        store.saveElevenLabsKey("secret")
        val file = File(dir, ApiKeyStore.FILENAME)
        val raw = file.readBytes()
        raw[0] = 0x02
        file.writeBytes(raw)
        try {
            store.elevenLabsKey()
            fail("expected UnknownVersion")
        } catch (e: ApiKeyStoreException.UnknownVersion) {
            // refuse to guess
        }
    }

    @Test
    fun tamperedBodyRefusesDecrypt() {
        val dir = tmpDir()
        val store = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey())
        store.saveElevenLabsKey("secret")
        val file = File(dir, ApiKeyStore.FILENAME)
        val raw = file.readBytes()
        raw[raw.lastIndex] = (raw[raw.lastIndex].toInt() xor 0xFF).toByte()
        file.writeBytes(raw)
        try {
            store.elevenLabsKey()
            fail("expected Corrupt")
        } catch (e: ApiKeyStoreException.Corrupt) {
            // GCM tag mismatch
        }
    }

    @Test
    fun atomicReplaceOverwrites() {
        val dir = tmpDir()
        val store = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey())
        store.saveElevenLabsKey("first")
        store.saveElevenLabsKey("second")
        assertEquals("second", store.elevenLabsKey())
        assertFalse(File(dir, "apikeys.bin.tmp").exists())
    }

    @Test
    fun associatedDataIsFilename() {
        assertEquals("apikeys.bin", ApiKeyStore.FILENAME)
        val encoded = ApiKeyStore.encodeElevenLabs("k")
        assertEquals("k", ApiKeyStore.decodeElevenLabs(encoded))
    }

    @Test
    fun wrongAssociatedDataIsCorrupt() {
        val dir = tmpDir()
        val key = softwareKey()
        ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, key).saveElevenLabsKey("secret")
        val envelope = File(dir, ApiKeyStore.FILENAME).readBytes()
        try {
            ApiKeyStore.decryptEnvelope(envelope, key, "not-apikeys.bin".toByteArray())
            fail("expected Corrupt")
        } catch (_: ApiKeyStoreException.Corrupt) {
        }
        val plain = ApiKeyStore.decryptEnvelope(envelope, key, ApiKeyStore.AAD)
        assertEquals("secret", ApiKeyStore.decodeElevenLabs(plain))
    }

    @Test
    fun wrongWrappingKeyIsCorrupt() {
        val dir = tmpDir()
        ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey()).saveElevenLabsKey("secret")
        try {
            ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey()).elevenLabsKey()
            fail("expected Corrupt")
        } catch (_: ApiKeyStoreException.Corrupt) {
        }
    }

    @Test
    fun dirIsOwnerOnlyWhenPosix() {
        val dir = tmpDir()
        val store = ApiKeyStore(dir, ApiKeyStore.TEST_ALIAS, softwareKey())
        store.saveElevenLabsKey("k")
        try {
            val perms = Files.getPosixFilePermissions(dir.toPath())
            assertEquals(
                setOf(
                    PosixFilePermission.OWNER_READ,
                    PosixFilePermission.OWNER_WRITE,
                    PosixFilePermission.OWNER_EXECUTE,
                ),
                perms,
            )
        } catch (_: UnsupportedOperationException) {
            // FAT/etc.
        }
    }

    private fun tmpDir(): File {
        val dir = File(System.getProperty("java.io.tmpdir"), "murmur-keys-${System.nanoTime()}")
        assertTrue(dir.mkdirs())
        return dir
    }

    private fun softwareKey(): SecretKey {
        val gen = KeyGenerator.getInstance("AES")
        gen.init(256)
        return gen.generateKey()
    }
}
