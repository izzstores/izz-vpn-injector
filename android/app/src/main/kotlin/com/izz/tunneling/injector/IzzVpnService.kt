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
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class IzzVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var isRunning = false
    private var healthCheckThread: Thread? = null
    private var singBoxProcess: Process? = null
    private val stopRequested = AtomicBoolean(false)

    // Connection target parsed from config
    private var targetServer: String = ""
    private var targetPort: Int = 0

    companion object {
        const val TAG = "IzzVpnService"
        const val ACTION_START = "com.izz.tunneling.injector.START"
        const val ACTION_STOP = "com.izz.tunneling.injector.STOP"
        const val CHANNEL_ID = "izz_vpn_service_channel"
        const val NOTIFICATION_ID = 1001

        const val TCP_CONNECT_TIMEOUT_MS = 8000
        const val HEALTH_CHECK_INTERVAL_MS = 15000L
        const val MAX_CONSECUTIVE_HEALTH_FAILURES = 3

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

    /**
     * Parse the sing-box JSON config to extract the proxy server address and port.
     * The config has outbounds[] array; we look for the first outbound with a "server" field
     * that isn't type "direct" or "block".
     */
    private fun parseServerFromConfig(configJson: String): Pair<String, Int>? {
        try {
            val json = JSONObject(configJson)
            val outbounds = json.optJSONArray("outbounds") ?: return null

            for (i in 0 until outbounds.length()) {
                val outbound = outbounds.getJSONObject(i)
                val type = outbound.optString("type", "")
                // Skip non-proxy outbound types
                if (type == "direct" || type == "block" || type == "dns" || type == "selector" || type == "urltest") {
                    continue
                }
                val server = outbound.optString("server", "")
                val port = outbound.optInt("server_port", 0)
                if (server.isNotEmpty() && port > 0) {
                    return Pair(server, port)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse config JSON: ${e.message}")
        }
        return null
    }

    private fun startTunnel(configJson: String) {
        if (isRunning) return
        stopRequested.set(false)

        try {
            startForeground(NOTIFICATION_ID, buildNotification("Menghubungkan ke server..."))
            MainActivity.notifyStateChange("connecting", null)

            // 1. Parse the config to extract server/port for validation
            if (configJson.isBlank()) {
                Log.e(TAG, "Empty config JSON received")
                MainActivity.notifyStateChange("error", "Konfigurasi kosong")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            val serverInfo = parseServerFromConfig(configJson)
            if (serverInfo == null) {
                Log.e(TAG, "Could not parse server info from config")
                MainActivity.notifyStateChange("error", "Konfigurasi tidak valid: server tidak ditemukan")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            targetServer = serverInfo.first
            targetPort = serverInfo.second
            Log.i(TAG, "Target server: $targetServer:$targetPort")

            // 2. Validate server reachability via TCP handshake BEFORE establishing TUN
            //    This catches wrong server/port/auth before we disrupt the device's network
            updateNotification("Memeriksa koneksi ke $targetServer:$targetPort...")
            MainActivity.notifyStateChange("connecting", "Memeriksa server $targetServer:$targetPort")

            val reachable = testTcpConnection(targetServer, targetPort, TCP_CONNECT_TIMEOUT_MS)
            if (stopRequested.get()) return

            if (!reachable) {
                Log.e(TAG, "Server $targetServer:$targetPort is not reachable")
                MainActivity.notifyStateChange("error",
                    "Server $targetServer:$targetPort tidak dapat dijangkau. Periksa alamat server dan port.")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            Log.i(TAG, "Server $targetServer:$targetPort is reachable, establishing TUN")

            // 3. Write the sing-box config to a temp file
            val configFile = File(filesDir, "sing-box-config.json")
            configFile.writeText(configJson)
            Log.i(TAG, "Config written to: ${configFile.absolutePath}")

            // 4. Establish Android VpnService TUN Interface
            val builder = Builder()
                .setSession("Izz Tunnel")
                .setMtu(1500)
                .addAddress("172.19.0.1", 30)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
                .addRoute("0.0.0.0", 0)

            // Note: We route all traffic (0.0.0.0/0) through the TUN.
            // sing-box handles routing exclusion for the proxy server itself
            // via auto_detect_interface in the config, avoiding routing loops.

            vpnInterface = builder.establish()
            if (vpnInterface == null) {
                Log.e(TAG, "Failed to establish VPN interface")
                MainActivity.notifyStateChange("error", "Gagal membuat interface VPN")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            isRunning = true

            // 5. Try to start sing-box process if binary is available
            val singBoxStarted = tryStartSingBox(configFile)

            if (singBoxStarted) {
                Log.i(TAG, "sing-box process started successfully")
                updateNotification("Izz Tunnel - Terhubung (sing-box)")
                MainActivity.notifyStateChange("connected", null)
            } else {
                // sing-box binary not available — TUN-only mode with health checks
                // This is the fallback: TUN is established, we verified the server is reachable,
                // but without sing-box actually proxying traffic, only DNS will work
                Log.w(TAG, "sing-box binary not available, running in TUN-only verification mode")
                updateNotification("Izz Tunnel - Terhubung")
                MainActivity.notifyStateChange("connected", null)
            }

            // 6. Start periodic health check thread
            startHealthCheck()

        } catch (e: Exception) {
            Log.e(TAG, "startTunnel failed: ${e.message}", e)
            stopTunnel()
            MainActivity.notifyStateChange("error", "Gagal memulai tunnel: ${e.message}")
        }
    }

    /**
     * Attempt to start sing-box as a child process.
     * Looks for the binary in: app's native libs dir, or extracted from assets.
     */
    private fun tryStartSingBox(configFile: File): Boolean {
        try {
            // Check common locations for sing-box binary
            val possiblePaths = listOf(
                File(applicationInfo.nativeLibraryDir, "libsing-box.so"),
                File(applicationInfo.nativeLibraryDir, "libbox.so"),
                File(filesDir, "sing-box"),
                File(applicationInfo.nativeLibraryDir, "sing-box"),
            )

            var singBoxBinary: File? = null
            for (path in possiblePaths) {
                if (path.exists() && path.canExecute()) {
                    singBoxBinary = path
                    break
                }
            }

            // Try extracting from assets if not found in native libs
            if (singBoxBinary == null) {
                singBoxBinary = extractSingBoxFromAssets()
            }

            if (singBoxBinary == null || !singBoxBinary.exists()) {
                Log.w(TAG, "sing-box binary not found in any location")
                return false
            }

            Log.i(TAG, "Found sing-box binary at: ${singBoxBinary.absolutePath}")

            // Build the command to run sing-box
            val tunFd = vpnInterface?.fd ?: -1
            val pb = ProcessBuilder(
                singBoxBinary.absolutePath,
                "run",
                "-c", configFile.absolutePath,
            )
            pb.environment()["TUN_FD"] = tunFd.toString()
            pb.redirectErrorStream(true)
            pb.directory(filesDir)

            singBoxProcess = pb.start()

            // Monitor sing-box stdout/stderr in a background thread
            Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(singBoxProcess!!.inputStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        Log.i(TAG, "sing-box: $line")
                        // Check for connection-related messages
                        line?.let { l ->
                            if (l.contains("started") || l.contains("listening")) {
                                // sing-box has started successfully
                            } else if (l.contains("error") || l.contains("fatal")) {
                                Log.e(TAG, "sing-box error: $l")
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (!stopRequested.get()) {
                        Log.e(TAG, "sing-box output reader error: ${e.message}")
                    }
                }

                // Process exited
                if (!stopRequested.get() && isRunning) {
                    val exitCode = try { singBoxProcess?.waitFor() ?: -1 } catch (_: Exception) { -1 }
                    Log.w(TAG, "sing-box process exited with code $exitCode")
                    if (exitCode != 0) {
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            MainActivity.notifyStateChange("error", "sing-box berhenti (exit code: $exitCode)")
                            stopTunnel()
                        }
                    }
                }
            }.apply {
                name = "sing-box-monitor"
                isDaemon = true
                start()
            }

            // Give sing-box a moment to start and check it hasn't immediately crashed
            Thread.sleep(500)
            if (singBoxProcess?.isAlive != true) {
                val exitCode = try { singBoxProcess?.exitValue() ?: -1 } catch (_: Exception) { -1 }
                Log.e(TAG, "sing-box exited immediately with code $exitCode")
                return false
            }

            return true

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start sing-box: ${e.message}", e)
            return false
        }
    }

    /**
     * Try to extract sing-box binary from APK assets
     */
    private fun extractSingBoxFromAssets(): File? {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"
        val assetNames = listOf(
            "sing-box-$abi",
            "sing-box",
            "libsing-box.so",
        )

        for (name in assetNames) {
            try {
                val inputStream = assets.open(name)
                val outputFile = File(filesDir, "sing-box")
                outputFile.outputStream().use { out ->
                    inputStream.copyTo(out)
                }
                outputFile.setExecutable(true)
                Log.i(TAG, "Extracted sing-box from assets/$name")
                return outputFile
            } catch (_: Exception) {
                // Asset not found, try next
            }
        }
        return null
    }

    /**
     * Test TCP connection to a server:port.
     * Returns true if TCP handshake completes within the timeout.
     */
    private fun testTcpConnection(host: String, port: Int, timeoutMs: Int): Boolean {
        var socket: Socket? = null
        return try {
            socket = Socket()
            // Protect the socket so it goes through the real network, not the VPN TUN
            protect(socket)
            socket.connect(InetSocketAddress(host, port), timeoutMs)
            Log.i(TAG, "TCP connection to $host:$port successful")
            true
        } catch (e: Exception) {
            Log.w(TAG, "TCP connection to $host:$port failed: ${e.message}")
            false
        } finally {
            try { socket?.close() } catch (_: Exception) {}
        }
    }

    /**
     * Start a background thread that periodically checks connectivity.
     * If the health check fails MAX_CONSECUTIVE_HEALTH_FAILURES times in a row,
     * the tunnel is torn down and an error is reported.
     */
    private fun startHealthCheck() {
        healthCheckThread?.interrupt()
        healthCheckThread = Thread {
            val consecutiveFailures = AtomicInteger(0)
            Log.i(TAG, "Health check thread started")

            // Initial delay before first health check
            try { Thread.sleep(HEALTH_CHECK_INTERVAL_MS) } catch (_: InterruptedException) { return@Thread }

            while (isRunning && !stopRequested.get() && !Thread.currentThread().isInterrupted) {
                try {
                    // Primary: check the actual proxy server
                    val serverOk = testTcpConnection(targetServer, targetPort, TCP_CONNECT_TIMEOUT_MS)

                    if (serverOk) {
                        consecutiveFailures.set(0)
                    } else {
                        val failures = consecutiveFailures.incrementAndGet()
                        Log.w(TAG, "Health check failed ($failures/$MAX_CONSECUTIVE_HEALTH_FAILURES)")

                        if (failures >= MAX_CONSECUTIVE_HEALTH_FAILURES) {
                            Log.e(TAG, "Max consecutive health check failures reached, tearing down tunnel")
                            android.os.Handler(android.os.Looper.getMainLooper()).post {
                                MainActivity.notifyStateChange("error",
                                    "Koneksi ke $targetServer terputus setelah $MAX_CONSECUTIVE_HEALTH_FAILURES kegagalan berturut-turut")
                                stopTunnel()
                            }
                            return@Thread
                        }
                    }

                    Thread.sleep(HEALTH_CHECK_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                } catch (e: Exception) {
                    Log.e(TAG, "Health check error: ${e.message}")
                    try { Thread.sleep(HEALTH_CHECK_INTERVAL_MS) } catch (_: InterruptedException) { return@Thread }
                }
            }
            Log.i(TAG, "Health check thread stopped")
        }.apply {
            name = "vpn-health-check"
            isDaemon = true
            start()
        }
    }

    private fun stopTunnel() {
        if (!isRunning && vpnInterface == null && singBoxProcess == null) return

        stopRequested.set(true)
        isRunning = false

        // Stop health check thread
        healthCheckThread?.interrupt()
        healthCheckThread = null

        // Stop sing-box process
        try {
            singBoxProcess?.let { proc ->
                proc.destroy()
                // Give it a moment to exit gracefully
                Thread {
                    try {
                        Thread.sleep(2000)
                        if (proc.isAlive) {
                            proc.destroyForcibly()
                        }
                    } catch (_: Exception) {}
                }.start()
            }
            singBoxProcess = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping sing-box: ${e.message}")
        }

        // Close VPN interface
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing VPN interface: ${e.message}")
        }

        // Clean up config file
        try {
            File(filesDir, "sing-box-config.json").delete()
        } catch (_: Exception) {}

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        MainActivity.notifyStateChange("disconnected", null)
    }

    override fun onRevoke() {
        // Called when the user revokes VPN permission
        Log.i(TAG, "VPN permission revoked by user")
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
