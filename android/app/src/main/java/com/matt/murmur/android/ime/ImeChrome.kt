package com.matt.murmur.android.ime

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.matt.murmur.android.R

/**
 * Views QWERTY + mic placeholder. Letter keys [commitText] through [Listener].
 * Follows system night mode; companion UI is dark-first and lives elsewhere.
 */
class ImeChrome(
    context: Context,
    private val listener: Listener,
) : LinearLayout(context) {

    interface Listener {
        fun onCommit(text: String)
        fun onDelete()
        fun onEnter()
        fun onSwitchIme()
        fun onMicPlaceholder()
    }

    private var shifted = false
    private val letterKeys = mutableListOf<TextView>()
    private val specialKeys = mutableListOf<TextView>()
    private val statusLabel: TextView
    private val micButton: ImageView
    private lateinit var shiftKey: TextView

    private val night: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    init {
        orientation = VERTICAL
        val pad = 6.dp
        setPadding(pad, pad, pad, pad)

        statusLabel = TextView(context).apply {
            text = "Murmur"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(12.dp, 0, 0, 0)
        }
        micButton = ImageView(context).apply {
            setImageResource(R.drawable.ic_mic)
            contentDescription = "Microphone (placeholder)"
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(10.dp, 10.dp, 10.dp, 10.dp)
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                statusLabel.text = "Mic is a placeholder — no recording in this build"
                listener.onMicPlaceholder()
            }
        }

        addView(buildStatusStrip(), LayoutParams(LayoutParams.MATCH_PARENT, 44.dp))
        addView(letterRow(ROW_1))
        addView(letterRow(ROW_2, sidePad = true))
        addView(buildShiftRow())
        addView(buildActionRow())
        applyChromeColors()
    }

    private fun buildStatusStrip(): LinearLayout {
        return LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(micButton, LayoutParams(40.dp, 40.dp))
            addView(statusLabel, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
        }
    }

    private fun letterRow(letters: List<String>, sidePad: Boolean = false): LinearLayout {
        val row = keyRow()
        if (sidePad) {
            row.addView(View(context), LayoutParams(0, LayoutParams.MATCH_PARENT, 0.5f))
        }
        for (letter in letters) {
            val key = letterKey(letter)
            letterKeys += key
            row.addView(key, keyParams())
        }
        if (sidePad) {
            row.addView(View(context), LayoutParams(0, LayoutParams.MATCH_PARENT, 0.5f))
        }
        return row
    }

    private fun buildShiftRow(): LinearLayout {
        val row = keyRow()
        shiftKey = specialKey("⇧") {
            shifted = !shifted
            refreshLetters()
            applyChromeColors()
        }
        specialKeys += shiftKey
        row.addView(shiftKey, keyParams(weight = 1.4f))
        for (letter in ROW_3) {
            val key = letterKey(letter)
            letterKeys += key
            row.addView(key, keyParams())
        }
        val del = specialKey("⌫") { listener.onDelete() }
        specialKeys += del
        row.addView(del, keyParams(weight = 1.4f))
        return row
    }

    private fun buildActionRow(): LinearLayout {
        val row = keyRow()
        val globe = specialKey("🌐") { listener.onSwitchIme() }
        val comma = specialKey(",") { listener.onCommit(",") }
        val space = specialKey("space") { listener.onCommit(" ") }
        val period = specialKey(".") { listener.onCommit(".") }
        val enter = specialKey("↵") { listener.onEnter() }
        specialKeys += listOf(globe, comma, space, period, enter)
        row.addView(globe, keyParams(weight = 1.2f))
        row.addView(comma, keyParams(weight = 1f))
        row.addView(space, keyParams(weight = 4f))
        row.addView(period, keyParams(weight = 1f))
        row.addView(enter, keyParams(weight = 1.4f))
        return row
    }

    private fun letterKey(letter: String): TextView {
        return TextView(context).apply {
            text = letter
            tag = letter
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            typeface = Typeface.DEFAULT_BOLD
            isClickable = true
            isFocusable = true
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                val raw = tag as String
                val out = if (shifted) raw.uppercase() else raw
                listener.onCommit(out)
                if (shifted) {
                    shifted = false
                    refreshLetters()
                    applyChromeColors()
                }
            }
        }
    }

    private fun specialKey(label: String, onClick: () -> Unit): TextView {
        return TextView(context).apply {
            text = label
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                onClick()
            }
        }
    }

    private fun keyRow(): LinearLayout {
        return LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER
            val lp = LayoutParams(LayoutParams.MATCH_PARENT, 48.dp)
            lp.topMargin = 6.dp
            layoutParams = lp
        }
    }

    private fun keyParams(weight: Float = 1f): LayoutParams {
        return LayoutParams(0, LayoutParams.MATCH_PARENT, weight).apply {
            marginStart = 3.dp
            marginEnd = 3.dp
        }
    }

    private fun refreshLetters() {
        for (key in letterKeys) {
            val raw = key.tag as String
            key.text = if (shifted) raw.uppercase() else raw
        }
    }

    private fun applyChromeColors() {
        val dark = night
        setBackgroundColor(if (dark) BACKDROP_DARK else BACKDROP_LIGHT)
        statusLabel.setTextColor(if (dark) Color.WHITE else Color.BLACK)
        val micBg = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(CORAL)
        }
        micButton.background = micBg
        val letterFill = if (dark) LETTER_FILL_DARK else LETTER_FILL_LIGHT
        val specialFill = if (shifted && dark) SHIFTED_FILL_DARK else if (shifted) SHIFTED_FILL_LIGHT
            else if (dark) SPECIAL_FILL_DARK else SPECIAL_FILL_LIGHT
        val glyph = if (dark) Color.WHITE else Color.BLACK
        for (key in letterKeys) {
            key.setTextColor(glyph)
            key.background = keyDrawable(letterFill, glyph)
        }
        for (key in specialKeys) {
            val fill = if (key === shiftKey && shifted) {
                CORAL
            } else if (dark) SPECIAL_FILL_DARK else SPECIAL_FILL_LIGHT
            key.setTextColor(if (key === shiftKey && shifted) Color.WHITE else glyph)
            key.background = keyDrawable(fill, glyph)
        }
        // silence unused when shift is off
        if (!shifted) {
            shiftKey.background = keyDrawable(specialFill, glyph)
        }
    }

    private fun keyDrawable(fill: Int, ripple: Int): RippleDrawable {
        val shape = GradientDrawable().apply {
            cornerRadius = 8.5f.dp
            setColor(fill)
        }
        return RippleDrawable(ColorStateList.valueOf(ripple and 0x40FFFFFF), shape, shape)
    }

    private val Int.dp: Int
        get() = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            toFloat(),
            resources.displayMetrics,
        ).toInt()

    private val Float.dp: Float
        get() = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            this,
            resources.displayMetrics,
        )

    companion object {
        private val ROW_1 = listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p")
        private val ROW_2 = listOf("a", "s", "d", "f", "g", "h", "j", "k", "l")
        private val ROW_3 = listOf("z", "x", "c", "v", "b", "n", "m")

        private val CORAL = Color.parseColor("#D85A30")
        private val BACKDROP_DARK = Color.rgb(28, 28, 31)
        private val BACKDROP_LIGHT = Color.rgb(226, 226, 228)
        private val LETTER_FILL_DARK = Color.rgb(128, 128, 128)
        private val LETTER_FILL_LIGHT = Color.WHITE
        private val SPECIAL_FILL_DARK = Color.rgb(56, 56, 56)
        private val SPECIAL_FILL_LIGHT = Color.rgb(173, 178, 186)
        private val SHIFTED_FILL_DARK = Color.rgb(80, 80, 80)
        private val SHIFTED_FILL_LIGHT = Color.rgb(200, 200, 204)
    }
}
