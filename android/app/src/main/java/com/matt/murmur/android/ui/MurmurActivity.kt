package com.matt.murmur.android.ui

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.R

class MurmurActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val barScrim = getColor(R.color.murmur_bg)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(barScrim),
            navigationBarStyle = SystemBarStyle.dark(barScrim),
        )
        setContent {
            MurmurCompanionTheme {
                EnableImeScreen(
                    onEnableKeyboard = {
                        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                    },
                )
            }
        }
    }
}

@Composable
private fun MurmurCompanionTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = MurmurTokens.coral,
            onPrimary = MurmurTokens.textPrimary,
            background = MurmurTokens.bg,
            surface = MurmurTokens.bg,
            onBackground = MurmurTokens.textPrimary,
            onSurface = MurmurTokens.textPrimary,
        ),
        content = content,
    )
}

@Composable
private fun EnableImeScreen(onEnableKeyboard: () -> Unit) {
    var scratch by remember { mutableStateOf("") }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MurmurTokens.bg)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Murmur", color = MurmurTokens.coralLight, fontSize = 28.sp)
        Text(
            "Enable Murmur as a keyboard, then type hello in Keep, Messages, or the field below. " +
                "This build commits typed keys only — the mic is a placeholder.",
            color = MurmurTokens.textSecondary,
            fontSize = 16.sp,
        )
        Button(
            onClick = onEnableKeyboard,
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(24.dp),
        ) {
            Text("Enable Murmur keyboard")
        }
        Text("Try it", color = MurmurTokens.textPrimary, fontSize = 14.sp)
        BasicTextField(
            value = scratch,
            onValueChange = { scratch = it },
            textStyle = TextStyle(color = MurmurTokens.textPrimary, fontSize = 18.sp),
            cursorBrush = SolidColor(MurmurTokens.coralLight),
            modifier = Modifier
                .fillMaxWidth()
                .background(Color.White.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                .padding(16.dp),
            decorationBox = { inner ->
                Box {
                    if (scratch.isEmpty()) {
                        Text("Type hello…", color = MurmurTokens.textSecondary, fontSize = 18.sp)
                    }
                    inner()
                }
            },
        )
    }
}
