package com.matt.murmur.android.ime

import android.view.inputmethod.EditorInfo
import com.matt.murmur.android.logic.SecureDictation

fun EditorInfo?.isSecureDictationTarget(): Boolean {
    if (this == null) return false
    val hints = readAutofillHints()
    return SecureDictation.isSecureDictationTarget(
        inputType,
        hints.value,
        hintsReadable = hints.readable,
    )
}

internal class AutofillHintsRead(
    val readable: Boolean,
    val value: Array<out String>?,
)

/**
 * Runtime `autofillHints` field. Distinguish "field present, value null"
 * (not a password hint) from "cannot read" (fail-closed).
 */
internal fun EditorInfo.readAutofillHints(): AutofillHintsRead {
    return try {
        val field = EditorInfo::class.java.getField("autofillHints")
        @Suppress("UNCHECKED_CAST")
        AutofillHintsRead(readable = true, value = field.get(this) as? Array<out String>)
    } catch (_: Exception) {
        AutofillHintsRead(readable = false, value = null)
    }
}

internal fun EditorInfo.autofillHintsForLog(): String {
    val hints = readAutofillHints()
    if (!hints.readable) return "unreadable"
    return hints.value?.joinToString(",").orEmpty()
}
