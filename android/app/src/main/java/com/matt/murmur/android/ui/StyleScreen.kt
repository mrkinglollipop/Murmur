package com.matt.murmur.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.matt.murmur.android.logic.StyleProfile

@Composable
fun StyleScreen(state: CompanionState) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = MurmurTokens.textPrimary, fontFamily = FontFamily.Serif, fontSize = 32.sp)) {
                    append("Your ")
                }
                withStyle(SpanStyle(color = MurmurTokens.coral, fontSize = 26.sp)) {
                    append("default sound")
                }
            },
        )
        Text(
            "Caps, punctuation, and spacing only. Murmur does not rewrite your words.",
            color = MurmurTokens.textSecondary,
            fontSize = 15.sp,
        )
        StyleProfile.entries.forEach { profile ->
            styleCard(profile, selected = state.style == profile) {
                state.chooseStyle(profile)
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun styleCard(profile: StyleProfile, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(MurmurTokens.cardRadius.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MurmurTokens.card, shape)
            .border(2.dp, if (selected) MurmurTokens.coral else MurmurTokens.card, shape)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(profile.displayName, color = MurmurTokens.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            if (selected) {
                Text("✓", color = MurmurTokens.coral, fontSize = 18.sp)
            }
        }
        Text(profile.subtitle, color = MurmurTokens.textSecondary, fontSize = 14.sp)
        Text(
            "“${profile.example}”",
            color = MurmurTokens.textPrimary,
            fontSize = 15.sp,
            fontStyle = FontStyle.Italic,
            modifier = Modifier
                .fillMaxWidth()
                .background(MurmurTokens.coral.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
                .padding(12.dp),
        )
    }
}

private val StyleProfile.displayName: String
    get() = when (this) {
        StyleProfile.FORMAL -> "Formal"
        StyleProfile.CASUAL -> "Casual"
        StyleProfile.VERY_CASUAL -> "Very casual"
    }

private val StyleProfile.subtitle: String
    get() = when (this) {
        StyleProfile.FORMAL -> "Caps + punctuation"
        StyleProfile.CASUAL -> "Caps + less punctuation"
        StyleProfile.VERY_CASUAL -> "No caps + less punctuation"
    }

private val StyleProfile.example: String
    get() = when (this) {
        StyleProfile.FORMAL ->
            "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        StyleProfile.CASUAL ->
            "Hey, are you free for lunch tomorrow let's do 12 if that works for you"
        StyleProfile.VERY_CASUAL ->
            "hey are you free for lunch tomorrow let's do 12 if that works for you"
    }
