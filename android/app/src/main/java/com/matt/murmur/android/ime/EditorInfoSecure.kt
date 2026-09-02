package com.matt.murmur.android.ime

import android.view.inputmethod.EditorInfo
import com.matt.murmur.android.logic.SecureDictation

fun EditorInfo?.isSecureDictationTarget(): Boolean {
    if (this == null) return false
    return SecureDictation.isSecureDictationTarget(inputType, autofillHintsOrNull())
}

/** Runtime field; some compileSdk jars omit the public `autofillHints` member. */
fun EditorInfo.autofillHintsOrNull(): Array<out String>? {
    return try {
        @Suppress("UNCHECKED_CAST")
        EditorInfo::class.java.getField("autofillHints").get(this) as? Array<out String>
    } catch (_: Exception) {
        extras?.getStringArray("android.view.autofill.extra.AUTOFILL_HINTS")
    }
}
