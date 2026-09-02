package com.matt.murmur.android.logic

import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * iOS history subset: id / date / text / failed, cap [MAX_ENTRIES].
 * Mac history.json also has engine, injected, audioPath and caps at 1000 —
 * a superset that needs a mapper. Do not treat the files as interchangeable.
 */
data class HistoryEntry(
    val id: String = UUID.randomUUID().toString(),
    val date: Instant = Instant.now(),
    val text: String,
    val failed: Boolean = false,
)

class HistoryStore(
    initial: List<HistoryEntry> = emptyList(),
    private val file: File? = null,
) {
    private val entriesMut: MutableList<HistoryEntry> = mutableListOf()

    val entries: List<HistoryEntry>
        get() = entriesMut.toList()

    val wordCount: Int
        get() = entriesMut.filter { !it.failed }.sumOf { wordsIn(it.text) }

    init {
        if (file != null) {
            entriesMut.addAll(HistoryJson.read(file))
        } else {
            entriesMut.addAll(initial)
        }
    }

    fun reload() {
        val f = file ?: return
        entriesMut.clear()
        entriesMut.addAll(HistoryJson.read(f))
    }

    fun append(text: String, failed: Boolean) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        entriesMut.add(0, HistoryEntry(text = trimmed, failed = failed))
        if (entriesMut.size > MAX_ENTRIES) {
            while (entriesMut.size > MAX_ENTRIES) {
                entriesMut.removeAt(entriesMut.lastIndex)
            }
        }
        persist()
    }

    fun flush() = persist()

    private fun persist() {
        val f = file ?: return
        AtomicJson.write(f, HistoryJson.encode(entriesMut))
    }

    companion object {
        const val MAX_ENTRIES = 200

        fun wordsIn(text: String): Int =
            text.split(Regex("\\s+")).count { it.isNotEmpty() }
    }
}

internal object HistoryJson {
    fun read(file: File): List<HistoryEntry> {
        val text = AtomicJson.read(file) ?: return emptyList()
        return try {
            decode(parseJson(text))
        } catch (_: Exception) {
            AtomicJson.quarantine(file)
            emptyList()
        }
    }

    fun encode(entries: List<HistoryEntry>): String {
        return jsonArray(
            entries.map { entry ->
                jsonObject(
                    listOf(
                        "id" to jsonString(entry.id),
                        "date" to jsonString(formatIso(entry.date)),
                        "text" to jsonString(entry.text),
                        "failed" to entry.failed.toString(),
                    ),
                )
            },
        )
    }

    fun decode(value: JsonVal): List<HistoryEntry> {
        val arr = value.arr() ?: throw IllegalArgumentException("history.json must be an array")
        return arr.map { item ->
            val obj = item.obj() ?: throw IllegalArgumentException("history entry")
            HistoryEntry(
                id = obj["id"]?.str() ?: throw IllegalArgumentException("id"),
                date = parseIso(obj["date"]?.str() ?: throw IllegalArgumentException("date")),
                text = obj["text"]?.str() ?: throw IllegalArgumentException("text"),
                failed = obj["failed"]?.bool() ?: false,
            )
        }
    }

    fun formatIso(instant: Instant): String =
        DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))

    fun parseIso(raw: String): Instant {
        return try {
            Instant.parse(raw)
        } catch (_: DateTimeParseException) {
            Instant.parse(raw.replace(" ", "T"))
        }
    }
}
