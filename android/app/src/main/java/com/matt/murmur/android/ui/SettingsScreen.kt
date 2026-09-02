package com.matt.murmur.android.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.logic.CloudEngine
import com.matt.murmur.android.logic.SettingsStore

@Composable
fun SettingsScreen(
    state: CompanionState,
    onEnableKeyboard: () -> Unit,
    onDone: () -> Unit,
) {
    var apiKey by remember { mutableStateOf("") }
    var geminiKey by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        state.refreshStatus()
        status = if (state.micGranted) "Microphone allowed" else "Allow microphone in Murmur"
    }
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = MurmurTokens.coral,
        cursorColor = MurmurTokens.coralLight,
        focusedTextColor = MurmurTokens.textPrimary,
        unfocusedTextColor = MurmurTokens.textPrimary,
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Settings", color = MurmurTokens.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onDone,
                colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
                shape = RoundedCornerShape(20.dp),
            ) { Text("Done") }
        }

        section("Setup") {
            settingsRow(
                title = "Murmur keyboard",
                subtitle = if (state.imeEnabled) {
                    "Enabled. Switch to it from a text field (globe / picker)."
                } else {
                    "Turn Murmur on in input-method settings."
                },
            ) {
                Button(
                    onClick = onEnableKeyboard,
                    colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
                    shape = RoundedCornerShape(20.dp),
                ) { Text("Enable keyboard") }
            }
            hairline()
            settingsRow(
                title = "Microphone",
                subtitle = if (state.micGranted) "Granted" else "Needed for dictation. The IME records only while a take is on.",
            ) {
                Button(
                    onClick = {
                        val needed = mutableListOf(Manifest.permission.RECORD_AUDIO)
                        if (Build.VERSION.SDK_INT >= 33) needed += Manifest.permission.POST_NOTIFICATIONS
                        permissionLauncher.launch(needed.toTypedArray())
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
                    shape = RoundedCornerShape(20.dp),
                ) { Text("Request microphone") }
            }
        }

        section("Dictation") {
            settingsRow(
                title = "Cloud engine",
                subtitle = state.engine.displayName,
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (choice in CloudEngine.entries) {
                        val selected = state.engine == choice
                        Button(
                            onClick = { state.chooseEngine(choice) },
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (selected) {
                                    MurmurTokens.coral
                                } else {
                                    MurmurTokens.card
                                },
                            ),
                            shape = RoundedCornerShape(20.dp),
                        ) { Text(choice.displayName, fontSize = 12.sp) }
                    }
                }
            }
            hairline()
            toggleRow(
                title = "Code-aware punctuation",
                subtitle = "Spoken identifier joiners (foo period bar → foo.bar). On by default.",
                checked = state.codeAware,
                onCheckedChange = { state.chooseCodeAware(it) },
            )
            hairline()
            toggleRow(
                title = "Press and hold to dictate",
                subtitle = "Off: tap to start, tap to stop. On: press starts, release stops.",
                checked = state.pressAndHold,
                onCheckedChange = { state.choosePressAndHold(it) },
            )
            hairline()
            toggleRow(
                title = "Remove filler words",
                subtitle = "Scribe no_verbatim. Strips ums and false starts.",
                checked = state.removeFillerWords,
                onCheckedChange = { state.chooseRemoveFillerWords(it) },
            )
        }

        section("Keys") {
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                Text("ElevenLabs API key", color = MurmurTokens.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = apiKey,
                    onValueChange = { apiKey = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Paste xi-… key", color = MurmurTokens.textSecondary) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    colors = fieldColors,
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = {
                        val trimmed = apiKey.trim()
                        if (trimmed.isEmpty()) {
                            status = "Paste a key first"
                            return@Button
                        }
                        status = if (state.saveApiKey(trimmed)) "Key saved" else "Could not save key"
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
                    shape = RoundedCornerShape(20.dp),
                ) { Text("Save key") }
                Spacer(Modifier.height(8.dp))
                Text(
                    if (state.hasApiKey) "A key is stored on this device." else "Stored in Android Keystore. Nothing goes to a Murmur server.",
                    color = MurmurTokens.textSecondary,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(16.dp))
                Text("Gemini API key", color = MurmurTokens.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = geminiKey,
                    onValueChange = { geminiKey = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Paste Gemini key", color = MurmurTokens.textSecondary) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    colors = fieldColors,
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = {
                        val trimmed = geminiKey.trim()
                        if (trimmed.isEmpty()) {
                            status = "Paste a Gemini key first"
                            return@Button
                        }
                        status = if (state.saveGeminiKey(trimmed)) "Gemini key saved" else "Could not save key"
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MurmurTokens.coral),
                    shape = RoundedCornerShape(20.dp),
                ) { Text("Save Gemini key") }
                Spacer(Modifier.height(8.dp))
                Text(
                    if (state.hasGeminiKey) "A Gemini key is stored on this device." else "Used for Gemini 3.5 Transcribe Live and batch fallback.",
                    color = MurmurTokens.textSecondary,
                    fontSize = 13.sp,
                )
            }
        }

        if (status.isNotEmpty()) {
            Text(status, color = MurmurTokens.textSecondary, fontSize = 14.sp)
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title.uppercase(),
            color = MurmurTokens.textSecondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(start = 8.dp),
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MurmurTokens.card, RoundedCornerShape(MurmurTokens.cardRadius.dp)),
        ) {
            content()
        }
    }
}

@Composable
private fun settingsRow(title: String, subtitle: String, accessory: @Composable () -> Unit = {}) {
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
        Text(title, color = MurmurTokens.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(subtitle, color = MurmurTokens.textSecondary, fontSize = 13.sp)
        Spacer(Modifier.height(8.dp))
        accessory()
    }
}

@Composable
private fun toggleRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = MurmurTokens.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            Text(subtitle, color = MurmurTokens.textSecondary, fontSize = 13.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedTrackColor = MurmurTokens.coral),
        )
    }
}

@Composable
private fun hairline() {
    Spacer(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp)
            .height(1.dp)
            .background(MurmurTokens.hairline),
    )
}
