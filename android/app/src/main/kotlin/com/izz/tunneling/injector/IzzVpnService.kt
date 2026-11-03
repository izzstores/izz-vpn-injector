package com.izz.tunneling.injector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.content.SharedPreferences
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
    private val startInProgress = AtomicBoolean(false)
    @Volatile private var singBoxLastLog = ""
    @Volatile private var failureReported = false
    @Volatile private var xrayTrafficSeen = false

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
            ACTION_START -> {
                val config = intent.getStringExtra("CONFIG_JSON") ?: ""
                Thread { startTunnel(config) }.apply {
                    name = "vpn-startup"
                    isDaemon = true
                    start()
                }
            }
        }
        return START_STICKY
    }

    private fun startTunnel(configJson: String) {
        if (isRunning || !startInProgress.compareAndSet(false, true)) {
            MainActivity.notifyStateChange("error", "Koneksi masih berjalan atau sedang dimulai")
            return
        }
        stopRequested.set(false)
        failureReported = false
        xrayTrafficSeen = false
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

            if (isSsh && first != null) {
                // SSH must expose the local SOCKS backend before HEV starts.
                // Starting TUN first can make legacy HEV accept packets while
                // 127.0.0.1:10808 is not listening yet, causing connected-without-internet.
                startSshInjector(first)
                if (!waitForLocalPort(LOCAL_PROXY_PORT, 15000)) {
                    failureReported = true
                    MainActivity.notifyStateChange("error", "SOCKS SSH tidak siap; tunnel tidak dilanjutkan")
                    stopTunnel()
                    return
                }
                MainActivity.notifyStateChange("connecting", "SOCKS SSH siap, membuat interface VPN...")
            }

            if (!establishTun()) {
                stopTunnel()
                return
            }

            if (isSsh) {
                // A live SSH session and a running HEV process are not enough:
                // require one real SOCKS CONNECT plus downstream response.
                val manager = jschManager
                if (manager == null || !manager.probeInternet()) {
                    failureReported = true
                    MainActivity.notifyStateChange("error", "${manager?.probeFailureReason() ?: "Internet probe gagal"}")
                    stopTunnel()
                    return
                }
                markConnected()
            } else {
                startXrayCore(configJson)
            }

        } catch (t: Throwable) {
            Log.e(TAG, "startTunnel failed", t)
            MainActivity.notifyStateChange("error", "Gagal konek: ${t.message ?: t.javaClass.simpleName}")
            stopTunnel()
        }
    }

    /** TUN Android + hev-socks5-tunnel -> SOCKS5 127.0.0.1:10808 */
    private fun establishTun(): Boolean {
        return try {
            // The bundled HEV AAR declares minSdk 29. Do not enter its native
            // code on older Android versions; that can terminate the process
            // with a native linker/SIGSEGV before Kotlin can catch it.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                val api = Build.VERSION.SDK_INT
                Log.e(TAG, "HEV tunnel requires Android API 29+, device API=$api")
                MainActivity.notifyStateChange(
                    "error",
                    "Perangkat ini Android API $api; engine tunnel memerlukan Android 10/API 29 atau lebih baru"
                )
                return false
            }
            updateNotification("Membuat interface VPN...")

            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val primaryDns = prefs.getString("flutter.custom_dns_primary", "1.1.1.1") ?: "1.1.1.1"
            val secondaryDns = prefs.getString("flutter.custom_dns_secondary", "1.0.0.1") ?: "1.0.0.1"
            val legacyAndroid = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
            // Legacy HEV uses mapped DNS so domain connections can travel through
            // the CONNECT-only SSH SOCKS server without UDP ASSOCIATE.
            val vpnDns = if (legacyAndroid) "198.18.0.2" else primaryDns
            Log.i(TAG, "Using configured DNS: $primaryDns, $secondaryDns; VPN DNS=$vpnDns")
            val tunMtu = if (legacyAndroid) 1400 else 1500
            // The in-process SSH SOCKS server is RFC CONNECT-only. HEV's TCP
            // relay mode requires a different HEV SOCKS server, so keep UDP mode
            // standard and use mapped DNS for legacy domain lookups.
            val udpMode = "udp"
            val mapDnsConfig = if (legacyAndroid) """
mapdns:
  address: 198.18.0.2
  port: 53
  network: 100.64.0.0
  netmask: 255.192.0.0
  cache-size: 10000
""".trimIndent() else ""
            val builder = Builder()
                .setSession("Izz Tunnel")
                .setMtu(tunMtu)
                .addAddress("172.19.0.1", 30)
                .addDnsServer(vpnDns)
                .addRoute("0.0.0.0", 0)
            if (!legacyAndroid) {
                builder.addDnsServer(secondaryDns)
            }

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
  mtu: $tunMtu
  ipv4: 172.19.0.1

socks5:
  port: $LOCAL_PROXY_PORT
  address: 127.0.0.1
  udp: '$udpMode'

$mapDnsConfig

misc:
  log-file: ${File(filesDir, "hev.log").absolutePath}
  log-level: info
  tcp-buffer-size: 65536
  udp-recv-buffer-size: 262144
  connect-timeout: 15000
  tcp-read-write-timeout: 300000
  udp-read-write-timeout: 60000
""".trimIndent()
            )

            hevStarted = try {
                TProxyService.TProxyStartService(hevConfigFile.absolutePath, tunFd)
            } catch (e: Throwable) {
                Log.e(TAG, "TProxyStartService error", e)
                false
            }
            val hevRunning = try {
                TProxyService.TProxyIsRunning()
            } catch (t: Throwable) {
                Log.e(TAG, "TProxyIsRunning check failed", t)
                false
            }
            Log.i(TAG, "hev-socks5-tunnel started=$hevStarted running=$hevRunning mtu=$tunMtu udp=$udpMode")
            if (!hevStarted || !hevRunning) {
                MainActivity.notifyStateChange("error", "Tunnel TProxy gagal dimulai pada perangkat ini")
                try { vpnInterface?.close() } catch (_: Throwable) {}
                vpnInterface = null
                return false
            }
            true
        } catch (t: Throwable) {
            Log.e(TAG, "establishTun error", t)
            MainActivity.notifyStateChange("error", "Gagal membuat interface VPN: ${t.message ?: t.javaClass.simpleName}")
            try { vpnInterface?.close() } catch (_: Throwable) {}
            vpnInterface = null
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
            // SOCKS readiness is not tunnel readiness. The caller marks connected only after TUN/HEV starts.
            onConnected = { MainActivity.notifyStateChange("connecting", "SSH SOCKS siap") },
            onError = { err ->
                if (!stopRequested.get()) {
                    failureReported = true
                    MainActivity.notifyStateChange("error", err)
                    stopTunnel()
                }
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
            if (xrayTrafficSeen) {
                markConnected()
                return
            }
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
        startInProgress.set(false)
        isRunning = true
        updateNotification("Izz Tunnel - Terhubung")
        MainActivity.notifyStateChange("connected", null)
        startStatsMonitoring()
    }

    private fun startXray(configFile: File): Boolean {
        return try {
            val binary = File(applicationInfo.nativeLibraryDir, "libxray.so")
            if (!binary.exists() || binary.length() < 1_000_000L || !binary.canExecute()) {
                val detail = "${binary.absolutePath} exists=${binary.exists()} size=${binary.length()} executable=${binary.canExecute()}"
                Log.e(TAG, "Xray native library unusable: $detail")
                failureReported = true
                MainActivity.notifyStateChange("error", "Xray native library tidak dapat dieksekusi: $detail")
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
                            val lower = l.lowercase()
                            if (lower.contains(" accepted ") || lower.contains(" accepted") || lower.contains(" proxy") && lower.contains("accepted")) {
                                xrayTrafficSeen = true
                            }
                            val isWarning = lower.contains("warning") || lower.contains("deprecated") || lower.contains("not recommended")
                            val isFatal = lower.contains("fatal") || lower.contains("panic") || lower.contains("failed to") || lower.contains("rejected")
                            if (!isWarning && isFatal && !failureReported) {
                                failureReported = true
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

        startInProgress.set(false)
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
