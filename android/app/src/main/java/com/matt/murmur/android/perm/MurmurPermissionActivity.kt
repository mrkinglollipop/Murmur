package com.matt.murmur.android.perm

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.matt.murmur.android.R

/**
 * Companion prompt for RECORD_AUDIO and POST_NOTIFICATIONS.
 * The IME cannot show a runtime dialog; it launches this with FLAG_ACTIVITY_NEW_TASK.
 */
class MurmurPermissionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val needed = missingPermissions()
        if (needed.isEmpty()) {
            finish()
            return
        }

        val pad = (24 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(BG)
            setPadding(pad, pad, pad, pad)
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val body = TextView(this).apply {
            text = getString(R.string.permission_disclosure)
            setTextColor(TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        }
        val button = Button(this).apply {
            text = getString(R.string.permission_continue)
            setOnClickListener {
                requestPermissions(missingPermissions().toTypedArray(), REQ)
            }
        }
        root.addView(body)
        root.addView(
            button,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = pad },
        )
        setContentView(root)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        finish()
    }

    private fun missingPermissions(): List<String> {
        val needed = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) {
            needed += Manifest.permission.POST_NOTIFICATIONS
        }
        return needed.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    companion object {
        const val ACTION_REQUEST_MIC = "com.matt.murmur.android.REQUEST_MIC"
        private const val REQ = 1
        private val BG = Color.parseColor("#101014")
        private val TEXT = Color.parseColor("#F5F5F7")
    }
}
