package com.matt.murmur.android.ime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
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
    private const val TAG = "murmur"

    fun start(service: Service, inputViewShown: Boolean): Boolean {
        if (!MicForegroundGate.canStartMicrophoneForeground(inputViewShown)) {
            Log.w(TAG, "fgs.start.denied")
            return false
        }
        ensureChannel(service)
        val notification = Notification.Builder(service, CHANNEL_ID)
            .setContentTitle(service.getString(R.string.app_name))
            .setContentText(service.getString(R.string.fgs_listening))
            .setSmallIcon(R.drawable.ic_mic)
            .setOngoing(true)
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
            Log.w(TAG, "fgs.start.denied")
            false
        }
    }

    fun stop(service: Service) {
        service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
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
