package com.matt.murmur.android.logic

import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * In-repo AES-GCM file envelope over a wrapping key (Android Keystore in :app).
 * Envelope: `0x01 || 12-byte IV || ciphertext||tag`. Associated data = [FILENAME].
 *
 * Tests must use [TEST_ALIAS] with a software key — never the production alias
 * (Mac KeychainStore tests destroyed a live xAI key on 2026-07-09).
 */
class ApiKeyStore(
    private val murmurDir: File,
    val alias: String,
    private val key: SecretKey,
) {
    init {
        require(alias == PRODUCTION_ALIAS || alias == TEST_ALIAS) {
            "alias must be production or TESTS throwaway, got $alias"
        }
    }

    fun saveElevenLabsKey(value: String) {
        writePayload(encodeElevenLabs(value))
    }

    fun elevenLabsKey(): String? {
        val file = File(murmurDir, FILENAME)
        if (!file.isFile) return null
        val plain = decrypt(file.readBytes())
        return decodeElevenLabs(plain)?.takeIf { it.isNotBlank() }
    }

    fun clear() {
        val file = File(murmurDir, FILENAME)
        if (file.exists() && !file.delete()) {
            throw ApiKeyStoreException.Io("could not delete $FILENAME")
        }
    }

    private fun writePayload(plaintext: ByteArray) {
        ensurePrivateDir(murmurDir)
        val envelope = encrypt(plaintext)
        val target = File(murmurDir, FILENAME)
        val tmp = File(murmurDir, TMP_FILENAME)
        FileOutputStream(tmp).use { fos ->
            fos.write(envelope)
            fos.flush()
            fos.fd.sync()
        }
        try {
            Files.move(
                tmp.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            try {
                Files.move(
                    tmp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: Exception) {
                tmp.delete()
                throw ApiKeyStoreException.Io("could not replace $FILENAME")
            }
        }
        setOwnerOnlyFile(target)
    }

    private fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(AAD)
        val iv = cipher.iv
        require(iv.size == IV_BYTES) { "GCM IV must be $IV_BYTES bytes, got ${iv.size}" }
        val body = cipher.doFinal(plaintext)
        val out = ByteArray(1 + IV_BYTES + body.size)
        out[0] = VERSION
        System.arraycopy(iv, 0, out, 1, IV_BYTES)
        System.arraycopy(body, 0, out, 1 + IV_BYTES, body.size)
        return out
    }

    private fun decrypt(envelope: ByteArray): ByteArray {
        return decryptEnvelope(envelope, key, AAD)
    }

    companion object {
        const val PRODUCTION_ALIAS = "com.matt.murmur.android.apikeys"
        const val TEST_ALIAS = "com.matt.murmur.android.apikeys.TESTS"
        const val FILENAME = "apikeys.bin"
        const val VERSION: Byte = 0x01
        const val IV_BYTES = 12
        const val TAG_BITS = 128
        const val TAG_BYTES = TAG_BITS / 8
        const val TRANSFORMATION = "AES/GCM/NoPadding"

        private const val TMP_FILENAME = "apikeys.bin.tmp"
        internal val AAD = FILENAME.toByteArray(Charsets.UTF_8)

        internal fun decryptEnvelope(envelope: ByteArray, key: SecretKey, aad: ByteArray): ByteArray {
            if (envelope.isEmpty()) throw ApiKeyStoreException.Corrupt
            val version = envelope[0]
            if (version != VERSION) throw ApiKeyStoreException.UnknownVersion(version)
            if (envelope.size < 1 + IV_BYTES + TAG_BYTES) throw ApiKeyStoreException.Corrupt
            val iv = envelope.copyOfRange(1, 1 + IV_BYTES)
            val body = envelope.copyOfRange(1 + IV_BYTES, envelope.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
            cipher.updateAAD(aad)
            return try {
                cipher.doFinal(body)
            } catch (_: Exception) {
                throw ApiKeyStoreException.Corrupt
            }
        }

        internal fun encodeElevenLabs(value: String): ByteArray {
            return "{\"elevenLabs\":\"${jsonEscape(value)}\"}".toByteArray(Charsets.UTF_8)
        }

        internal fun decodeElevenLabs(plain: ByteArray): String? {
            val s = plain.toString(Charsets.UTF_8)
            val marker = "\"elevenLabs\":\""
            val start = s.indexOf(marker)
            if (start < 0) return null
            return jsonUnescape(s, start + marker.length)
        }

        private fun jsonEscape(s: String): String {
            val sb = StringBuilder(s.length)
            for (c in s) {
                when (c) {
                    '\\' -> sb.append("\\\\")
                    '"' -> sb.append("\\\"")
                    '\n' -> sb.append("\\n")
                    '\r' -> sb.append("\\r")
                    '\t' -> sb.append("\\t")
                    else -> if (c.code < 0x20) {
                        sb.append("\\u%04x".format(c.code))
                    } else {
                        sb.append(c)
                    }
                }
            }
            return sb.toString()
        }

        private fun jsonUnescape(s: String, from: Int): String? {
            val sb = StringBuilder()
            var i = from
            while (i < s.length) {
                val c = s[i]
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' && i + 1 < s.length -> {
                        when (val n = s[i + 1]) {
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            'u' -> {
                                if (i + 5 >= s.length) return null
                                val hex = s.substring(i + 2, i + 6)
                                sb.append(hex.toInt(16).toChar())
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

        private fun ensurePrivateDir(dir: File) {
            if (!dir.exists() && !dir.mkdirs()) {
                throw ApiKeyStoreException.Io("could not create ${dir.path}")
            }
            setOwnerOnlyDir(dir)
        }

        private fun setOwnerOnlyDir(dir: File) {
            try {
                Files.setPosixFilePermissions(
                    dir.toPath(),
                    setOf(
                        PosixFilePermission.OWNER_READ,
                        PosixFilePermission.OWNER_WRITE,
                        PosixFilePermission.OWNER_EXECUTE,
                    ),
                )
            } catch (_: UnsupportedOperationException) {
                dir.setReadable(false, false)
                dir.setWritable(false, false)
                dir.setExecutable(false, false)
                dir.setReadable(true, true)
                dir.setWritable(true, true)
                dir.setExecutable(true, true)
            }
        }

        private fun setOwnerOnlyFile(file: File) {
            try {
                Files.setPosixFilePermissions(
                    file.toPath(),
                    setOf(
                        PosixFilePermission.OWNER_READ,
                        PosixFilePermission.OWNER_WRITE,
                    ),
                )
            } catch (_: UnsupportedOperationException) {
                file.setReadable(false, false)
                file.setWritable(false, false)
                file.setExecutable(false, false)
                file.setReadable(true, true)
                file.setWritable(true, true)
            }
        }
    }
}

sealed class ApiKeyStoreException(message: String) : Exception(message) {
    class UnknownVersion(version: Byte) : ApiKeyStoreException("unknown apikeys.bin version $version")
    object Corrupt : ApiKeyStoreException("apikeys.bin corrupt")
    class Io(message: String) : ApiKeyStoreException(message)
}
