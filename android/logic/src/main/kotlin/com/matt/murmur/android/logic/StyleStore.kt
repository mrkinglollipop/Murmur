package com.matt.murmur.android.logic

import java.io.File

/** Persists the selected iOS StyleProfile raw value in style.json. */
class StyleStore(
    private val file: File? = null,
) {
    private var selectedMut: StyleProfile = StyleProfile.CASUAL

    var selected: StyleProfile
        get() = selectedMut
        set(value) {
            if (selectedMut == value) return
            selectedMut = value
            persist()
        }

    init {
        if (file != null) {
            selectedMut = StyleJson.read(file) ?: StyleProfile.CASUAL
        }
    }

    fun reload() {
        val f = file ?: return
        selectedMut = StyleJson.read(f) ?: StyleProfile.CASUAL
    }

    fun flush() = persist()

    private fun persist() {
        val f = file ?: return
        AtomicJson.write(f, StyleJson.encode(selectedMut))
    }
}

internal object StyleJson {
    fun read(file: File): StyleProfile? {
        val text = AtomicJson.read(file) ?: return null
        return try {
            decode(parseJson(text))
        } catch (_: Exception) {
            AtomicJson.quarantine(file)
            null
        }
    }

    fun encode(profile: StyleProfile): String =
        jsonObject(listOf("selected" to jsonString(profile.rawValue)))

    fun decode(value: JsonVal): StyleProfile {
        val raw = when (value) {
            is JsonVal.Str -> value.value
            is JsonVal.Obj -> value.value["selected"]?.str()
                ?: throw IllegalArgumentException("selected")
            else -> throw IllegalArgumentException("style.json")
        }
        return StyleProfile.fromRawValue(raw)
            ?: throw IllegalArgumentException("unknown style $raw")
    }
}
