package com.izz.tunneling.injector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat

class IzzVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var isRunning = false

    companion object {
        const val ACTION_START = "com.izz.tunneling.injector.START"
        const val ACTION_STOP = "com.izz.tunneling.injector.STOP"
        const val CHANNEL_ID = "izz_vpn_service_channel"
        const val NOTIFICATION_ID = 1001
        
        var instance: IzzVpnService? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopTunnel()
            return START_NOT_STICKY
        } else if (action == ACTION_START) {
            val config = intent.getStringExtra("CONFIG_JSON") ?: ""
            startTunnel(config)
        }
        return START_STICKY
    }

    private fun startTunnel(configJson: String) {
        if (isRunning) return
        
        try {
            startForeground(NOTIFICATION_ID, buildNotification("Menghubungkan ke server..."))

            // Establish Android VpnService TUN Interface
            val builder = Builder()
                .setSession("Izz Tunnel")
                .setMtu(1500)
                .addAddress("172.19.0.1", 30)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
                .addRoute("0.0.0.0", 0)

            vpnInterface = builder.establish()
            isRunning = true

            updateNotification("Izz Tunnel - Terhubung")
            MainActivity.notifyStateChange("connected")

        } catch (e: Exception) {
            e.printStackTrace()
            stopTunnel()
            MainActivity.notifyStateChange("error")
        }
    }

    private fun stopTunnel() {
        isRunning = false
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        MainActivity.notifyStateChange("disconnected")
    }

    override fun onDestroy() {
        stopTunnel()
        instance = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Izz Tunnel Background Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Izz Tunnel")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
