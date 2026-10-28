package com.izz.tunneling.injector

import android.net.VpnService
import android.os.Build
import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.*

class SshTunnelInjector(
    private val vpnService: VpnService,
    private val remoteServer: String,
    private val remotePort: Int,
    private val enableSsl: Boolean,
    private val sni: String,
    private val enablePayload: Boolean,
    private val payload: String,
    private val enableProxy: Boolean,
    private val remoteProxy: String,
    private val onLog: (String) -> Unit
) {
    companion object {
        const val TAG = "SshTunnelInjector"
    }

    private var serverSocket: ServerSocket? = null
    private var listenThread: Thread? = null
    private val isRunning = AtomicBoolean(false)
    private val activeSockets = mutableListOf<Socket>()

    fun start(): Int {
        serverSocket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        isRunning.set(true)
        val port = serverSocket!!.localPort

        listenThread = Thread {
            Log.i(TAG, "SSH Tunnel Injector listening on 127.0.0.1:$port")
            while (isRunning.get()) {
                try {
                    val clientSocket = serverSocket?.accept() ?: break
                    synchronized(activeSockets) { activeSockets.add(clientSocket) }
                    Thread {
                        handleClient(clientSocket)
                    }.apply {
                        name = "ssh-injector-client"
                        isDaemon = true
                        start()
                    }
                } catch (e: Exception) {
                    if (!isRunning.get()) break
                }
            }
        }.apply {
            name = "ssh-injector-listener"
            isDaemon = true
            start()
        }

        return port
    }

    private fun handleClient(clientSocket: Socket) {
        var targetSocket: Socket? = null
        try {
            val targetHost: String
            val targetPort: Int

            if (enableProxy && remoteProxy.isNotBlank()) {
                val parts = remoteProxy.split(":")
                targetHost = parts[0].trim()
                targetPort = if (parts.size > 1) parts[1].trim().toIntOrNull() ?: 8080 else 8080
                onLog("SSH Inject: Menghubungkan ke Remote Proxy $targetHost:$targetPort...")
            } else {
                targetHost = remoteServer
                targetPort = remotePort
                onLog("SSH Inject: Menghubungkan ke $targetHost:$targetPort...")
            }

            var rawSocket = Socket()
            // Critical: protect socket so packets route through physical network, not VPN TUN
            vpnService.protect(rawSocket)
            rawSocket.tcpNoDelay = true
            rawSocket.soTimeout = 15000
            rawSocket.connect(InetSocketAddress(targetHost, targetPort), 12000)

            synchronized(activeSockets) { activeSockets.add(rawSocket) }

            if (enableSsl) {
                val sniHost = if (sni.isNotBlank()) sni.trim() else remoteServer.trim()
                onLog("SSH Inject: SSL Handshake (SNI: $sniHost)...")

                val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
                    override fun getAcceptedIssuers(): Array<X509Certificate>? = null
                    override fun checkClientTrusted(chain: Array<X509Certificate>?, authType: String?) {}
                    override fun checkServerTrusted(chain: Array<X509Certificate>?, authType: String?) {}
                })
                val sc = SSLContext.getInstance("TLS")
                sc.init(null, trustAll, SecureRandom())
                val sslFactory = sc.socketFactory
                val sslSocket = sslFactory.createSocket(rawSocket, targetHost, targetPort, true) as SSLSocket

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    val params = sslSocket.sslParameters
                    params.serverNames = listOf(SNIHostName(sniHost))
                    sslSocket.sslParameters = params
                }
                sslSocket.startHandshake()
                rawSocket = sslSocket
                synchronized(activeSockets) { activeSockets.add(rawSocket) }
                onLog("SSH Inject: SSL Berhasil!")
            }

            if (enablePayload) {
                val sniHost = if (sni.isNotBlank()) sni.trim() else remoteServer.trim()
                var finalPayload = payload.trim()
                if (finalPayload.isBlank()) {
                    finalPayload = "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf][crlf]"
                }

                finalPayload = finalPayload
                    .replace("[crlf]", "\r\n", ignoreCase = true)
                    .replace("[lf]", "\n", ignoreCase = true)
                    .replace("[cr]", "\r", ignoreCase = true)
                    .replace("[host_port]", "$remoteServer:$remotePort", ignoreCase = true)
                    .replace("[host]", sniHost, ignoreCase = true)
                    .replace("[port]", remotePort.toString(), ignoreCase = true)
                    .replace("[ua]", "okhttp/4.9.0", ignoreCase = true)
                    .replace("[protocol]", "HTTP/1.1", ignoreCase = true)

                onLog("SSH Inject: Mengirim HTTP Payload...")
                val out = rawSocket.getOutputStream()
                out.write(finalPayload.toByteArray(Charsets.UTF_8))
                out.flush()

                // Read HTTP response until \r\n\r\n or \n\n
                val `in` = rawSocket.getInputStream()
                val headerBuf = StringBuilder()
                val b = ByteArray(1)
                while (`in`.read(b) != -1) {
                    headerBuf.append(b[0].toInt().toChar())
                    if (headerBuf.endsWith("\r\n\r\n") || headerBuf.endsWith("\n\n")) {
                        break
                    }
                    if (headerBuf.length > 8192) break
                }
                val firstLine = headerBuf.lines().firstOrNull()?.trim() ?: "HTTP/1.1 200 OK"
                onLog("SSH Inject HTTP Status: $firstLine")
            }

            // Remove socket timeout for ongoing SSH session
            rawSocket.soTimeout = 0
            clientSocket.soTimeout = 0

            targetSocket = rawSocket
            onLog("SSH Inject: Terhubung! Menyerahkan koneksi ke Core...")

            // Bidirectional streaming
            val clientIn = clientSocket.getInputStream()
            val clientOut = clientSocket.getOutputStream()
            val targetIn = targetSocket.getInputStream()
            val targetOut = targetSocket.getOutputStream()

            val t1 = Thread {
                try {
                    val buf = ByteArray(16384)
                    var len = 0
                    while (isRunning.get() && clientIn.read(buf).also { len = it } != -1) {
                        targetOut.write(buf, 0, len)
                        targetOut.flush()
                    }
                } catch (_: Exception) {}
            }

            val t2 = Thread {
                try {
                    val buf = ByteArray(16384)
                    var len = 0
                    while (isRunning.get() && targetIn.read(buf).also { len = it } != -1) {
                        clientOut.write(buf, 0, len)
                        clientOut.flush()
                    }
                } catch (_: Exception) {}
            }

            t1.start()
            t2.start()
            t1.join()
            t2.join()

        } catch (e: Exception) {
            onLog("SSH Inject Gagal: ${e.message}")
            Log.e(TAG, "handleClient error", e)
        } finally {
            try { clientSocket.close() } catch (_: Exception) {}
            try { targetSocket?.close() } catch (_: Exception) {}
            synchronized(activeSockets) {
                activeSockets.remove(clientSocket)
                if (targetSocket != null) activeSockets.remove(targetSocket)
            }
        }
    }

    fun stop() {
        isRunning.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        synchronized(activeSockets) {
            for (s in activeSockets) {
                try { s.close() } catch (_: Exception) {}
            }
            activeSockets.clear()
        }
        listenThread = null
    }
}
