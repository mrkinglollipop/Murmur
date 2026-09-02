package com.matt.murmur.android.ime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.drawable.Icon
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import com.matt.murmur.android.R
import com.matt.murmur.android.logic.MicForegroundGate

/**
 * Version-gated microphone FGS on the IME service.
 * API 34+ type is mandatory; API 33 uses untyped startForeground.
 */
object ImeMicForeground {
    const val NOTIFICATION_ID = 1001
    const val CHANNEL_ID = "murmur_microphone"
    const val ACTION_STOP = "com.matt.murmur.android.STOP_DICTATION"
    private const val TAG = "murmur"

    fun start(service: Service, inputViewShown: Boolean): Boolean {
        if (!MicForegroundGate.canStartMicrophoneForeground(inputViewShown)) {
            Log.w(TAG, "fgs.start.denied")
            return false
        }
        ensureChannel(service)
        val stopIntent = Intent(ACTION_STOP).setPackage(service.packageName)
        val stopPi = PendingIntent.getBroadcast(
            service,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(service, CHANNEL_ID)
            .setContentTitle(service.getString(R.string.app_name))
            .setContentText(service.getString(R.string.fgs_listening))
            .setSmallIcon(R.drawable.ic_mic)
            .setOngoing(true)
            .setContentIntent(stopPi)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(service, R.drawable.ic_mic),
                    service.getString(R.string.fgs_stop),
                    stopPi,
                ).build(),
            )
            .build()
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                service.startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                @Suppress("DEPRECATION")
                service.startForeground(NOTIFICATION_ID, notification)
            }
            Log.i(TAG, "fgs.start")
            true
        } catch (e: Exception) {
            Log.w(TAG, "fgs.start.denied", e)
            false
        }
    }

    fun stop(service: Service) {
        try {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
    }

    private fun ensureChannel(service: Service) {
        val nm = service.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            service.getString(R.string.fgs_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = service.getString(R.string.fgs_channel_desc)
            setSound(null, null)
        }
        nm.createNotificationChannel(channel)
    }
}
