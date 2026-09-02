package com.matt.murmur.android.logic

import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import java.util.UUID

/** Compact JSON tree for iOS-shaped store files. Not a general library. */
internal sealed class JsonVal {
    object Null : JsonVal()
    data class Bool(val value: Boolean) : JsonVal()
    data class Num(val value: Double) : JsonVal()
    data class Str(val value: String) : JsonVal()
    data class Arr(val value: List<JsonVal>) : JsonVal()
    data class Obj(val value: Map<String, JsonVal>) : JsonVal()

    fun obj(): Map<String, JsonVal>? = (this as? Obj)?.value
    fun arr(): List<JsonVal>? = (this as? Arr)?.value
    fun str(): String? = (this as? Str)?.value
    fun bool(): Boolean? = (this as? Bool)?.value
    fun int(): Int? = (this as? Num)?.value?.toInt()
}

internal fun parseJson(text: String): JsonVal = JsonParser(text).parseDocument()

internal fun jsonString(value: String): String {
    val sb = StringBuilder(value.length + 2)
    sb.append('"')
    for (c in value) {
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
    sb.append('"')
    return sb.toString()
}

internal fun jsonObject(fields: List<Pair<String, String>>): String {
    return fields.joinToString(prefix = "{", postfix = "}") { (k, encoded) ->
        "${jsonString(k)}:$encoded"
    }
}

internal fun jsonArray(encodedItems: List<String>): String =
    encodedItems.joinToString(prefix = "[", postfix = "]")

internal object AtomicJson {
    fun read(file: File): String? {
        if (!file.isFile) return null
        return runCatching { file.readText(Charsets.UTF_8) }.getOrNull()
    }

    fun write(file: File, text: String) {
        val parent = file.parentFile ?: throw IllegalArgumentException("json file needs a parent")
        ensurePrivateDir(parent)
        val tmp = File(parent, "${file.name}.tmp.${UUID.randomUUID()}")
        try {
            FileOutputStream(tmp).use { fos ->
                fos.write(text.toByteArray(Charsets.UTF_8))
                fos.flush()
                fos.fd.sync()
            }
            try {
                Files.move(
                    tmp.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                try {
                    Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
                } catch (_: Exception) {
                    throw IllegalStateException("could not replace ${file.name}")
                }
            }
            setOwnerOnlyFile(file)
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    fun quarantine(file: File) {
        if (!file.isFile) return
        val bak = File(file.path + ".corrupt.${System.currentTimeMillis() / 1000}")
        runCatching {
            if (bak.exists()) bak.delete()
            file.renameTo(bak)
        }
    }

    fun ensurePrivateDir(dir: File) {
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("could not create ${dir.path}")
        }
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
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
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

private class JsonParser(private val s: String) {
    private var i = 0

    fun parseDocument(): JsonVal {
        val value = parseValue()
        skipWs()
        if (i != s.length) throw IllegalArgumentException("trailing json")
        return value
    }

    private fun parseValue(): JsonVal {
        skipWs()
        val c = peek() ?: throw IllegalArgumentException("empty json")
        return when (c) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> JsonVal.Str(parseString())
            't' -> {
                consumeLiteral("true")
                JsonVal.Bool(true)
            }
            'f' -> {
                consumeLiteral("false")
                JsonVal.Bool(false)
            }
            'n' -> {
                consumeLiteral("null")
                JsonVal.Null
            }
            '-', in '0'..'9' -> JsonVal.Num(parseNumber())
            else -> throw IllegalArgumentException("unexpected '$c'")
        }
    }

    private fun parseObject(): JsonVal {
        consume('{')
        val fields = linkedMapOf<String, JsonVal>()
        skipWs()
        if (peek() == '}') {
            i++
            return JsonVal.Obj(fields)
        }
        while (true) {
            skipWs()
            if (peek() != '"') throw IllegalArgumentException("expected key")
            val key = parseString()
            skipWs()
            if (!consume(':')) throw IllegalArgumentException("expected ':'")
            fields[key] = parseValue()
            skipWs()
            when (peek()) {
                ',' -> i++
                '}' -> {
                    i++
                    return JsonVal.Obj(fields)
                }
                else -> throw IllegalArgumentException("expected ',' or '}'")
            }
        }
    }

    private fun parseArray(): JsonVal {
        consume('[')
        val items = mutableListOf<JsonVal>()
        skipWs()
        if (peek() == ']') {
            i++
            return JsonVal.Arr(items)
        }
        while (true) {
            items += parseValue()
            skipWs()
            when (peek()) {
                ',' -> i++
                ']' -> {
                    i++
                    return JsonVal.Arr(items)
                }
                else -> throw IllegalArgumentException("expected ',' or ']'")
            }
        }
    }

    private fun parseString(): String {
        if (!consume('"')) throw IllegalArgumentException("expected string")
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
                            if (i + 5 >= s.length) throw IllegalArgumentException("bad unicode")
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
        throw IllegalArgumentException("unterminated string")
    }

    private fun parseNumber(): Double {
        val start = i
        if (peek() == '-') i++
        if (i >= s.length) throw IllegalArgumentException("bad number")
        while (i < s.length) {
            val c = s[i]
            if (c.isDigit() || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                i++
            } else {
                break
            }
        }
        return s.substring(start, i).toDouble()
    }

    private fun consumeLiteral(lit: String) {
        if (!s.startsWith(lit, i)) throw IllegalArgumentException("expected $lit")
        i += lit.length
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
