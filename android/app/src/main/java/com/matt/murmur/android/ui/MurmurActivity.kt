package com.matt.murmur.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.R
import com.matt.murmur.android.capture.MicCapture
import com.matt.murmur.android.cloud.ElevenLabsBatch
import com.matt.murmur.android.cloud.GeminiBatch
import com.matt.murmur.android.crypto.MurmurSecrets
import com.matt.murmur.android.logic.CloudEngine
import com.matt.murmur.android.logic.WavWriter
import com.matt.murmur.android.prefs.EnginePrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

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
                CompanionScreen(
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
private fun CompanionScreen(onEnableKeyboard: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var scratch by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var geminiKey by remember { mutableStateOf("") }
    var engine by remember { mutableStateOf(EnginePrefs.engine(context)) }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { granted ->
        val mic = granted[Manifest.permission.RECORD_AUDIO] == true
        status = if (mic) {
            "Microphone allowed"
        } else {
            "Allow microphone in Murmur"
        }
    }

    fun requestMicAndNotifications() {
        val needed = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) {
            needed += Manifest.permission.POST_NOTIFICATIONS
        }
        permissionLauncher.launch(needed.toTypedArray())
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MurmurTokens.bg)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Murmur", color = MurmurTokens.coralLight, fontSize = 28.sp)
        Text(
            "Enable Murmur as a keyboard, paste a cloud key, then tap the mic in a " +
                "text field to dictate. Partials stay on the IME status strip until you stop.",
            color = MurmurTokens.textSecondary,
            fontSize = 16.sp,
        )
        Text("Engine", color = MurmurTokens.textPrimary, fontSize = 14.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (choice in CloudEngine.entries) {
                val selected = engine == choice
                Button(
                    onClick = {
                        engine = choice
                        EnginePrefs.setEngine(context, choice)
                        status = "Engine: ${choice.displayName}"
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (selected) MurmurTokens.coral else Color.White.copy(alpha = 0.12f),
                    ),
                    shape = RoundedCornerShape(24.dp),
                ) {
                    Text(choice.displayName, fontSize = 13.sp)
                }
            }
        }
        Button(
            onClick = onEnableKeyboard,
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(24.dp),
        ) {
            Text("Enable Murmur keyboard")
        }
        Text("ElevenLabs API key", color = MurmurTokens.textPrimary, fontSize = 14.sp)
        BasicTextField(
            value = apiKey,
            onValueChange = { apiKey = it },
            textStyle = TextStyle(color = MurmurTokens.textPrimary, fontSize = 16.sp),
            cursorBrush = SolidColor(MurmurTokens.coralLight),
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier
                .fillMaxWidth()
                .background(Color.White.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                .padding(16.dp),
            decorationBox = { inner ->
                Box {
                    if (apiKey.isEmpty()) {
                        Text("Paste xi-… key", color = MurmurTokens.textSecondary, fontSize = 16.sp)
                    }
                    inner()
                }
            },
        )
        Button(
            onClick = {
                val trimmed = apiKey.trim()
                if (trimmed.isEmpty()) {
                    status = "Paste a key first"
                    return@Button
                }
                try {
                    MurmurSecrets.apiKeyStore(context).saveElevenLabsKey(trimmed)
                    status = "Key saved"
                } catch (_: Exception) {
                    status = "Could not save key"
                }
            },
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(24.dp),
        ) {
            Text("Save ElevenLabs key")
        }
        Text("Gemini API key", color = MurmurTokens.textPrimary, fontSize = 14.sp)
        BasicTextField(
            value = geminiKey,
            onValueChange = { geminiKey = it },
            textStyle = TextStyle(color = MurmurTokens.textPrimary, fontSize = 16.sp),
            cursorBrush = SolidColor(MurmurTokens.coralLight),
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier
                .fillMaxWidth()
                .background(Color.White.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                .padding(16.dp),
            decorationBox = { inner ->
                Box {
                    if (geminiKey.isEmpty()) {
                        Text("Paste Gemini key", color = MurmurTokens.textSecondary, fontSize = 16.sp)
                    }
                    inner()
                }
            },
        )
        Button(
            onClick = {
                val trimmed = geminiKey.trim()
                if (trimmed.isEmpty()) {
                    status = "Paste a Gemini key first"
                    return@Button
                }
                try {
                    MurmurSecrets.apiKeyStore(context).saveGeminiKey(trimmed)
                    EnginePrefs.setGeminiLiveHandshakeFailed(context, false)
                    status = "Gemini key saved"
                } catch (_: Exception) {
                    status = "Could not save key"
                }
            },
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(24.dp),
        ) {
            Text("Save Gemini key")
        }
        Button(
            onClick = {
                if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    requestMicAndNotifications()
                    return@Button
                }
                if (busy) return@Button
                busy = true
                status = "Recording 3s…"
                scope.launch {
                    status = try {
                        withContext(Dispatchers.IO) {
                            val pcm = MicCapture(context).record(3_000L)
                            val wav = File.createTempFile("murmur-", ".wav", context.cacheDir)
                            try {
                                WavWriter.writePcm16(pcm, wav)
                                val keys = MurmurSecrets.apiKeyStore(context)
                                when (EnginePrefs.engine(context)) {
                                    CloudEngine.ELEVEN_LABS -> {
                                        val key = keys.elevenLabsKey()
                                            ?: throw IllegalStateException("no-key")
                                        ElevenLabsBatch.transcribe(wav, key)
                                    }
                                    CloudEngine.GEMINI -> {
                                        val key = keys.geminiKey()
                                            ?: throw IllegalStateException("no-gemini-key")
                                        GeminiBatch.transcribe(wav, key)
                                    }
                                }
                            } finally {
                                wav.delete()
                            }
                        }
                    } catch (e: IllegalStateException) {
                        when (e.message) {
                            "no-key" -> "Paste and save an ElevenLabs key"
                            "no-gemini-key" -> "Paste and save a Gemini key"
                            else -> "Mic capture failed"
                        }
                    } catch (_: SecurityException) {
                        "Allow microphone in Murmur"
                    } catch (_: Exception) {
                        "Transcribe failed"
                    }
                    busy = false
                }
            },
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
            shape = RoundedCornerShape(24.dp),
        ) {
            Text("Record 3s and transcribe")
        }
        if (status.isNotEmpty()) {
            Text(status, color = MurmurTokens.textSecondary, fontSize = 14.sp)
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
