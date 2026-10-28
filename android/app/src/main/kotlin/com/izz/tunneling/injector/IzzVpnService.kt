package com.izz.tunneling.injector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import hev.htproxy.TProxyService
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.atomic.AtomicBoolean

class IzzVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var isRunning = false
    private var singBoxProcess: Process? = null
    private val stopRequested = AtomicBoolean(false)
    private var statsThread: Thread? = null
    private var jschManager: JSchTunnelManager? = null

    companion object {
        const val TAG = "IzzVpnService"
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
        stopRequested.set(false)

        try {
            startForeground(NOTIFICATION_ID, buildNotification("Memulai service..."))
            MainActivity.notifyStateChange("connecting", "Menyiapkan tunnel...")

            if (configJson.isBlank()) {
                Log.e(TAG, "Empty config JSON received")
                MainActivity.notifyStateChange("error", "Konfigurasi kosong")
                stopTunnel()
                return
            }

            val json = JSONObject(configJson)
            val outbounds = json.optJSONArray("outbounds")
            val firstOutbound = if (outbounds != null && outbounds.length() > 0) outbounds.getJSONObject(0) else null
            val isSsh = firstOutbound?.optString("type") == "ssh"

            if (isSsh && firstOutbound != null) {
                // ==========================================
                // SSH INJECT: Use Pure JSch Engine (HTTP Custom Architecture)
                // ==========================================
                val server = firstOutbound.optString("server", "")
                val port = firstOutbound.optInt("server_port", 443)
                val user = firstOutbound.optString("user", "")
                val pass = firstOutbound.optString("password", "")
                val enableSsl = firstOutbound.optBoolean("_enable_ssl", true)
                val sni = firstOutbound.optString("_sni", "")
                val enablePayload = firstOutbound.optBoolean("_enable_payload", true)
                val payload = firstOutbound.optString("_payload", "")
                val enableProxy = firstOutbound.optBoolean("_enable_proxy", false)
                val remoteProxy = firstOutbound.optString("_remote_proxy", "")

                jschManager = JSchTunnelManager(
                    vpnService = this,
                    host = server,
                    port = port,
                    user = user,
                    pass = pass,
                    enableSsl = enableSsl,
                    sni = sni,
                    enablePayload = enablePayload,
                    payload = payload,
                    enableProxy = enableProxy,
                    remoteProxy = remoteProxy,
                    onLog = { msg ->
                        MainActivity.notifyStateChange("connecting", msg)
                    },
                    onConnected = {
                        setupVpnAndHevTunnel()
                    },
                    onError = { errMsg ->
                        MainActivity.notifyStateChange("error", errMsg)
                        stopTunnel()
                    }
                )
                jschManager!!.start()

            } else {
                // ==========================================
                // V2RAY / XRAY: Use sing-box Core
                // ==========================================
                val configFile = File(filesDir, "sing-box-config.json")
                configFile.writeText(configJson)

                val singBoxStarted = startSingBox(configFile)
                Thread.sleep(500)

                if (singBoxProcess != null && !singBoxProcess!!.isAlive) {
                    val exitCode = try { singBoxProcess?.exitValue() ?: -1 } catch (_: Exception) { -1 }
                    MainActivity.notifyStateChange("error", "Engine sing-box keluar (code: $exitCode)")
                    stopTunnel()
                    return
                }

                setupVpnAndHevTunnel()
            }

        } catch (e: Exception) {
            Log.e(TAG, "startTunnel failed: ${e.message}", e)
            MainActivity.notifyStateChange("error", "Gagal konek: ${e.message}")
            stopTunnel()
        }
    }

    private fun setupVpnAndHevTunnel() {
        if (stopRequested.get()) return

        try {
            updateNotification("Membuat interface VPN...")

            val builder = Builder()
                .setSession("Izz Tunnel")
                .setMtu(1500)
                .addAddress("172.19.0.1", 30)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
                .addRoute("0.0.0.0", 0)

            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                Log.w(TAG, "Could not add disallowed application: ${e.message}")
            }

            vpnInterface = builder.establish()
            if (vpnInterface == null) {
                Log.e(TAG, "Failed to establish VPN interface")
                MainActivity.notifyStateChange("error", "Gagal membuat interface VPN Android")
                stopTunnel()
                return
            }

            val tunFd = vpnInterface!!.fd
            Log.i(TAG, "VPN TUN established with FD: $tunFd")

            val hevConfigFile = File(filesDir, "hev.yml")
            val hevConfigYaml = """
tunnel:
  mtu: 1500
  ipv4: 172.19.0.1

socks5:
  port: 10808
  address: 127.0.0.1
  udp: 'tcp'

misc:
  log-level: warn
""".trimIndent()
            hevConfigFile.writeText(hevConfigYaml)

            val tproxyStarted = try {
                TProxyService.TProxyStartService(hevConfigFile.absolutePath, tunFd)
            } catch (e: Throwable) {
                Log.e(TAG, "TProxyStartService error: ${e.message}", e)
                false
            }
            Log.i(TAG, "hev-socks5-tunnel started: $tproxyStarted")

            isRunning = true
            updateNotification("Izz Tunnel - Terhubung")
            MainActivity.notifyStateChange("connected", null)

            startStatsMonitoring()

        } catch (e: Exception) {
            Log.e(TAG, "setupVpnAndHevTunnel error", e)
            MainActivity.notifyStateChange("error", "Gagal mengaktifkan VPN: ${e.message}")
            stopTunnel()
        }
    }

    private fun startSingBox(configFile: File): Boolean {
        try {
            val possiblePaths = listOf(
                File(applicationInfo.nativeLibraryDir, "libsing-box.so"),
                File(filesDir, "sing-box"),
                File(applicationInfo.nativeLibraryDir, "sing-box")
            )

            var singBoxBinary: File? = null
            for (p in possiblePaths) {
                if (p.exists() && p.canExecute()) {
                    singBoxBinary = p
                    break
                }
            }

            if (singBoxBinary == null) {
                Log.w(TAG, "sing-box binary not found or not executable in nativeLibraryDir")
                return false
            }

            Log.i(TAG, "Starting sing-box from ${singBoxBinary.absolutePath}")
            val pb = ProcessBuilder(singBoxBinary.absolutePath, "run", "-c", configFile.absolutePath)
            pb.redirectErrorStream(true)
            pb.directory(filesDir)
            singBoxProcess = pb.start()

            Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(singBoxProcess!!.inputStream))
                    var line: String? = null
                    while (!stopRequested.get() && reader.readLine().also { line = it } != null) {
                        Log.i(TAG, "sing-box: $line")
                        line?.let { l ->
                            if (l.contains("fatal") || l.contains("panic")) {
                                MainActivity.notifyStateChange("error", l)
                            }
                        }
                    }
                } catch (_: Exception) {}
            }.apply {
                name = "sing-box-log"
                isDaemon = true
                start()
            }

            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch sing-box: ${e.message}", e)
            return false
        }
    }

    private fun startStatsMonitoring() {
        statsThread?.interrupt()
        statsThread = Thread {
            var lastTx: Long = 0
            var lastRx: Long = 0

            while (isRunning && !stopRequested.get()) {
                try {
                    Thread.sleep(1000)
                    if (!isRunning) break

                    val stats = try {
                        TProxyService.TProxyGetStats()
                    } catch (_: Throwable) {
                        null
                    }

                    if (stats != null && stats.size >= 2) {
                        val currentTx = stats[0]
                        val currentRx = stats[1]

                        val upSpeedBytes = if (lastTx > 0 && currentTx >= lastTx) currentTx - lastTx else 0
                        val downSpeedBytes = if (lastRx > 0 && currentRx >= lastRx) currentRx - lastRx else 0

                        lastTx = currentTx
                        lastRx = currentRx

                        val downStr = formatSpeed(downSpeedBytes)
                        val upStr = formatSpeed(upSpeedBytes)

                        val statsMap = mapOf(
                            "ping_ms" to "28",
                            "down_speed" to downStr,
                            "up_speed" to upStr
                        )
                        MainActivity.notifyStats(statsMap)
                    }
                } catch (_: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Stats thread error: ${e.message}")
                }
            }
        }.apply {
            name = "vpn-stats-thread"
            isDaemon = true
            start()
        }
    }

    private fun formatSpeed(bytesPerSec: Long): String {
        return if (bytesPerSec >= 1024 * 1024) {
            String.format("%.1f MB/s", bytesPerSec.toDouble() / (1024 * 1024))
        } else if (bytesPerSec >= 1024) {
            String.format("%d KB/s", bytesPerSec / 1024)
        } else {
            "$bytesPerSec B/s"
        }
    }

    private fun stopTunnel() {
        if (!isRunning && vpnInterface == null && singBoxProcess == null && jschManager == null) return

        stopRequested.set(true)
        isRunning = false

        statsThread?.interrupt()
        statsThread = null

        try {
            jschManager?.stop()
            jschManager = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping jschManager", e)
        }

        try {
            TProxyService.TProxyStopService()
        } catch (e: Throwable) {
            Log.e(TAG, "TProxyStopService error: ${e.message}")
        }

        try {
            singBoxProcess?.destroyForcibly()
            singBoxProcess = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping sing-box: ${e.message}")
        }

        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing VPN interface: ${e.message}")
        }

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        MainActivity.notifyStateChange("disconnected", null)
    }

    override fun onRevoke() {
        stopTunnel()
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
