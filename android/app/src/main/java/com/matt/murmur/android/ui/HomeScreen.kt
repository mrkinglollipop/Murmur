package com.matt.murmur.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.logic.HistoryEntry
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun HomeScreen(state: CompanionState, onOpenSettings: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        hero(state)
        if (state.setupIncomplete) {
            setupCard(onOpenSettings)
        }
        today(state)
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun hero(state: CompanionState) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MurmurTokens.hero, RoundedCornerShape(MurmurTokens.cardRadius.dp))
            .padding(22.dp),
    ) {
        if (state.wordCount == 0) {
            val onOff = if (state.setupIncomplete) "off" else "on"
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = MurmurTokens.textPrimary, fontFamily = FontFamily.Serif, fontSize = 32.sp)) {
                        append("Murmur is ")
                    }
                    withStyle(SpanStyle(color = MurmurTokens.coral, fontFamily = FontFamily.Serif, fontSize = 32.sp)) {
                        append(onOff)
                    }
                },
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Dictate from the Murmur keyboard. This phone keeps a local count.",
                color = MurmurTokens.textSecondary,
                fontSize = 15.sp,
            )
        } else {
            Text(
                "${String.format(Locale.US, "%,d", state.wordCount)} words",
                color = MurmurTokens.textPrimary,
                fontSize = 36.sp,
                fontFamily = FontFamily.Serif,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "you've dictated on this phone",
                color = MurmurTokens.textSecondary,
                fontSize = 15.sp,
            )
        }
    }
}

@Composable
private fun setupCard(onOpenSettings: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MurmurTokens.card, RoundedCornerShape(MurmurTokens.cardRadius.dp))
            .clickable(onClick = onOpenSettings)
            .padding(18.dp),
    ) {
        Text("Finish setup", color = MurmurTokens.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(
            "Enable the keyboard, allow the microphone, and paste an API key in Settings.",
            color = MurmurTokens.textSecondary,
            fontSize = 14.sp,
        )
    }
}

@Composable
private fun today(state: CompanionState) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Today", color = MurmurTokens.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        val todays = state.todayEntries
        if (todays.isEmpty()) {
            Text(
                "Dictations show up here.",
                color = MurmurTokens.textSecondary,
                fontSize = 15.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MurmurTokens.card, RoundedCornerShape(MurmurTokens.cardRadius.dp))
                    .padding(18.dp),
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MurmurTokens.card, RoundedCornerShape(MurmurTokens.cardRadius.dp)),
            ) {
                todays.forEachIndexed { index, entry ->
                    historyRow(entry)
                    if (index < todays.lastIndex) {
                        Spacer(
                            Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(MurmurTokens.hairline),
                        )
                    }
                }
            }
        }
    }
}

private val timeFmt = DateTimeFormatter.ofPattern("h:mm a")

@Composable
private fun historyRow(entry: HistoryEntry) {
    val time = entry.date.atZone(ZoneId.systemDefault()).format(timeFmt)
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
        Text(
            entry.text,
            color = if (entry.failed) MurmurTokens.failed else MurmurTokens.textPrimary,
            fontSize = 16.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 3,
        )
        Spacer(Modifier.height(4.dp))
        Text(time, color = MurmurTokens.textSecondary, fontSize = 13.sp)
    }
}
