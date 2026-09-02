package com.matt.murmur.android.ui

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.R

class MurmurActivity : ComponentActivity() {
    private val companionState by lazy { CompanionState(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val barScrim = getColor(R.color.murmur_bg)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(barScrim),
            navigationBarStyle = SystemBarStyle.dark(barScrim),
        )
        setContent {
            MurmurCompanionTheme {
                CompanionShell(
                    state = companionState,
                    onEnableKeyboard = {
                        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                    },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        companionState.reload()
    }
}

@Composable
private fun MurmurCompanionTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = MurmurTokens.coral,
            onPrimary = MurmurTokens.textPrimary,
            background = MurmurTokens.bg,
            surface = MurmurTokens.card,
            onBackground = MurmurTokens.textPrimary,
            onSurface = MurmurTokens.textPrimary,
        ),
        content = content,
    )
}

private enum class CompanionTab(val title: String) {
    HOME("Home"),
    DICTIONARY("Dictionary"),
    SNIPPETS("Snippets"),
    STYLE("Style"),
    SCRATCHPAD("Scratchpad"),
}

@Composable
private fun CompanionShell(
    state: CompanionState,
    onEnableKeyboard: () -> Unit,
) {
    var tab by remember { mutableStateOf(CompanionTab.HOME) }
    var showSettings by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MurmurTokens.bg)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (tab == CompanionTab.HOME) "Murmur" else tab.title,
                color = MurmurTokens.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Text(
                "Settings",
                color = MurmurTokens.coralLight,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .clickable { showSettings = true }
                    .padding(8.dp),
            )
        }

        Box(modifier = Modifier.weight(1f)) {
            if (showSettings) {
                SettingsScreen(
                    state = state,
                    onEnableKeyboard = onEnableKeyboard,
                    onDone = { showSettings = false },
                )
            } else {
                when (tab) {
                    CompanionTab.HOME -> HomeScreen(state, onOpenSettings = { showSettings = true })
                    CompanionTab.DICTIONARY -> DictionaryScreen(state)
                    CompanionTab.SNIPPETS -> SnippetsScreen(state)
                    CompanionTab.STYLE -> StyleScreen(state)
                    CompanionTab.SCRATCHPAD -> ScratchpadScreen(state)
                }
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .background(MurmurTokens.card, RoundedCornerShape(28.dp))
                .padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CompanionTab.entries.forEach { item ->
                val selected = item == tab && !showSettings
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .background(
                            if (selected) MurmurTokens.coral.copy(alpha = 0.18f) else MurmurTokens.card,
                            RoundedCornerShape(20.dp),
                        )
                        .clickable {
                            showSettings = false
                            tab = item
                            if (item == CompanionTab.HOME) state.reloadHistory()
                        }
                        .padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        item.title,
                        color = if (selected) MurmurTokens.coral else MurmurTokens.textSecondary,
                        fontSize = 10.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }
        Spacer(Modifier.height(4.dp))
    }
}
