package com.matt.murmur.android.cloud

/**
 * Minimal JSON codec. Top-level field reads skip nested objects so
 * `words[].text` cannot win over `"text"`.
 */
sealed class JsonValue {
    object Null : JsonValue()
    data class Bool(val value: Boolean) : JsonValue()
    data class Num(val raw: String) : JsonValue()
    data class Str(val value: String) : JsonValue()
    data class Arr(val items: List<JsonValue>) : JsonValue()
    data class Obj(val fields: Map<String, JsonValue>) : JsonValue() {
        fun string(key: String): String? = (fields[key] as? Str)?.value
        fun obj(key: String): Obj? = fields[key] as? Obj
        fun arr(key: String): List<JsonValue>? = (fields[key] as? Arr)?.items
        fun bool(key: String): Boolean? = (fields[key] as? Bool)?.value
        fun has(key: String): Boolean = fields.containsKey(key)
        fun get(key: String): JsonValue? = fields[key]
        fun objAny(vararg keys: String): Obj? {
            for (key in keys) {
                val found = obj(key)
                if (found != null) return found
            }
            return null
        }
    }

    companion object {
        fun parse(text: String): JsonValue? {
            return try {
                val p = Parser(text)
                val value = p.parseValue() ?: return null
                p.skipWs()
                if (p.remaining()) return null
                value
            } catch (_: Exception) {
                null
            }
        }

        fun obj(text: String): Obj? = parse(text) as? Obj

        fun encode(value: Any?): String {
            val sb = StringBuilder()
            write(sb, value)
            return sb.toString()
        }

        private fun write(sb: StringBuilder, value: Any?) {
            when (value) {
                null -> sb.append("null")
                is Boolean -> sb.append(value)
                is Int, is Long, is Short, is Byte -> sb.append(value)
                is Double, is Float -> sb.append(value)
                is String -> writeString(sb, value)
                is Map<*, *> -> {
                    sb.append('{')
                    var first = true
                    for ((k, v) in value) {
                        if (!first) sb.append(',')
                        first = false
                        writeString(sb, k.toString())
                        sb.append(':')
                        write(sb, v)
                    }
                    sb.append('}')
                }
                is Iterable<*> -> {
                    sb.append('[')
                    var first = true
                    for (item in value) {
                        if (!first) sb.append(',')
                        first = false
                        write(sb, item)
                    }
                    sb.append(']')
                }
                is Array<*> -> write(sb, value.asList())
                else -> writeString(sb, value.toString())
            }
        }

        private fun writeString(sb: StringBuilder, s: String) {
            sb.append('"')
            for (c in s) {
                when (c) {
                    '"' -> sb.append("\\\"")
                    '\\' -> sb.append("\\\\")
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
        }
    }

    private class Parser(private val s: String) {
        private var i = 0

        fun remaining(): Boolean = i < s.length

        fun skipWs() {
            while (i < s.length && s[i].isWhitespace()) i++
        }

        fun parseValue(): JsonValue? {
            skipWs()
            val c = peek() ?: return null
            return when (c) {
                '"' -> parseString()?.let { Str(it) }
                '{' -> parseObject()
                '[' -> parseArray()
                't' -> if (consumeLiteral("true")) Bool(true) else null
                'f' -> if (consumeLiteral("false")) Bool(false) else null
                'n' -> if (consumeLiteral("null")) Null else null
                '-', in '0'..'9' -> parseNumber()
                else -> null
            }
        }

        private fun parseObject(): Obj? {
            if (!consume('{')) return null
            val fields = linkedMapOf<String, JsonValue>()
            while (true) {
                skipWs()
                if (peek() == '}') {
                    i++
                    return Obj(fields)
                }
                if (fields.isNotEmpty()) {
                    if (!consume(',')) return null
                    skipWs()
                    if (peek() == '}') {
                        i++
                        return Obj(fields)
                    }
                }
                skipWs()
                val key = parseString() ?: return null
                skipWs()
                if (!consume(':')) return null
                val value = parseValue() ?: return null
                fields[key] = value
            }
        }

        private fun parseArray(): Arr? {
            if (!consume('[')) return null
            val items = mutableListOf<JsonValue>()
            while (true) {
                skipWs()
                if (peek() == ']') {
                    i++
                    return Arr(items)
                }
                if (items.isNotEmpty()) {
                    if (!consume(',')) return null
                    skipWs()
                    if (peek() == ']') {
                        i++
                        return Arr(items)
                    }
                }
                val value = parseValue() ?: return null
                items += value
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

        private fun parseNumber(): Num? {
            val start = i
            if (peek() == '-') i++
            if (i >= s.length) return null
            while (i < s.length) {
                val c = s[i]
                if (c.isDigit() || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                    i++
                } else {
                    break
                }
            }
            if (i == start) return null
            return Num(s.substring(start, i))
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
    }
}

fun redactedBodyFragment(body: String, max: Int = 300): String {
    val redacted = Regex("[A-Za-z0-9_\\-]{20,}").replace(body, "…")
    return if (redacted.length <= max) redacted else redacted.substring(0, max)
}

internal fun parseTranscriptText(json: String): String? {
    return JsonValue.obj(json)?.string("text")
}
