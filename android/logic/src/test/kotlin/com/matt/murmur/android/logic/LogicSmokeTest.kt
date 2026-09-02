package com.matt.murmur.android.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class LogicSmokeTest {
    @Test
    fun moduleName() {
        assertEquals("murmur-logic", Logic.NAME)
    }
}
