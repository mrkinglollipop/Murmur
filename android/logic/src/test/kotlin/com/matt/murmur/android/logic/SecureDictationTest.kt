package com.matt.murmur.android.logic

import com.matt.murmur.android.logic.SecureDictation.TYPE_CLASS_NUMBER
import com.matt.murmur.android.logic.SecureDictation.TYPE_CLASS_TEXT
import com.matt.murmur.android.logic.SecureDictation.TYPE_NUMBER_VARIATION_PASSWORD
import com.matt.murmur.android.logic.SecureDictation.TYPE_TEXT_VARIATION_PASSWORD
import com.matt.murmur.android.logic.SecureDictation.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
import com.matt.murmur.android.logic.SecureDictation.TYPE_TEXT_VARIATION_WEB_PASSWORD
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureDictationTest {

    @Test
    fun textPasswordIsSecure() {
        assertTrue(isSecureDictationTarget(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD))
    }

    @Test
    fun webPasswordIsSecure() {
        assertTrue(isSecureDictationTarget(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_PASSWORD))
    }

    @Test
    fun visiblePasswordIsSecure() {
        assertTrue(isSecureDictationTarget(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD))
    }

    @Test
    fun numberPasswordIsSecure() {
        assertTrue(isSecureDictationTarget(TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD))
    }

    @Test
    fun plainTextIsNotSecure() {
        assertFalse(isSecureDictationTarget(TYPE_CLASS_TEXT))
    }

    @Test
    fun numberIsNotSecure() {
        assertFalse(isSecureDictationTarget(TYPE_CLASS_NUMBER))
    }

    @Test
    fun emailVariationIsNotSecure() {
        val typeTextVariationEmail = 0x00000020
        assertFalse(isSecureDictationTarget(TYPE_CLASS_TEXT or typeTextVariationEmail))
    }

    @Test
    fun autofillPasswordHintIsSecure() {
        assertTrue(
            isSecureDictationTarget(TYPE_CLASS_TEXT, arrayOf("password")),
        )
    }

    @Test
    fun autofillNewPasswordHintIsSecure() {
        assertTrue(
            isSecureDictationTarget(TYPE_CLASS_TEXT, arrayOf("newPassword")),
        )
    }

    @Test
    fun autofillHintIsCaseInsensitive() {
        assertTrue(
            isSecureDictationTarget(TYPE_CLASS_TEXT, arrayOf("PASSWORD")),
        )
        assertTrue(
            isSecureDictationTarget(TYPE_CLASS_TEXT, arrayOf("NewPassword")),
        )
    }

    @Test
    fun otherAutofillHintsAreNotSecure() {
        assertFalse(
            isSecureDictationTarget(TYPE_CLASS_TEXT, arrayOf("emailAddress", "username")),
        )
    }

    @Test
    fun nullHintsOnPlainTextAreNotSecure() {
        assertFalse(isSecureDictationTarget(TYPE_CLASS_TEXT, null, hintsReadable = true))
    }

    @Test
    fun unreadableHintsOnPlainTextAreSecure() {
        assertTrue(isSecureDictationTarget(TYPE_CLASS_TEXT, null, hintsReadable = false))
    }

    @Test
    fun readableEmptyHintsOnPlainTextAreNotSecure() {
        assertFalse(isSecureDictationTarget(TYPE_CLASS_TEXT, emptyArray(), hintsReadable = true))
    }
}
