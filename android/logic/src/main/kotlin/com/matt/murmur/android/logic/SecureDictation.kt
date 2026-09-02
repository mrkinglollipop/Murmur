package com.matt.murmur.android.logic

/**
 * Password [inputType] variations and autofill password hints.
 * Constants match `android.text.InputType` / `HintConstants` so this stays JVM-pure.
 */
object SecureDictation {
    const val TYPE_MASK_CLASS = 0x0000000f
    const val TYPE_MASK_VARIATION = 0x00000ff0
    const val TYPE_CLASS_TEXT = 0x00000001
    const val TYPE_CLASS_NUMBER = 0x00000002
    const val TYPE_TEXT_VARIATION_PASSWORD = 0x00000080
    const val TYPE_TEXT_VARIATION_VISIBLE_PASSWORD = 0x00000090
    const val TYPE_TEXT_VARIATION_WEB_PASSWORD = 0x000000e0
    const val TYPE_NUMBER_VARIATION_PASSWORD = 0x00000010
    const val AUTOFILL_HINT_PASSWORD = "password"
    const val AUTOFILL_HINT_NEW_PASSWORD = "newPassword"

    fun isSecureDictationTarget(
        inputType: Int,
        autofillHints: Array<out String>? = null,
        hintsReadable: Boolean = true,
    ): Boolean {
        val cls = inputType and TYPE_MASK_CLASS
        val varn = inputType and TYPE_MASK_VARIATION
        val passwordType = when (cls) {
            TYPE_CLASS_TEXT ->
                varn == TYPE_TEXT_VARIATION_PASSWORD ||
                    varn == TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                    varn == TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            TYPE_CLASS_NUMBER -> varn == TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
        if (passwordType) return true
        if (!hintsReadable) return true
        return autofillHints?.any {
            it.equals(AUTOFILL_HINT_PASSWORD, ignoreCase = true) ||
                it.equals(AUTOFILL_HINT_NEW_PASSWORD, ignoreCase = true)
        } == true
    }
}

fun isSecureDictationTarget(
    inputType: Int,
    autofillHints: Array<out String>? = null,
    hintsReadable: Boolean = true,
): Boolean = SecureDictation.isSecureDictationTarget(inputType, autofillHints, hintsReadable)
