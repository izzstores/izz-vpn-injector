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
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class IzzVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var isRunning = false
    private var singBoxProcess: Process? = null
    private val stopRequested = AtomicBoolean(false)
    private var statsThread: Thread? = null
    private var jschManager: JSchTunnelManager? = null
    private var hevStarted = false
    @Volatile private var singBoxLastLog = ""
    @Volatile private var failureReported = false

    companion object {
        const val TAG = "IzzVpnService"
        const val ACTION_START = "com.izz.tunneling.injector.START"
        const val ACTION_STOP = "com.izz.tunneling.injector.STOP"
        const val CHANNEL_ID = "izz_vpn_service_channel"
        const val NOTIFICATION_ID = 1001
        const val LOCAL_PROXY_PORT = 10808

        var instance: IzzVpnService? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            ACTION_START -> startTunnel(intent.getStringExtra("CONFIG_JSON") ?: "")
        }
        return START_STICKY
    }

    private fun startTunnel(configJson: String) {
        if (isRunning) return
        stopRequested.set(false)
        failureReported = false
        singBoxLastLog = ""

        try {
            startForeground(NOTIFICATION_ID, buildNotification("Memulai service..."))
            MainActivity.notifyStateChange("connecting", "Menyiapkan tunnel...")

            if (configJson.isBlank()) {
                MainActivity.notifyStateChange("error", "Konfigurasi kosong")
                stopTunnel()
                return
            }

            val json = JSONObject(configJson)
            val outbounds = json.optJSONArray("outbounds")
            val first = if (outbounds != null && outbounds.length() > 0) outbounds.getJSONObject(0) else null
            val isSsh = first?.optString("type") == "ssh"

            // TUN Android + hev-socks5-tunnel dibangun lebih dulu (pola V2RayNG / HTTP Injector)
            if (!establishTun()) {
                stopTunnel()
                return
            }

            if (isSsh && first != null) {
                startSshInjector(first)
            } else {
                startXrayCore(configJson)
            }

        } catch (e: Exception) {
            Log.e(TAG, "startTunnel failed", e)
            MainActivity.notifyStateChange("error", "Gagal konek: ${e.message}")
            stopTunnel()
        }
    }

    /** TUN Android + hev-socks5-tunnel -> SOCKS5 127.0.0.1:10808 */
    private fun establishTun(): Boolean {
        return try {
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
                Log.w(TAG, "addDisallowedApplication: ${e.message}")
            }

            vpnInterface = builder.establish()
            if (vpnInterface == null) {
                MainActivity.notifyStateChange("error", "Izin VPN ditolak / gagal membuat interface")
                return false
            }

            val tunFd = vpnInterface!!.fd
            Log.i(TAG, "TUN established fd=$tunFd")

            val hevConfigFile = File(filesDir, "hev.yml")
            hevConfigFile.writeText(
                """
tunnel:
  mtu: 1500
  ipv4: 172.19.0.1

socks5:
  port: $LOCAL_PROXY_PORT
  address: 127.0.0.1
  udp: 'tcp'

misc:
  log-level: warn
""".trimIndent()
            )

            hevStarted = try {
                TProxyService.TProxyStartService(hevConfigFile.absolutePath, tunFd)
            } catch (e: Throwable) {
                Log.e(TAG, "TProxyStartService error", e)
                false
            }
            Log.i(TAG, "hev-socks5-tunnel started=$hevStarted")
            true
        } catch (e: Exception) {
            Log.e(TAG, "establishTun error", e)
            MainActivity.notifyStateChange("error", "Gagal membuat interface VPN: ${e.message}")
            false
        }
    }

    /** SSH: JSch membuka SOCKS5 di 10808, hev meneruskan TUN ke situ */
    private fun startSshInjector(first: JSONObject) {
        val manager = JSchTunnelManager(
            vpnService = this,
            host = first.optString("server", ""),
            port = first.optInt("server_port", 443),
            user = first.optString("user", ""),
            pass = first.optString("password", ""),
            enableSsl = first.optBoolean("_enable_ssl", true),
            sni = first.optString("_sni", ""),
            enablePayload = first.optBoolean("_enable_payload", true),
            payload = first.optString("_payload", ""),
            enableProxy = first.optBoolean("_enable_proxy", false),
            remoteProxy = first.optString("_remote_proxy", ""),
            onLog = { msg -> MainActivity.notifyStateChange("connecting", msg) },
            onConnected = { markConnected() },
            onError = { err ->
                MainActivity.notifyStateChange("error", err)
                stopTunnel()
            }
        )
        jschManager = manager
        manager.start()
    }

    /** Xray-core resmi sebagai proxy lokal; TUN tetap dipegang Android + hev. */
    private fun startXrayCore(configJson: String) {
        val configFile = File(filesDir, "xray-config.json")
        configFile.writeText(configJson)

        if (!startXray(configFile)) {
            if (!failureReported) {
                failureReported = true
                MainActivity.notifyStateChange("error", "Xray gagal dijalankan: binary atau konfigurasi tidak valid")
            }
            stopTunnel()
            return
        }

        if (!waitForLocalPort(LOCAL_PROXY_PORT, 6000)) {
            val code = try { singBoxProcess?.exitValue() } catch (_: Exception) { null }
            val detail = singBoxLastLog.trim().takeLast(260)
            if (!failureReported) {
                failureReported = true
                MainActivity.notifyStateChange(
                    "error",
                    if (code != null) {
                        "Xray berhenti (code: $code)${if (detail.isNotEmpty()) ": $detail" else ""}"
                    } else {
                        "Xray tidak merespons di port $LOCAL_PROXY_PORT${if (detail.isNotEmpty()) ": $detail" else ""}"
                    }
                )
            }
            stopTunnel()
            return
        }
        markConnected()
    }

    private fun waitForLocalPort(port: Int, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (stopRequested.get()) return false
            if (singBoxProcess != null && !singBoxProcess!!.isAlive) return false
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", port), 400)
                    return true
                }
            } catch (_: Exception) {
                Thread.sleep(250)
            }
        }
        return false
    }

    private fun markConnected() {
        if (stopRequested.get()) return
        isRunning = true
        updateNotification("Izz Tunnel - Terhubung")
        MainActivity.notifyStateChange("connected", null)
        startStatsMonitoring()
    }

    private fun startXray(configFile: File): Boolean {
        return try {
            val binary = File(filesDir, "xray")
            val abi = Build.SUPPORTED_ABIS.firstOrNull { it == "arm64-v8a" || it == "x86_64" }
            val assetName = when (abi) {
                "arm64-v8a" -> "xray/arm64-v8a"
                "x86_64" -> "xray/x86_64"
                else -> null
            }
            if (assetName == null) {
                failureReported = true
                MainActivity.notifyStateChange("error", "Arsitektur Android tidak didukung Xray: ${Build.SUPPORTED_ABIS.joinToString()}")
                return false
            }
            val assetSize = try {
                assets.open(assetName).use { it.available().toLong() }
            } catch (e: Exception) {
                Log.e(TAG, "Xray asset missing: $assetName", e)
                0L
            }
            if (assetSize < 1_000_000L) {
                failureReported = true
                MainActivity.notifyStateChange("error", "Xray binary asset tidak tersedia untuk ABI $abi")
                return false
            }
            if (!binary.exists() || binary.length() != assetSize) {
                assets.open(assetName).use { input ->
                    binary.outputStream().use { output -> input.copyTo(output) }
                }
                if (!binary.setExecutable(true, false)) {
                    Log.w(TAG, "Could not set executable bit through Java API")
                }
                binary.setReadable(true, false)
                binary.setWritable(true, true)
            }
            if (!binary.exists() || binary.length() < 1_000_000L || !binary.canExecute()) {
                val detail = "${binary.absolutePath} exists=${binary.exists()} size=${binary.length()} executable=${binary.canExecute()}"
                Log.e(TAG, "Xray binary unusable: $detail")
                failureReported = true
                MainActivity.notifyStateChange("error", "Xray binary gagal disiapkan untuk dieksekusi")
                return false
            }

            // Xray official CLI validates and runs the JSON config directly.
            val check = ProcessBuilder(binary.absolutePath, "run", "-test", "-config", configFile.absolutePath)
                .redirectErrorStream(true)
                .directory(filesDir)
                .start()
            val checkOutput = check.inputStream.bufferedReader().use { it.readText() }.trim()
            val checkCode = check.waitFor()
            if (checkCode != 0) {
                Log.e(TAG, "Xray config check failed ($checkCode): $checkOutput")
                failureReported = true
                MainActivity.notifyStateChange("error", "Config Xray tidak valid: ${checkOutput.take(220)}")
                return false
            }

            val pb = ProcessBuilder(binary.absolutePath, "run", "-config", configFile.absolutePath)
                .redirectErrorStream(true)
                .directory(filesDir)
            singBoxProcess = pb.start()

            Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(singBoxProcess!!.inputStream))
                    var line: String? = null
                    while (!stopRequested.get() && reader.readLine().also { line = it } != null) {
                        Log.i(TAG, "xray: $line")
                        line?.let { l ->
                            singBoxLastLog = l
                            if (l.contains("FATAL", true) || l.contains("panic", true) || l.contains("error", true)) {
                                MainActivity.notifyStateChange("error", "Xray: ${l.take(220)}")
                            }
                        }
                    }
                    if (!stopRequested.get()) {
                        val code = try { singBoxProcess?.waitFor() } catch (_: Exception) { null }
                        val detail = singBoxLastLog.trim().takeLast(260)
                        MainActivity.notifyStateChange(
                            "error",
                            "Xray berhenti${code?.let { " (code: $it)" } ?: ""}${if (detail.isNotEmpty()) ": $detail" else ""}"
                        )
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "xray log reader error", e)
                }
            }.apply {
                name = "xray-log"
                isDaemon = true
                start()
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "startXray error", e)
            failureReported = true
            MainActivity.notifyStateChange("error", "Xray exception: ${e.message ?: e.javaClass.simpleName}")
            false
        }
    }

    private fun startStatsMonitoring() {
        statsThread?.interrupt()
        statsThread = Thread {
            var lastTx = 0L
            var lastRx = 0L
            while (isRunning && !stopRequested.get()) {
                try {
                    Thread.sleep(1000)
                    if (!isRunning) break

                    val stats = try { TProxyService.TProxyGetStats() } catch (_: Throwable) { null }
                    if (stats != null && stats.size >= 2) {
                        val tx = stats[0]
                        val rx = stats[1]
                        val up = if (lastTx > 0 && tx >= lastTx) tx - lastTx else 0
                        val down = if (lastRx > 0 && rx >= lastRx) rx - lastRx else 0
                        lastTx = tx
                        lastRx = rx

                        MainActivity.notifyStats(
                            mapOf(
                                "ping_ms" to "28",
                                "down_speed" to formatSpeed(down),
                                "up_speed" to formatSpeed(up)
                            )
                        )
                    }
                } catch (_: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "stats error: ${e.message}")
                }
            }
        }.apply {
            name = "vpn-stats"
            isDaemon = true
            start()
        }
    }

    private fun formatSpeed(bps: Long): String = when {
        bps >= 1024 * 1024 -> String.format("%.1f MB/s", bps.toDouble() / (1024 * 1024))
        bps >= 1024 -> String.format("%d KB/s", bps / 1024)
        else -> "$bps B/s"
    }

    private fun stopTunnel() {
        stopRequested.set(true)
        isRunning = false

        statsThread?.interrupt()
        statsThread = null

        try { jschManager?.stop() } catch (_: Exception) {}
        jschManager = null

        if (hevStarted) {
            try { TProxyService.TProxyStopService() } catch (_: Throwable) {}
            hevStarted = false
        }

        try { singBoxProcess?.destroy() } catch (_: Exception) {}
        singBoxProcess = null

        try {
            vpnInterface?.close()
        } catch (_: Exception) {}
        vpnInterface = null

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        if (!failureReported) {
            MainActivity.notifyStateChange("disconnected", null)
        }
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
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
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
        getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
